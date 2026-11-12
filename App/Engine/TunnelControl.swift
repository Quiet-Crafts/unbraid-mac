import Foundation
import NetworkExtension
import SystemExtensions

/// The system side of the VPN: installs the tunnel extension, owns the single VPN configuration, and starts,
/// reloads and stops the tunnel. The engine itself runs in the extension; see `PacketTunnelProvider`.
@Observable
final class TunnelControl: NSObject, OSSystemExtensionRequestDelegate {
    /// `needsRestart`: macOS finishes installing it at the next restart.
    enum Extension: Equatable { case unknown, installing, needsApproval, needsRestart, ready, failed(String) }

    private(set) var status: NEVPNStatus = .invalid
    private(set) var statusLoaded = false
    /// Why the tunnel last stopped on its own (the extension's start error, macOS turning it off), redacted.
    var lastError: String? { disconnectReason.text }
    private var disconnectReason = DisconnectReason()
    /// The revision (as `revisions()` reports it) of the configuration last swapped in or confirmed running here; nil
    /// while a change is under way or its outcome unknown. Another start since (Connect on Demand) runs another one.
    private(set) var applied: String?
    var connectedSince: Date? { manager?.connection.connectedDate }
    private(set) var ext: Extension = .unknown
    /// Connect on Demand is wanted but off: the extension couldn't seal the configuration it runs.
    private(set) var onDemandUnavailable = false
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var loading: Task<Void, Error>?
    var onStatusChange: (() -> Void)?
    /// Called once the extension is active; `replaced` when this launch swapped in a new version (an update), which
    /// macOS does by stopping the running tunnel.
    var onReady: ((_ replaced: Bool) -> Void)?
    private var replaced = false
    /// How many replacements this launch began (approved swaps in a new version): names the one under way.
    private(set) var replacements = 0

    struct Profile: Equatable {
        var killSwitch: Bool
        var lan: Bool
        var onDemand: Bool

        /// What shapes the running tunnel: Connect on Demand only decides who starts it.
        var routing: Profile { var p = self; p.onDemand = false; return p }
    }

    var profile: Profile? {
        guard let m = manager, let p = m.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return Profile(killSwitch: p.includeAllNetworks, lan: p.excludeLocalNetworks, onDemand: m.isOnDemandEnabled)
    }

    override init() {
        super.init()
        // Only unbraid's own configuration is loaded, so any status change worth reading is its own.
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Task { try? await initialize() }
    }

    func initialize() async throws {
        _ = try await load()
        refresh(initial: true)
    }

    private func refresh(initial: Bool = false) {
        let previous = status
        status = manager?.connection.status ?? .invalid
        let first = !statusLoaded
        if initial { statusLoaded = true }
        guard initial || previous != status else { return }
        // Only a stop seen this session has a reason worth reading: the one left by an earlier run is old news.
        if status == .disconnected, previous != status, !first, let c = manager?.connection {
            let g = previous == .disconnecting && disconnectReason.pending ? disconnectReason.generation : disconnectReason.begin()
            c.fetchLastDisconnectError { e in
                let text = e.map { Redact.clean(($0 as NSError).localizedDescription) }
                Task { @MainActor in
                    guard self.disconnectReason.finish(text, generation: g) else { return }
                    if let e { Diagnostics.noteStop(e) }
                }
            }
        } else if status == .disconnecting {
            _ = disconnectReason.begin()
        } else {
            disconnectReason.invalidate()
        }
        // Stop ownership is invalidated immediately; only the text waits for the system's answer.
        onStatusChange?()
    }

