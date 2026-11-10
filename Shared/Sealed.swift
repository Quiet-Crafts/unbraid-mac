import CryptoKit
import Darwin
import Foundation
import Security
import Synchronization

/// Files sealed with AES-GCM under a 256-bit key that lives in the keychain (the user's for the app, the System
/// keychain for the root extension). Nothing secret is ever written in the clear: provider accounts, WireGuard keys,
/// Tailscale's node keys, the engine config.
nonisolated struct Sealed: Sendable {
    let dir: URL
    private let account: String
    /// Tests only: where the key comes from instead of the keychain (nil = a keychain that can't be read right now).
    private let fixed: (@Sendable () -> SymmetricKey?)?

    init(dir: URL, account: String = "storage") {
        self.dir = dir
        self.account = account
        fixed = nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// A store sealed with `key()` instead of the keychain's key, for tests; nil behaves like a keychain that won't answer.
    init(dir: URL, key: @escaping @Sendable () -> SymmetricKey?) {
        self.dir = dir
        account = ""
        fixed = key
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Nil while the keychain can't be read (locked, denied): then nothing opens and nothing is written. Asked again on
    /// each use, so a keychain that becomes available later just works; a found key is kept for the process.
    private var key: SymmetricKey? {
        if let fixed { return fixed() }
        #if DEBUG
        // The smoothness matrix's throwaway copy (App/PerfHarness.swift) never goes near the keychain.
        if getenv("UNBRAID_PERF") != nil { return Self.perfKey }
        #endif
        return Self.cache.withLock { keys in
            if let k = keys[account] { return k }
            let k = Self.key(account)
            keys[account] = k
            return k
        }
    }

    private static let cache = Mutex<[String: SymmetricKey]>([:])
    #if DEBUG
    private static let perfKey = SymmetricKey(size: .bits256)
    #endif

    /// The key can be read right now. A file that won't open while this is false may be perfectly fine.
    var keyAvailable: Bool { key != nil }

    func read(_ name: String) -> Data? {
        guard let key, let blob = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
        return try? AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
    }

    /// Like `read`, but only a file that isn't there is nil: one that can't be opened now (no key, damaged, sealed under
    /// another key) throws, so it is never mistaken for no state at all.
    func open(_ name: String) throws -> Data? {
        let blob: Data
        do { blob = try Data(contentsOf: dir.appending(path: name)) } catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
        guard let key else { throw Fail("The keychain key can't be read") }
        guard let data = try? AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key) else { throw Fail("\(name) can't be opened") }
        return data
    }

    /// Atomic replace with the file and directory synced before success is reported. Nil deletes.
    @discardableResult
    func write(_ name: String, _ data: Data?) -> Bool {
        let url = dir.appending(path: name)
        guard let data else { return (try? FileManager.default.removeItem(at: url)) != nil }
        guard let key, let box = try? AES.GCM.seal(data, using: key).combined else { return false }
        let temporary = dir.appending(path: ".\(name).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try box.write(to: temporary, options: .withoutOverwriting)
            // F_FULLFSYNC: on macOS fsync alone leaves the data in the drive's cache.
            let handle = try FileHandle(forWritingTo: temporary)
            guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0 || fsync(handle.fileDescriptor) == 0 else { try? handle.close(); return false }
            try handle.close()
            guard Darwin.rename(temporary.path, url.path) == 0 else { return false }
            // The rename is the commit: the new data is in place, so a directory that can't be synced is logged, not a
            // failure (reporting one would have a pending deletion take the file that now holds new data).
            let fd = Darwin.open(dir.path, O_RDONLY)
            if fd < 0 || (fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0) { Log.error("sealed: directory not synced", facts: name) }
            if fd >= 0 { Darwin.close(fd) }
            return true
        } catch { return false }
    }

    /// Remove only temporary files left by a sealed write that did not finish: older than [age], so a write still under
    /// way (another writer, or a quitting copy of the app) keeps its file; one renamed or removed meanwhile counts as gone.
    static func sweepTemps(_ dir: URL, olderThan age: TimeInterval = 60, now: Date = .now) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return !FileManager.default.fileExists(atPath: dir.path)
        }
        var ok = true
        for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            let parts = name.dropFirst().dropLast(4).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts.dropLast().joined(separator: ".").isEmpty,
                  UUID(uuidString: String(parts.last!)) != nil else { continue }
            let url = dir.appending(path: name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) >= age else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile {}
            catch { ok = false }
        }
        return ok
    }

    /// Reads, or creates on first use, the keychain item holding this store's key. The app keeps it in the
    /// data-protection keychain under its app group, which never prompts when the app's signature changes (a development
    /// build replaced by a release). The root extension uses the file-based (System) keychain only.
    private static func key(_ account: String) -> SymmetricKey? {
        // Pinned to the file-based keychain: without the flag a query can also reach data-protection items.
        let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.unbraid",
                                     kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: false]
        guard getuid() != 0 else { return find(legacy, create: true) }
        let modern = legacy.merging([kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: AppGroup.id]) { $1 }
        #if DEBUG
        let choice = choose(modern: copy(modern), legacy: copy(legacy), developmentKeys: true)
        #else
        // A release never looks at the file-based item: nothing there is adopted, and nothing falls back to it.
        let choice = choose(modern: copy(modern), legacy: .missing, developmentKeys: false)
        #endif
        switch choice {
        case .use(let k): return k
        case .adopt(let k): _ = add(modern, k); return k
        case .create: let k = SymmetricKey(size: .bits256); return add(modern, k) ? k : nil
        case .fileBased: return find(legacy, create: true)
        case .none: return nil
        }
    }

    enum Lookup { case found(SymmetricKey), missing, failed(OSStatus) }
    enum Choice { case use(SymmetricKey), adopt(SymmetricKey), create, fileBased, none }

    /// What the app does with its lookups. `developmentKeys`, in debug builds (and the unsigned test runs) only: a
    /// development build's key may still be in the file-based keychain, and a test run has no app group. A release never
    /// reads that item: any process running as the user can plant one there, and every file would then be sealed under a
    /// key it knows. `legacy` is read only when a development key may be adopted.
    static func choose(modern: Lookup, legacy: @autoclosure () -> Lookup, developmentKeys: Bool) -> Choice {
        switch modern {
        case .found(let k): return .use(k)
        case .failed(errSecMissingEntitlement) where developmentKeys: return .fileBased
        case .failed: return .none
        case .missing:
            guard developmentKeys else { return .create }
            // Only a key that doesn't exist anywhere is created: a locked or failing keychain must never replace it.
            switch legacy() {
            // Copied, never moved: the old item stays as a backup (deleting it once took the new copy along).
            case .found(let k): return .adopt(k)
            case .missing: return .create
            case .failed: return .none
            }
        }
    }

    private static func copy(_ query: [String: Any]) -> Lookup {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data, data.count == 32 { return .found(SymmetricKey(data: data)) }
        if status == errSecItemNotFound { return .missing }
        Log.error("keychain: key unreadable", facts: "\(status)")
        return .failed(status)
    }

    private static func add(_ query: [String: Any], _ key: SymmetricKey) -> Bool {
        let raw = key.withUnsafeBytes { Data($0) }
        let added = SecItemAdd(query.merging([kSecValueData as String: raw,
                                              kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
        if added != errSecSuccess { Log.error("keychain: key not stored", facts: "\(added)") }
        return added == errSecSuccess
    }

    /// The file-based keychain alone: found, or created only when it doesn't exist.
    private static func find(_ query: [String: Any], create: Bool) -> SymmetricKey? {
        switch copy(query) {
        case .found(let k): return k
        case .missing: let k = SymmetricKey(size: .bits256); return create && add(query, k) ? k : nil
        case .failed: return nil
        }
    }
}
