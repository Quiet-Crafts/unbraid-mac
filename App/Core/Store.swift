import Foundation
import Observation

/// Everything unbraid persists. Secrets (setup, provider accounts, cached tunnels) are sealed files in Application
/// Support; server catalogues are plain JSON; small flags live in UserDefaults.
@MainActor @Observable
final class Store {
    static let shared = Store()

    private let dir: URL
    private let vault: Sealed
    private let defaults: UserDefaults

    /// What the user configured. Sealed: it can hold imported WireGuard private keys and a Tailscale auth key.
    private(set) var setup: Setup
    /// Signed-in providers: provider id → the opaque account blob its `signIn` returned.
    private(set) var accounts: [String: String]
    /// Set when a change applied but couldn't be written: it would be gone after a restart, so the UI says so.
    var unsaved: Bool { setupUnsaved || accountsUnsaved }
    var unsavedDismissed = false
    private var setupUnsaved = false
    private var accountsUnsaved = false
    @ObservationIgnored private var saveVersions: [String: Int] = [:]
    /// Sealed files that exist but couldn't be opened because the keychain couldn't be read at launch, or that won't
    /// open and couldn't be kept as ".bad". Never written over (an empty setup would replace the real one); read again
    /// once the key is available, and they replace what is in memory, which was never saved.
    @ObservationIgnored private var held: Set<String> = []
    /// Credential files a Sign Out of Everything couldn't delete yet: retried at every launch, never read back. One
    /// written again since holds new data (its old contents are gone with the replace) and leaves the list.
    @ObservationIgnored private var forgetting: Set<String> = []
    /// Bumped by Sign Out of Everything: only writes made after it may take their file off `forgetting`.
    @ObservationIgnored private var forgetEpoch = 0
    @ObservationIgnored private var linksOwed = false
    @ObservationIgnored private var linksVersion = 0

    init(dir: URL = URL.applicationSupportDirectory.appending(path: "unbraid"), vault: Sealed? = nil, defaults: UserDefaults = .standard) {
        let vault = vault ?? Sealed(dir: dir)
        self.dir = dir
        self.vault = vault
        self.defaults = defaults
        _ = Sealed.sweepTemps(dir)
        if defaults.bool(forKey: "linksCleanupPending") {
            let remaining = Self.delete(dir, ["links.bin"])
            if remaining.isEmpty { defaults.removeObject(forKey: "linksCleanupPending") }
            linksOwed = !remaining.isEmpty
        }
        // A Sign Out of Everything whose deletion didn't finish: finish it before anything is read back, and never read
        // back what still couldn't be deleted.
        let pending = Self.pending(defaults)
        let left = pending.isEmpty ? [] : Self.delete(dir, pending)
        Self.persist(left, defaults)
        // Asked once: a keychain that answers only after the reads below must not leave stand-ins unprotected.
        let keyed = vault.keyAvailable
        let readable = { (name: String) in !left.contains(name) }
        var unkept: Set<String> = []
        let loaded = readable("setup.bin") ? Self.load(vault, "setup.bin", Setup.self, dir, keyed: keyed, unkept: &unkept) : nil
        var s = loaded ?? Setup()
        if loaded != nil, s.profileSalt == nil { s.profileSalt = UUID().uuidString }
        setup = s
        accounts = readable("accounts.bin") ? Self.load(vault, "accounts.bin", [String: String].self, dir, keyed: keyed, unkept: &unkept) ?? [:] : [:]
        forgetting = left
        // Files still awaiting deletion are never held for reading back later either.
        if !keyed {
            held = Set(["setup.bin", "accounts.bin"].filter { readable($0) && FileManager.default.fileExists(atPath: dir.appending(path: $0).path) })
        } else { held = unkept }
        // A setup with apps already assigned was made after the disclosure (or before the gate existed).
        disclosed = defaults.bool(forKey: "disclosed") || !s.apps.isEmpty
        if loaded != nil, loaded?.profileSalt == nil { save("setup", setup) }
        // Kept in plain defaults before it moved into the sealed setup: Tailscale's own domain carries over, any other is
        // asked about again (a file any process running as the user can write is no one's consent).
        if held.isEmpty, let legacy = defaults.string(forKey: "tsSuffix") {
            if s.home.tsSuffix == nil, let t = Compiler.tsSuffix(legacy), Compiler.officialTs(s.home), Compiler.tsSuffixIsTailscales(t) { update { $0.home.tsSuffix = t } }
            defaults.removeObject(forKey: "tsSuffix")
        }
    }

