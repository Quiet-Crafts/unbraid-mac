import AppKit
import Observation
import UniformTypeIdentifiers

/// The apps on this Mac, read from the usual application folders; tools the user added by hand are kept by path.
@Observable
final class AppCatalog {
    static let shared = AppCatalog()

    private init() { followSetup() }

    private(set) var apps: [AppInfo] = [] {
        didSet { index = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Apps by key: names are looked up per row and inside sort comparators.
    @ObservationIgnored private var index: [String: AppInfo] = [:]
    private(set) var loaded = false
    private(set) var revision = 0
    /// Bumped by every rescan, changed or not: the connection rechecks its match patterns (a symlink moved, an app
    /// updated in place) without every row redrawing as `revision` would make it.
    private(set) var patternRevision = 0
    private struct CachedPatterns {
        var paths: [String]
        var blocked: [String]
    }
    @ObservationIgnored private var patternCache: [String: CachedPatterns] = [:]
    @ObservationIgnored private let icons = IconCache()
    @ObservationIgnored private var iconWork: Task<Void, Never>?
    /// Further copies of an app (another version in ~/Applications, a beta): routed like the one listed.
    private var copies: [String: [String]] = [:]
    /// Copies of routed apps outside the scanned folders, per scan: those LaunchServices knows and running ones.
    @ObservationIgnored private var elsewhere: [String: [String]] = [:] { didSet { changed(oldValue, elsewhere) } }
    /// Apps with a copy inside another app's bundle, as the last scan found them: see `routingKeys`.
    @ObservationIgnored private var nesting = NestedApps(kept: AppCatalog.savedNested)
    /// The setup's apps as last seen, for those that leave it (`followNesting`).
    @ObservationIgnored private var routedBefore = Store.shared.setup.apps
    /// Copies of routed apps seen starting from a place their patterns missed.
    @ObservationIgnored private var launched: [String: Set<String>] = [:] { didSet { changed(oldValue, launched) } }
    /// The patterns each tool is matched by: what it leads to now, and what it led to before while a process still runs
    /// from there (an interpreter started before `brew upgrade` relinked it keeps its rule; a blocked one stays blocked).
    @ObservationIgnored private var toolPatterns: [String: Set<String>] = [:]
    /// What each tool leads to now. Kept while its own path leads nowhere (a relink halfway, a reinstall).
    @ObservationIgnored private var toolCurrent: [String: Set<String>] = [:]
    /// Bumped each time a tool is resolved or forgotten: a prune worked out before applies only if none came since.
    @ObservationIgnored private var toolGeneration: [String: Int] = [:]
    @ObservationIgnored private var pruning: Task<Void, Never>?
    /// A prune asked for while one ran: run again after it, for the tools it didn't look at.
    @ObservationIgnored private var pruneAgain = false
    /// Starts its patterns couldn't take in, even rebuilt: see `UnmatchedStarts`.
    @ObservationIgnored private var unmatched = UnmatchedStarts()
    /// Starts of apps listed as missing, from a copy their patterns already match: one rescan each for a while, not one
    /// at every start (an agent in a bundle the scan can't read). Their traffic is matched meanwhile.
    @ObservationIgnored private var returning = UnmatchedStarts()
    /// Where routed apps are remembered, for a start of another app there (see `started`).
    @ObservationIgnored private var places = AppPaths.Places([:])
    /// What the scans saved of each routed app (`AppPresence`), at hand without decoding it again.
    @ObservationIgnored private var records: [String: AppPresence.Record] = [:]
    /// Missing apps that nothing runs from where they were, as of the last scan (see `remembered`).
    @ObservationIgnored private var gone: Set<String> = []
    /// Starts of missing apps from a place they are matched at, numbered: a process listing taken before one doesn't
    /// count that app as gone (see `checkGone`).
    @ObservationIgnored private var startsSeen = 0
    @ObservationIgnored private var lastStart: [String: Int] = [:]
    /// The folders each tool's links run through, worked out with its patterns.
    @ObservationIgnored private var toolFolderCache: [String: [String]] = [:]
    /// Every developer folder known, where Xcode's shims in /usr/bin may lead: each Xcode's, the Command Line Tools',
    /// the active one (xcode-select -p).
    @ObservationIgnored private var developerDirs: [String] = []
    @ObservationIgnored private let watch = FolderWatch()
    @ObservationIgnored private var appDirs: Set<String> = []
    @ObservationIgnored private var toolDirs: Set<String> = []
    /// A watched folder that doesn't exist yet (~/Applications, a relinked opt/ folder) → its nearest folder that does,
    /// watched for it to appear.
    @ObservationIgnored private var awaited: [String: String] = [:]
    /// What the watched app folders held (dot files aside): Finder rewriting .DS_Store is no reason to rescan.
    @ObservationIgnored private var appEntries: [String: Set<String>] = [:]
    @ObservationIgnored private var vendors: [String] = []
    @ObservationIgnored private var toolsSoon: Task<Void, Never>?
    /// Places of an app another app was seen in (see `AppPaths.claims`), kept across launches: unbraid restarted while
    /// that app updates must not hand it the first one's route.
    @ObservationIgnored private var taken: [String: Set<String>] = AppCatalog.savedTaken {
        didSet { if taken != oldValue { Self.savedTaken = taken; changed(oldValue, taken) } }
    }
    /// Bundles the last scan couldn't read (being installed, or an installer's leftovers): see `Retries`.
    @ObservationIgnored private(set) var pending: Set<String> = []
    /// Called when a folder apps live in changes: an app installed, removed, renamed or moved.
    @ObservationIgnored var onChange: () -> Void = {}

    private nonisolated static let roots: [(String, Bool)] = [
        ("/Applications", false), (NSHomeDirectory() + "/Applications", false), ("/System/Applications", true),
        ("/System/Applications/Utilities", true), ("/System/Library/CoreServices/Applications", true),
    ]

    /// Scans off the main thread; a second call refreshes (new installs, removals). Returns the routed apps missing for
    /// long enough to lose their route (see `AppPresence`), with the route they had; the caller drops them.
    func load() async -> [String: String] {
        #if DEBUG
        // Pictures from the test copy: a fixed made-up list, never what is installed here.
        if PerfHost.active, let fake = PerfFake.apps {
            if !loaded || apps != fake { apps = fake; loaded = true; invalidate() }
            return [:]
        }
        #endif
        let own = Bundle.main.bundleIdentifier
        // Where every copy of the apps listed, added, routed or kept really is: LaunchServices, what runs and links are
        // read here, not each time the patterns are asked for (see `NestedApps`).
        let (byHand, others) = (Self.addedPaths, Array(Store.shared.setup.apps.keys) + nesting.kept)
        nesting.scanning()
        let (scan, active, known, inside) = await Task.detached(priority: .utility) {
            let scan = AppScan.scan(Self.roots, skip: own)
            let running = NSWorkspace.shared.runningApplications.reduce(into: [String: [String]]()) { out, a in
                if let id = a.bundleIdentifier, let path = a.bundleURL?.path { out[id, default: []].append(path) }
            }
            let known = NestedApps.known(scan, added: byHand, others: others, launchServices: { id in
                NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
            }, running: running)
            return (scan, Self.developerDir(), known, NestedApps.inside(known))
        }.value
        let setup = Store.shared.setup
        let tools = setup.apps.keys.filter { $0.hasPrefix("/") }.map(Self.tool)
        // Bundles added by hand from elsewhere (Add App…) aren't in the scan: remembered by path across launches and
        // listed while they're still on disk (and still that app).
        let scanned = Set(scan.apps.map(\.id))
        // One added where another app is now is gone (see `AppPaths.claims`).
        let hand = Self.addedPaths
        let ours = hand.reduce(into: [String: [String]]()) { out, e in out[e.key] = claims(e.key, e.value) }.filter { !$0.value.isEmpty }
        if ours != hand { Self.addedPaths = ours }
        let added = ours.compactMap { id, paths in scanned.contains(id) ? nil : paths.lazy.compactMap { Self.info($0, id) }.first }
        // Every copy of a routed app LaunchServices knows or that runs, wherever it is (moved, in Downloads, on another
        // disk): matched like the others, and listed when it is the only one. One running counts even if its bundle
        // has gone from disk meanwhile.
        let routed = setup.apps.keys.filter { !$0.hasPrefix("/") }
        taken = taken.filter { setup.apps[$0.key] != nil && !$0.value.isEmpty }
        forgetTools()
        elsewhere = Dictionary(uniqueKeysWithValues: routed.map { ($0, copies(of: $0)) })
        launched = launched.reduce(into: [:]) { out, e in
            let still = e.value.filter { holds($0, e.key) }
            if !still.isEmpty { out[e.key] = still }
        }
        let old = Self.presence
        // Or where it was last seen, outside the scanned folders. Not where it was before a Trash (`before`): found there
        // alone, it would forget the Trash copy a helper may still run from; that place is matched while it is missing.
        let near = scanned.union(added.map(\.id))
        let moved = routed.filter { !near.contains($0) }.compactMap { id in
            elsewhere[id]?.lazy.compactMap { Self.info($0, id) }.first ?? old[id].flatMap { Self.info($0.path, id) } ?? running(id)
        }
        let wasKept = nesting.kept
        nesting.scanned(inside, asked: Set(known.keys), listed: near)
        if nesting.kept != wasKept { Self.savedNested = nesting.kept }
        // Those on the default route have their copies at hand, found above: their patterns look nothing up.
        elsewhere.merge(nesting.candidates(setup).compactMap { id in known[id].map { (id, $0) } }) { routed, _ in routed }
        let present = scan.apps + added + moved
        let seen = Dictionary(present.map { ($0.id, (name: $0.name, path: $0.path)) }) { first, _ in first }
        // Here again: its next return gets a rescan of its own.
        for id in seen.keys { returning.forget(id) }
        // A place read as the app on disk now (where it is listed, its copies, those LaunchServices knows), under any
        // spelling, is its own again. Not one it only runs from: an old process there says nothing of what the place holds.
        taken = taken.reduce(into: [:]) { out, e in
            let candidates = (scan.copies[e.key] ?? []) + (elsewhere[e.key] ?? []) + [seen[e.key]?.path].compactMap { $0 }
            let read = AppPaths.Places([e.key: candidates.filter { AppScan.id(at: $0) == e.key }])
            let rest = e.value.filter { !read.contains($0) }
            if !rest.isEmpty { out[e.key] = rest }
        }
        let now = Date.now
        // A folder the scan couldn't read proves nothing about the apps in it, a disk not mounted nothing about those
        // on it (for a while), a bundle being installed nothing about the app it was.
        let unknown = Set(routed.filter { id in
            AppPresence.undecided((old[id]?.places ?? []) + (ours[id] ?? []), failed: scan.failed, unreadable: !scan.unreadable.isEmpty, doubt: Self.unconfirmed)
        })
        let (kept, drop) = AppPresence.reconcile(apps: setup.apps, seen: seen, unknown: unknown, records: old, now: now)
        // A remembered place another app has taken is no longer this one's, even while that app updates.
        let records = AppPresence.retire(kept) { id, path in !claims(id, [path]).isEmpty }
        if records != old { Self.presence = records }
        self.records = records
        // Bundles that couldn't be read, among them where a routed app was: it may be being installed again.
        pending = Set(scan.unreadable).union(routed.flatMap { id in
            ((records[id]?.places ?? []) + (ours[id] ?? [])).filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) && AppScan.id(at: $0) == nil }
        })
        // Still routed and not here: listed as missing, so the user sees why a route stays up (or the kill switch on).
        let missing = records.filter { seen[$0.key] == nil }.map { id, r in
            AppInfo(id: id, name: Self.missingName(id, r), path: r.path, system: false, missing: true)
        }
        let next = (present + tools + missing).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        developerDirs = Self.developerDirs(active: active, scan: scan)
        vendors = scan.vendors
        rememberPlaces()
        if !loaded || next != apps || scan.copies != copies {
            copies = scan.copies
            apps = next
            loaded = true
            invalidate()
        } else {
            // An unchanged scan only drops cached match patterns: icons, rows and the connection's patterns stay as they
            // are, so becoming active doesn't redraw every row (and a table redrawn as a page closes can abort in SwiftUI).
            patternCache.removeAll(); toolFolderCache.removeAll(); patternRevision += 1
        }
        iconWork = Task { [icons, previous = iconWork, paths = apps.filter { !$0.missing && $0.path.hasSuffix(".app") }.map(\.path)] in
            await previous?.value
            if await icons.refresh(paths) { revision += 1 }
        }
        rewatch()
        let settled = records.filter { seen[$0.key] == nil && AppPresence.settled($0.value.missingSince, now: now) }.keys
        await checkGone(settled.isEmpty ? [:] : patterns(for: Array(settled)))
        return Dictionary(uniqueKeysWithValues: drop.compactMap { id in setup.apps[id].map { (id, $0) } })
    }

