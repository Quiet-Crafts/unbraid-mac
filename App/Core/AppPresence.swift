import Foundation

/// Whether the apps the setup routes are still on this Mac, and when a missing one loses its route.
///
/// A rescan can miss an app for a while: a reinstall, an updater halfway through, the disk of an app added by hand not
/// mounted. Block is never taken off an app that way: dropping it would quietly unblock the app when it comes back.
/// Nor is Direct: it holds no tunnel open. A VPN route is let go only once the app has been missing, on that route, for
/// several scans and some days, so an uninstalled app doesn't keep a tunnel up for good. Tools (keyed by path) are never
/// dropped, as before.
nonisolated enum AppPresence {
    /// What is remembered of a routed app: how to list it while it is missing, and since when, on which route, it is.
    struct Record: Codable, Hashable, Sendable {
        var name: String
        var path: String
        var missingSince: Date?
        var missedScans = 0
        /// The route it went missing on: moving it starts the wait again.
        var route: String?
        /// Since when scans couldn't tell whether it is here (see `unknownGrace`). Kept through scans that could tell it
        /// is missing, so a disk unplugged again later doesn't get a new month.
        var unavailableSince: Date?
        /// Where it was before, while `path` is in a Trash or translocated by Gatekeeper (see `transient`): `path` still
        /// matches what runs from there, and a copy installed again where it was is matched too.
        var before: String?

        /// Every place it is remembered at.
        var places: [String] { [path, before ?? ""].filter { !$0.isEmpty } }
    }

    static let graceScans = 3
    static let graceTime: TimeInterval = 7 * 24 * 3600
    /// How long scans that can't tell (a disk not mounted, a folder or a bundle that can't be read) hold off a VPN route's
    /// wait: the disk may never be plugged in again, the leftovers of an uninstaller never go, and the route holds a
    /// tunnel. After that they count as missing for it. Block and Direct are never dropped, so they wait for good.
    static let unknownGrace: TimeInterval = 30 * 24 * 3600

    /// One scan's verdict. `seen` holds the routed apps found on this Mac (bundle id → name and path), `unknown` those
    /// whose absence this scan can't confirm (a folder it couldn't read, a disk not mounted): their scan count stands
    /// still, neither reset nor advanced, and none goes on such a scan, for `unknownGrace` at most. The wait counts from
    /// the first scan that counted the app missing, and its days keep running meanwhile: a scan that can tell after a
    /// long pause may end it at once. Returns the records to keep (routed bundle ids only) and the bundle ids whose route
    /// goes.
    static func reconcile(
        apps: [String: String], seen: [String: (name: String, path: String)], unknown: Set<String> = [],
        records: [String: Record], now: Date
    ) -> (records: [String: Record], drop: [String]) {
        var out: [String: Record] = [:]
        var drop: [String] = []
        for (id, route) in apps where !id.hasPrefix("/") {
            if let s = seen[id] {
                var r = Record(name: s.name, path: s.path)
                // In the Trash or translocated by Gatekeeper: not a place it will be again. Where it was before stays too.
                if transient(s.path), let old = records[id] {
                    r.before = transient(old.path) || old.path.isEmpty ? old.before : old.path
                }
                out[id] = r
                continue
            }
            var r = records[id] ?? Record(name: "", path: "")
            // On another route than when it went missing (or a scan first couldn't tell): the wait starts over.
            if r.route != route { (r.missingSince, r.missedScans, r.unavailableSince, r.route) = (nil, 0, nil, route) }
            if unknown.contains(id) {
                let since = r.unavailableSince ?? now
                r.unavailableSince = since
                if route == BLOCK || route == DIRECT || now.timeIntervalSince(since) < unknownGrace {
                    out[id] = r
                    continue
                }
            }
            if r.missingSince == nil { (r.missingSince, r.missedScans) = (now, 0) }
            // Capped: past the threshold only time counts, and an unchanged record isn't written again.
            r.missedScans = min(r.missedScans + 1, graceScans)
            if route != BLOCK, route != DIRECT, r.missedScans >= graceScans, let since = r.missingSince, now.timeIntervalSince(since) >= graceTime {
                drop.append(id)
            } else {
                out[id] = r
            }
        }
        return (out, drop.sorted())
    }

    /// A remembered path another app has taken (`ours` false: see `AppPaths.claims`) is no longer this one's: it stops
    /// matching it, even while the other app is being updated and can't be read. The name stays.
    static func retire(_ records: [String: Record], ours: (_ id: String, _ path: String) -> Bool) -> [String: Record] {
        var out = records
        for (id, r) in records {
            if !r.path.isEmpty, !ours(id, r.path) { out[id]?.path = "" }
            if let b = r.before, !ours(id, b) { out[id]?.before = nil }
        }
        return out
    }

    /// The user just put these apps on a route or took them off (Undo included): a missing one's wait starts again.
    static func restart(_ records: [String: Record], _ ids: [String]) -> [String: Record] {
        var out = records
        for id in ids where out[id]?.missingSince != nil || out[id]?.unavailableSince != nil {
            (out[id]!.missingSince, out[id]!.missedScans, out[id]!.unavailableSince, out[id]!.route) = (nil, 0, nil, nil)
        }
        return out
    }

    /// Whether a scan can't tell if a routed app is gone, from the places it was (its last path, copies added by hand):
    /// one is in a folder the scan couldn't read (`failed`), or `doubt` says so (a disk not mounted, a bundle being
    /// installed). With no place known, any folder or bundle the scan couldn't read may be it.
    static func undecided(_ places: [String], failed: [String], unreadable: Bool, doubt: (String) -> Bool) -> Bool {
        let places = places.filter { !$0.isEmpty }
        guard !places.isEmpty else { return !failed.isEmpty || unreadable }
        return places.contains { p in failed.contains { p == $0 || p.hasPrefix($0 + "/") } || doubt(p) }
    }

    /// How long an app has been missing before its remembered rules stop counting as an app here for the whole Mac's
    /// guards (`Compiler.Input.remembered`): a program of it may still run for a while after its bundle went (from the
    /// Trash, or an agent started before), refused by its rule but still able to ping or send without an owner.
    static let settledAfter: TimeInterval = 24 * 3600

    static func settled(_ missingSince: Date?, now: Date) -> Bool {
        guard let since = missingSince else { return false }
        return now.timeIntervalSince(since) >= settledAfter
    }

    /// A copy in a Trash or translocated by Gatekeeper (a random folder per start).
    static func transient(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" || $0 == "AppTranslocation" }
    }
}
