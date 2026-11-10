import Foundation

/// What the app may ask the extension over XPC. The engine and its command client live in the extension only (the app
/// links no engine): each method runs one libbox command there and answers in plain values. One connection per call
/// or subscription: streams come back through `EngineEventsProtocol`, exported by the app on that connection, and
/// invalidating the connection stops whatever it started.
@objc nonisolated protocol CommandXPCProtocol {
    /// Whether the engine accepts a compiled configuration: nil, or its reason (redacted). Works while stopped.
    func checkConfig(_ json: String, reply: @escaping (String?) -> Void)
    /// Checks a compiled configuration and keeps it for the next start or reload, which name it by the token in the
    /// reply ("token", "revision"; or "error", redacted, with "foreign" when another user's engine runs). Works while
    /// stopped. `search`: the tailnet's search domain for the tunnel's resolver, applied with the configuration (a reload
    /// changes it without a restart); "" for none, nil to keep reading it from the VPN profile as older versions did.
    func stageConfig(_ json: String, search: String?, persist: Bool, reply: @escaping ([String: String]) -> Void)
    /// Seals a configuration as this user's copy for unattended starts without running it (a pause runs another one), while
    /// this user's engine runs. "durable": its revision, sealed. Otherwise "error" (redacted), with "foreign" when
    /// another user's engine runs, and "invalid" when the previous copy was already withdrawn: then nothing starts
    /// unattended until a later seal succeeds.
    func sealConfig(_ json: String, search: String?, reply: @escaping ([String: String]) -> Void)
    /// Seals a configuration that can use no account and lets traffic out as Direct does (`ConfigVet.isFallback`) as this
    /// user's copy, in place of one a sign-out or erase removed while Connect on Demand couldn't be turned off, so what it
    /// starts keeps the Mac online. Never over a copy an unattended start runs, nor over another user's, and not while
    /// another user's engine runs; no engine needed. "durable" and "seal": its revision and sealing. "kept": left as it is.
    /// Otherwise "error" (redacted), with "foreign" when another user's engine runs. Never once [deadline] (system uptime,
    /// `DispatchTime.uptimeNanoseconds`) has passed: the app has given up waiting by then, and may already have found none.
    func sealFallback(_ json: String, before deadline: UInt64, reply: @escaping ([String: String]) -> Void)
    /// Drops this user's fallback once Connect on Demand is off: only the very one sealed as [expected] ("seal" in
    /// `revisions`). "result": "ok", "kept" (anything else is there, or it can't be told) or "failed".
    func dropFallback(_ expected: String, reply: @escaping ([String: String]) -> Void)
    /// The revisions of the configuration the engine runs ("running") and of the sealed copy an unattended start would
    /// run ("durable"), each only when it is this user's; absent otherwise. "foreign": the engine runs for another user on
    /// this Mac. "fallback-running", "fallback-durable": this user's engine runs, or their sealed copy is, the fallback
    /// (`sealFallback`).
    func revisions(reply: @escaping ([String: String]) -> Void)
    /// "foreign" when the engine runs for another user on this Mac; answered at once, never queued behind engine work.
    func ownership(reply: @escaping ([String: String]) -> Void)
    /// A single-use token for one Tailscale reset message ("token"), which removes only what is this user's. While another
    /// user's engine runs, the extension removes this user's own identity at once instead ("done").
    func authorizeReset(reply: @escaping ([String: String]) -> Void)
    /// Drops this user's sealed copy and anything they staged. [expected]: the sealing of it the app last heard of
    /// (`revisions`' "seal", "none" for none): a copy sealed since is newer than the request, and stays. "result": "ok" (dropped,
    /// none, or one that can't be read now and is never started as this user's), "foreign" (the sealed copy is another
    /// user's), "superseded" (a newer copy of theirs is sealed), "suppressed" (not removed, only kept from starting as
    /// theirs: still owed) or "failed".
    func forgetSealed(_ expected: String, reply: @escaping ([String: String]) -> Void)
    /// Connection events and status ticks every `interval` ns (debug builds: engine logs too). False: not subscribed.
    func subscribeStats(interval: Int64, logs: Bool, reply: @escaping (Bool) -> Void)
    /// Tailscale status updates. False: not subscribed.
    func subscribeTailscale(reply: @escaping (Bool) -> Void)
    /// One STUN binding through `outboundTag`: true on the first external address or result, false on an error.
    func stunTest(_ server: String, outboundTag: String, reply: @escaping (Bool) -> Void)
    /// Tailscale changes run one at a time, in the order they arrive, whichever connection sent them; closing the
    /// connection cancels one still waiting for the engine.
    func tailscaleLogout(_ endpointTag: String, reply: @escaping (Bool) -> Void)
    func setTailscaleExitNode(_ endpointTag: String, stableID: String, reply: @escaping (Bool) -> Void)
}

/// The app's side of a subscription: what the engine streams, encoded as `EngineWire` values.
@objc nonisolated protocol EngineEventsProtocol {
    func connectionEvents(_ data: Data)
    func status()
    func logs(_ lines: [String])
    func tailscale(_ data: Data)
    /// The stream ended without being stopped.
    func lost()
}

/// The values streamed from the extension to the app.
nonisolated enum EngineWire {
    struct Events: Codable, Sendable {
        var reset: Bool
        var list: [Event]
    }

    struct Event: Codable, Sendable {
        enum Kind: UInt8, Codable, Sendable { case new, update, closed }
        var kind: Kind
        var id: String
        var deltaUp: Int64
        var deltaDown: Int64
        /// Nil when the engine sent no connection with the event.
        var connection: Connection?
    }

    struct Connection: Codable, Sendable {
        var up: Int64
        var down: Int64
        var path: String
        var chain: [String]
        var inbound: String
        var createdAt: Int64
        var closedAt: Int64
        /// Debug builds only, for the engine trace: network, destination, domain, rule and outbound.
        var trace: String?
    }

    struct Tailscale: Codable, Sendable {
        struct Node: Codable, Sendable {
            var name: String
            var ip: String
            var online: Bool
            var id: String
            /// The exit node in use.
            var exit = false
        }

        /// The node identity in the Tailscale state the extension has sealed for this user: present only once the
        /// state holding the node key is stored for good, and while it is the state the engine runs with.
        struct SealedIdentity: Codable, Sendable, Equatable {
            /// Hex SHA-256 over the user, the control server and the node's public key: the same value means the same
            /// enrolment, for this user and server.
            var id: String
            /// The control server the node is enrolled with, as tsnet records it (Tailscale's own is
            /// "https://controlplane.tailscale.com").
            var control: String
            /// This engine read that identity back from the sealed state (it started, or reloaded, with it), rather
            /// than only writing it.
            var restored: Bool
        }

        var authURL: String?
        var backendState: String
        var suffix: String
        /// Peers offering themselves as exit nodes, sorted by name.
        var nodes: [Node]
        /// The stable id of the exit node in use, also when it isn't among `nodes`; nil for none.
        var exitNode: String?
        var sealed: SealedIdentity?
    }
}

nonisolated extension EngineWire.Tailscale.Node {
    /// `exit` is absent from what an older extension sends: not in use, rather than no status at all.
    init(from decoder: Decoder) throws {
        enum Key: String, CodingKey { case name, ip, online, id, exit }
        let c = try decoder.container(keyedBy: Key.self)
        self.init(name: try c.decode(String.self, forKey: .name), ip: try c.decode(String.self, forKey: .ip), online: try c.decode(Bool.self, forKey: .online),
                  id: try c.decode(String.self, forKey: .id), exit: try c.decodeIfPresent(Bool.self, forKey: .exit) ?? false)
    }
}