    func app(_ id: String) -> AppInfo? {
        _ = apps // Still observed: a view that looks an app up redraws when the list changes.
        if id == StatsMath.otherPrograms { return AppInfo(id: id, name: "Other programs", path: "", system: false) }
        return index[id] ?? (id.hasPrefix("/") || id.hasPrefix("~/") ? Self.tool(id) : nil)
    }

    /// The apps whose patterns the compiler needs for [setup]: those it routes, and those listed here on the default route
    /// inside the bundle of one routed elsewhere, which get a rule of their own (`Compiler.nestedDefaults`).
    func routingKeys(_ setup: Setup) -> [String] {
        let routed = Array(setup.apps.keys)
        // Only an app with a copy inside another bundle can be nested: few, found by the scan, so only theirs are worked out.
        let inner = nesting.candidates(setup).filter { index[$0]?.missing != true }
        guard !inner.isEmpty else { return routed }
        return routed + Compiler.nestedDefaults(setup, patterns(for: routed + inner))
    }

    /// Engine match patterns per app key. A bundle matches every process inside it, under its listed path and its real
    /// one (Safari's lives in a system cryptex behind a link). Apps no longer installed get none. See `AppPaths`.
    func patterns(for keys: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        // A tool unrouted meanwhile (another default, a route removed) starts afresh if routed again.
        forgetTools()
        for key in keys {
            // A tool routed since the last scan (or again) is watched from now on, so its relinks are seen too.
            if key.hasPrefix("/"), Store.shared.setup.apps[key] != nil {
                if toolFolderCache[key] == nil { toolFolderCache[key] = Self.toolFolders(key, developerDirs) }
                if !Set(toolFolderCache[key] ?? []).isSubset(of: toolDirs) { rewatch() }
            }
            if let cached = patternCache[key] {
                let patterns = cached.paths + (Store.shared.setup.apps[key] == BLOCK ? cached.blocked : [])
                if !patterns.isEmpty { out[key] = patterns }
                continue
            }
            let found: [String]
            var blocked: [String] = []
            if key.hasPrefix("/") {
                let current = AppPaths.absent(key) ? toolCurrent[key] ?? Set(AppPaths.tool(key, developerDirs: developerDirs))
                    : Set(AppPaths.tool(key, developerDirs: developerDirs))
                toolCurrent[key] = current
                toolGeneration[key, default: 0] += 1
                toolPatterns[key, default: []].formUnion(current)
                found = toolPatterns[key, default: []].sorted()
                if toolPatterns[key] != current { prune() }
            } else {
                // Every copy routes alike: the listed one, scanned ones, ones seen starting while they still hold this
                // app, and any other LaunchServices knows of or that runs (moved, in Downloads, on a disk image). An app
                // routed since the last scan is looked up now. Where it was last seen while missing, and copies added by
                // hand, stay matched unless another app is there now (see `AppPaths.claims`).
                if elsewhere[key] == nil { elsewhere[key] = copies(of: key) }
                var all = Set(copies[key] ?? [])
                if let a = index[key] { all.formUnion(a.missing ? claims(key, [a.path] + (records[key]?.before.map { [$0] } ?? [])) : [a.path]) }
                all.formUnion(claims(key, Self.addedPaths[key] ?? []))
                all.formUnion((launched[key] ?? []).filter { holds($0, key) })
                all.formUnion(elsewhere[key] ?? [])
                // A copy the last scan saw at a place another app has taken since (see `started`), under any spelling,
                // isn't this app. A scan gives back a place it reads as this app, so this never drops one it found.
                if let t = taken[key], !t.isEmpty {
                    let gone = AppPaths.Places([key: Array(t)])
                    all = all.filter { !gone.contains($0) }
                }
                found = AppPaths.bundle(Array(all))
                blocked = AppPaths.blockedTranslocations(Array(all))
                // A start its rules now take in may be rebuilt again if it ever runs something they don't.
                unmatched.forget(key) { AppPaths.matches(found, $0) }
            }
            patternCache[key] = CachedPatterns(paths: found, blocked: blocked)
            let patterns = found + (Store.shared.setup.apps[key] == BLOCK ? blocked : [])
            if !patterns.isEmpty { out[key] = patterns }
        }
        return out
    }

