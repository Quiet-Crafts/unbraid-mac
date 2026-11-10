import Foundation

/// Tailscale's own state (its backend state), named once so every place that shows it says the same thing. Not a
/// reachability measurement: "connected" means Tailscale says it runs.
nonisolated enum TailscaleStatus: Equatable, Sendable {
    case connected, signInNeeded, awaitingApproval, starting, stopped, unknown

    /// Nil when Tailscale hasn't reported yet.
    init?(_ backendState: String?) {
        guard let backendState else { return nil }
        switch backendState {
        case "Running": self = .connected
        case "NeedsLogin": self = .signInNeeded
        case "NeedsMachineAuth": self = .awaitingApproval
        case "Starting", "NoState": self = .starting
        case "Stopped": self = .stopped
        default: self = .unknown
        }
    }
}
