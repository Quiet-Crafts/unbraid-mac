import Foundation

/// Whether a route's tunnel works while connected, and every sentence the app says about one that stopped answering.
/// Decided here, so the route's page, the sidebar and the menu bar panel only draw it.
nonisolated enum RouteHealth: Equatable, Sendable {
    /// Answers, or isn't checked (the widgets say working only after a check: `Snapshot.Route.ok`).
    case ok
    /// No usable tunnel (`VpnState.blocked`): each place keeps what it shows for that, with the reason.
    case blocked
    /// Its tunnel stopped answering and unbraid can't move it to another server (`VpnState.silent`).
    case silent

    /// Nil while not connected: nothing is known about a tunnel then. A blocked route is blocked, whatever else is said.
    init?(_ id: String, phase: Snapshot.Phase, silent: [String], blocked: [String: String]) {
        guard phase == .on else { return nil }
        self = blocked[id] != nil ? .blocked : silent.contains(id) ? .silent : .ok
    }

    /// The status after a route's facts, in the sidebar's help and in the menu bar panel.
    static let status = "Not answering"
    /// Blames neither side: the checks go through the network the Mac is on to the internet beyond the server, so a
    /// server without internet and a network without it (a hotel's before its sign-in page) fail them alike.
    static let title = "No answer through this server"

    /// What a silent route means for what it carries, where the trouble likely is, and why it stays where it is: "Its 3
    /// apps and 1 website can't connect until it answers again. unbraid can't tell whether the server or this network
    /// is the cause. unbraid keeps checking. It never moves your own server's route somewhere else." `othersAnswer`:
    /// another route's check was answered meanwhile, so the network reaches the internet.
    static func explanation(_ r: Route?, apps: Int, sites: Int, othersAnswer: Bool = false) -> String {
        let carried = [apps > 0 ? "\(apps) app\(apps == 1 ? "" : "s")" : nil, sites > 0 ? Snapshot.websites(sites) : nil].compactMap { $0 }
        let first = carried.isEmpty ? "Nothing can connect through it until it answers again."
            : "Its \(carried.joined(separator: " and ")) can't connect until it answers again."
        let cause = othersAnswer ? " Your other routes answer, so the trouble is at the server or its own connection."
            : " unbraid can't tell whether the server or this network is the cause."
        // An own server has no other server to go to; a pinned server or a dedicated address is the user's choice to change.
        // A file downloaded from a provider (PureVPN's, unused for a while) may simply have expired. Not for a Tailscale exit.
        let expired = r.map { $0.imported && $0.tsExit == nil } == true ? " If this file came from a provider, it may have expired: download a new one." : ""
        let why = r.map { $0.imported ? " It never moves your own server's route somewhere else." + expired : " To use another server, click the pin at the top of its page (Change Location…)." } ?? ""
        return first + cause + " unbraid keeps checking." + why
    }

    /// What a proxy route that doesn't answer says instead of `title` and `explanation`, with Try Again; nil for any other.
    static func proxySilent(_ r: Route?) -> String? {
        r?.socks5 == nil ? nil : "The proxy didn't answer. Traffic on this route is blocked. Check the address and port."
    }
    static let tryAgain = "Try Again"

    /// A Tailscale device as Tailscale lists it: [id] is the stable id its status names the exit in use by.
    struct ExitDevice: Equatable, Sendable {
        var name: String, ip: String, online: Bool, id = ""
    }

    /// Whether a route through the Tailscale exit device at [ip] works, from Tailscale's own list: false while the device is
    /// offline (its apps get no internet), true while it is online and the exit in use ([used], Tailscale's id for it).
    /// Nil when Tailscale says nothing certain: no list yet, the device isn't in it, or it uses another device (a speed
    /// test's switch, or one not made yet), which says nothing about this one.
    static func exitWorks(ip: String, used: String?, nodes: [ExitDevice]) -> Bool? {
        guard let node = nodes.first(where: { $0.ip == ip }) else { return nil }
        if !node.online { return false }
        return !node.id.isEmpty && node.id == used ? true : nil
    }

    /// The Tailscale exit device a route goes through, when Tailscale lists it and says it is offline; nil otherwise.
    static func offlineExit(ip: String?, nodes: [ExitDevice]) -> ExitDevice? {
        guard let ip, exitWorks(ip: ip, used: nil, nodes: nodes) == false else { return nil }
        return nodes.first { $0.ip == ip }
    }

    /// What the route page says about an offline exit device.
    static func offlineExitText(_ device: String) -> String {
        "\(device) is offline: its apps have no internet. Choose another exit."
    }
    static let chooseExit = "Choose Exit…"

    /// The "Check internet access" switch is offered for an own server only: provider routes are always checked, and
    /// Tailscale exits never are.
    static func offersInternetCheck(_ r: Route) -> Bool { r.imported && r.tsExit == nil }
    static let checkTitle = "Check internet access"
    static let checkCaption = "Tests about once a minute that this server reaches the internet. Turn it off for a server that only reaches your home network."
}