    /// The other routed tools that lead to the same program as tool `key` on another route (see `AppPaths.sharing`).
    func sharing(_ key: String, _ setup: Setup) -> [String] {
        _ = patternRevision // Observed: a relink re-resolves the tools.
        let tools = setup.apps.keys.filter { $0.hasPrefix("/") }
        guard tools.count > 1, setup.apps[key] != nil else { return [] }
        return AppPaths.sharing(patterns(for: tools), routes: Dictionary(uniqueKeysWithValues: tools.map { ($0, setup.routeOf($0)) }))[key] ?? []
    }

    /// A routed app just started. If its patterns miss the copy it runs from (moved, opened from a disk image or
    /// Downloads, translocated, reinstalled since the last scan), they are rebuilt with that copy now, not at the next
    /// scan, and the connection picks them up. True when they were. Its first connections may already have left by the
    /// default route: this catches up, it doesn't stand guard.
    func launched(_ id: String, bundle: URL, executable: URL?) -> Bool {
        let path = executable?.path ?? bundle.path + "/"
        let known = patterns(for: [id])[id] ?? []
        let start = UnmatchedStarts.key(id, bundle.path, path), real = AppPaths.real(path)
        guard !(AppPaths.matches(known, path) && AppPaths.matches(known, real)) else {
            unmatched.matched(start)
            // One listed as missing is here again: rescanned, though its remembered path may already match.
            guard index[id]?.missing == true else { return false }
            // Something of it runs: not gone, so its whole-Mac guards are back now (see `remembered`), even when this
            // start's rescan isn't due or its bundle can't be read.
            startsSeen += 1; lastStart[id] = startsSeen
            if gone.remove(id) != nil { patternRevision += 1 }
            // Installed again (its bundle reads as this app): no longer only remembered (see `remembered`), from now.
            if AppScan.id(at: bundle.path) == id, launched[id]?.contains(bundle.path) != true, !claims(id, [bundle.path]).isEmpty {
                launched[id, default: []].insert(bundle.path)
                patternCache[id] = nil
                patternRevision += 1
            }
            guard returning.due(start, real: real, now: .now) else { return false }
            returning.rebuilt(start, real: real, now: .now)
            return true
        }
        // Rebuilt once per copy and what it runs; a start the rebuild still can't take in (a copy another app has
        // taken, a program of macOS) isn't rescanned at each start, for a while (see `UnmatchedStarts`).
        guard unmatched.due(start, real: real, now: .now) else { return false }
        // Only a copy that is this app (not a place another has taken): the next scan would drop it again.
        if holds(bundle.path, id) { launched[id, default: []].insert(bundle.path) }
        unmatched.rebuilt(start, real: real, now: .now)
        patternCache[id] = nil
        patternRevision += 1
        return true
    }

