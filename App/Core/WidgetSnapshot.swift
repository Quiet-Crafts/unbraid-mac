import Foundation

// What the widgets show, built from the connection and the setup (the routes the tunnel runs while connected).

extension Snapshot {
    /// What the widgets show. While connected, the routes are the ones the tunnel runs, not the edited setup: a change
    /// the engine refused (the previous configuration kept running) must not look applied. Off, paused or connecting,
    /// the edited setup is what Connect or Resume will run, and no route's health is known.
    /// `silent` and `blocked`: routes not answering and routes with no usable tunnel; `tsState`: Tailscale's own state.
    static func make(phase: Phase, since: Date?, pausedUntil: Date?, failed: Bool, edited: Setup, running: Setup?,
                     exits: Int, week: [Day], profileGeneration: String? = nil, protection: Bool? = nil,
                     silent: [String] = [], blocked: Set<String> = [], tsState: String? = nil) -> Snapshot {
        let s = phase == .on ? running ?? edited : edited
        let counts = Dictionary(grouping: s.apps.values, by: { $0 }).mapValues(\.count)
        let sites = Dictionary(grouping: s.sites.values, by: { $0 }).mapValues(\.count)
        let down = blocked.union(silent)
        return Snapshot(
            phase: phase, since: since, pausedUntil: pausedUntil, exits: exits,
            routes: s.activeRoutes.map {
                Route(id: $0.id, name: $0.name, code: $0.code, hue: $0.hue, apps: counts[$0.id] ?? 0, isDefault: $0.id == s.defaultRoute,
                      country: $0.imported ? nil : $0.loc.countryCode, sites: sites[$0.id], ok: phase == .on ? !down.contains($0.id) : nil)
            },
            direct: counts[DIRECT] ?? 0, blocked: counts[BLOCK] ?? 0, directSites: sites[DIRECT], blockedSites: sites[BLOCK], week: week,
            failed: failed ? true : nil, defaultRoute: s.defaultRoute == DIRECT ? DIRECT : nil,
            profiles: edited.profiles.map(\.name), profile: edited.profile, profileGeneration: profileGeneration, protected: protection,
            tailscale: tailscale(s, on: phase == .on && TailscaleStatus(tsState) == .connected))
    }

    /// "TS on" or "HS off": HS for a self-hosted control server; on only while Tailscale itself says it runs. Nil when
    /// Tailscale isn't set up (neither home access through it nor an exit node).
    static func tailscale(_ s: Setup, on: Bool) -> String? {
        s.tailscale ? "\(Compiler.officialTs(s.home) ? "TS" : "HS") \(on ? "on" : "off")" : nil
    }
}
