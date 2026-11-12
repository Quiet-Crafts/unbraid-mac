import Foundation

/// One app the user can route: a bundle (keyed by its bundle identifier) or a command-line tool (keyed by its path).
nonisolated struct AppInfo: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String
    /// Part of macOS rather than installed by the user.
    var system: Bool
    /// Routed, but not on this Mac now: listed by its remembered name so its route or Block stays in view.
    var missing = false
}

/// Reading the application folders.
nonisolated enum AppScan {
    struct Result: Sendable {
        var apps: [AppInfo] = []
        /// Further copies by bundle id (another version in ~/Applications, a beta).
        var copies: [String: [String]] = [:]
        /// Vendor folders holding apps, in the folders that aren't macOS's own: watched like the roots.
        var vendors: [String] = []
        /// Folders there that couldn't be read: the scan proves no app in them missing.
        var failed: [String] = []
        var complete: Bool { failed.isEmpty }
        /// Bundles whose id couldn't be read (an installer halfway through): any app could be one of them.
        var unreadable: [String] = []
    }

    /// The apps in `roots` (path, part of macOS), and in vendor folders one level down ("Adobe Creative Cloud",
    /// "Microsoft Office"). The first copy of a bundle id is listed, the others are its copies. `skip`: unbraid itself.
    static func scan(_ roots: [(String, Bool)], skip: String?) -> Result {
        var out = Result()
        var seen = Set<String>()
        let fm = FileManager.default
        // A folder that isn't there is no failure: ~/Applications often isn't.
        func list(_ dir: String) -> [String]? {
            do { return try fm.contentsOfDirectory(atPath: dir) } catch CocoaError.fileReadNoSuchFile { return nil } catch {
                out.failed.append(dir)
                return nil
            }
        }
        for (root, system) in roots {
            guard let items = list(root) else { continue }
            for item in items.sorted() {
                let url = URL(fileURLWithPath: root).appending(path: item)
                var candidates = [url]
                if !item.lowercased().hasSuffix(".app") {
                    guard AppPaths.isFolder(url.path) else { continue }
                    guard let inner = list(url.path) else { continue }
                    candidates = inner.filter { $0.lowercased().hasSuffix(".app") }.sorted().map { url.appending(path: $0) }
                    if !system, !candidates.isEmpty { out.vendors.append(url.path) }
                }
                for c in candidates {
                    guard let info = bundle(c, system: system) else { out.unreadable.append(c.path); continue }
                    guard info.id != skip else { continue }
                    if seen.insert(info.id).inserted { out.apps.append(info) } else { out.copies[info.id, default: []].append(info.path) }
                }
            }
        }
        return out
    }

    /// The app at `url` as it is on disk now (see `id(at:)`), or nil while its id can't be read; its name localised when
    /// the cached bundle is still that app.
    static func bundle(_ url: URL, system: Bool) -> AppInfo? {
        guard url.pathExtension.lowercased() == "app", let plist = info(url.path), let id = plist["CFBundleIdentifier"] as? String else { return nil }
        let b = Bundle(url: url)
        let same = b?.bundleIdentifier == id
        let name = ((same ? b?.localizedInfoDictionary?["CFBundleDisplayName"] : nil) ?? plist["CFBundleDisplayName"] ?? plist["CFBundleName"]
            ?? (same ? b?.infoDictionary?["CFBundleDisplayName"] ?? b?.infoDictionary?["CFBundleName"] : nil)) as? String
        return AppInfo(id: id, name: name ?? url.deletingPathExtension().lastPathComponent, path: url.path, system: system)
    }

    /// The bundle id of the app at `path` as it is on disk now. Bundle objects are cached per path for the life of the
    /// process, so a bundle replaced by another app at the same path would still read as the old one.
    static func id(at path: String) -> String? { info(path)?["CFBundleIdentifier"] as? String }

    /// A Mac app's Info.plist, a flat bundle's, or that of the iPhone or iPad app a Mac wrapper holds.
    private static func info(_ path: String) -> NSDictionary? {
        ["/Contents/Info.plist", "/Info.plist", "/WrappedBundle/Info.plist"].lazy.compactMap { NSDictionary(contentsOfFile: path + $0) }.first
    }
}