    func update(_ f: (inout Setup) -> Void) {
        // The real files first, if they can be opened now: the change then applies to them, never to the stand-in.
        reloadHeld()
        var s = Self.edited(setup, f)
        guard s != setup || s.profileSalt != setup.profileSalt else { return }
        if s.profileSalt == nil { s.profileSalt = UUID().uuidString }
        setup = s
        // A keychain hiccup must not lose the change in memory; the next change writes again.
        save("setup", s)
    }

    /// A setup after a change. Whatever made it (a setting, an import, an undo), a block never runs without the kill switch:
    /// turning it off while an app is blocked keeps the level it had (Internet and home network stays that, not Internet,
    /// which would let blocked apps reach the home network), and only a kill switch that was already off comes on at the
    /// Internet level.
    nonisolated static func edited(_ setup: Setup, _ f: (inout Setup) -> Void) -> Setup {
        var s = setup
        f(&s)
        if s.apps.values.contains(BLOCK), s.prefs.killLevel == .off, setup.prefs.killLevel != .off { s.prefs.killLevel = setup.prefs.killLevel }
        s.requireKillSwitchForBlocks()
        s.profiles = s.saved
        return s
    }

    func account(_ provider: String, _ blob: String?, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        reloadHeld()
        accounts[provider] = blob
        // A sign-out that couldn't be written would come back after a restart: say so like any unsaved change.
        save("accounts", accounts, completion: completion)
        if blob == nil {
            linksOwed = true
            defaults.set(true, forKey: "linksCleanupPending")
            rememberLinks([:])
        }
    }

    /// Still showing stand-ins for files the keychain wouldn't open: nothing saved now would last.
    var isHeld: Bool { !held.isEmpty }

    /// Opens held files once the keychain answers: their contents come back in place of the stand-ins. Returns the
    /// files reloaded, whose stand-in values must not be written after them.
    @discardableResult
    func reloadHeld() -> Set<String> {
        guard !held.isEmpty, vault.keyAvailable else { return [] }
        // With the key read, a file that still won't open is kept as ".bad" before the stand-in may be written over it.
        var migrate = false, unkept: Set<String> = []
        if held.contains("setup.bin"), var s = Self.load(vault, "setup.bin", Setup.self, dir, keyed: true, unkept: &unkept) {
            migrate = s.profileSalt == nil
            if migrate { s.profileSalt = UUID().uuidString }
            setup = s; setupUnsaved = false
        }
        if held.contains("accounts.bin"), let a = Self.load(vault, "accounts.bin", [String: String].self, dir, keyed: true, unkept: &unkept) { accounts = a; accountsUnsaved = false }
        let reloaded = held
        held = unkept
        if migrate { save("setup", setup) }
        return reloaded
    }

    /// Retry the current values, even when the user hasn't changed them again. Dismissal never marks them saved.
    func retrySave() {
        reloadHeld()
        if setupUnsaved { save("setup", setup) }
        if accountsUnsaved { save("accounts", accounts) }
        if linksOwed { rememberLinks([:]) }
        unsavedDismissed = false
    }

    @ObservationIgnored private var saveCleanups: [String: [(Int, @MainActor @Sendable () -> Void)]] = [:]

    /// Run after the next successful write of this file, including a later retry.
    func afterSave(_ name: String, _ cleanup: @escaping @MainActor @Sendable () -> Void) {
        saveCleanups[name, default: []].append(((saveVersions[name] ?? 0) + 1, cleanup))
    }

    /// A stale completion cannot clear a newer failure or report failure for a value already replaced.
    /// Confirm the current setup after a group of changes. A superseded or held write is never acknowledged.
    func confirmSetup(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        if reloadHeld().contains("setup.bin") { completion(false); return }
        if !isHeld, setup.profileSalt == nil { setup.profileSalt = UUID().uuidString }
        save("setup", setup, completion: completion)
    }

