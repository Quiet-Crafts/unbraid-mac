import Foundation

/// Whether a route's tunnel works while connected, and every sentence the app says about one that stopped answering.
/// Decided here, so the route's page, the sidebar and the menu bar panel only draw it.
nonisolated enum RouteHealth: Equatable, Sendable {
    /// Answers, or isn't checked.
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
    static let title = "This server isn't answering"

    /// What a silent route means for what it carries, and why it stays where it is: "Its 3 apps and 1 website can't
    /// connect until it answers again. unbraid keeps checking. It never moves your own server's route somewhere else."
    static func explanation(_ r: Route?, apps: Int, sites: Int) -> String {
        let carried = [apps > 0 ? "\(apps) app\(apps == 1 ? "" : "s")" : nil, sites > 0 ? Snapshot.websites(sites) : nil].compactMap { $0 }
        let first = carried.isEmpty ? "Nothing can connect through it until it answers again."
            : "Its \(carried.joined(separator: " and ")) can't connect until it answers again."
        // An own server has no other server to go to; a pinned server or a dedicated address is the user's choice to change.
        let why = r.map { $0.imported ? " It never moves your own server's route somewhere else." : " Choose Change Location… to use another server." } ?? ""
        return first + " unbraid keeps checking." + why
    }

    /// The "Check internet access" switch is offered for an own server only: provider routes are always checked, and
    /// Tailscale exits never are.
    static func offersInternetCheck(_ r: Route) -> Bool { r.imported && r.tsExit == nil }
    static let checkTitle = "Check internet access"
    static let checkCaption = "Tests every few minutes that this server reaches the internet. Turn it off for a server that only reaches your home network."
}