    /// The reason for this stop, allowing the system at most 300 ms to supply it. A newer connection has no old reason.
    func disconnectError() async -> String? {
        let g = disconnectReason.generation
        let deadline = ContinuousClock.now + .milliseconds(300)
        while disconnectReason.generation == g, disconnectReason.pending, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
        }
        return disconnectReason.generation == g ? disconnectReason.text : nil
    }

    // MARK: System extension

    /// Activates (or replaces with this build's) the tunnel extension. The first time, macOS asks the user to allow it.
    func installExtension() {
        ext = .installing
        let r = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AppGroup.tunnelBundle, queue: .main)
        r.delegate = self
        OSSystemExtensionManager.shared.submitRequest(r)
    }

    /// Release builds never downgrade the root extension (an older signed copy of the app could otherwise bring back an
    /// older engine); debug builds always replace.
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        #if DEBUG
        let action = OSSystemExtensionRequest.ReplacementAction.replace
        #else
        let action: OSSystemExtensionRequest.ReplacementAction = (Int(ext.bundleVersion) ?? 0) >= (Int(existing.bundleVersion) ?? 0) ? .replace : .cancel
        #endif
        let swapped = action == .replace && existing.bundleVersion != ext.bundleVersion
        Task { @MainActor in if swapped { replaced = true; replacements += 1 } }
        return action
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in ext = .needsApproval }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            ext = switch result {
            case .completed: .ready
            case .willCompleteAfterReboot: .needsRestart
            @unknown default: .needsApproval
            }
            if ext == .ready { onReady?(replaced); replaced = false }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        let code = ns.domain == OSSystemExtensionErrorDomain ? OSSystemExtensionError.Code(rawValue: ns.code) : nil
        // A replacement refused on purpose (an older app over a newer extension): the newer extension stays active.
        if code == .requestCanceled {
            Task { @MainActor in ext = .ready }
            return
        }
        let text = code == .unsupportedParentBundleLocation ? "Move unbraid to the Applications folder, then open it from there." : error.localizedDescription
        Task { @MainActor in ext = .failed(text) }
    }

    // MARK: VPN configuration

    /// unbraid's one configuration, created on first use (macOS asks the user to allow adding a VPN).
    private func load() async throws -> NETunnelProviderManager {
        if let m = manager { return m }
        if loading == nil {
            loading = Task {
                self.manager = try await NETunnelProviderManager.loadAllFromPreferences().first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppGroup.tunnelBundle
                } ?? NETunnelProviderManager()
            }
        }
        defer { loading = nil }
        try await loading!.value
        guard let manager else { throw Fail("Could not load the VPN profile") }
        return manager
    }

    /// Writes the profile: kill switch and on-demand come from Settings; LAN stays reachable when allowed.
    func configure(_ profile: Profile) async throws {
        let (killSwitch, lan, onDemand) = (profile.killSwitch, profile.lan, profile.onDemand)
        let m = try await load()
        let existing = m.protocolConfiguration as? NETunnelProviderProtocol
        // What the system holds now, put back in memory if the save fails (memory must not claim what was never saved).
        let before = (killSwitch: existing?.includeAllNetworks ?? false, lan: existing?.excludeLocalNetworks ?? false,
                      rules: m.onDemandRules, onDemand: m.isOnDemandEnabled)
        let p = existing ?? NETunnelProviderProtocol()
        p.providerBundleIdentifier = AppGroup.tunnelBundle
        p.serverAddress = "unbraid"
        p.includeAllNetworks = killSwitch
        p.excludeLocalNetworks = lan
        p.excludeAPNs = false
        // Never enforceRoutes: measured on macOS 27 (WireGuard via the engine, 2026-10-20), it stops all traffic, Direct
        // included, although the handshake completes. The kill switch covers interface-bound leaks instead.
        p.enforceRoutes = false
        // The tailnet's search domain comes with each configuration (`stage`), so a new one needs no restart: an older
        // version's copy here goes (the extension reads it only for a sealed copy that names none).
        p.providerConfiguration = nil
        m.protocolConfiguration = p
        m.localizedDescription = "unbraid"
        m.isEnabled = true
        m.onDemandRules = onDemand ? [NEOnDemandRuleConnect()] : nil
        m.isOnDemandEnabled = onDemand
        do { try await m.saveToPreferences() } catch {
            if let existing {
                existing.includeAllNetworks = before.killSwitch
                existing.excludeLocalNetworks = before.lan
            } else {
                m.protocolConfiguration = nil
            }
            m.onDemandRules = before.rules
            m.isOnDemandEnabled = before.onDemand
            throw error
        }
        try await m.loadFromPreferences()
    }

    /// A configuration the extension holds for one start or reload, named by an unguessable token.
    struct Staged {
        let config: String
        let search: String?
        let persist: Bool
        let token: String
        let revision: String
        let at: ContinuousClock.Instant
    }

    /// Staging failed: nothing changed in the extension, so a running tunnel still runs what it ran.
    struct Unstaged: LocalizedError {
        let errorDescription: String?
        /// Another user's engine runs: it is theirs, so nothing here may stop or change it.
        var foreign = false
    }

    /// Hands [config] to the extension over XPC (code-signed both ways), which checks it and keeps it in memory only, for
    /// a minute. Sealed for on-demand starts once it runs, when [persist]. [search]: the tailnet's search domain, applied
    /// with it ("" for none; see `Compiler.searchDomain`); nil leaves it to the VPN profile, as older versions set it.
    func stage(_ config: String, persist: Bool, search: String? = nil) async throws -> Staged {
        guard let r = await EngineLink.call(timeout: 30, { $0.stageConfig(config, search: search, persist: persist, reply: $1) }) else {
            throw Unstaged(errorDescription: "The connection engine didn't answer. Check that unbraid is allowed in System Settings › General › Login Items & Extensions.")
        }
        if r["foreign"] != nil { throw Unstaged(errorDescription: Ownership.otherUser, foreign: true) }
        guard let token = r["token"], let revision = r["revision"] else {
            // Engine errors can quote the config, keys included: logged redacted, never shown.
            Log.error("stage", detail: Redact.clean(r["error"]))
            Diagnostics.noteRejection(r["error"], config: config)
            throw Unstaged(errorDescription: "The connection engine rejected this setup.")
        }
        return Staged(config: config, search: search, persist: persist, token: token, revision: revision, at: .now)
    }

    /// Another user's engine runs now (it started meanwhile, after this app's staging): theirs, so nothing here may stop
    /// or change it.
    struct Foreign: LocalizedError {
        var errorDescription: String? { Ownership.otherUser }
    }

    /// Whether [error] says another user's engine runs, at staging or after a start.
    static func foreign(_ error: Error) -> Bool { (error as? Unstaged)?.foreign == true || error is Foreign }

    /// Staging again once the tunnel was already changed: its failure is no longer "nothing changed".
    private func restage(_ s: Staged) async throws -> Staged {
        do { return try await stage(s.config, persist: s.persist, search: s.search) } catch let u as Unstaged {
            if u.foreign { throw Foreign() }
            throw Fail(u.errorDescription ?? "")
        }
    }

    /// Starts with a staged configuration. The start options carry only its token: anyone can start the tunnel with
    /// options of their own, and those run the sealed copy. [still] is asked right before the start (staging waits): when
    /// it no longer holds, nothing starts.
    func start(_ staged: Staged, while still: () -> Bool = { true }) async throws -> Staged {
        let m = try await load()
        // One staged before a long wait (macOS asking to allow the VPN) is staged again rather than left to expire.
        let staged = ContinuousClock.now - staged.at < .seconds(40) ? staged : try await restage(staged)
        guard still() else { throw CancellationError() }
        disconnectReason.invalidate()
        try m.connection.startVPNTunnel(options: ["token": staged.token as NSString])
        refresh()
        return staged
    }

    /// Once connected: makes sure the engine runs [staged]. A token that expired before the start leaves the sealed copy
    /// running: the requested one is then swapped in, once, without a restart. Returns whether it is durable (see
    /// `EngineAck.Outcome`).
    func confirm(_ staged: Staged, while still: () -> Bool = { true }) async throws -> Bool {
        func outcome() async throws -> EngineAck.Outcome {
            guard let r = await revisions() else { throw Fail("The tunnel did not answer") }
            // Started meanwhile for another user (their Connect on Demand): not this setup, and not this app's to change.
            if r.foreign { throw Foreign() }
            return EngineAck.outcome(running: r.running, durable: r.durable, revision: staged.revision, persist: staged.persist)
        }
        applied = nil
        if case .runs(let durable) = try await outcome() { applied = staged.revision; return durable }
        let token = try await restage(staged).token
        guard still() else { throw CancellationError() }
        _ = try await send(Data([3]) + Data(token.utf8))
        guard case .runs(let durable) = try await outcome() else { throw Fail("The VPN started without this setup") }
        applied = staged.revision
        return durable
    }

    /// Swaps the running engine's config without dropping the tunnel. A pause must never replace on-demand policy.
    /// False when [persist] was asked but the extension couldn't seal it: it runs, but Connect on Demand can't start it.
    /// [still] as for `start`; when it no longer holds after staging, nothing changed. [search] as for `stage`.
    /// [staged]: told the staged revision before it is sent.
    func reload(config: String, persist: Bool = true, search: String? = nil, while still: () -> Bool = { true },
                staged told: (Staged) -> Void = { _ in }) async throws -> Bool {
        let staged = try await stage(config, persist: persist, search: search)
        guard still() else { throw CancellationError() }
        told(staged)
        applied = nil
        let ack = try await send(Data([3]) + Data(staged.token.utf8))
        applied = staged.revision
        return ack == EngineAck.done
    }

    /// The extension couldn't seal: `withdrawn` when the copy it had is gone too, so nothing starts unattended now.
    struct Unsealed: LocalizedError {
        let errorDescription: String?
        var foreign = false
        var withdrawn = false
        /// No answer in time: it may have been sealed, refused or withdrawn.
        var unanswered = false
    }

    /// Makes [config] the sealed copy Connect on Demand starts, without running it: while paused, what this user blocks
    /// meanwhile must be blocked by an unattended start too. Only while this user's engine runs. Returns the sealed
    /// revision (as `revisions()` reports it). No answer leaves the outcome unknown: `revisions()` tells.
    @discardableResult
    func seal(_ config: String, search: String? = nil) async throws -> String {
        guard let r = await EngineLink.call(timeout: 30, { $0.sealConfig(config, search: search, reply: $1) }) else {
            throw Unsealed(errorDescription: "The connection engine didn't answer", unanswered: true)
        }
        if let durable = r["durable"] { return durable }
        Log.error("seal", detail: Redact.clean(r["error"]))
        throw Unsealed(errorDescription: r["foreign"] != nil ? Ownership.otherUser : "The tunnel couldn't save its configuration",
                       foreign: r["foreign"] != nil, withdrawn: r["invalid"] != nil)
    }

    /// Whether unbraid's VPN configuration exists, read again from the system (the user may have removed it). Loading
    /// never saves one, so this never asks the user to add a VPN. Throws when the system can't say.
    func hasProfile() async throws -> Bool {
        let saved = try await NETunnelProviderManager.loadAllFromPreferences().contains {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppGroup.tunnelBundle
        }
        return saved
    }

    /// Erases the extension's sealed config and Tailscale identity. NetworkExtension authenticates the owning app and can
    /// launch the provider for this message while stopped. Without a VPN configuration there is no session to send it
    /// on, and none is created for it (an erase never asks the user to add a VPN). The extension removes only this user's
    /// Tailscale identity, and stops only this user's engine (see `Ownership`).
    func resetTailscale() async throws {
        guard try await hasProfile() else { throw Fail("No VPN configuration") }
        guard let r = await EngineLink.call({ $0.authorizeReset(reply: $1) }) else { throw Fail("The connection engine didn't answer") }
        // Another user's engine runs: the extension removed this user's identity at once, and their tunnel is theirs.
        if r["done"] != nil { return }
        guard let token = r["token"] else { throw Fail("The connection engine didn't answer") }
        guard try await send(Data([2]) + Data(token.utf8)) == EngineAck.done else { throw Fail("The tunnel did not acknowledge the change") }
    }

    /// The extension's running and sealed revisions, and whether it has a sealed copy anyone's unattended start runs
    /// (`Ownership.revisions`); nil when it didn't answer. This user's credential-free fallback (`sealFallback`) isn't
    /// theirs to start: told as [fallback] instead (no durable revision, nothing startable), and [fallbackRunning] while
    /// their engine runs it.
    func revisions(timeout: Double = 10) async -> Revisions? {
        await EngineLink.call(timeout: timeout) { $0.revisions(reply: $1) }.map(Lifecycle.revisions)
    }

    typealias Revisions = Lifecycle.Revisions

    /// `cleared`: nothing of this user's that could hold a signed-out account is left in the sealed copy (dropped, none
    /// there, or one that can't be read now kept from ever starting as theirs). `foreign`: the copy is another user's,
    /// left as it is. `superseded`: a newer copy of this user's was sealed since it was named, and stays. `suppressed`: it
    /// couldn't be removed, only kept from starting as theirs (still owed). `failed`: no answer, or the extension couldn't
    /// drop it.
    enum Forgot { case cleared, foreign, superseded, suppressed, failed }

    /// What names the sealed copy now (`Ownership.sealing`): [seal] its sealing, told only for a copy that may be this
    /// user's (nil: none, or another user's); [durable] the user's copy an unattended start runs (nil for the fallback,
    /// see `revisions`). [fallback]: the copy is this user's credential-free fallback. Nil when the extension didn't answer.
    struct Sealing: Equatable { var seal: String?; var durable: String?; var fallback = false }

    func sealing() async -> Sealing? {
        await EngineLink.call(timeout: 10) { $0.revisions(reply: $1) }.map {
            let r = Lifecycle.revisions($0)
            return Sealing(seal: $0["seal"], durable: r.durable, fallback: r.fallback)
        }
    }

    /// Seals [config], the credential-free fallback (`Compiler.fallback`), in place of a copy that was removed while Connect
    /// on Demand couldn't be turned off (`PacketTunnelProvider.sealFallback`). Its sealing; nil when not sealed (something
    /// else is sealed, another user's engine runs, a failure, or no answer).
    func sealFallback(_ config: String) async -> String? {
        // The extension seals nothing after 10 s, well before this stops waiting: no answer means none was sealed after.
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        let r = await EngineLink.call(timeout: 15) { $0.sealFallback(config, before: deadline, reply: $1) }
        if r == nil {
            // No answer before the deadline (the connection failed early): the request may still be under way there, so
            // nothing is decided until the extension can't seal it any more. Not cut short by cancellation.
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline) + .milliseconds(100)) { k.resume() }
            }
        }
        if let error = r?["error"] { Log.error("fallback", detail: Redact.clean(error)) }
        return r?["durable"] == nil ? nil : r?["seal"]
    }

    /// Drops the fallback sealed as [seal] once Connect on Demand is off (`PacketTunnelProvider.dropFallback`): true when
    /// it is gone or something else is there now, false when that has to be asked again (a failure, no answer).
    func dropFallback(_ seal: String) async -> Bool {
        switch await EngineLink.call(timeout: 15, { $0.dropFallback(seal, reply: $1) })?["result"] {
        case "ok", "kept": return true
        default: return false
        }
    }

    /// Drops the extension's sealed copy, if it is this user's and still the sealing [expected] names (`sealing`, "none"
    /// for none; see `Ownership.forgetStands`): a drop that arrives or runs late (after a timeout here) never drops a copy
    /// sealed after it, even one with the same content.
    func forgetSealed(_ expected: String) async -> Forgot {
        switch await EngineLink.call(timeout: 15, { $0.forgetSealed(expected, reply: $1) })?["result"] {
        case "ok": return .cleared
        case "foreign": return .foreign
        case "superseded": return .superseded
        case "suppressed": return .suppressed
        default: return .failed
        }
    }

    /// The running tunnel is another user's on this Mac: leave it alone. False when the extension doesn't answer quickly.
    /// Answered without waiting for engine work, so a Disconnect during a start isn't held up.
    func runsForAnotherUser() async -> Bool { await EngineLink.call(timeout: 3) { $0.ownership(reply: $1) }?["foreign"] != nil }

    /// Connect on Demand starts the extension's sealed copy: it is turned on only when that copy is what the user chose.
    func armOnDemand(_ wanted: Bool, durable: Bool) async throws {
        try await setOnDemand(wanted && durable)
        let unavailable = wanted && !durable
        if unavailable && !onDemandUnavailable {
            Notifier.post(title: "Connect on demand unavailable",
                          body: "The tunnel couldn't save its configuration, so macOS can't bring it back on its own. unbraid tries again with the next change.")
        }
        onDemandUnavailable = unavailable
    }

    /// After a failed change: Connect on Demand comes back only if the extension still has a sealed copy to start, and
    /// only while [still] holds once that is known (the question suspends, and a Disconnect may come in meanwhile).
    func restoreOnDemand(while still: () -> Bool) async {
        // Not while another user's engine runs: they own what Connect on Demand would find running.
        guard let r = await revisions(), !r.foreign, r.durable != nil else { return Log.error("on-demand not restored: no sealed configuration") }
        guard still() else { return }
        do { try await setOnDemand(true) } catch { Log.error("on-demand not restored", error: error) }
    }

    /// The extension's answer: [0] done, [1] running but not sealed; anything else is its error.
    private func send(_ data: Data) async throws -> Data {
        guard let session = try await load().connection as? NETunnelProviderSession else { throw Fail("No tunnel session") }
        // NetworkExtension doesn't promise an answer (an extension that dies or hangs mid-message): without a deadline one
        // lost reply would hold every later change, Disconnect included, in the queue for good.
        let reply: Data? = try await withCheckedThrowingContinuation { c in
            let answer = Answer(c)
            do { try session.sendProviderMessage(data) { answer.finish(.success($0)) } } catch { answer.finish(.failure(error)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) { answer.finish(.failure(Fail("The tunnel did not answer"))) }
        }
        guard let reply else { throw Fail("The tunnel did not acknowledge the change") }
        guard reply == Data([0]) || reply == Data([1]) else { throw Fail(String(decoding: reply, as: UTF8.self)) }
        return reply
    }

    /// Whether the VPN profile has Connect on Demand on, read again from the system (another process, System Settings
    /// say, may have changed it); nil when it can't be read.
    func onDemandOn() async -> Bool? {
        guard let m = try? await load() else { return nil }
        // A profile never saved has nothing to read back (and Connect on Demand off).
        if m.protocolConfiguration != nil { do { try await m.loadFromPreferences() } catch { return nil } }
        return m.isOnDemandEnabled
    }

    /// Both protection settings as saved by macOS, or nil when the profile can't be read.
    func protectionProfile() async -> Profile? {
        guard let m = try? await load(), m.protocolConfiguration != nil else { return nil }
        do { try await m.loadFromPreferences() } catch { return nil }
        guard let p = m.protocolConfiguration as? NETunnelProviderProtocol else { return nil }
        return Profile(killSwitch: p.includeAllNetworks, lan: p.excludeLocalNetworks, onDemand: m.isOnDemandEnabled)
    }

    func setOnDemand(_ enabled: Bool) async throws {
        let m = try await load()
        // Read back first: another process (System Settings) may have changed it since this app last did.
        if m.protocolConfiguration != nil { try await m.loadFromPreferences() }
        guard m.isOnDemandEnabled != enabled else { return }
        m.isOnDemandEnabled = enabled
        m.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : nil
        do { try await m.saveToPreferences() } catch {
            // A failed save must not make the next attempt mistake memory for persisted preferences.
            m.isOnDemandEnabled = !enabled
            throw error
        }
        // Saved: a failed read-back says nothing about what was saved.
        try await m.loadFromPreferences()
    }

    /// A stop given up because a newer operation took over after Connect on Demand was already turned off for it.
    struct Overtaken: Error {}

    /// False when the tunnel is another user's and was left alone. [still] is asked after each wait, right before the stop
    /// request: once it no longer holds (a Connect made meanwhile), nothing is stopped: `CancellationError`, or `Overtaken`
    /// when Connect on Demand was turned off already.
    @discardableResult
    func stop(userInitiated: Bool = false, while still: () -> Bool = { true }) async throws -> Bool {
        let m = try await load()
        // Another user's tunnel (fast user switching) is theirs: never stopped, nor its on-demand turned off, from here.
        // An extension that doesn't answer doesn't hold up a stop.
        if await runsForAnotherUser() { return false }
        guard still() else { throw CancellationError() }
        // Only a user's stop disables automatic recovery, and its save must finish before the stop request. A failed save
        // still stops (the caller hears about the save): on-demand may bring the tunnel back.
        if userInitiated {
            do { try await setOnDemand(false); onDemandUnavailable = false } catch {
                guard still() else { throw CancellationError() }
                m.connection.stopVPNTunnel(); refresh(); throw error
            }
            guard still() else { throw Overtaken() }
        }
        m.connection.stopVPNTunnel()
        refresh()
        return true
    }

    /// The status as macOS has it now, read again (a status change not delivered yet included).
    func refreshStatus() -> NEVPNStatus {
        refresh()
        return status
    }

    func waitStopped() async throws {
        for _ in 0..<150 {
            refresh()
            if status == .disconnected || status == .invalid { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Fail("The VPN did not stop")
    }
}

/// The first of a reply and the deadline resumes the waiting change.
private nonisolated final class Answer: @unchecked Sendable {
    private var c: CheckedContinuation<Data?, Error>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Data?, Error>) { self.c = c }
    func finish(_ r: Result<Data?, Error>) { lock.withLock { let k = c; c = nil; return k }?.resume(with: r) }
}