    /// Any app just started. One at a place a routed app is remembered at (see `AppPaths.claims`) may have taken that
    /// place: if the place now reads as another app, the routed app's rules stop matching it now, not at the next scan
    /// (which a copy that took long to finish, or one outside the watched folders, may not get for days). Only what the
    /// place holds decides, not which app reported the start: an app still running from there after another replaced it
    /// says nothing about it. True when a place was taken, or when an app listed (or kept) on the default route started
    /// from a copy inside another app's bundle that no scan found: the rescan gives that copy its rule (`NestedApps`).
    func started(_ id: String, bundle: URL) -> Bool {
        let routed = Store.shared.setup.apps
        var moved = false
        for c in places.others(id, at: bundle.path) where routed[c.owner] != nil {
            var t = taken[c.owner] ?? []
            _ = AppPaths.claims(c.owner, [c.path], taken: &t)
            guard t != taken[c.owner] ?? [] else { continue }
            taken[c.owner] = t.isEmpty ? nil : t
            patternCache[c.owner] = nil
            moved = true
        }
        if moved { patternRevision += 1 }
        let nested = routed[id] == nil && NestedApps.inBundle(bundle.path) && nesting.copies[id]?.contains(bundle.path) != true
            && (index[id].map { !$0.missing } ?? nesting.kept.contains(id))
        return moved || nested
    }

