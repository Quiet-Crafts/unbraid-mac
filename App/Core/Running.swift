import CryptoKit
import Foundation

/// What the engine runs, sealed, so an app restart can take over a running tunnel.
/// A credential file like the others: one a Sign Out of Everything couldn't delete yet is never read back, and one
/// written since leaves the deletion list.
@MainActor enum Running {
    /// [accounts]: provider → `fingerprint` of the account the links were made with; nil in an older version's record.
    nonisolated struct State: Codable, Sendable { var setup: Setup; var links: [String: Link]; var accounts: [String: String]? }

    nonisolated struct SealedState: Codable, Sendable { var setup: Setup; var linked: Set<String>? }

    /// What a record keeps of [s]: an auth key the configuration no longer holds (the node is enrolled) isn't kept either.
    nonisolated static func recorded(_ s: Setup) -> Setup {
        var s = s
        if s.home.tsEnrolled != nil { s.home.tsAuthKey = nil }
        return s
    }
    private static let vault = Sealed(dir: URL.applicationSupportDirectory.appending(path: "unbraid"))

    /// [saved] runs on the main actor after a fresh record is written and its session taint is cleared.
    static func save(_ s: State?, store: Store = .shared, vault: Sealed = vault, saved: @escaping @MainActor () -> Void = {}) {
        let done = store.writing("running.bin")
        let tainted = vault.dir.appending(path: "running-tainted")
        let s = s.map { State(setup: recorded($0.setup), links: $0.links, accounts: $0.accounts) }
        // In the order things happen here (the marker on disk goes only once the record is written).
        stoppedHere = false
        let epoch = taintGeneration
        FileWork.shared.submit {
            let data: Data?
            do { data = try s.map { try JSONEncoder().encode($0) } }
            catch { done(false); return }
            let written = vault.write("running.bin", data)
            // A record written since replaces one a pause must not seal from (`taint`).
            if written, s != nil, FileManager.default.fileExists(atPath: tainted.path) { try? FileManager.default.removeItem(at: tainted) }
            // A record written (or deleted) since is no longer one of a connection seen stopping (`stopped`).
            if written { mark("running-stopped", nil, vault) }
            done(written && s != nil)
            if written, s != nil {
                Task { @MainActor in
                    if epoch == taintGeneration { Self.tainted = false }
                    saved()
                }
            }
        }
    }

    /// Remove a signed-out provider's credentials without changing the setup a pause's baseline names. The read and
    /// write share one file-queue turn, so a newer running record cannot be overwritten with an older snapshot.
    /// False leaves the sign-out owed for retry, including while a tainted record must not be read or rewritten.
    static func prune(_ provider: String, account: String?, store: Store = .shared, vault: Sealed = vault) async -> Bool {
        let blocked = tainted || store.awaitsDeletion("running.bin")
        let accounts = fingerprints(store.accounts)
        let epoch = taintGeneration
        let done = store.writing("running.bin")
        let pruned = await FileWork.shared.read {
            guard FileManager.default.fileExists(atPath: vault.dir.appending(path: "running.bin").path) else { return true }
            guard !blocked, !FileManager.default.fileExists(atPath: vault.dir.appending(path: "running-tainted").path) else { return false }
            guard let data = vault.read("running.bin"), let record = try? JSONDecoder().decode(State.self, from: data) else { return false }
            let clean = pruning(record, provider: provider, account: account, current: accounts)
            guard let encoded = try? JSONEncoder().encode(clean) else { return false }
            let written = vault.write("running.bin", encoded)
            done(written)
            return written
        }
        return pruned && epoch == taintGeneration
    }

    nonisolated static func pruning(_ record: State, provider: String, account: String?, current: [String: String] = [:]) -> State {
        func removes(_ p: String) -> Bool {
            guard provider.isEmpty || p == provider else { return false }
            // A new account's record supersedes the sign-out. An unknown debt keeps links made with today's accounts.
            // Older records have no fingerprint, so their provider links still go.
            if let made = record.accounts?[p] {
                if let account { return made == account }
                if current[p] == made { return false }
            }
            return true
        }
        var clean = record
        let ids = Set(record.setup.routes.filter { !$0.imported && removes($0.loc.provider) }.map(\.id))
        clean.links = record.links.filter { !ids.contains($0.key) }
        clean.accounts = record.accounts.map { $0.filter { !removes($0.key) } }
        return clean
    }

