import Foundation

/// Chooses the tunnel each active route runs.
nonisolated enum LinkPicker {
    enum Blocked: Equatable, Sendable {
        case signedOut(String), refused(String, String), removed(String), unreachable(String), noLongerOffered(String), clash, waiting
        /// Restored from a backup saved without keys (`Route.keyless`): refused, never retried, until its config is back.
        case keyLeftOut

        var text: String {
            switch self {
            case .signedOut: "signed out"
            case .refused(let provider, _): "\(provider) refused this Mac. Sign in again"
            case .removed(let provider): "\(provider) no longer has this Mac. Sign in again."
            case .unreachable(let message): message
            case .noLongerOffered(let server): "\(server) is no longer offered. Pick another server"
            case .clash: Compiler.clashMessage
            case .waiting: "waiting for a server"
            case .keyLeftOut: "needs its config again"
            }
        }
    }

    struct Result {
        var links: [String: Link]
        var remember: [String: Link]
        var blocked: [String: Blocked]
    }

    /// A confirmed removal survives outages until the location or account changes, or the connection ends.
    struct RemovedPins: Sendable {
        private struct Entry: Sendable {
            var location: Location
            var reason: Blocked
            var account: String?
        }
        private var entries: [String: Entry] = [:]

        mutating func update(_ setup: Setup, accounts: [String: String]) {
            entries = entries.filter { id, entry in
                guard let route = setup.route(id), !route.imported else { return false }
                return route.loc == entry.location && accounts[entry.location.provider] == entry.account
            }
        }

        mutating func remember(_ blocked: [String: Blocked], setup: Setup, accounts: [String: String]) {
            for (id, reason) in blocked {
                guard case .noLongerOffered = reason, let route = setup.route(id), !route.imported,
                      route.loc.pinned != nil else { continue }
                entries[id] = Entry(location: route.loc, reason: reason, account: accounts[route.loc.provider])
            }
        }

        mutating func forget(_ provider: String) {
            entries = entries.filter { $0.value.location.provider != provider }
        }

        func reason(for route: Route) -> Blocked? {
            guard !route.imported, route.loc.pinned != nil else { return nil }
            return entries.values.first { pinKey($0.location) == pinKey(route.loc) }?.reason
        }
    }

    /// Changes that must reach the engine before a provider can delay them. A ready route also needs the new app
    /// rules installed when another route is waiting, otherwise apps leaving Direct still use their real address.
    /// - Parameter suffixes: the tailnet domain the running input and the new one hand the engine (`Compiler.Input.tsSuffix`),
    ///   when the caller has them: the first exit node turns it on with the switches and the saved domain alike.
    static func needsInterim(from old: Setup?, to new: Setup, revoking: Bool = false, suffixes: (old: String?, new: String?)? = nil) -> Bool {
        guard let old else { return false }
        if revoking { return true }
        let routes = Set(new.activeRoutes.map(\.id))
        func changes(_ before: String, _ after: String) -> Bool {
            (before == DIRECT && routes.contains(after)) || (before != BLOCK && after == BLOCK)
        }
        // Any change to the websites counts: a website's rule sits before its app's, so one given a route, moved or
        // blocked may be leaving Direct whatever its app does. So does a change to what the engine does with them that
        // leaves the saved websites alike: the tailnet's domain accepted and the switches that decide which private names
        // answer before them (Reach your tailnet, Reach devices on this network), which can take names under a saved
        // public website away from it; and the filter that looks a Direct website's names up.
        // A route given a Via, or one whose Via changed (another entry, or one tunnel by the provider's multi-hop): the
        // tunnel that runs now goes straight to its server, so it stops at once (the interim pick holds the route until
        // its entry is up) rather than run on until the providers have answered.
        let oldActive = Set(old.activeRoutes.map(\.id))
        // Any change that puts traffic on a Via route (a route not running before, or one whose Via changed) takes the
        // interim path, and so does one that removes or invalidates an entry: the routes that depended on it are held.
        let viaChanged = new.activeRoutes.contains { r in
            r.via != nil && (!oldActive.contains(r.id) || old.route(r.id).map { $0.via != r.via || $0.viaNative != r.viaNative } != false)
        } || old.activeRoutes.contains { o in
            o.via != nil && new.route(o.id).map { $0.via != nil && new.viaProblem($0) != nil } == true
        }
        // Traffic moving onto a route that goes by the provider's own multi-hop: its tunnel is asked for again each time.
        let native = Set(new.routes.filter { $0.viaNative && $0.via != nil }.map(\.id))
        let toNative = !native.isEmpty && ((native.contains(new.defaultRoute) && old.defaultRoute != new.defaultRoute)
            || Set(old.apps.keys).union(new.apps.keys).contains { native.contains(new.routeOf($0)) && old.routeOf($0) != new.routeOf($0) }
            || new.sites.contains { native.contains($0.value) && old.sites[$0.key] != $0.value })
        return viaChanged || toNative || changes(old.defaultRoute, new.defaultRoute) || old.sites != new.sites
            || !new.sites.isEmpty && (Sites.tailnet(of: old) != Sites.tailnet(of: new) || old.home.tailscale != new.home.tailscale
                || old.prefs.lan != new.prefs.lan || old.prefs.effectiveFilter != new.prefs.effectiveFilter
                || suffixes.map { Compiler.tsSuffix($0.old) != Compiler.tsSuffix($0.new) } == true)
            || Set(old.apps.keys).union(new.apps.keys).contains { changes(old.routeOf($0), new.routeOf($0)) }
            // "Mullvad-owned servers only" turned on: a running route on a rented server stops at once (the interim
            // pick holds it) rather than run on until Mullvad's list has been read for an owned one.
            || old.opt("mullvad", "owned") != "on" && new.opt("mullvad", "owned") == "on"
                && new.activeRoutes.contains { !$0.imported && $0.loc.provider == "mullvad" && $0.loc.pinned == nil }
            // IVPN's Disguise turned on: a running plain tunnel stops at once (the interim pick puts the disguised one in
            // its place, or holds the route when its server has none) rather than run on plain until the list is read.
            || old.opt("ivpn", "disguise") != "on" && new.opt("ivpn", "disguise") == "on"
                && new.activeRoutes.contains { !$0.imported && $0.loc.provider == "ivpn" }
    }

    /// A route restored without its keys, or one given an own server still waiting for its config however it got there:
    /// it has no tunnel to run, and its traffic is refused rather than sent anywhere else.
    static func keyLeftOut(_ r: Route, in setup: Setup) -> Bool {
        r.keyless || (r.own.map { id in setup.servers.contains { $0.id == id && $0.keyless } } ?? false)
    }

    /// The tunnel of an imported route, as its config gives it; nil for a provider route.
    static func imported(_ r: Route) -> Link? {
        if let w = r.wg {
            return .wg(Server(name: w.name, host: w.endpoint.split(separator: ":", omittingEmptySubsequences: false).dropLast().joined(separator: ":"), ip: "", publicKey: w.publicKey, load: 0), w)
        }
        if let o = r.ovpn { return .ovpn(Server(name: o.name, host: o.name, ip: "", publicKey: "", load: 0), o) }
        if let s = r.ss { return .ss(Server(name: s.name, host: s.server, ip: s.server, publicKey: "", load: 0), s) }
        if let x = r.tsExit { return .ts(Server(name: r.name, host: x, ip: "", publicKey: "", load: 0)) }
        return nil
    }

    /// Fallback-cache key: a pinned route is its own entry, so it can never inherit another server's tunnel.
    static func serverKey(_ r: Route, _ l: Link) -> String { "\(r.loc.provider)|\(serverId(l.server))" }
    /// A route's own count of Automatic's port steps, carried when a dead route moves to another server (`steps`): a new
    /// server at the first port again would fail the same way on a network that blocks that port. Keyed by the route and
    /// where the user sent it, so a route the user changes to another provider or place starts over.
    static func routeStepKey(_ r: Route) -> String {
        "route|\(r.id)|\(r.loc.provider)|\(r.loc.countryId ?? -1)|\(r.loc.cityId ?? -1)|\(r.loc.region ?? "")|\(r.loc.group ?? "")"
    }
    /// The port step each route's tunnel takes (route id → step): its server's, or more if the route brought steps from a
    /// dead server and is alone on its new one. Routes that share a server take the server's step, so they never dial
    /// two ports of one server (a clash that would block one of them), and one that answers there shows which port works.
    static func steps(_ setup: Setup, _ links: [String: Link], step: [String: Int]) -> [String: Int] {
        var onServer: [String: Int] = [:]
        for (id, l) in links { if let r = setup.route(id), !r.imported { onServer[serverKey(r, l), default: 0] += 1 } }
        var out: [String: Int] = [:]
        for (id, l) in links {
            guard let r = setup.route(id), !r.imported else { continue }
            let key = serverKey(r, l), own = step[key] ?? 0
            out[id] = onServer[key] == 1 ? max(own, step[routeStepKey(r)] ?? 0) : own
        }
        return out
    }

    /// Bound to the account the tunnel was made with: another account of the same provider (signed in after a sign-out)
    /// never falls back on it. Keys saved before carry no account and simply miss.
    static func cacheKey(_ r: Route, account: String?) -> String {
        var unpinned = r.loc
        unpinned.pinned = nil
        // Sorted keys: the key is stored with the cached tunnel, so it must read the same on every launch.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let place = (try? encoder.encode(unpinned)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        // The first 8 bytes of the account's fingerprint: keys written by earlier builds read the same.
        let owner = account.map { String(Running.fingerprint($0).prefix(16)) } ?? ""
        return "\(r.loc.provider)|@\(owner)|\(place)|\(r.loc.pinned.map(pinId) ?? "")"
    }

    private static func serverId(_ s: Server) -> String { s.ip.isEmpty ? s.host : s.ip }

    /// A pin without an address (restored from a backup) by its host and name: AirVPN gives every server of a country
    /// one host name, so the host alone would make two such pins one cached tunnel.
    private static func pinId(_ s: Server) -> String { s.ip.isEmpty ? "\(s.host)|\(s.name)" : s.ip }

    /// Which pinned server a route names, for "this server is gone": the provider and host, plus the server's name where
    /// a host stands for several servers (AirVPN's per country) and the technology where a server can be gone for one
    /// and not another (NordVPN's NordLynx and OpenVPN lists). Nil for a route without a pin.
    static func pinKey(_ loc: Location) -> String? {
        guard let p = loc.pinned else { return nil }
        var key = "\(loc.provider)|\(p.host.lowercased())"
        if loc.provider == "airvpn" { key += "|\(p.name)" }
        if loc.provider == "nord" { key += "|\(Nord.tech(loc))" }
        return key
    }

    /// Imported configs as they are; provider routes get the best server now, keeping the current one if the route's
    /// location didn't change, and falling back to the last good one if the API is down. An unpinned route that lands
    /// on a server another route already uses is moved to a different server of its location. A pinned route is never
    /// moved: it shares that server's tunnel (see `Compiler`) or fails.
    /// - Parameter avoid: servers ("provider|ip") to stay away from: ones that just stopped answering.
    static func pick(
        _ setup: Setup, keep: [String: Link], applied: Setup?, appliedAccounts: [String: String], accounts: [String: String],
        last: [String: Link], avoid: Set<String> = [], refused: [String: Blocked] = [:], gone: RemovedPins = RemovedPins(), deferred: [String: Blocked] = [:], portStep: [String: Int] = [:], offline: Bool = false, providers: (String) -> (any Provider)?
    ) async throws -> Result {
        var used = avoid
        var out: [String: Link] = [:]
        var blocked: [String: Blocked] = [:]
        for r in setup.activeRoutes {
            if keyLeftOut(r, in: setup) { blocked[r.id] = .keyLeftOut; continue }
            // A Via that can't be used stops the route before any provider is asked anything (PIA's set-up would reach the exit).
            if let why = setup.viaProblem(r) { blocked[r.id] = .unreachable(why); continue }
            if let reason = gone.reason(for: r) { blocked[r.id] = reason; continue }
            if let reason = deferred[r.id] { blocked[r.id] = reason; continue }
            if !r.imported, let reason = refused[r.loc.provider] { blocked[r.id] = reason; continue }
            let link: Link
            do {
                if let l = imported(r) {
                    link = l
                } else if let k = keep[r.id], let a = applied?.route(r.id), !a.imported, a.loc == r.loc, a.viaNative == r.viaNative, !hopped(k),
                          appliedAccounts[r.loc.provider] == accounts[r.loc.provider],
                          (r.loc.provider != "mullvad" || r.loc.pinned != nil || applied?.opt("mullvad", "owned") == setup.opt("mullvad", "owned")),
                          r.loc.pinned != nil || providers(r.loc.provider)?.suits(k.server, opts: setup.opts[r.loc.provider] ?? [:]) != false,
                          (r.loc.pinned != nil || r.loc.group == Nord.dedicatedIp || !avoid.contains(serverKey(r, k))), dialable(k), trusted(k, r, accounts, providers),
                          disguised(setup, r, k), AutoProtocol.matches(r, k) {
                    // `trusted` also requires the provider and a signed-in account: it vouches for a server, not for the
                    // credentials in its tunnel, so two missing accounts never count as the same one.
                    link = k
                } else if offline {
                    guard let p = providers(r.loc.provider) else { throw Fail("Unknown provider \(r.loc.provider)") }
                    guard let account = accounts[p.id] else { throw AuthError("Sign in to \(p.name)") }
                    // Match the online fallback's account, trust, pin, avoidance and owned-server checks.
                    guard !(p.id == "mullvad" && r.loc.pinned == nil && setup.opt(p.id, "owned") == "on"),
                          let cached = last[cacheKey(r, account: account)],
                          (r.loc.pinned != nil || r.loc.group == Nord.dedicatedIp || !avoid.contains(serverKey(r, cached))),
                          dialable(cached), !hopped(cached), trusted(cached, r, accounts, providers), disguised(setup, r, cached), AutoProtocol.matches(r, cached) else {
                        blocked[r.id] = .waiting
                        continue
                    }
                    link = cached
                } else {
                    link = try await fresh(r, accounts, last, used, avoid, setup.opts[r.loc.provider] ?? [:], providers)
                    // Never a plain tunnel under Disguise: a server without V2Ray data keeps the route off, and says why.
                    if !disguised(setup, r, link) { throw NoDisguise(provider: providers(r.loc.provider)?.name ?? r.loc.provider, server: link.server.name) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if !r.imported, r.loc.proto == AutoProtocol.key { AutoProtocol.fallBack(r.id) }
                let provider = providers(r.loc.provider)?.name ?? r.loc.provider
                if error is AuthError {
                    blocked[r.id] = accounts[r.loc.provider] == nil ? .signedOut(provider) : .refused(provider, error.localizedDescription)
                } else if let gone = error as? Catalog.Gone {
                    blocked[r.id] = .noLongerOffered(gone.server)
                } else if let e = error as? NoDisguise {
                    blocked[r.id] = .unreachable(e.errorDescription ?? "can't be reached through V2Ray")
                } else if error is KeyNotReady || error is Unsupported {
                    blocked[r.id] = .unreachable(error.localizedDescription)
                } else if error is Catalog.Damaged {
                    blocked[r.id] = .unreachable(error.localizedDescription)
                } else {
                    blocked[r.id] = .unreachable("can't reach its servers right now")
                }
                continue
            }
            if !r.imported { used.insert("\(r.loc.provider)|\(serverId(link.server))") }
            out[r.id] = link
        }
        for r in setup.activeRoutes where !r.imported {
            if let refusal = setup.activeRoutes.lazy.compactMap({ other -> Blocked? in
                guard !other.imported, other.loc.provider == r.loc.provider, let reason = blocked[other.id] else { return nil }
                if case .refused = reason { return reason }
                return nil
            }).first {
                blocked[r.id] = refusal; out.removeValue(forKey: r.id)
            }
            if r.loc.pinned != nil, let gone = setup.activeRoutes.lazy.compactMap({ other -> Blocked? in
                guard !other.imported, other.loc.pinned != nil, pinKey(other.loc) == pinKey(r.loc),
                      let reason = blocked[other.id] else { return nil }
                if case .noLongerOffered = reason { return reason }
                return nil
            }).first {
                blocked[r.id] = gone; out.removeValue(forKey: r.id)
            }
        }
        // The provider's own multi-hop: the exit's tunnel goes to its forwarding port at the entry's server. The entry
        // needs no tunnel of its own: its server is asked for when no app uses it. Anything missing blocks the route.
        var bases: [String: Link] = [:] // the exits as picked, for the fallback cache: a multi-hop is never reused
        for r in setup.activeRoutes where r.viaNative && out[r.id] != nil {
            do {
                let hopped = try await nativeHop(r, setup: setup, out: out, blocked: blocked, gone: gone, refused: refused, accounts: accounts, offline: offline, providers: providers)
                bases[r.id] = out[r.id]
                out[r.id] = hopped
            } catch is CancellationError { throw CancellationError() }
            catch let e as Hop { out.removeValue(forKey: r.id); blocked[r.id] = e.reason }
            catch let e as AuthError {
                out.removeValue(forKey: r.id)
                let name = providers(setup.route(r.via ?? "")?.loc.provider ?? "")?.name ?? r.loc.provider
                blocked[r.id] = accounts[r.loc.provider] == nil ? .signedOut(name) : .refused(name, e.localizedDescription)
            } catch {
                try Task.checkCancellation()
                out.removeValue(forKey: r.id)
                blocked[r.id] = .unreachable("\(r.name): can't reach its entry's servers right now")
            }
        }
        out = ported(setup, out, step: portStep)
        for id in Compiler.clashes(setup, out) { out.removeValue(forKey: id); blocked[id] = .clash }
        // Via, once every entry is settled: a route whose entry can't be used or isn't connected is blocked, never sent
        // straight to its server instead; only a WireGuard tunnel can go through another.
        for r in setup.activeRoutes where r.via != nil && out[r.id] != nil {
            if let why = viaBlock(r, setup: setup, out: out, providers: providers) { out.removeValue(forKey: r.id); blocked[r.id] = .unreachable(why) }
        }
        let remember = Dictionary(setup.activeRoutes.filter { !$0.imported }.compactMap { r -> (String, Link)? in
            guard let link = out[r.id] else { return nil }
            return (cacheKey(r, account: accounts[r.loc.provider]), bases[r.id] ?? link)
        }) { $1 }
        // A provider can return success after its request was cancelled. Its answer no longer belongs to this pick.
        try Task.checkCancellation()
        return Result(links: out, remember: remember, blocked: blocked)
    }

    /// Why a Via route can't be used with the tunnels picked, or nil when it can.
    private static func viaBlock(_ r: Route, setup: Setup, out: [String: Link], providers: (String) -> (any Provider)?) -> String? {
        if let why = setup.viaProblem(r) { return why }
        guard case .wg(_, let peer, _, _)? = out[r.id] else { return "Via works for WireGuard routes only" }
        if !r.viaNative {
            let host = peer.endpoint.split(separator: ":", omittingEmptySubsequences: false).dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if !FilterServer.ipv4(host) { return "\(r.name) needs an IPv4 server address to go through another route" }
        }
        guard let entry = r.via.flatMap(setup.route) else { return nil }
        // Not tried together yet: blocked rather than sent without the disguise or the Via.
        if let x = [r, entry].first(where: { !$0.imported && setup.opt($0.loc.provider, "disguise") == "on" }) {
            return "\(r.name): Disguise doesn't work with Via yet. Turn Disguise off on the \(providers(x.loc.provider)?.name ?? x.loc.provider) page, or remove the Via"
        }
        if !r.viaNative {
            guard case .wg? = out[entry.id] else { return "\(r.name) waits for \(entry.name), the route it goes through" }
        }
        return nil
    }

    /// A route blocked for a reason the picker words itself (see `nativeHop`).
    private struct Hop: Error { let reason: Blocked }

    /// `r`'s tunnel as the provider's own multi-hop: the exit's key and server key, dialed at the entry server's address
    /// on the exit's forwarding port. The entry's server is the entry route's own when it runs, else asked for (never
    /// while offline: the route waits until then, it is never left straight). The two must be in different countries.
    private static func nativeHop(_ r: Route, setup: Setup, out: [String: Link], blocked: [String: Blocked], gone: RemovedPins, refused: [String: Blocked],
                                  accounts: [String: String], offline: Bool, providers: (String) -> (any Provider)?) async throws -> Link {
        guard let v = r.via, let e = setup.route(v), case .wg(let server, var peer, let ports, let entries)? = out[r.id] else {
            throw Hop(reason: .unreachable("\(r.name): multi-hop works for WireGuard routes only"))
        }
        guard let port = peer.hopPort else {
            throw Hop(reason: .unreachable("\(r.name): \(server.name) doesn't say how to reach it by multi-hop right now. Try again later, or use two tunnels"))
        }
        let entry: Server
        if case .wg(let s, _, _, _)? = out[e.id] { entry = s }
        // The main pick's word on the entry stands: one it blocked is not asked for again, nor a removed or refused one.
        else if blocked[e.id] != nil || setup.activeRoutes.contains(where: { $0.id == e.id }) {
            throw Hop(reason: .unreachable("\(r.name) waits for \(e.name), the route it goes through"))
        }
        else if let why = gone.reason(for: e) ?? refused[e.loc.provider] { throw Hop(reason: why) }
        else if offline { throw Hop(reason: .waiting) }
        else {
            guard let p = providers(e.loc.provider) else { throw Fail("Unknown provider \(e.loc.provider)") }
            guard let account = accounts[p.id] else { throw AuthError("Sign in to \(p.name) for \(e.name)") }
            do {
                guard case .wg(let s, _, _, _) = try await p.connect(AutoProtocol.resolved(e), account, opts: setup.opts[p.id] ?? [:]) else {
                    throw Hop(reason: .unreachable("\(r.name): its entry \(e.name) is not a WireGuard route"))
                }
                entry = s
            } catch is Catalog.Gone {
                throw Hop(reason: .unreachable("\(r.name): its entry \(e.name) is on a server that's no longer offered. Choose another for \(e.name)"))
            }
        }
        guard Catalog.Entry.publicIPv4(entry.ip) else { throw Hop(reason: .unreachable("\(r.name): its entry \(e.name) has no address to connect to")) }
        if entry.ip == server.ip { throw Hop(reason: .unreachable("\(r.name) and its entry are on the same server")) }
        let inEntry = entry.country.isEmpty ? (e.loc.countryCode ?? "") : entry.country
        let inExit = server.country.isEmpty ? (r.loc.countryCode ?? "") : server.country
        if inEntry.isEmpty || inExit.isEmpty || inEntry.caseInsensitiveCompare(inExit) == .orderedSame {
            throw Hop(reason: .unreachable("\(r.name) and its entry must be in two different countries. Pick servers in two countries"))
        }
        peer.endpoint = "\(entry.ip):\(port)"
        peer.hopEntry = entry.ip
        return .wg(server, peer, ports: ports, entries: entries)
    }

    /// A tunnel already made to go through an entry server's address: never kept, cached or reused.
    static func hopped(_ l: Link) -> Bool {
        if case .wg(_, let peer, _, _) = l { return peer.hopEntry != nil }
        return false
    }

    /// A server that can't take a disguised tunnel while the provider page's Disguise is on.
    struct NoDisguise: LocalizedError {
        let provider: String
        let server: String
        var errorDescription: String? { "\(server) can't be reached through V2Ray right now. Pick another server, or turn Disguise off on the \(provider) page" }
    }

    /// With Disguise on for its provider, a WireGuard tunnel must come with its V2Ray data: never a plain one instead.
    static func disguised(_ setup: Setup, _ r: Route, _ l: Link) -> Bool {
        guard !r.imported, setup.opt(r.loc.provider, "disguise") == "on", case .wg(_, let peer, _, _) = l else { return true }
        return peer.disguise != nil
    }

    /// The same from a provider's raw options (the cached tunnel that stands in for a failed lookup): only IVPN has Disguise.
    static func disguised(_ opts: [String: String], _ r: Route, _ l: Link) -> Bool {
        guard !r.imported, r.loc.provider == "ivpn", opts["disguise"] == "on", case .wg(_, let peer, _, _) = l else { return true }
        return peer.disguise != nil
    }

    /// Applies the selected provider ports to the links. `step` is the number of ports that have failed, per tunnel (provider and
    /// server, `serverKey`): routes on one server share it, another server keeps its port. A route the health round moved
    /// to another server carries its own count (`routeStepKey`), so it goes on from the port it had reached (`steps`).
    static func ported(_ setup: Setup, _ links: [String: Link], step: [String: Int]) -> [String: Link] {
        let stepFor = steps(setup, links, step: step)
        var lists: [String: [Int]] = [:]
        for id in links.keys.sorted() {
            guard let r = setup.route(id), !r.imported, case .wg(_, let p, let ports, _) = links[id], !ports.isEmpty, p.hopEntry == nil else { continue }
            if lists[r.loc.provider] == nil { lists[r.loc.provider] = ports }
        }
        let plain = links.mapValuesWithKey { id, link in
            guard case .wg(let server, var peer, let ports, let entries) = link else { return link }
            // The provider's multi-hop has its own forwarding port at the entry: no port or entry setting moves it.
            if peer.hopEntry != nil, let route = setup.route(id), !route.imported {
                peer.mtu = Int(setup.opt(route.loc.provider, "mtu") ?? "") ?? 1280
                peer.junk = setup.opt(route.loc.provider, "junk") == "on" ? ProviderOption.junkCount : 0
                (peer.vmess, peer.disguise) = (nil, nil)
                return .wg(server, peer, ports: ports, entries: entries)
            }
            guard let route = setup.route(id), !route.imported else {
                peer.mtu = min(peer.mtu, 1280)
                peer.junk = 0
                (peer.vmess, peer.disguise) = (nil, nil)
                return .wg(server, peer, ports: ports, entries: entries)
            }
            let provider = route.loc.provider
            if let colon = peer.endpoint.lastIndex(of: ":") {
                var host = String(peer.endpoint[..<colon])
                // A tunnel that was disguised dials its V2Ray server's WireGuard port: not one to go back to.
                let oldPort = peer.vmess == nil ? String(peer.endpoint[peer.endpoint.index(after: colon)...]) : String(Ivpn.port)
                let offered = ports.isEmpty ? (lists[provider] ?? []) : ports
                // IVPN's fixed-port choices come from the complete server list; its automatic list is a smaller subset.
                let fixed = setup.opt(provider, "port").flatMap(Int.init).flatMap {
                    (offered.contains($0) || (provider == "ivpn" && (1...65535).contains($0))) ? $0 : nil
                }
                let offset = max(0, stepFor[id] ?? 0)
                let picked = fixed ?? (offered.isEmpty ? nil : offered[offset % offered.count])
                // A port the server takes on one entry address only goes to that entry, whatever the entry setting says. A
                // tunnel that doesn't know that entry would dial nowhere: it takes the first port any entry takes.
                let only = provider == "airvpn" ? AirVpn.portEntry : [:]
                let needs = picked.flatMap { only[$0] }
                let fits = needs.map { $0 <= entries.count } ?? true
                let port = (fits ? picked : offered.first { only[$0] == nil }).map(String.init) ?? oldPort
                let entry = fits ? needs : nil
                if let index = entry ?? setup.opt(provider, "entry").flatMap(Int.init), index > 0, index <= entries.count { host = entries[index - 1] }
                peer.endpoint = "\(host):\(port)"
            }
            peer.mtu = Int(setup.opt(provider, "mtu") ?? "") ?? 1280
            peer.vmess = nil
            peer.junk = setup.opt(provider, "junk") == "on" ? ProviderOption.junkCount : 0
            // Disguised: the tunnel goes inside V2Ray to the server's own WireGuard port behind it. The port setting
            // doesn't apply, and the small packet size does. A server without the data stays plain here and is held
            // back by `disguised` before this (and refused by the compiler if it ever got this far).
            if provider == "ivpn", setup.opt(provider, "disguise") == "on", let d = peer.disguise,
               let colon = peer.endpoint.lastIndex(of: ":") {
                peer.endpoint = "\(peer.endpoint[..<colon]):\(d.wgPort)"
                peer.vmess = d.vmess
                peer.mtu = 1280
            }
            return .wg(server, peer, ports: ports, entries: entries)
        }
        // A tunnel inside another one loses its outer headers' room: 1280 less WireGuard's 80.
        return plain.mapValuesWithKey { id, link in
            guard case .wg(let server, var peer, let ports, let entries) = link, let route = setup.route(id), route.via != nil, !route.viaNative else { return link }
            peer.mtu = min(peer.mtu, viaMtu)
            return .wg(server, peer, ports: ports, entries: entries)
        }
    }

    /// The largest packet size of a tunnel that goes through another route.
    static let viaMtu = 1200

    /// A provider's WireGuard tunnel names the host and port it dials. One without (a server that had no address) is
    /// never compiled: the engine would get a peer with an empty address.
    static func dialable(_ l: Link) -> Bool {
        guard case .wg(_, let peer, _, _) = l else { return true }
        guard let colon = peer.endpoint.lastIndex(of: ":"), let port = Int(peer.endpoint[peer.endpoint.index(after: colon)...]) else { return false }
        return !peer.endpoint[..<colon].isEmpty && (1...65535).contains(port)
    }

    /// A kept or cached tunnel is reused only if its provider still vouches for its server key (`Provider.trusts`).
    static func trusted(_ l: Link, _ r: Route, _ accounts: [String: String], _ providers: (String) -> (any Provider)?) -> Bool {
        // Without the provider or its account nobody vouches for it: connect afresh, which says what's missing.
        guard let p = providers(r.loc.provider), let acc = accounts[p.id] else { return false }
        return p.trusts(l, acc)
    }

    private static func again(_ p: any Provider, _ r: Route, _ acc: String, _ last: [String: Link], _ used: Set<String>,
                              _ accounts: [String: String], _ opts: [String: String], _ providers: (String) -> (any Provider)?) async throws -> Link? {
        guard p.oneKey, r.loc.pinned == nil, let cached = last[cacheKey(r, account: acc)], case .wg = cached,
              dialable(cached), trusted(cached, r, accounts, providers), !used.contains(serverKey(r, cached)) else { return nil }
        do {
            guard let server = try await p.servers(r.loc, acc, limit: 10, opts: opts).first(where: { serverId($0) == serverId(cached.server) }) else { return nil }
            var loc = r.loc
            loc.pinned = server
            let link = try await p.connect(loc, acc, opts: opts)
            return dialable(link) && trusted(link, r, accounts, providers) ? link : nil
        } catch let e as AuthError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private static func fresh(_ r: Route, _ accounts: [String: String], _ last: [String: Link], _ used: Set<String>,
                              _ avoid: Set<String>, _ opts: [String: String], _ providers: (String) -> (any Provider)?) async throws -> Link {
        guard let p = providers(r.loc.provider) else { throw Fail("Unknown provider \(r.loc.provider)") }
        guard let acc = accounts[p.id] else { throw AuthError("Sign in to \(p.name) for \(r.name)") }
        let pinned = r.loc.pinned
        // Automatic is asked for as the protocol it has come to: WireGuard, or OpenVPN TCP once the network blocked it.
        let asked = AutoProtocol.resolved(r)
        let l: Link
        do {
            if let previous = try await again(p, r, acc, last, used, accounts, opts, providers) { l = previous }
            else { l = try await p.connect(asked, acc, opts: opts) }
        } catch let e as AuthError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as Catalog.Damaged {
            // Not an outage: no cached tunnel stands in, and the message says what to do.
            throw e
        } catch let e as Catalog.Gone {
            // Nor is a pinned server the provider just said it no longer has.
            throw e
        } catch let e as KeyNotReady {
            // No cached tunnel stands in either: it would run without the quantum-safe key.
            throw e
        } catch let e as Unsupported {
            // Nor for a protocol the sign-in can't serve: a WireGuard tunnel would not be what the route asked for.
            throw e
        } catch {
            guard !(p.id == "mullvad" && pinned == nil && opts["owned"] == "on"),
                  let cached = last[cacheKey(r, account: acc)], (pinned != nil || r.loc.group == Nord.dedicatedIp || !avoid.contains(serverKey(r, cached))), dialable(cached), !hopped(cached), trusted(cached, r, accounts, providers), disguised(opts, r, cached), AutoProtocol.matches(r, cached) else {
                throw pinned.map { Fail("\(r.name): \($0.name) is unreachable") } ?? error
            }
            l = cached
        }
        guard dialable(l) else { throw Fail("\(r.name): \(l.server.name) has no address to connect to") }
        if pinned != nil || !used.contains("\(p.id)|\(serverId(l.server))") { return l }
        // The best server is taken by another route: any other server of the location will do, else share this one.
        var other: Link?
        do {
            let servers = try await p.servers(asked, acc, limit: 10, opts: opts)
            if let server = servers.first(where: { !used.contains("\(p.id)|\(serverId($0))") }) {
                var loc = asked
                loc.pinned = server
                let candidate = try await p.connect(loc, acc, opts: opts)
                if dialable(candidate) { other = candidate }
            }
        } catch let error as AuthError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation() }
        try Task.checkCancellation()
        return other ?? l
    }
}

private extension Dictionary {
    nonisolated func mapValuesWithKey<T>(_ transform: (Key, Value) -> T) -> [Key: T] {
        Dictionary<Key, T>(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