    /// Of `keys`, the apps whose patterns are only places they were last seen: listed as missing for a day at least (see
    /// `AppPresence.settled`), with no copy found or seen starting since, nothing left at those places and nothing
    /// running from them. Their rules stay, but they don't turn on what guards against a blocked or routed app's ways
    /// round (see `Compiler.Input.remembered`): one installed again does at its first start, or the scan after it.
    func remembered(_ keys: [String]) -> Set<String> {
        let now = Date.now
        return Set(keys.filter { k in
            guard let a = index[k], a.missing, gone.contains(k), AppPresence.settled(records[k]?.missingSince, now: now),
                  (elsewhere[k] ?? []).isEmpty, (launched[k] ?? []).isEmpty, (copies[k] ?? []).isEmpty else { return false }
            // A bundle still there but unreadable (being installed or updated) may be it, and holds what is inside it.
            return ([a.path] + (records[k]?.before.map { [$0] } ?? []) + (Self.addedPaths[k] ?? [])).allSatisfy { $0.isEmpty || AppPaths.absent($0) }
        })
    }

    /// Which of the missing apps (id → the patterns it is still matched by) nothing runs from any more: a helper left
    /// running from a deleted bundle is still refused by the app's rule, and keeps the whole Mac's guards with it. Checked
    /// off the main thread; none counts when the processes can't all be read, or while one runs from a program file that
    /// is gone: that could be such a helper, which only the whole-Mac guards hold (its connections have no owner).
    private func checkGone(_ patterns: [String: [String]]) async {
        let from = startsSeen
        var next: Set<String> = patterns.isEmpty ? [] : await Task.detached(priority: .utility) { () -> Set<String> in
            guard let running = AppPaths.runningImages(), running.unnamed == 0 else { return [] }
            return Set(patterns.filter { AppPaths.running(Set($0.value), running.images).isEmpty }.keys)
        }.value
        // One seen starting while the processes were listed may not be in that listing.
        next = next.filter { (lastStart[$0] ?? 0) <= from }
        if next != gone { gone = next; patternRevision += 1 }
    }

    /// What decides an app's patterns changed (copies found or launched, places taken): its starts left out are due again.
    /// None and an empty list are the same.
    private func changed<V: Collection & Equatable>(_ old: [String: V], _ new: [String: V]) {
        func some(_ v: V?) -> V? { v.flatMap { $0.isEmpty ? nil : $0 } }
        for id in Set(old.keys).union(new.keys) where some(old[id]) != some(new[id]) { unmatched.forget(id) }
    }

    /// The user just put these apps on a route or took them off (Undo included): a missing one's wait starts again.
    /// Called once the setup has changed.
    func reassigned(_ ids: [String]) {
        let old = Self.presence
        let new = AppPresence.restart(old, ids)
        if new != old { Self.presence = new }
        records = new
        forgetTools()
        // A tool moved is worked out afresh, so what it led to before is pruned now, not at the next rescan.
        for id in ids where id.hasPrefix("/") { patternCache[id] = nil }
    }