    static func load(store: Store = .shared, vault: Sealed = vault) async -> State? {
        if store.awaitsDeletion("running.bin") { return nil }
        return await FileWork.shared.read { vault.read("running.bin").flatMap { try? JSONDecoder().decode(State.self, from: $0) } }
    }

    /// The record as a takeover needs it: `locked` while it exists but the keychain key can't be read yet (it may be
    /// perfectly fine); `none` when there is none to go by (none written, awaiting deletion, or damaged).
    nonisolated enum Read: Sendable { case locked, none, record(State) }

    static func read(store: Store = .shared, vault: Sealed = vault) async -> Read {
        if store.awaitsDeletion("running.bin") { return .none }
        return await FileWork.shared.read {
            // Asked before opening: a key that answers only after a failed open isn't taken for a damaged file.
            guard vault.keyAvailable else {
                return FileManager.default.fileExists(atPath: vault.dir.appending(path: "running.bin").path) ? .locked : .none
            }
            guard let data = try? vault.open("running.bin"), let s = try? JSONDecoder().decode(State.self, from: data) else { return .none }
            return .record(s)
        }
    }

    /// The setup the extension's sealed copy was made from, once it confirmed sealing it; nil when unknown (nothing
    /// confirmed, a seal that failed, or an older version's). It holds credentials (imported keys, a Tailscale auth key),
    /// so it is a credential file too.
    static func sealed(_ s: Setup?, linked: Set<String>? = nil, store: Store = .shared, vault: Sealed = vault, build: String = build) {
        let done = store.writing("sealed.bin"), s = s.map(recorded)
        FileWork.shared.submit {
            let written = vault.write("sealed.bin", s.flatMap { try? JSONEncoder().encode(SealedState(setup: $0, linked: linked)) })
            mark("sealed-build", written && s != nil ? build : nil, vault)
            done(written && s != nil)
        }
    }

    /// Forgets the record now (not queued): true once there is none. That also finishes a deletion still pending for it.
    static func unsealed(store: Store = .shared, vault: Sealed = vault) async -> Bool {
        let done = store.writing("sealed.bin")
        let gone = await FileWork.shared.read {
            let url = vault.dir.appending(path: "sealed.bin")
            let gone = !FileManager.default.fileExists(atPath: url.path) || vault.write("sealed.bin", nil)
            mark("sealed-build", nil, vault)
            return gone
        }
        done(gone)
        return gone
    }

    /// The connection the record describes was last seen stopping (by macOS, the user in System Settings, another user's
    /// start, or a failure), not running: an update doesn't connect again for it (`Lifecycle.ready`). Cleared by the next
    /// record written. Not secret.
    static func stopped(_ on: Bool, vault: Sealed = vault) {
        // Also kept for the session, should the marker not be written.
        if on { stoppedHere = true }
        FileWork.shared.submit { mark("running-stopped", on ? "1" : nil, vault) }
    }

    private static var stoppedHere = false

    static func stopped(vault: Sealed = vault) async -> Bool {
        if stoppedHere { return true }
        return await FileWork.shared.read { FileManager.default.fileExists(atPath: vault.dir.appending(path: "running-stopped").path) }
    }