    private func save<T: Encodable & Sendable>(_ name: String, _ value: T, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        // `value` was taken from the stand-in: once the real file came back, it is never written over it.
        if reloadHeld().contains("\(name).bin"), !held.contains("\(name).bin") { completion?(false); return }
        unsavedDismissed = false
        // Still held: the real file stays as it is, and the change is reported unsaved.
        if held.contains("\(name).bin") {
            if name == "setup" { setupUnsaved = true } else { accountsUnsaved = true }
            completion?(false)
            return
        }
        saveVersions[name, default: 0] += 1
        let version = saveVersions[name] ?? 0, epoch = forgetEpoch
        if let completion { awaiting[name, default: []].append((version, epoch, completion)) }
        FileWork.shared.submit { [vault, weak self] in
            let encoder = JSONEncoder()
            encoder.userInfo[Setup.includeProfileSalt] = true
            // A value that won't encode is a failed save: nil would delete the file.
            let ok = (try? encoder.encode(value)).map { vault.write("\(name).bin", $0) } ?? false
            if !ok { Log.error("store: not saved", facts: name) }
            Task { @MainActor in
                guard let self else { completion?(false); return }
                if ok { self.written("\(name).bin", epoch) }
                let current = self.saveVersions[name] == version && self.forgetEpoch == epoch
                if current { if name == "setup" { self.setupUnsaved = !ok } else { self.accountsUnsaved = !ok } }
                if ok && epoch == self.forgetEpoch {
                    let ready = (self.saveCleanups[name] ?? []).filter { $0.0 <= version }
                    self.saveCleanups[name]?.removeAll { $0.0 <= version }
                    ready.forEach { $0.1() }
                }
                self.settle(name, version: version, epoch: epoch, ok: ok, current: current)
            }
        }
    }

    /// Changes waiting to hear whether a write holding them reached the disk: (save version, forget epoch, completion).
    @ObservationIgnored private var awaiting: [String: [(Int, Int, @MainActor @Sendable (Bool) -> Void)]] = [:]

    /// Every write holds the whole value, so a later one that succeeds also saves the changes of earlier ones still
    /// waiting (they are told yes); a failed write answers only once nothing newer is on its way. A Sign Out of
    /// Everything in between answers no.
    private func settle(_ name: String, version: Int, epoch: Int, ok: Bool, current: Bool) {
        guard ok || current else { return }
        var left: [(Int, Int, @MainActor @Sendable (Bool) -> Void)] = []
        for w in awaiting[name] ?? [] {
            if w.0 > version { left.append(w) } else { w.2(ok && w.1 == epoch && epoch == forgetEpoch) }
        }
        awaiting[name] = left.isEmpty ? nil : left
    }

    /// For credential files written outside the store (the running tunnel's record): call the result with whether the
    /// write succeeded.
    func writing(_ name: String) -> @Sendable (Bool) -> Void {
        let epoch = forgetEpoch
        return { [weak self] ok in if ok { Task { @MainActor in self?.written(name, epoch) } } }
    }

    /// A Sign Out of Everything couldn't delete it yet: never read back.
    func awaitsDeletion(_ name: String) -> Bool { forgetting.contains(name) }

    /// A file written after the last Sign Out of Everything holds new data: a deletion still pending must not take it.
    private func written(_ name: String, _ epoch: Int) {
        guard epoch == forgetEpoch, forgetting.remove(name) != nil else { return }
        Self.persist(forgetting, defaults)
    }

    // MARK: Server catalogues (public data, sealed so that nothing else can plant one)

    nonisolated private struct CountryCache: Codable {
        var countries: [Country]
        var published: Int64?
    }

    /// A same-user process can write any plain file here, and a location is saved by its country id: a list it planted
    /// could pair a name with another country. Sealed like the rest, an unsealed (older, plain) file is never read.
    nonisolated private static func countryFile(_ provider: String) -> String { "countries-\(provider).bin" }

    private func countryCache(_ provider: String) -> CountryCache? {
        guard let data = vault.read(Self.countryFile(provider)) else { return nil }
        if let cache = try? JSONDecoder().decode(CountryCache.self, from: data) { return cache }
        return (try? JSONDecoder().decode([Country].self, from: data)).map { CountryCache(countries: $0, published: nil) }
    }