    /// A tool no longer routed loses what it led to before: routed again, it starts from what it leads to then.
    private func forgetTools() {
        let apps = Store.shared.setup.apps
        for key in Set(toolPatterns.keys).union(toolCurrent.keys) where apps[key] == nil {
            (toolPatterns[key], toolCurrent[key], patternCache[key], toolFolderCache[key]) = (nil, nil, nil, nil)
            toolGeneration[key, default: 0] += 1
        }
    }

    /// The patterns a tool led to before stay only while a process runs from them: checked off the main thread, and
    /// kept if the processes can't all be read. Pruned at a later re-resolution (a rescan, a relink) once none runs.
    private func prune() {
        guard pruning == nil else { pruneAgain = true; return }
        pruneAgain = false
        pruning = Task {
            // Once every tool of this pass is resolved.
            let (all, current, generation) = (toolPatterns, toolCurrent, toolGeneration)
            let stale = all.reduce(into: [String: Set<String>]()) { out, e in
                let before = e.value.subtracting(current[e.key] ?? [])
                if !before.isEmpty { out[e.key] = before }
            }
            let kept = await Task.detached(priority: .utility) { () -> [String: Set<String>]? in
                // A process running from a program file that is gone matches no pattern in the engine, so it keeps none.
                guard let running = AppPaths.runningImages() else { return nil }
                return stale.mapValues { AppPaths.running($0, running.images) }
            }.value
            pruning = nil
            guard let kept else { if pruneAgain { prune() }; return }
            var changed = false
            // Only tools nothing re-resolved meanwhile; the others again, with what they lead to now.
            for (key, keep) in kept where toolGeneration[key] == generation[key] {
                let next = (current[key] ?? []).union(keep)
                if next != toolPatterns[key] { toolPatterns[key] = next; patternCache[key] = nil; changed = true }
            }
            if changed { patternRevision += 1 }
            if pruneAgain || kept.keys.contains(where: { toolGeneration[$0] != generation[$0] && toolPatterns[$0] != toolCurrent[$0] }) { prune() }
        }
    }

    /// Every setup change, connected or not (another default, a route removed, a move): a tool no longer routed forgets
    /// what it led to before, and an app put on the default route with a copy inside another app's bundle keeps its rule
    /// once no scan lists it (`NestedApps`).
    private func followSetup() {
        withObservationTracking { _ = Store.shared.setup.apps } onChange: {
            Task { @MainActor in AppCatalog.shared.forgetTools(); AppCatalog.shared.followNesting(); AppCatalog.shared.followSetup() }
        }
    }

    private func followNesting() {
        let setup = Store.shared.setup
        let left = routedBefore.keys.filter { setup.apps[$0] == nil }
        routedBefore = setup.apps
        guard !left.isEmpty else { return }
        let kept = nesting.kept
        let new = nesting.returned(left, setup) { id in [index[id]?.path].compactMap { $0 } + (copies[id] ?? []) + (elsewhere[id] ?? []) }
        if nesting.kept != kept { Self.savedNested = nesting.kept }
        // The connection may have compiled the change already, without it.
        if new { patternRevision += 1 }
    }

    func icon(_ app: AppInfo) -> NSImage {
        _ = revision // Rows also redraw when a refresh finds a changed icon at an unchanged path.
        return app.missing ? IconCache.genericIcon : icons.image(app.path)
    }

    /// Adds a bundle or tool the scan doesn't find (anywhere on disk). Returns its key.
    func add(_ url: URL) -> String {
        let info = AppScan.bundle(url, system: false) ?? Self.tool(url.path)
        // Tools are kept by path in the setup already; a bundle from outside the scanned folders is remembered here.
        if !info.id.hasPrefix("/") {
            var paths = Self.addedPaths
            if !paths[info.id, default: []].contains(info.path) { paths[info.id, default: []].append(info.path) }
            Self.addedPaths = paths
            rememberPlaces()
            // From inside another app's bundle, or by a link into one: its own rule on the default route from now.
            nesting.found(NestedApps.inside([info.id: [info.path]]))
        }
        // An Xcode added by hand is one more place Xcode's shims may lead (DEVELOPER_DIR), from now.
        let developer = info.path + "/Contents/Developer"
        if info.id == "com.apple.dt.Xcode", !developerDirs.contains(developer) { developerDirs.append(developer) }
        // By key: another copy of a listed app (or a system app added by hand) must not become a second row. One listed
        // as missing is here again.
        if let i = apps.firstIndex(where: { $0.id == info.id }) { if apps[i].missing { apps[i] = info } }
        else { apps.append(info); apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        invalidate()
        return info.id
    }

    /// Every place an app is remembered at: where it was last seen (the record of a routed app) and copies added by hand.
    private func rememberPlaces() {
        places = AppPaths.Places(Self.presence.compactMapValues { $0.places.isEmpty ? nil : $0.places }.merging(Self.addedPaths) { $0 + $1 })
    }

    /// The developer folders of every Xcode known (scanned, known to LaunchServices, added by hand, running), the Command
    /// Line Tools' (installed or not: it may be any time) and the active one, which may be anywhere.
    private static func developerDirs(active: String?, scan: AppScan.Result) -> [String] {
        let xcode = "com.apple.dt.Xcode"
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: xcode).map(\.path).filter { AppScan.id(at: $0) == xcode }
        let added = (addedPaths[xcode] ?? []).filter { AppScan.id(at: $0) == xcode }
        let copies = scan.apps.filter { $0.id == xcode }.map(\.path) + (scan.copies[xcode] ?? []) + known + added + runningPaths(xcode)
        var out: [String] = []
        for d in [active].compactMap({ $0 }) + copies.map({ $0 + "/Contents/Developer" }) + ["/Library/Developer/CommandLineTools"] where !out.contains(d) {
            out.append(d)
        }
        return out
    }