    /// This build of the app (`CFBundleVersion`).
    nonisolated static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    /// The build that sealed the copy `sealed` records, while it records one: an update since may be why the extension
    /// refuses it (`Lifecycle.reseal`). Nil when none is on record, or it was sealed by a build that didn't say. Not secret.
    static func sealedBy(store: Store = .shared, vault: Sealed = vault) async -> String? {
        if store.awaitsDeletion("sealed.bin") { return nil }
        return await FileWork.shared.read {
            guard FileManager.default.fileExists(atPath: vault.dir.appending(path: "sealed.bin").path) else { return nil }
            return (try? Data(contentsOf: vault.dir.appending(path: "sealed-build"))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Notes [build] as the one launched last, once per launch: the build launched before it, nil when none that notes it
    /// ran for this user before. [build] itself when that isn't known for sure (the note can't be read, or this launch
    /// couldn't be noted, so a later launch couldn't tell it from the first): nothing then counts as a first launch. Not secret.
    static func launched(_ build: String = build, vault: Sealed = vault) async -> String? {
        await FileWork.shared.read {
            let file = vault.dir.appending(path: "launched-build")
            var previous: String?
            if FileManager.default.fileExists(atPath: file.path) {
                guard let data = try? Data(contentsOf: file) else { return build }
                previous = String(decoding: data, as: UTF8.self)
            }
            return mark("launched-build", build, vault) ? previous : build
        }
    }

    /// Writes [value] to the plain file [name] beside the records, or removes it (nil): true once done. On the file queue only.
    @discardableResult
    private nonisolated static func mark(_ name: String, _ value: String?, _ vault: Sealed) -> Bool {
        let file = vault.dir.appending(path: name)
        do {
            if let value { try Data(value.utf8).write(to: file, options: .atomic) }
            else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return true
        } catch {
            Log.error("marker not recorded", error: error)
            return false
        }
    }

    static func sealed(store: Store = .shared, vault: Sealed = vault) async -> Setup? {
        await sealedState(store: store, vault: vault)?.setup
    }

    nonisolated static func decodeSealed(_ data: Data) -> SealedState? {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(SealedState.self, from: data) { return state }
        // A record (with a setup or link list) that won't read is unknown, never an older bare setup (read as defaults).
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["setup"] != nil || o["linked"] != nil { return nil }
        return (try? decoder.decode(Setup.self, from: data)).map { SealedState(setup: $0, linked: nil) }
    }

    static func sealedState(store: Store = .shared, vault: Sealed = vault) async -> SealedState? {
        if store.awaitsDeletion("sealed.bin") { return nil }
        return await FileWork.shared.read { vault.read("sealed.bin").flatMap(decodeSealed) }
    }

    /// An account's fingerprint (SHA-256, hex): what records and caches keep to tell accounts apart, never the account.
    nonisolated static func fingerprint(_ account: String) -> String {
        SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fingerprints(_ accounts: [String: String]) -> [String: String] { accounts.mapValues(fingerprint) }

    /// The revision (as the extension reports it running) of a deny-all configuration that stands in for a failed change
    /// (`Connection.recover`); nil when none runs. Not secret: a hash. A takeover never stops what runs under it: it holds
    /// no account, and stopping it would let the apps it blocks out.
    static func blocker(_ revision: String?, vault: Sealed = vault) {
        let file = vault.dir.appending(path: "blocking")
        FileWork.shared.submit {
            do {
                if let revision { try Data(revision.utf8).write(to: file, options: .atomic) }
                else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            } catch { Log.error("blocking: not recorded", error: error) }
        }
    }

    static func blocker(vault: Sealed = vault) async -> String? {
        let file = vault.dir.appending(path: "blocking")
        return await FileWork.shared.read { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// The record may hold accounts a sign-out a quit interrupted left behind: a pause never seals from it, until a record
    /// written since replaces it (`save`). Kept in memory for the session too: true once the marker is on disk.
    static func taint(vault: Sealed = vault) async -> Bool {
        taintGeneration += 1
        tainted = true
        let file = vault.dir.appending(path: "running-tainted")
        return await FileWork.shared.read { FileManager.default.createFile(atPath: file.path, contents: Data()) }
    }

    private static var tainted = false
    private static var taintGeneration = 0

    static func tainted(vault: Sealed = vault) async -> Bool {
        if tainted { return true }
        let file = vault.dir.appending(path: "running-tainted")
        return await FileWork.shared.read { FileManager.default.fileExists(atPath: file.path) }
    }

    /// What a pause began from (`Connection.sealPause`): a digest of the setup that ran, so a record left from an older
    /// configuration (one whose replacement failed to be written) is never sealed for it, after a relaunch either. Not
    /// secret. Nil clears it.
    static func pauseBaseline(_ s: Setup?, vault: Sealed = vault) {
        let file = vault.dir.appending(path: "pause-baseline"), value = s.map { Self.digest(recorded($0)) }
        FileWork.shared.submit {
            if let value { try? Data(value.utf8).write(to: file, options: .atomic) }
            else if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func pauseBaseline(vault: Sealed = vault) async -> String? {
        let file = vault.dir.appending(path: "pause-baseline")
        return await FileWork.shared.read { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// Of the setup as a record reads it back (decoding fills in what an encoding leaves out), so the two compare.
    nonisolated static func digest(_ s: Setup) -> String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let read = (try? e.encode(s)).flatMap { try? JSONDecoder().decode(Setup.self, from: $0) } ?? s
        return fingerprint(String(decoding: (try? e.encode(read)) ?? Data(), as: UTF8.self))
    }

    /// Providers whose sign-out still owes a drop of the extension's sealed copy (see `Connection.forgetSealed`), each with
    /// the sealing the drop names ("" until the extension first named it): a retry never drops a copy sealed since.
    /// A new sign-out names its copy afresh. Provider names and sealing ids only, no credentials.
    static func owe(_ provider: String, _ on: Bool, vault: Sealed = vault) {
        updateOwed(vault) { if on { $0[provider] = "" } else { $0[provider] = nil } }
    }

    /// The sealing [provider]'s owed drop names from now on.
    static func owe(_ provider: String, named sealing: String, vault: Sealed = vault) {
        updateOwed(vault) { if $0[provider] != nil { $0[provider] = sealing } }
    }

    private static func updateOwed(_ vault: Sealed, _ change: @escaping @Sendable (inout [String: String]) -> Void) {
        let file = vault.dir.appending(path: "forget-sealed.json")
        FileWork.shared.submit {
            var owed = unsavedOwed[file] ?? readOwed(file)
            change(&owed)
            saveOwed(owed, file)
        }
    }

    /// An owed list a write failed to save, written again as it is: with each settling of the drops (`settleOwed`) and at
    /// quit, not only with the next change, which an unanswered drop never makes. Nothing when none is unsaved.
    static func retryOwed(vault: Sealed = vault) {
        let file = vault.dir.appending(path: "forget-sealed.json")
        FileWork.shared.submit { if let owed = unsavedOwed[file] { saveOwed(owed, file) } }
    }

    /// On the file queue only.
    private nonisolated static func saveOwed(_ owed: [String: String], _ file: URL) {
        do {
            if owed.isEmpty { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
            else { try JSONEncoder().encode(owed).write(to: file, options: .atomic) }
            unsavedOwed[file] = nil
        } catch {
            // Kept, and written again (`retryOwed`, or the next change): a drop owed must survive a quit.
            unsavedOwed[file] = owed
            Log.error("owed drops not recorded", error: error)
        }
    }

    /// The owed list a write failed to save, per file: the next change starts from it. On the file queue only.
    private nonisolated(unsafe) static var unsavedOwed: [URL: [String: String]] = [:]

    /// Provider → the sealing its drop names ("" for none yet). An older version kept the providers only.
    static func owed(vault: Sealed = vault) async -> [String: String] {
        let file = vault.dir.appending(path: "forget-sealed.json")
        return await FileWork.shared.read { unsavedOwed[file] ?? readOwed(file) }
    }

    private nonisolated static func readOwed(_ file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        if let named = try? JSONDecoder().decode([String: String].self, from: data) { return named }
        return Dictionary(((try? JSONDecoder().decode([String].self, from: data)) ?? []).map { ($0, "") }) { a, _ in a }
    }

    /// Connect on Demand has to go off and that isn't saved yet (`Lifecycle.OnDemandOwed`); nil once it is. [done] says
    /// whether it was written, on the main actor. Not secret.
    static func onDemandOwed(_ owed: Lifecycle.OnDemandOwed?, vault: Sealed = vault, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        FileWork.shared.submit {
            let written = mark("ondemand-off", owed?.rawValue, vault)
            Task { @MainActor in done(written) }
        }
    }

    /// Unreadable reads as `hold`: decided again on what the extension has, never left on for want of the file.
    static func onDemandOwed(vault: Sealed = vault) async -> Lifecycle.OnDemandOwed? {
        let file = vault.dir.appending(path: "ondemand-off")
        return await FileWork.shared.read {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return (try? Data(contentsOf: file)).flatMap { Lifecycle.OnDemandOwed(rawValue: String(decoding: $0, as: UTF8.self)) } ?? .hold
        }
    }
}
