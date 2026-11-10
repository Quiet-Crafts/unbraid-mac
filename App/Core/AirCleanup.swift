import Foundation

/// Created devices stay recorded even when sign-in or sign-out cannot finish.
actor AirCleanup {
    struct Record: Codable, Hashable, Sendable { var key: String; var id: String }
    static let shared = AirCleanup(vault: Sealed(dir: URL.applicationSupportDirectory.appending(path: "unbraid")))
    private let vault: Sealed
    private let file = "airvpn-devices.bin"
    private var inUse: Set<Record> = []
    private var retrying: Set<Record> = []
    private var forgetting = false
    init(vault: Sealed) { self.vault = vault }
    func records() throws -> [Record] {
        let keyed = vault.keyAvailable
        do {
            guard let data = try vault.open(file) else { return [] }
            return try JSONDecoder().decode([Record].self, from: data)
        } catch {
            guard keyed else { throw error }
            let source = vault.dir.appending(path: file)
            let bad = vault.dir.appending(path: "\(file).bad")
            if FileManager.default.fileExists(atPath: bad.path) { try FileManager.default.removeItem(at: bad) }
            try FileManager.default.moveItem(at: source, to: bad)
            Log.error("AirVPN: damaged cleanup journal saved")
            return []
        }
    }
    func add(_ item: Record) throws {
        guard !forgetting else { throw Fail("Signing out of everything") }
        var all = try records()
        if !all.contains(item) { all.append(item) }
        try save(all)
        inUse.insert(item)
    }
    func remove(_ item: Record) throws {
        if forgetting { inUse.remove(item); return }
        let all = try records()
        if all.contains(item) { try save(all.filter { $0 != item }) }
        inUse.remove(item)
    }
    func owed(excluding: Set<Record>) throws -> [Record] {
        let items = try records().filter { !inUse.contains($0) && !retrying.contains($0) && !excluding.contains($0) }
        retrying.formUnion(items)
        return items
    }
    func finishedRetry(_ item: Record) { retrying.remove(item) }
    func release(_ item: Record) { inUse.remove(item) }
    func beginForgetting() throws -> [Record] { forgetting = true; return try records() }
    func resumeWrites() { forgetting = false }
    private func save(_ all: [Record]) throws {
        guard vault.write(file, try JSONEncoder().encode(all)) else { throw Fail("Couldn't save AirVPN device cleanup") }
    }
}