/// The apps with a copy inside another app's bundle (Simulator inside Xcode, or an app in /Applications that is a link
/// into one). That copy matches the outer bundle's pattern too, so one on the default route needs a rule of its own to
/// stay there, as the list shows it (`Compiler.nestedDefaults`). Worked out afresh by each scan, off the main thread, from
/// what outlives a restart: the scan, copies added by hand, LaunchServices, what runs. A route change needs no rescan.
nonisolated struct NestedApps: Sendable {
    /// App id → its copies inside another app's bundle, as found or where their links lead.
    private(set) var copies: [String: [String]] = [:]
    /// Apps put back on the default route that no scan lists (every copy inside another app's bundle: listed only while
    /// routed). Kept by id, so each scan looks them up again and they keep their rule after a restart.
    private(set) var kept: Set<String>
    /// Apps found or kept since the running scan began (`scanning`): what it found of them came too late for that scan,
    /// so it is kept until the next scan looks.
    private var since: Set<String> = []

    init(kept: Set<String> = []) { self.kept = kept }

    /// Every copy known of the apps a scan lists (`scan`), those added by hand (`added`, id → paths) and `others` (routed
    /// or kept): scanned, added, known to LaunchServices (`launchServices`) or running (`running`, id → bundle paths).
    /// One outside the scan only while it holds that app (`holder`), or for one added or running, can't be read (being
    /// installed, or gone while it runs), as `AppPaths.claims` counts them.
    static func known(_ scan: AppScan.Result, added: [String: [String]], others: [String], launchServices: (String) -> [String],
                      running: [String: [String]], holder: (String) -> String? = AppScan.id(at:)) -> [String: [String]] {
        var out: [String: Set<String>] = [:]
        for a in scan.apps { out[a.id, default: []].insert(a.path) }
        for (id, paths) in scan.copies { out[id, default: []].formUnion(paths) }
        for id in Set(out.keys).union(added.keys).union(others) where !id.hasPrefix("/") {
            let scanned = out[id] ?? []
            func holds(_ p: String, unreadable: Bool) -> Bool { !p.isEmpty && !scanned.contains(p) && (holder(p).map { $0 == id } ?? unreadable) }
            out[id] = scanned.union(launchServices(id).filter { holds($0, unreadable: false) })
                .union(((added[id] ?? []) + (running[id] ?? [])).filter { holds($0, unreadable: true) })
        }
        return out.mapValues { $0.sorted() }
    }

    /// Of `known` (id → copies), those inside another app's bundle, as found or where their links lead (`resolve`).
    static func inside(_ known: [String: [String]], resolve: (String) -> String = AppPaths.resolved) -> [String: [String]] {
        known.compactMapValues { paths in
            let inside = paths.filter { inBundle($0) || inBundle(resolve($0)) }
            return inside.isEmpty ? nil : inside
        }
    }

    /// A scan begins: what is known now is what it reads.
    mutating func scanning() { since = [] }

    /// What a scan found (`inside`) for the apps it asked about (`asked`). A kept app it lists itself (`listed`: scanned, or
    /// added by hand) needs keeping no more, nor one with no copy inside a bundle now (gone, or moved out). What was found
    /// or kept while the scan ran is added to what it found, asked about or not, until the next scan.
    mutating func scanned(_ inside: [String: [String]], asked: Set<String>, listed: Set<String>) {
        copies = inside.merging(copies.filter { since.contains($0.key) }) { Array(Set($0 + $1)).sorted() }
        kept = kept.filter { !listed.contains($0) && copies[$0] != nil }
        since = []
    }

    /// Found outside a scan (an app added by hand).
    mutating func found(_ inside: [String: [String]]) {
        copies.merge(inside) { Array(Set($0 + $1)).sorted() }
        since.formUnion(inside.keys)
    }

    /// `ids` left the setup's apps: on the default route now, by any change (a move, another default, a route removed, a
    /// profile). One with a copy inside another app's bundle (as the last scan found it, or among `known`, as listed or
    /// where its links lead: `resolve`, once per change, only for one no scan saw nested) is kept: no scan may list it once
    /// it has no route. True when one wasn't known to be nested before.
    @discardableResult
    mutating func returned(_ ids: [String], _ setup: Setup, resolve: (String) -> String = AppPaths.resolved, known: (String) -> [String]) -> Bool {
        var new = false
        for id in ids where !id.hasPrefix("/") && setup.apps[id] == nil {
            if copies[id] == nil, let inside = Self.inside([id: Array(Set(known(id))).sorted()], resolve: resolve)[id] {
                copies[id] = inside
                new = true
            }
            if copies[id] != nil { kept.insert(id); since.insert(id) }
        }
        return new
    }

    /// Those on the default route of `setup`: the compiler gives one a rule of its own if a copy is inside the bundle of
    /// an app routed elsewhere.
    func candidates(_ setup: Setup) -> [String] { copies.keys.filter { setup.apps[$0] == nil }.sorted() }

    /// A path inside an app bundle (a ".app" folder on the way), in any case.
    static func inBundle(_ path: String) -> Bool { path.lowercased().contains(".app/") }
}