    func countries(_ provider: String) -> [Country] { countryCache(provider)?.countries ?? [] }
    func catalogDate(_ provider: String) -> Int64? { countryCache(provider)?.published }

    /// True when the provider's cached catalogue is under a day old (and can be read: with the keychain locked it can't).
    func countriesFresh(_ provider: String) -> Bool {
        guard vault.keyAvailable else { return false }
        let date = try? dir.appending(path: Self.countryFile(provider)).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // A date ahead of the clock (it was wrong when the file was written) says nothing about its age: not fresh.
        return date.map { let age = -$0.timeIntervalSinceNow; return age >= 0 && age < 86_400 } ?? false
    }

    func countries(_ provider: String, _ list: [Country], published: Int64? = nil) {
        let cache = CountryCache(countries: list, published: published)
        FileWork.shared.submit { [dir, vault] in
            guard let data = try? JSONEncoder().encode(cache), vault.write(Self.countryFile(provider), data) else { return }
            try? FileManager.default.removeItem(at: dir.appending(path: "countries-\(provider).json")) // the plain file of older builds
        }
    }

    // MARK: Last good tunnels (hold keys, so sealed)

    /// Last tunnel that worked per "provider|location", used when a provider's API is unreachable.
    func lastLinks() async -> [String: Link] {
        // A file still awaiting deletion holds a signed-out setup's tunnels: never read back.
        if forgetting.contains("links.bin") || linksOwed { return [:] }
        return await FileWork.shared.read { [vault] in Self.load(vault, "links.bin", [String: Link].self, nil) ?? [:] }
    }

    /// Merges `add`, keeping only providers still signed in (a sign-out may have raced a connect). `from` are the
    /// accounts the tunnels were made with: one whose provider has since been signed out, or into another account, is
    /// dropped, not cached for that other account to fall back on.
    func rememberLinks(_ add: [String: Link], from used: [String: String]? = nil) {
        let live = Set(accounts.keys)
        let add = used.map { Self.current(add, made: $0, now: accounts) } ?? add
        // A file still awaiting deletion is never merged back in.
        let stale = forgetting.contains("links.bin"), epoch = forgetEpoch
        linksVersion += 1
        let version = linksVersion, owed = linksOwed
        FileWork.shared.submit { [vault, weak self] in
            let previous = stale ? [:] : Self.load(vault, "links.bin", [String: Link].self, nil) ?? [:]
            let merged = previous.merging(add) { $1 }.filter { live.contains(Self.provider($0.key)) }
            let ok = (try? JSONEncoder().encode(merged)).map { vault.write("links.bin", $0) } ?? false
            if !ok && owed { _ = Self.delete(vault.dir, ["links.bin"]) }
            Task { @MainActor in
                guard let self else { return }
                if ok { self.written("links.bin", epoch) }
                if ok && self.linksVersion == version && self.forgetEpoch == epoch && self.linksOwed {
                    self.linksOwed = false
                    self.defaults.removeObject(forKey: "linksCleanupPending")
                }
            }
        }
    }

    private nonisolated static func provider(_ cacheKey: String) -> String { String(cacheKey.split(separator: "|").first ?? "") }

    /// The tunnels of `add` whose provider is still signed in to the very account they were made with.
    nonisolated static func current(_ add: [String: Link], made: [String: String], now: [String: String]) -> [String: Link] {
        add.filter { let p = provider($0.key); return made[p] != nil && made[p] == now[p] }
    }

    // MARK: Flags

    /// The app owns pause timing. Keep the active flag and optional wall-clock deadline together across restarts.
    var pause: (until: Date?, since: Date, uptime: TimeInterval?, boot: String?)? {
        get {
            guard let saved = defaults.dictionary(forKey: "pause"), saved["active"] as? Bool == true else { return nil }
            return (saved["until"] as? Date, saved["since"] as? Date ?? .now, saved["uptime"] as? TimeInterval, saved["boot"] as? String)
        }
        set {
            if let newValue {
                var saved: [String: Any] = ["active": true, "since": newValue.since]
                saved["until"] = newValue.until
                saved["uptime"] = newValue.uptime; saved["boot"] = newValue.boot
                defaults.set(saved, forKey: "pause")
            } else { defaults.removeObject(forKey: "pause") }
        }
    }