    /// Bundle id → the paths of its copies added by hand (an earlier build kept one path per app: read as a list of one).
    private static var addedPaths: [String: [String]] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: "addedApps") ?? [:]
            return raw.compactMapValues { ($0 as? [String]) ?? ($0 as? String).map { [$0] } }
        }
        set { UserDefaults.standard.set(newValue, forKey: "addedApps") }
    }

    /// The apps `NestedApps` keeps, by id.
    private static var savedNested: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "appsNestedOnDefault") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "appsNestedOnDefault") }
    }

    private static var savedTaken: [String: Set<String>] {
        get { (UserDefaults.standard.dictionary(forKey: "appPlacesTaken") as? [String: [String]] ?? [:]).mapValues(Set.init) }
        set { UserDefaults.standard.set(newValue.filter { !$0.value.isEmpty }.mapValues { $0.sorted() }, forKey: "appPlacesTaken") }
    }

    /// Bundle id → what is remembered of a routed app, to list it while it is missing. See `AppPresence`.
    private static var presence: [String: AppPresence.Record] {
        get { UserDefaults.standard.data(forKey: "appPresence").flatMap { try? JSONDecoder().decode([String: AppPresence.Record].self, from: $0) } ?? [:] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "appPresence") }
    }

    private static func missingName(_ id: String, _ r: AppPresence.Record) -> String {
        if !r.name.isEmpty { return r.name }
        let path = r.path.isEmpty ? addedPaths[id]?.first ?? "" : r.path
        return path.isEmpty ? String(id.split(separator: ".").last ?? Substring(id)) : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    /// The app `id` at `path`, if that is what the path holds now.
    private static func info(_ path: String, _ id: String) -> AppInfo? {
        guard AppScan.id(at: path) == id else { return nil }
        let name = AppScan.bundle(URL(fileURLWithPath: path), system: false)?.name
        return AppInfo(id: id, name: name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path, system: false)
    }

    /// A copy of `id` that runs, as the system lists it; its bundle may have gone from disk, but not been taken by
    /// another app.
    private func running(_ id: String) -> AppInfo? {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).lazy.compactMap { a in
            a.bundleURL.flatMap { url in
                self.claims(id, [url.path]).isEmpty ? nil
                    : AppInfo(id: id, name: a.localizedName ?? url.deletingPathExtension().lastPathComponent, path: url.path, system: false)
            }
        }.first
    }

    /// Whether `path` is a copy of `id`: on disk as that app, or running as it while no other app has taken its place.
    private func holds(_ path: String, _ id: String) -> Bool {
        !claims(id, [path]).isEmpty && (AppScan.id(at: path) == id || Self.runningPaths(id).contains(path))
    }

    /// The copies of a bundle LaunchServices knows that are on disk and still that app, and those running (unless
    /// another app is now where one ran from: its path would match that app too).
    private func copies(of id: String) -> [String] {
        let known = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path).filter { AppScan.id(at: $0) == id }
        return Set(known + claims(id, Self.runningPaths(id))).sorted()
    }

    /// The places among `paths` that may still be app `id` (see `AppPaths.claims`), noting those another app has taken.
    /// Worked on a copy: `taken` is saved and compared only when a place was actually taken or given back.
    private func claims(_ id: String, _ paths: [String]) -> [String] {
        var t = taken[id] ?? []
        let out = AppPaths.claims(id, paths, taken: &t)
        if t != taken[id] ?? [] { taken[id] = t.isEmpty ? nil : t }
        return out
    }

    private static func runningPaths(_ id: String) -> [String] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap(\.bundleURL?.path)
    }

    /// Whether a place a routed app was can't say it is gone: on a disk that isn't mounted now, or still there but not
    /// readable as an app (an installer halfway through). For a while: see `AppPresence.unknownGrace`.
    private static func unconfirmed(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.count > 2, parts[0] == "Volumes", !AppPaths.mounted("/Volumes/\(parts[1])") { return true }
        return !AppPaths.absent(path) && AppScan.id(at: path) == nil
    }

    /// The folders a tool's links run through, less those of macOS itself, which don't change while the Mac runs. For a
    /// shim in /usr/bin, those of the tool it may lead to in each developer folder too (the Command Line Tools being
    /// installed, a toolchain relinked).
    private static func toolFolders(_ key: String, _ developerDirs: [String]) -> [String] {
        let system = ["/System", "/usr/bin", "/usr/sbin", "/bin", "/sbin", "/usr/libexec"]
        let shims = (key as NSString).deletingLastPathComponent == "/usr/bin" ? AppPaths.shimTargets(key, developerDirs) : []
        return Set(([key] + shims).flatMap(AppPaths.linkFolders)).filter { d in d != "/" && !system.contains { d == $0 || d.hasPrefix($0 + "/") } }.sorted()
    }

    /// Watches the folders apps are installed into (and their vendor folders), once scanned, and those deciding where
    /// routed tools lead (Homebrew relinks them on upgrade): an app change rescans, a tool change only re-resolves the
    /// tools.
    private func rewatch() {
        let tools = Store.shared.setup.apps.keys.filter { $0.hasPrefix("/") }
        for key in tools { toolFolderCache[key] = Self.toolFolders(key, developerDirs) }
        toolDirs = Set(tools.flatMap { toolFolderCache[$0] ?? [] })
        appDirs = loaded ? Set(Self.roots.filter { !$0.1 }.map(\.0) + vendors) : []
        appEntries = appEntries.filter { appDirs.contains($0.key) }
        for dir in appDirs where appEntries[dir] == nil { appEntries[dir] = Self.entries(dir) }
        awaited = [:]
        for dir in appDirs.union(toolDirs) where !AppPaths.isFolder(dir) { awaited[dir] = AppPaths.nearest(dir) }
        watch.watch(appDirs.union(toolDirs).filter { awaited[$0] == nil }.union(awaited.values)) { [weak self] dir, gone in
            self?.changed(dir, gone: gone)
        }
    }

    private func changed(_ dir: String, gone: Bool) {
        // Each folder on the way to one waited for that appears moves the watch closer; the folder itself, once there,
        // is watched and looked at.
        // Only then: the home folder waited on for ~/Applications changes with every shell history save.
        if awaited.values.contains(dir), gone || AppPaths.closer(awaited, dir) {
            let appeared = awaited.filter { $0.value == dir && AppPaths.isFolder($0.key) }.map(\.key)
            rewatch()
            if appeared.contains(where: appDirs.contains) { onChange() }
            if appeared.contains(where: toolDirs.contains) { toolsChanged() }
        }
        if appDirs.contains(dir) {
            let now = Self.entries(dir)
            // A folder removed or replaced has lost its watch: the rescan watches it again, whatever it now holds.
            if gone || now != appEntries[dir] { appEntries[dir] = now; onChange() }
        }
        // A link replaced by one of the same name (Homebrew relinking) changes no name: every event counts.
        if toolDirs.contains(dir) { toolsChanged() }
    }

    private static func entries(_ dir: String) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") })
    }

    /// A folder on the way to a routed tool changed (`brew upgrade` relinks): once it settles, the tools' patterns are
    /// worked out again and the connection reloads if they differ. No rescan of the apps.
    private func toolsChanged() {
        guard toolsSoon == nil else { return }
        toolsSoon = Task {
            try? await Task.sleep(for: .seconds(Rescans.settle))
            toolsSoon = nil
            for key in patternCache.keys where key.hasPrefix("/") { patternCache[key] = nil }
            toolFolderCache.removeAll()
            patternRevision += 1
            rewatch()
        }
    }

    /// Refreshes also invalidate symlink resolutions and missing-app lookups, even if the visible list is identical.
    private func invalidate() { patternCache.removeAll(); toolFolderCache.removeAll(); revision += 1; patternRevision += 1 }

    /// The active developer folder, as Xcode's shims in /usr/bin find it. Nil if none is set (they then offer to install).
    private nonisolated static func developerDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && path.hasPrefix("/") ? path : nil
    }

    private nonisolated static func tool(_ path: String) -> AppInfo {
        AppInfo(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path, system: false)
    }
}

/// Folder watches: a folder whose entries change (added, removed, renamed) calls back on the main queue with its path.
/// A folder that is itself removed, renamed or unmounted calls back with `gone` and is dropped; the next `watch` watches
/// it again once it exists. The latest callback serves every folder.
private final class FolderWatch {
    private var sources: [String: any DispatchSourceFileSystemObject] = [:]
    private var changed: (String, Bool) -> Void = { _, _ in }

    func watch(_ dirs: Set<String>, _ changed: @escaping (String, Bool) -> Void) {
        self.changed = changed
        for (dir, source) in sources where !dirs.contains(dir) { source.cancel(); sources[dir] = nil }
        for dir in dirs where sources[dir] == nil {
            let fd = open(dir, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self, let source else { return }
                    let gone = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
                    if gone { source.cancel(); self.sources[dir] = nil }
                    self.changed(dir, gone)
                }
            }
            source.setCancelHandler { close(fd) }
            sources[dir] = source
            source.resume()
        }
    }
}
