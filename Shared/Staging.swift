import CryptoKit
import Foundation
import Security
import Synchronization

/// Configurations the app hands the extension over its code-signed XPC channel, each for one start or reload. A start's
/// options aren't authenticated (`scutil --nc start` and SCNetworkConnectionStart pass any dictionary), so all they can
/// carry is the token of a staged configuration: unpredictable, used once, gone within a minute, and kept apart from the
/// XPC connection that staged it (the app closes that as soon as it has the answer).
/// A Tailscale reset is authorised the same way: a token for one purpose is never good for another.
nonisolated final class Staging: Sendable {
    enum Purpose: Sendable { case run, reset }

    struct Entry: Sendable {
        /// ConfigVet's checked copy: what the engine runs (empty for a reset).
        let config: String
        /// The tailnet's search domain for the tunnel's resolver ("" for none; nil: the VPN profile's, as older apps
        /// set it), checked by `Staging.search`.
        let search: String?
        /// Whether it becomes the sealed copy that Connect on Demand starts.
        let persist: Bool
        /// The user whose app staged it.
        let uid: uid_t
        let revision: String
        let purpose: Purpose
        fileprivate let expires: ContinuousClock.Instant
    }

    static let shared = Staging()
    static let lifetime = Duration.seconds(60)
    /// Starts and reloads are serialised in the app: a few pending ones per user and purpose are plenty, and memory stays
    /// bounded. A user's new one pushes out only that user's oldest, never another user's.
    static let capacity = 4

    private struct State {
        var entries: [String: Entry] = [:]
        /// Counts each user's sign-outs and resets: a configuration checked before one is never kept after it.
        var epochs: [uid_t: Int] = [:]
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    /// Taken before checking [uid]'s configuration, and handed to `stage`.
    func epoch(for uid: uid_t) -> Int { state.withLock { $0.epochs[uid, default: 0] } }

    /// Keeps a checked configuration; returns its token and revision. The oldest pending one of the same user and purpose
    /// makes room. Refused if that user signed out or reset after `epoch`.
    func stage(_ config: String, search: String? = nil, persist: Bool, uid: uid_t, epoch: Int, for purpose: Purpose = .run) throws -> (token: String, revision: String) {
        let token = try Self.token(), revision = Self.revision(config, search: search), t = now()
        try state.withLock { s in
            guard s.epochs[uid, default: 0] == epoch else { throw Fail("Reset while checking the configuration") }
            s.entries = s.entries.filter { $0.value.expires > t }
            let mine = s.entries.filter { $0.value.uid == uid && $0.value.purpose == purpose }
            for old in mine.sorted(by: { $0.value.expires < $1.value.expires }).prefix(max(0, mine.count - Self.capacity + 1)) { s.entries[old.key] = nil }
            s.entries[token] = Entry(config: config, search: search, persist: persist, uid: uid, revision: revision, purpose: purpose, expires: t + Self.lifetime)
        }
        return (token, revision)
    }

    /// The entry for `token`, removed: a token works once, for its purpose only, and never after it expired.
    func take(_ token: String, for purpose: Purpose = .run) -> Entry? {
        let t = now()
        return state.withLock { s in
            guard let e = s.entries.removeValue(forKey: token) else { return nil }
            return e.expires > t && e.purpose == purpose ? e : nil
        }
    }

    /// Drops everything [uid] has pending, and whatever of theirs is being checked meanwhile. Other users' stay.
    func clear(uid: uid_t) {
        state.withLock { s in
            s.entries = s.entries.filter { $0.value.uid != uid }
            s.epochs[uid, default: 0] += 1
        }
    }

    /// The one thing a start's options may name. Anything else they carry (a configuration, a persist flag) is ignored.
    static func token(in options: [String: Any]?) -> String? { options?["token"] as? String }

    /// Which configuration runs or is sealed, without naming its contents. A search domain given with it is part of it.
    static func revision(_ config: String, search: String? = nil) -> String {
        SHA256.hash(data: Data((search.map { config + "\nsearch " + $0 } ?? config).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the extension takes [domain] as the tunnel resolver's search domain: a tailnet's domain in canonical form
    /// (lowercase letters, digits and inner hyphens, at least two labels of at most 63, 253 in all, not a public suffix of
    /// the usual country form). The app hands over nothing else (normalised by its compiler, then checked here): short
    /// names would otherwise be looked up under a domain nobody chose.
    static func isSearchDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return domain.utf8.count <= 253 && labels.count >= 2 && domain != "ts.net"
            && labels.allSatisfy { $0.utf8.count <= 63 && $0.wholeMatch(of: /[a-z0-9]([a-z0-9-]*[a-z0-9])?/) != nil }
            && domain.wholeMatch(of: /(co|com|net|org|gov|edu|ac|or|ne|go)\.[a-z]{2}/) == nil
    }

    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failing system RNG must not yield a guessable token: no token at all then.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Fail("No random bytes") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The extension's answers about what it runs, read the same way on both sides.
nonisolated enum EngineAck {
    /// Reload replies: applied (and sealed, if asked), or applied but not sealed. Anything else is an error's text.
    static let done = Data([0])
    static let unsealed = Data([1])

    enum Outcome: Equatable {
        /// The engine runs the requested configuration. `durable`: an unattended start would run it too (when it was
        /// to be sealed), or would at least run a sealed copy (when it wasn't, as for a pause).
        case runs(durable: Bool)
        /// Something else runs, such as the sealed copy after the request's token expired.
        case other
    }

    static func outcome(running: String?, durable: String?, revision: String, persist: Bool) -> Outcome {
        guard running == revision else { return .other }
        return .runs(durable: persist ? durable == revision : durable != nil)
    }
}

/// A call into the engine that must not hold the caller for long: cut off with `cancel` once `seconds` have passed. Nil
/// then, whatever the call returned: it may still take effect.
nonisolated enum Deadline {
    static func run(_ seconds: Double, cancel: @escaping @Sendable () -> Void, _ call: () -> Bool) -> Bool? {
        let fired = Fired()
        let cutOff = DispatchWorkItem {
            fired.set()
            cancel()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: cutOff)
        let result = call()
        cutOff.cancel()
        return fired.value ? nil : result
    }

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.withLock { fired = true } }
        var value: Bool { lock.withLock { fired } }
    }
}

/// The extension runs once for the Mac and serves every user's copy of unbraid: each user's app sees and changes only the
/// engine it started, and only its own Tailscale identity.
nonisolated enum Ownership {
    static let otherUser = "unbraid is connected for another user on this Mac."

    /// Staging (a start, or a reload of the running engine): anyone while nothing runs, otherwise its owner only.
    static func mayStage(_ uid: uid_t, running owner: uid_t?) -> Bool { owner == nil || owner == uid }

    /// Statistics, Tailscale status and changes, and tests through the engine: the running engine's owner only.
    static func mayUse(_ uid: uid_t, running owner: uid_t?) -> Bool { owner == uid }

    /// What `uid` is told about the engine and the sealed copy: revisions of its own only (another user's would show when
    /// they change setup, and their sealed copy is no reason to turn Connect on Demand on here), and "foreign" while the
    /// engine runs for someone else. "startable" whenever there is a sealed copy an unattended start runs, whoever's: with
    /// none of this user's, Connect on Demand still isn't left with nothing to start, so it isn't turned off for them.
    /// [fallback]: the engine runs, and the sealed copy is, the credential-free fallback (`PacketTunnelProvider.sealFallback`):
    /// told as "fallback-running" and "fallback-durable" to every user, whoever's it is: nothing of an account, and another
    /// user must know that what Connect on Demand starts (the Mac's) is no VPN, and that it is nothing to keep it on for.
    static func revisions(_ uid: uid_t, running: (revision: String?, owner: uid_t)?, sealed: (revision: String, owner: uid_t)?,
                          fallback: (running: Bool, sealed: Bool) = (false, false)) -> [String: String] {
        var out: [String: String] = [:]
        if let running, running.owner == uid { out["running"] = running.revision }
        if fallback.running, running?.revision != nil { out["fallback-running"] = "1" }
        if let sealed, sealed.owner == uid { out["durable"] = sealed.revision }
        if fallback.sealed, sealed != nil { out["fallback-durable"] = "1" }
        if sealed != nil { out["startable"] = "1" }
        if !mayStage(uid, running: running?.owner) { out["foreign"] = "1" }
        return out
    }

    /// Whether a drop of `uid`'s sealed copy, asked for while the app knew [expected] as its sealing (`sealing`, or "none"),
    /// still applies to the copy there now ([current], nil when none could be `uid`'s): not once it was sealed again, also
    /// with the same content, so a request that arrives or runs late never drops a copy made after it. Only proof of a
    /// sealing since counts: an id read now that differs from one read then, or one where there was none (no copy that
    /// could be theirs, or one sealed before ids were kept: "unknown"; ids are never removed). An id that couldn't be read
    /// (`unreadableSealing`) or isn't one, then or now, proves nothing, and the drop stands: a signed-out account's copy
    /// never stays for want of it (a newer copy may go with it then, which costs Connect on Demand until the next seal,
    /// never credentials).
    static func forgetStands(expected: String, current: String?) -> Bool {
        guard let current, let now = UUID(uuidString: current) else { return true }
        if expected == "none" || expected == "unknown" { return false }
        guard let then = UUID(uuidString: expected) else { return true }
        return now == then
    }

    static let unreadableSealing = "unreadable"

    /// What names one sealing of the copy to [uid] ("seal" in `revisions`): its sealing's random id, told only when the
    /// copy may be theirs ([seal]: theirs, ownerless, or unreadable now); "unknown" for one sealed before ids were kept
    /// (every sealing since writes its id before the copy, so no newer copy is ever without one); `unreadableSealing`
    /// when its id exists but can't be read ([unreadable]).
    static func sealing(_ uid: uid_t, seal: Seal, id: String?, unreadable: Bool = false) -> String? {
        switch seal {
        case .none: return nil
        case .owner(let o) where o != uid: return nil
        default: return unreadable ? unreadableSealing : id ?? "unknown"
        }
    }

    /// Who the sealed copy belongs to.
    enum Seal: Equatable {
        case none, legacy, unreadable
        case owner(uid_t)
    }

    /// What becomes of the sealed copy when a user signs out or resets (Tailscale included: the copy may hold its key).
    enum SealStep: Equatable {
        case keep
        /// It can't be read now, so whose it is can't be told: it stays, but is never started as this user's (their app
        /// sealing a new one lifts that).
        case suppress
        case drop
    }

    /// What a Tailscale reset by `uid` may remove besides what `forget` does to the sealed copy.
    enum Reset: Equatable {
        /// Another user's engine runs: only `uid`'s own identity, which isn't in use.
        case ownIdentity
        /// Stop the engine (it is `uid`'s, if any) and remove its state.
        case everything
    }

    /// What `uid` does to the sealed copy after signing out of an account it may hold; nil when the copy is someone
    /// else's: theirs to keep. Whose engine runs doesn't matter: nothing done here touches another user's copy or
    /// engine, and a copy of this user's must go even while someone else is connected.
    /// [dropPending]: an earlier drop of this very copy failed (no sealing since): it still goes, also once it can't be
    /// read, rather than being set aside as one whose owner can't be told.
    static func forget(_ uid: uid_t, seal: Seal, dropPending: Bool = false) -> SealStep? {
        if dropPending, seal == .unreadable { return .drop }
        return switch seal {
        case .none: .keep
        case .owner(let o): o == uid ? .drop : nil
        // Nobody can start one an older version sealed: removed rather than left holding credentials.
        case .legacy: .drop
        // Perhaps another user's: never deleted on someone else's behalf, nor kept from starting as theirs.
        case .unreadable: .suppress
        }
    }

    /// What a sign-out's drop answers once [step] was tried ([applied]: it went through). "ok" only when that is done: the
    /// copy removed (a drop), left as it is (none there), or one that can't be read now kept from starting as theirs (a
    /// suppress). A drop that failed and could only be set aside ([suppressed]: never started as theirs) is still owed:
    /// "suppressed", so the app asks again until the file is gone (an ownerless one an older version sealed is never
    /// reclaimed otherwise). "failed" when not even that was done.
    static func forgetResult(step: SealStep, applied: Bool, suppressed: Bool) -> String {
        if applied { return "ok" }
        return step == .drop && suppressed ? "suppressed" : "failed"
    }

    /// Whether [uid]'s fallback (`PacketTunnelProvider.sealFallback`) may take the sealed copy's place: never over one an
    /// unattended start runs ([startable], anyone's), nor over another user's or one that can't be read now (perhaps
    /// another user's); over none, one of [uid]'s that doesn't start (a failed sealing, a fallback whose sealing a crash
    /// interrupted, one kept from starting since they signed out), one an older version sealed for nobody, or one whose
    /// drop failed ([dropPending]: it goes anyway).
    static func mayFallback(_ uid: uid_t, seal: Seal, startable: Bool, dropPending: Bool) -> Bool {
        if startable { return false }
        if dropPending { return true }
        switch seal {
        case .none, .legacy: return true
        case .owner(let o): return o == uid
        case .unreadable: return false
        }
    }

    /// Whether a drop of [uid]'s fallback once Connect on Demand is off applies to the copy there now: only that very
    /// fallback ([expected], the sealing the app was told), still [uid]'s and still one ([fallback]), with an id read now
    /// ([current]). Anything else, or anything that can't be told, stays: it holds no account, so nothing is lost by
    /// keeping it, and a copy sealed since must never go with it.
    static func dropsFallback(_ uid: uid_t, expected: String, current: String?, seal: Seal, fallback: Bool) -> Bool {
        guard fallback, seal == .owner(uid), let current, let now = UUID(uuidString: current), let then = UUID(uuidString: expected) else { return false }
        return now == then
    }

    /// Whether [uid] may seal a configuration without running it (a pause runs another): only while their engine runs
    /// (a failed reload's included: it is still theirs) and is the one that ran when they asked, never once they signed out
    /// or reset since, and never after the sealed copy was withdrawn since (a late answer can't replace a newer copy, nor
    /// bring back one a failed change withdrew). Nil: go ahead; otherwise the reply.
    static func maySeal(_ uid: uid_t, running owner: uid_t?, epoch: (asked: Int, now: Int), engine: (asked: Int, now: Int),
                        seals: (asked: Int, now: Int)) -> [String: String]? {
        guard owner == uid else { return owner == nil ? ["error": "Not running"] : ["error": otherUser, "foreign": "1"] }
        guard epoch.asked == epoch.now else { return ["error": "Signed out while checking the configuration"] }
        guard engine.asked == engine.now, seals.asked == seals.now else { return ["error": "The connection changed meanwhile. Try again."] }
        return nil
    }

    /// The user whose sealed copy goes now: one who signed out while it couldn't be read, now that it can (`forgotten`:
    /// whether that user's marker is there). Anyone else's copy stays.
    static func signedOut(_ seal: Seal, forgotten: (uid_t) -> Bool) -> uid_t? {
        guard case .owner(let o) = seal, forgotten(o) else { return nil }
        return o
    }

    static func reset(_ uid: uid_t, running owner: uid_t?) -> Reset {
        if let owner, owner != uid { return .ownIdentity }
        return .everything
    }
}

/// The sealed copy an unattended start runs, the user whose app staged it and its search domain (see `Staging.Entry`),
/// written as one sealed file.
nonisolated enum SealedPolicy {
    /// [fallback]: the credential-free configuration sealed when Connect on Demand couldn't be turned off
    /// (`PacketTunnelProvider.sealFallback`).
    static func encode(_ config: String, owner: uid_t, search: String? = nil, fallback: Bool = false) -> Data? {
        var o: [String: Any] = ["config": config, "owner": NSNumber(value: owner)]
        o["search"] = search
        if fallback { o["fallback"] = true }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// Nil for anything else, a configuration sealed by an older version (no owner) included: nobody may start that one.
    /// No search domain (sealed by an older version) leaves it to the VPN profile.
    static func decode(_ data: Data) -> (config: String, owner: uid_t, search: String?, fallback: Bool)? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let config = o["config"] as? String,
              let n = o["owner"] as? NSNumber, CFGetTypeID(n) == CFNumberGetTypeID(), let owner = uid_t(exactly: n.int64Value) else { return nil }
        let search = o["search"] as? String
        let fallback = (o["fallback"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        return (config, owner, search.map { $0.isEmpty || Staging.isSearchDomain($0) ? $0 : "" }, fallback)
    }
}

/// The Tailscale node identity in the state the extension seals for a user (tsnet's FileStore JSON: each state key's bytes
/// in base64). The app is told it once that state is stored for good, so it can stop putting the auth key into every
/// configuration (see `EngineWire.Tailscale.sealed`).
nonisolated enum TailscaleIdentity {
    /// The current profile's control server, node public key and stable node id; nil unless the state holds all of it
    /// the way tsnet reads it at a start: the machine key, the current profile listed among the known ones (with the same
    /// node and server), and that profile's node key. A node that never signed in, or signed out, has none; so does a
    /// layout this doesn't know.
    static func parse(_ state: String) -> (control: String, node: Data, nodeID: String)? {
        guard let keys = try? JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any] else { return nil }
        func value(_ k: String) -> Data? { (keys[k] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 } }
        func object(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        guard let machine = value("_machinekey").map({ String(decoding: $0, as: UTF8.self) }), key(machine) != nil,
              let current = value("_current-profile").map({ String(decoding: $0, as: UTF8.self) }), current.hasPrefix("profile-"),
              let prefs = object(value(current)), let control = prefs["ControlURL"] as? String, !control.isEmpty,
              let persist = prefs["Config"] as? [String: Any], let nodeID = persist["NodeID"] as? String, !nodeID.isEmpty,
              let node = (persist["PrivateNodeKey"] as? String).flatMap(key),
              let pair = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: node),
              let known = object(value("_profiles")),
              known.contains(where: { id, p in
                  // Known profiles are looked up by their ID: an entry without one, or filed under another, isn't this one.
                  guard let p = p as? [String: Any], let pid = p["ID"] as? String, !pid.isEmpty, pid == id,
                        p["Key"] as? String == current, p["NodeID"] as? String == nodeID else { return false }
                  let server = p["ControlURL"] as? String ?? ""
                  return server.isEmpty || server == control
              }) else { return nil }
        return (control, pair.publicKey.rawRepresentation, nodeID)
    }

    /// What the extension tells about one engine's Tailscale state, kept apart from the engine so it can be tested.
    struct Tracker {
        let owner: uid_t
        /// The identity to tell and the stable id of the node it names; nil while there is none to tell.
        private(set) var told: (node: String, sealed: EngineWire.Tailscale.SealedIdentity)?
        /// The identity in the state read at the engine's last start or reload.
        private var loaded: String?
        /// A write failed since that read: what is sealed may differ from what runs (a later write can seal an older profile
        /// beside newer keys), so nothing is told until the state is read again.
        private var unsaved = false

        init(owner: uid_t) { self.owner = owner }

        /// The engine read its state from the seal at a start or reload (nil: none, or it couldn't be read).
        mutating func read(_ state: String?) {
            unsaved = false
            let found = identity(state)
            loaded = found?.id
            told = found.map { ($0.node, .init(id: $0.id, control: $0.control, restored: true)) }
        }

        /// The engine's state was sealed.
        mutating func wrote(_ state: String?) {
            let found = unsaved ? nil : identity(state)
            told = found.map { ($0.node, .init(id: $0.id, control: $0.control, restored: $0.id == loaded)) }
        }

        /// Sealing the engine's state failed.
        mutating func failed() {
            unsaved = true
            told = nil
        }

        /// The engine is replaced (a reload) or gone: nothing is told until it has read its state.
        mutating func reset() {
            loaded = nil
            unsaved = false
            told = nil
        }

        private func identity(_ state: String?) -> (id: String, control: String, node: String)? {
            state.flatMap(parse).map { (TailscaleIdentity.id(owner: owner, control: $0.control, node: $0.node), $0.control, $0.nodeID) }
        }
    }

    /// Bound to the user and the control server as well as the node: the app keeps it only for the setup it enrolled.
    static func id(owner: uid_t, control: String, node: Data) -> String {
        let text = "unbraid tailscale identity\n\(owner)\n\(control)\n"
        return SHA256.hash(data: Data(text.utf8) + node).map { String(format: "%02x", $0) }.joined()
    }

    /// A private key as tsnet writes it, "privkey:" and 64 hex digits; nil for the zero key it writes for none.
    private static func key(_ text: String) -> Data? {
        guard text.hasPrefix("privkey:") else { return nil }
        let hex = Array(text.utf8.dropFirst(8))
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            default: nil
            }
        }
        guard hex.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        for i in stride(from: 0, to: 64, by: 2) {
            guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        return bytes.contains { $0 != 0 } ? bytes : nil
    }
}