    /// The tailnet's MagicDNS domain in use, learned once Tailscale is signed in: Tailscale's own (*.ts.net) as reported,
    /// any other (a Headscale base domain) only once the user accepted it. Kept in the sealed setup; none while Tailscale
    /// is off. Setting it reports the domain Tailscale names (nil: signed out or another server).
    var tsSuffix: String? {
        get {
            let h = setup.home
            guard setup.tailscale else { return nil }
            return Compiler.trustedStoredSuffix(h)
        }
        set {
            // A sign-out or another server: an old domain still waiting to move out of defaults (a launch with the keychain
            // locked) must not come back with the next launch.
            if newValue == nil { defaults.removeObject(forKey: "tsSuffix") }
            let (accepted, offered) = Self.tsSuffix(reported: newValue, accepted: tsSuffix, official: Compiler.officialTs(setup.home))
            if tsSuffixOffered != offered { tsSuffixOffered = offered }
            update { if $0.home.tsSuffix != accepted { $0.home.tsSuffixConfirmed = false }; $0.home.tsSuffix = accepted }
        }
    }
    /// A domain the control server names that isn't Tailscale's own, waiting for the user's yes (`acceptTsSuffix`).
    private(set) var tsSuffixOffered: String?

    func acceptTsSuffix(_ suffix: String) {
        // Only the domain still on offer: a server that changed it since must be asked about again.
        guard suffix == tsSuffixOffered else { return }
        tsSuffixOffered = nil
        update { $0.home.tsSuffix = suffix; $0.home.tsSuffixConfirmed = true }
    }

    /// Stops using an accepted domain that isn't Tailscale's own; it goes back on offer, so the next report of it asks
    /// again rather than taking it.
    func removeTsSuffix(_ suffix: String) {
        // The real setup first, if it can be opened now (as `update` does): the domain checked is the one the change
        // applies to. Only the domain the user saw: one the server changed since isn't theirs to remove here.
        reloadHeld()
        guard let next = Self.tsSuffix(removing: suffix, accepted: setup.home.tsSuffix, official: Compiler.officialTs(setup.home)) else { return }
        // Offered again only once the setup has stopped using it, never while it is still the accepted domain: saving can
        // bring the real setup back in place of the edited one.
        var removed = false
        update { if $0.home.tsSuffix == suffix { $0.home.tsSuffix = next.accepted; removed = true } }
        if removed, setup.home.tsSuffix == next.accepted { tsSuffixOffered = next.offered }
    }

    /// The accepted and offered domains after the user removes `suffix`; nil when that isn't the accepted domain, or is
    /// Tailscale's own (always used while Tailscale runs).
    nonisolated static func tsSuffix(removing suffix: String, accepted: String?, official: Bool = true) -> (accepted: String?, offered: String?)? {
        guard suffix == accepted, !(official && Compiler.tsSuffixIsTailscales(suffix)) else { return nil }
        return (nil, suffix)
    }

