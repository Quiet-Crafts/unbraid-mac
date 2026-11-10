import Foundation

/// Every path an app or a tool runs from, as engine match patterns: the engine sees the path of the running image,
/// which is often not the one the user picked.
nonisolated enum AppPaths {
    /// A bundle, from every copy known (listed, scanned, added by hand, known to LaunchServices, seen running), under
    /// its path and its real one. Only copies seen: a pattern by file name alone could route other apps of that name too.
    /// An app whose program is a link out of its bundle (to a runtime installed elsewhere) runs as that file, which this
    /// doesn't match: other apps may run the same runtime.
    static func bundle(_ paths: [String]) -> [String] {
        Set((paths + paths.map(resolved)).map(Compiler.pattern(forPath:))).sorted()
    }

    /// Block a translocated copy from its first connection, even before the catalogue sees it start. An unrelated app
    /// with the same bundle name in App Translocation is blocked too; normal routes only match known copies.
    static func blockedTranslocations(_ paths: [String]) -> [String] {
        Set(paths.compactMap { path -> String? in
            let name = (path as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".app"), name.count > 4 else { return nil }
            return #"/AppTranslocation/[^/]+/d/"# + NSRegularExpression.escapedPattern(for: name) + "/"
        }).sorted()
    }

    /// The places app `id` is remembered at (its last path while it is missing, copies added by hand) that may still
    /// be it: gone, or there but unreadable (being installed again: Finder fills in Info.plist last), but not another
    /// app now. Matched like copies on disk, so a blocked app reinstalled there is blocked from its first start, and an
    /// update that removes the old copy before moving in the new one doesn't take its rule away and back.
    /// `taken`: places another app was seen in since, kept here, so a copy of this one still running from there (its
    /// bundle replaced) doesn't count while the other app is being updated and can't be read. A place read as this app
    /// again is its own again.
    static func claims(_ id: String, _ paths: [String], taken: inout Set<String>, holder: (String) -> String? = AppScan.id(at:)) -> [String] {
        paths.filter { p in
            guard !p.isEmpty else { return false }
            switch holder(p) {
            case id?: taken.remove(p); return true
            case nil: return !taken.contains(p)
            case _?: taken.insert(p); return false
            }
        }
    }

    static func claims(_ id: String, _ paths: [String], holder: (String) -> String? = AppScan.id(at:)) -> [String] {
        var taken = Set<String>()
        return claims(id, paths, taken: &taken, holder: holder)
    }

    /// The places apps are remembered at (see `claims`), by every spelling a start there may be reported under: the path,
    /// where its links lead, and either in lower case on a volume that ignores case. Another app starting at one may have
    /// taken it: looked at then, not left to the next scan (which a copy that took long to finish may not get for days).
    struct Places: Sendable {
        struct Claim: Hashable, Sendable {
            let owner: String
            let path: String
        }

        private var byAlias: [String: Set<Claim>] = [:]
        /// In lower case, those on a volume that ignores case.
        private var folded: [String: Set<Claim>] = [:]

        /// `remembered`: app id → its remembered places.
        init(_ remembered: [String: [String]], ignoresCase: (String) -> Bool = Compiler.volumeIgnoresCase) {
            for (owner, paths) in remembered {
                for p in paths where !p.isEmpty {
                    let fold = ignoresCase(p)
                    for a in Set([p, resolved(p)]) {
                        byAlias[a, default: []].insert(Claim(owner: owner, path: p))
                        if fold { folded[a.lowercased(), default: []].insert(Claim(owner: owner, path: p)) }
                    }
                }
            }
        }

        /// The places of apps other than `id` that `bundle` is.
        func others(_ id: String, at bundle: String) -> [Claim] {
            claims(at: bundle).filter { $0.owner != id }.sorted { ($0.owner, $0.path) < ($1.owner, $1.path) }
        }

        /// Whether `path` is one of the places, under any spelling.
        func contains(_ path: String) -> Bool { !claims(at: path).isEmpty }

        private func claims(at path: String) -> Set<Claim> {
            guard !byAlias.isEmpty else { return [] }
            let r = resolved(path)
            return Set([path, r].flatMap { byAlias[$0] ?? [] }).union([path, r].flatMap { folded[$0.lowercased()] ?? [] })
        }
    }

    /// A command-line tool: the file chosen and what it really runs as. Links are followed. Xcode's shims in /usr/bin
    /// (git, python3, clang…) run the tool of the selected developer folder. A framework Python (Homebrew's, Xcode's,
    /// python.org's) runs scripts as its Python.app, and git fetches over HTTPS with helpers in libexec/git-core. A
    /// Homebrew Cellar executable reached through a link (bin/node, opt/node) also matches any version of its formula,
    /// so `brew upgrade` doesn't leave the tool unmatched; a Cellar path chosen as such stays that version. Literal
    /// patterns stay beside the wildcard, and folders (the Python.app, git-core) stay literal: the compiler orders a
    /// route nested in another's folder by literal containment, which a wildcard would hide. The relink that comes
    /// with an upgrade re-resolves them.
    /// - Parameter developerDirs: every developer folder known (each Xcode's, the Command Line Tools', the active one):
    ///   a shim runs the tool of whichever is selected, by `xcode-select -s` or DEVELOPER_DIR, so it is matched in all.
    ///   Each is that same tool; an Xcode routed on its own still holds them by containment (the deeper tool wins),
    ///   except a blocked one, whose reject comes first.
    static func tool(_ path: String, developerDirs: [String], shims: String = "/usr/bin") -> [String] {
        let fm = FileManager.default
        var files = [path]
        if (path as NSString).deletingLastPathComponent == shims {
            files += shimTargets(path, developerDirs).filter { fm.fileExists(atPath: $0) }
        }
        files += files.map(real)
        let pinned = path.split(separator: "/").contains("Cellar")
        var out: Set = [Compiler.pattern(forPath: path)]
        let uniqueFiles = Set(files)
        for f in uniqueFiles where f != path {
            // The exact path too: an app or folder routed on its own that holds it is ordered against literal paths.
            out.insert(Compiler.pattern(forPath: f))
            if !pinned { out.insert(cellar(Compiler.pattern(forPath: f), f)) }
        }
        for f in uniqueFiles {
            let parts = f.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // …/Python.framework/Versions/3.14/bin/python3.14 re-execs …/Versions/3.14/Resources/Python.app; not
            // python3-config and the like, which only run as scripts.
            if let v = parts.lastIndex(of: "Versions"), v >= 1, v + 3 == parts.count - 1, parts[v - 1].hasSuffix(".framework"),
               parts[v + 2] == "bin", parts[v + 3].wholeMatch(of: /python[0-9.]*/) != nil {
                let app = parts[...(v + 1)].joined(separator: "/") + "/Resources/Python.app"
                if fm.fileExists(atPath: app) { out.insert(Compiler.pattern(forPath: app)) }
            }
            // <prefix>/bin/git runs git-remote-https and its other commands from <prefix>/libexec/git-core: all git.
            if parts.last == "git", parts.count >= 3, parts[parts.count - 2] == "bin" {
                let core = parts.dropLast(2).joined(separator: "/") + "/libexec/git-core"
                var dir: ObjCBool = false
                if fm.fileExists(atPath: core, isDirectory: &dir), dir.boolValue { out.insert(folder(core)) }
            }
        }
        return out.sorted()
    }

    /// Where a shim in /usr/bin may lead: the tool of that name in each developer folder.
    static func shimTargets(_ path: String, _ developerDirs: [String]) -> [String] {
        let name = (path as NSString).lastPathComponent
        return developerDirs.flatMap { [$0 + "/usr/bin/" + name, $0 + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/" + name] }
    }

    /// The folders whose entries decide where `path` leads: the one holding the file it ends at, and each one holding a
    /// link on the way, links inside a link's destination included (Homebrew replaces bin/node and opt/node on upgrade).
    static func linkFolders(_ path: String) -> [String] {
        let fm = FileManager.default
        var out = Set<String>()
        var rest = path.split(separator: "/").map(String.init)
        var dir = "/"
        var hops = 0
        while !rest.isEmpty {
            let next = (dir as NSString).appendingPathComponent(rest.removeFirst())
            guard hops < 32, let dest = try? fm.destinationOfSymbolicLink(atPath: next) else {
                if rest.isEmpty { out.insert(dir) }
                dir = next
                continue
            }
            // The rest of the path continues where the link leads, which may hold links of its own.
            out.insert(dir)
            hops += 1
            let target = dest.hasPrefix("/") ? dest : (dir as NSString).appendingPathComponent(dest)
            rest = URL(fileURLWithPath: target).standardized.path.split(separator: "/").map(String.init) + rest
            dir = "/"
        }
        return out.sorted()
    }

    /// The nearest folder on the way to `path` that exists: watched for `path` to appear.
    static func nearest(_ path: String) -> String {
        var up = (path as NSString).deletingLastPathComponent
        while !isFolder(up), up != "/" { up = (up as NSString).deletingLastPathComponent }
        return up
    }

    /// Whether a folder waited for (`awaited`: folder → the nearest one that existed, `dir`) has come closer: one on the
    /// way below `dir`, or the folder itself, exists now. A file of that name is no folder.
    static func closer(_ awaited: [String: String], _ dir: String) -> Bool {
        awaited.contains { $0.value == dir && (isFolder($0.key) || nearest($0.key) != dir) }
    }

    /// Whether a disk is mounted at `path` (or at where it links, as the startup disk's name in /Volumes does): a folder
    /// of that name left in /Volumes is not one.
    static func mounted(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let on = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        return on == path || on == real(path)
    }

    /// Whether nothing is at `path` (or a link there leads nowhere). False also when it can't be told: a folder on the
    /// way that can't be searched, a disk error.
    static func absent(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) != 0 && (errno == ENOENT || errno == ENOTDIR)
    }

    /// A folder, or a link to one.
    static func isFolder(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Whether any of `patterns` matches the process path `path`, as the engine would test it.
    static func matches(_ patterns: [String], _ path: String) -> Bool {
        patterns.contains { p in
            (try? NSRegularExpression(pattern: p)).map { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil } ?? false
        }
    }

    /// The processes running, as the engine sees them: the program of each it can name (`images`), and how many run
    /// from a program file that is gone (`unnamed`: deleted or replaced by an update while it runs). The engine names a
    /// connection's program with the same call, so it matches no rule to an unnamed process; its connections have no
    /// owner, which only the whole-Mac guards hold.
    struct Running: Equatable {
        var images: Set<String>
        var unnamed = 0
    }

    /// Every process running (see `Running`). Nil if one couldn't be read for another reason.
    static func runningImages() -> Running? {
        var count: Int32 = 0
        var pids: [pid_t] = []
        repeat {
            let n = proc_listallpids(nil, 0)
            guard n > 0 else { return nil }
            pids = [pid_t](repeating: 0, count: Int(n) + 64)
            count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return nil }
        } while Int(count) >= pids.count // Grew meanwhile: again.
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return images(Array(pids.prefix(Int(count)))) { pid in
            proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, 0) : (nil, errno)
        }
    }

    /// The processes `pids` (`path`: one's program, or the error reading it). One that ended meanwhile (ESRCH) is left
    /// out, one whose program file is gone (ENOENT) is counted as unnamed, and any other error makes the whole list
    /// unknown.
    static func images(_ pids: [pid_t], path: (pid_t) -> (String?, Int32)) -> Running? {
        var out = Running(images: [])
        for pid in pids where pid > 0 {
            let (p, error) = path(pid)
            if let p { out.images.insert(p) } else if error == ENOENT { out.unnamed += 1 } else if error != ESRCH { return nil }
        }
        return out
    }

    /// Those of `patterns` some process in `images` runs as.
    static func running(_ patterns: Set<String>, _ images: Set<String>) -> Set<String> {
        patterns.filter { p in
            guard let re = try? NSRegularExpression(pattern: p) else { return true }
            return images.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
    }

    /// Routed tools whose patterns overlap (the same file, Python's app, git's helpers) on different routes: the engine
    /// goes by the program that runs and takes the first rule that matches (Block first), so one of them doesn't get
    /// its route. Per tool, the others, sorted. Only shared patterns count: a folder pattern holding another tool's file
    /// isn't caught.
    static func sharing(_ patterns: [String: [String]], routes: [String: String]) -> [String: [String]] {
        let keys = patterns.keys.sorted()
        var out: [String: [String]] = [:]
        for (i, a) in keys.enumerated() {
            let mine = Set(patterns[a] ?? [])
            for b in keys[(i + 1)...] where routes[a] != routes[b] && !mine.isDisjoint(with: patterns[b] ?? []) {
                out[a, default: []].append(b)
                out[b, default: []].append(a)
            }
        }
        return out.mapValues { $0.sorted() }
    }

    /// The path with every link resolved, as the kernel reports a running image (/private/var stays /private/var).
    static func real(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// `real`, also for a path with nothing at it (an app remembered where it was): the links on the way to its nearest
    /// folder that exists resolved, so a copy installed there again is known under the path its process reports.
    static func resolved(_ path: String) -> String {
        let r = real(path)
        guard r == path, path.hasPrefix("/"), absent(path) else { return r }
        let up = nearest(path)
        guard up != path, path.hasPrefix(up) else { return path }
        let rest = path.dropFirst(up.count).split(separator: "/").joined(separator: "/")
        let base = real(up)
        return rest.isEmpty ? base : (base == "/" ? "/" : base + "/") + rest
    }

    /// Everything inside a folder: the compiler's exact pattern for it (its form: anchors, case), with the end anchor
    /// made a "/".
    private static func folder(_ dir: String) -> String {
        let p = Compiler.pattern(forPath: dir)
        return p.hasSuffix("$") ? String(p.dropLast()) + "/" : p
    }

    /// A path in a Homebrew Cellar (<prefix>/Cellar/<formula>/<version>/…) matches any version of the formula.
    private static func cellar(_ pattern: String, _ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let c = parts.firstIndex(of: "Cellar"), c + 3 < parts.count else { return pattern }
        let literal = "/Cellar/\(parts[c + 1])/\(parts[c + 2])/"
        guard let r = pattern.range(of: NSRegularExpression.escapedPattern(for: literal)) else { return pattern }
        return pattern.replacingCharacters(in: r, with: NSRegularExpression.escapedPattern(for: "/Cellar/\(parts[c + 1])/") + #"[^/]+\/"#)
    }
}
