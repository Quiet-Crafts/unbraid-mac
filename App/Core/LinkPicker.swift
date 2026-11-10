import Foundation

/// Chooses the tunnel each active route runs.
nonisolated enum LinkPicker {
    enum Blocked: Equatable, Sendable {
        case signedOut(String), refused(String, String), removed(String), unreachable(String), noLongerOffered(String), clash, waiting

        var text: String {
            switch self {
            case .signedOut: "signed out"
            case .refused(let provider, _): "\(provider) refused this Mac. Sign in again"
            case .removed(let provider): "\(provider) no longer has this Mac. Sign in again."
            case .unreachable(let message): message
            case .noLongerOffered(let server): "\(server) is no longer offered. Pick another server"
            case .clash: Compiler.clashMessage
            case .waiting: "waiting for a server"
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
            guard !route.imported, let pin = route.loc.pinned else { return nil }
            return entries.values.first {
                $0.location.provider == route.loc.provider && $0.location.pinned?.host == pin.host
            }?.reason
        }
    }

    /// Changes that must reach the engine before a provider can delay them. A ready route also needs the new app
    /// rules installed when another route is waiting, otherwise apps leaving Direct still use their real address.
    static func needsInterim(from old: Setup?, to new: Setup, revoking: Bool = false) -> Bool {
        guard let old else { return false }
        if revoking { return true }
        let routes = Set(new.activeRoutes.map(\.id))
        func changes(_ before: String, _ after: String) -> Bool {
            (before == DIRECT && routes.contains(after)) || (before != BLOCK && after == BLOCK)
        }
        return changes(old.defaultRoute, new.defaultRoute)
            || Set(old.apps.keys).union(new.apps.keys).contains { changes(old.routeOf($0), new.routeOf($0)) }
    }

    /// Fallback-cache key: a pinned route is its own entry, so it can never inherit another server's tunnel.
    static func serverKey(_ r: Route, _ l: Link) -> String { "\(r.loc.provider)|\(serverId(l.server))" }

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
        return "\(r.loc.provider)|@\(owner)|\(place)|\(r.loc.pinned.map(serverId) ?? "")"
    }

    private static func serverId(_ s: Server) -> String { s.ip.isEmpty ? s.host : s.ip }

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
            if let reason = gone.reason(for: r) { blocked[r.id] = reason; continue }
            if let reason = deferred[r.id] { blocked[r.id] = reason; continue }
            if !r.imported, let reason = refused[r.loc.provider] { blocked[r.id] = reason; continue }
            let link: Link
            do {
                if let w = r.wg {
                    link = .wg(Server(name: w.name, host: w.endpoint.split(separator: ":", omittingEmptySubsequences: false).dropLast().joined(separator: ":"), ip: "", publicKey: w.publicKey, load: 0), w)
                } else if let o = r.ovpn {
                    link = .ovpn(Server(name: o.name, host: o.name, ip: "", publicKey: "", load: 0), o)
                } else if let s = r.ss {
                    link = .ss(Server(name: s.name, host: s.server, ip: s.server, publicKey: "", load: 0), s)
                } else if let x = r.tsExit {
                    link = .ts(Server(name: r.name, host: x, ip: "", publicKey: "", load: 0))
                } else if let k = keep[r.id], let a = applied?.route(r.id), !a.imported, a.loc == r.loc,
                          appliedAccounts[r.loc.provider] == accounts[r.loc.provider],
                          (r.loc.provider != "mullvad" || r.loc.pinned != nil || applied?.opt("mullvad", "owned") == setup.opt("mullvad", "owned")),
                          (r.loc.pinned != nil || r.loc.group == Nord.dedicatedIp || !avoid.contains(serverKey(r, k))), dialable(k), trusted(k, r, accounts, providers) {
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
                          dialable(cached), trusted(cached, r, accounts, providers) else {
                        blocked[r.id] = .waiting
                        continue
                    }
                    link = cached
                } else {
                    link = try await fresh(r, accounts, last, used, avoid, setup.opts[r.loc.provider] ?? [:], providers)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let provider = providers(r.loc.provider)?.name ?? r.loc.provider
                if error is AuthError {
                    blocked[r.id] = accounts[r.loc.provider] == nil ? .signedOut(provider) : .refused(provider, error.localizedDescription)
                } else if let gone = error as? Catalog.Gone {
                    blocked[r.id] = .noLongerOffered(gone.server)
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
            if let pin = r.loc.pinned, let gone = setup.activeRoutes.lazy.compactMap({ other -> Blocked? in
                guard !other.imported, other.loc.provider == r.loc.provider, other.loc.pinned?.host == pin.host,
                      let reason = blocked[other.id] else { return nil }
                if case .noLongerOffered = reason { return reason }
                return nil
            }).first {
                blocked[r.id] = gone; out.removeValue(forKey: r.id)
            }
        }
        out = ported(setup, out, step: portStep)
        for id in Compiler.clashes(setup, out) { out.removeValue(forKey: id); blocked[id] = .clash }
        let remember = Dictionary(setup.activeRoutes.filter { !$0.imported }.compactMap { r in out[r.id].map { (cacheKey(r, account: accounts[r.loc.provider]), $0) } }) { $1 }
        // A provider can return success after its request was cancelled. Its answer no longer belongs to this pick.
        try Task.checkCancellation()
        return Result(links: out, remember: remember, blocked: blocked)
    }

    /// Applies the selected provider ports to the links.
    static func ported(_ setup: Setup, _ links: [String: Link], step: [String: Int]) -> [String: Link] {
        var lists: [String: [Int]] = [:]
        for id in links.keys.sorted() {
            guard let r = setup.route(id), !r.imported, case .wg(_, _, let ports, _) = links[id], !ports.isEmpty else { continue }
            if lists[r.loc.provider] == nil { lists[r.loc.provider] = ports }
        }
        return links.mapValuesWithKey { id, link in
            guard case .wg(let server, var peer, let ports, let entries) = link else { return link }
            guard let route = setup.route(id), !route.imported else {
                peer.mtu = min(peer.mtu, 1280)
                return .wg(server, peer, ports: ports, entries: entries)
            }
            let provider = route.loc.provider
            if let colon = peer.endpoint.lastIndex(of: ":") {
                var host = String(peer.endpoint[..<colon])
                let oldPort = String(peer.endpoint[peer.endpoint.index(after: colon)...])
                if let value = setup.opt(provider, "entry"), let index = Int(value), index > 0, index <= entries.count { host = entries[index - 1] }
                let offered = ports.isEmpty ? (lists[provider] ?? []) : ports
                // IVPN's fixed-port choices come from the complete server list; its automatic list is a smaller subset.
                let fixed = setup.opt(provider, "port").flatMap(Int.init).flatMap {
                    (offered.contains($0) || (provider == "ivpn" && (1...65535).contains($0))) ? $0 : nil
                }
                let offset = max(0, step[provider] ?? 0)
                let port = fixed.map(String.init) ?? (offered.isEmpty ? oldPort : String(offered[offset % offered.count]))
                peer.endpoint = "\(host):\(port)"
            }
            peer.mtu = Int(setup.opt(provider, "mtu") ?? "") ?? 1280
            return .wg(server, peer, ports: ports, entries: entries)
        }
    }

    /// A provider's WireGuard tunnel names the host and port it dials. One without (a server that had no address) is
    /// never compiled: the engine would get a peer with an empty address.
    static func dialable(_ l: Link) -> Bool {
        guard case .wg(_, let peer, _, _) = l else { return true }
        guard let colon = peer.endpoint.lastIndex(of: ":"), let port = Int(peer.endpoint[peer.endpoint.index(after: colon)...]) else { return false }
        return !peer.endpoint[..<colon].isEmpty && (1...65535).contains(port)
    }

    /// A kept or cached tunnel is reused only if its provider still vouches for its server key (`Provider.trusts`).
    private static func trusted(_ l: Link, _ r: Route, _ accounts: [String: String], _ providers: (String) -> (any Provider)?) -> Bool {
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
        let l: Link
        do {
            if let previous = try await again(p, r, acc, last, used, accounts, opts, providers) { l = previous }
            else { l = try await p.connect(r.loc, acc, opts: opts) }
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
        } catch {
            guard !(p.id == "mullvad" && pinned == nil && opts["owned"] == "on"),
                  let cached = last[cacheKey(r, account: acc)], (pinned != nil || r.loc.group == Nord.dedicatedIp || !avoid.contains(serverKey(r, cached))), dialable(cached), trusted(cached, r, accounts, providers) else {
                throw pinned.map { Fail("\(r.name): \($0.name) is unreachable") } ?? error
            }
            l = cached
        }
        guard dialable(l) else { throw Fail("\(r.name): \(l.server.name) has no address to connect to") }
        if pinned != nil || !used.contains("\(p.id)|\(serverId(l.server))") { return l }
        // The best server is taken by another route: any other server of the location will do, else share this one.
        var other: Link?
        do {
            let servers = try await p.servers(r.loc, acc, limit: 10, opts: opts)
            if let server = servers.first(where: { !used.contains("\(p.id)|\(serverId($0))") }) {
                var loc = r.loc
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