    /// The accepted and offered domains after Tailscale reports one. Another domain than the accepted one is no longer the
    /// tailnet's: it stops being used, and is offered unless it is Tailscale's own.
    nonisolated static func tsSuffix(reported: String?, accepted: String?, official: Bool = true) -> (accepted: String?, offered: String?) {
        guard let r = Compiler.tsSuffix(reported) else { return (nil, nil) }
        if official && Compiler.tsSuffixIsTailscales(r) || r == accepted { return (r, nil) }
        return (nil, r)
    }
    /// The user agreed to M-Lab's terms for speed tests (results, with the exit's IP address, are published).
    var mlabConsent: Bool {
        get { defaults.bool(forKey: "mlabConsent") }
        set { defaults.set(newValue, forKey: "mlabConsent") }
    }
    /// Speed tests run today, for M-Lab's limit of 40 a day per user.
    var testsToday: Int {
        get { defaults.string(forKey: "testsDay") == Self.today ? defaults.integer(forKey: "testsToday") : 0 }
        set { defaults.set(Self.today, forKey: "testsDay"); defaults.set(newValue, forKey: "testsToday") }
    }
    /// A speed test switched Tailscale to another exit node and hasn't switched it back yet.
    var tsTestNode: Bool {
        get { defaults.bool(forKey: "tsTestNode") }
        set { defaults.set(newValue, forKey: "tsTestNode") }
    }
    /// The extension still holds a sealed copy of the setup and a Tailscale identity that a sign-out asked it to erase,
    /// and it hasn't confirmed: every start erases first, and a tunnel still running isn't taken over. Not secret.
    var extensionWipePending: Bool {
        get { defaults.bool(forKey: "extensionWipePending") }
        set { defaults.set(newValue, forKey: "extensionWipePending") }
    }
    /// The user read what unbraid does with the app list and network traffic.
    var disclosed: Bool { didSet { defaults.set(disclosed, forKey: "disclosed") } }
    /// Terms acceptance is separate from the app-list disclosure for existing users.
    var termsAccepted: Bool {
        get { defaults.bool(forKey: "termsAccepted") }
        set { defaults.set(newValue, forKey: "termsAccepted") }
    }
    var tourPending: Bool {
        get { defaults.bool(forKey: "tourPending") }
        set { defaults.set(newValue, forKey: "tourPending") }
    }
    var safetyConnected: Bool {
        get { defaults.bool(forKey: "safetyConnected") }
        set { defaults.set(newValue, forKey: "safetyConnected") }
    }
    var safetyNever: Bool {
        get { defaults.bool(forKey: "safetyNever") }
        set { defaults.set(newValue, forKey: "safetyNever") }
    }
    var safetyUntil: Date { defaults.object(forKey: "safetyUntil") as? Date ?? .distantPast }
    var safetySnoozes: Int { defaults.integer(forKey: "safetySnoozes") }
    nonisolated static func safetyDue(connected: Bool, never: Bool, until: Date, now: Date, onDemand: Bool?, killSwitch: Bool?) -> Bool {
        connected && !never && now >= until && onDemand == false && killSwitch == false
    }
    func snoozeSafety(now: Date = .now) {
        let days = [3, 7, 14][min(max(safetySnoozes, 0), 2)]
        defaults.set(now.addingTimeInterval(Double(days) * 86400), forKey: "safetyUntil")
        defaults.set(safetySnoozes + 1, forKey: "safetySnoozes")
    }

    /// Sign Out of Everything: accounts, setup and cached tunnels go from disk, not only from memory, kept copies of
    /// unreadable files included. Deleting needs no keychain, so a file held unopened since launch goes too. A deletion
    /// that fails is retried at every launch before anything is read; false = not everything is gone yet.
    func forgetAll() async -> Bool {
        forgetEpoch += 1
        saveCleanups.removeAll()
        forgetting = Set(Self.credentialFiles)
        Self.persist(forgetting, defaults)
        held = []
        // Writes already queued run first; their completions no longer report on these values.
        for name in ["setup", "accounts"] { saveVersions[name, default: 0] += 1 }
        setupUnsaved = false; accountsUnsaved = false
        accounts = [:]
        setup = Setup(routes: [], defaultRoute: DIRECT)
        tsSuffix = nil
        let all = forgetting
        linksVersion += 1
        let linksAtForget = linksVersion
        let (failed, tempsRemoved) = await FileWork.shared.read { [dir] in (Self.delete(dir, all), Sealed.sweepTemps(dir)) }
        if linksVersion == linksAtForget && !failed.contains("links.bin") { linksOwed = false; defaults.removeObject(forKey: "linksCleanupPending") }
        // Written again meanwhile (a new sign-in): no longer this deletion's to finish.
        forgetting.formIntersection(failed)
        Self.persist(forgetting, defaults)
        return failed.isEmpty && tempsRemoved
    }

    /// Remove copies of unreadable credential files after the last sign-out, retrying failures at launch.
    func forgetBadCopies() async {
        let bad = Set(Self.credentialFiles.filter { $0.hasSuffix(".bad") })
        forgetting.formUnion(bad)
        Self.persist(forgetting, defaults)
        let failed = await FileWork.shared.read { [dir] in Self.delete(dir, bad) }
        forgetting.subtract(bad.subtracting(failed))
        Self.persist(forgetting, defaults)
    }

    private nonisolated static let forgettingKey = "forgetAllPending"
    /// Everything that holds credentials: the setup, accounts, cached tunnels, the running tunnel's state, the record of
    /// what the extension sealed, and copies kept of unreadable ones.
    nonisolated static let credentialFiles = ["accounts.bin", "setup.bin", "links.bin", "running.bin", "sealed.bin", "airvpn-devices.bin"].flatMap { [$0, "\($0).bad"] }

    /// The files a deletion still has to finish. Earlier versions kept only "something is pending" (true): all of them.
    private nonisolated static func pending(_ defaults: UserDefaults) -> Set<String> {
        if let names = defaults.stringArray(forKey: forgettingKey) { return Set(names).intersection(credentialFiles) }
        return defaults.bool(forKey: forgettingKey) ? Set(credentialFiles) : []
    }

    private nonisolated static func persist(_ names: Set<String>, _ defaults: UserDefaults) {
        if names.isEmpty { defaults.removeObject(forKey: forgettingKey) } else { defaults.set(names.sorted(), forKey: forgettingKey) }
    }

    /// Deletes `names`; returns the ones that couldn't be. Every file is tried, whatever happened to the one before.
    private nonisolated static func delete(_ dir: URL, _ names: Set<String>) -> Set<String> {
        Set(names.filter { name in
            let url = dir.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            do { try FileManager.default.removeItem(at: url); return false } catch { Log.error("store: not deleted", facts: name); return true }
        })
    }

    private static var today: String { Date.now.formatted(.iso8601.year().month().day()) }

    /// Reads a sealed file. One that exists but won't open with a key that could be read (keychain reset, corruption) is
    /// kept as "<name>.bad" rather than silently replaced by defaults on the next write; one that couldn't be kept goes
    /// into [unkept], to be held. A keychain that can't be read says nothing about the file: it is held (see `held`),
    /// never copied.
    private nonisolated static func load<T: Decodable>(_ vault: Sealed, _ name: String, _ type: T.Type, _ dir: URL?, keyed: Bool = false) -> T? {
        var unkept: Set<String> = []
        return load(vault, name, type, dir, keyed: keyed, unkept: &unkept)
    }

    /// [unkept]: files that won't open and couldn't be kept as ".bad", to be held.
    private nonisolated static func load<T: Decodable>(_ vault: Sealed, _ name: String, _ type: T.Type, _ dir: URL?, keyed: Bool,
                                                       unkept: inout Set<String>) -> T? {
        // `keyed` is asked before the read: a found key stays cached, so the read used it, and a key that turns up only
        // after a failed read can't make a healthy file look bad.
        if let data = vault.read(name) {
            if let v = try? SavedDecoding.$strict.withValue(true, operation: { try JSONDecoder().decode(type, from: data) }) { return v }
            // It opens, but a value in it won't read: that value takes its default and the rest is used as it is (its
            // blocks among it), as before; the file is kept as ".bad" before a save may replace it. That copy is a best
            // effort: protection comes first, so a change is saved as before even if it couldn't be made.
            if let v = try? JSONDecoder().decode(type, from: data) {
                if !keepBad(dir, name) { Log.error("store: unreadable value, copy not kept", facts: name) }
                return v
            }
        }
        if keyed, let dir, FileManager.default.fileExists(atPath: dir.appending(path: name).path), !keepBad(dir, name) { unkept.insert(name) }
        return nil
    }

    /// Copies [name] to "<name>.bad"; a ".bad" an earlier incident left gives way, the file that won't read now is the
    /// newer one. False if it couldn't be kept.
    private nonisolated static func keepBad(_ dir: URL?, _ name: String) -> Bool {
        guard let dir else { return true }
        let bad = dir.appending(path: "\(name).bad")
        do {
            if FileManager.default.fileExists(atPath: bad.path) { try FileManager.default.removeItem(at: bad) }
            try FileManager.default.copyItem(at: dir.appending(path: name), to: bad)
            return true
        } catch { return false }
    }
}
