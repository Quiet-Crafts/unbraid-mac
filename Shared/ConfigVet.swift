import Foundation

/// Defence in depth for the tunnel extension: the engine runs as root, so it runs only the shape of config unbraid's
/// compiler writes, even if something in the app were turned against it. Every object, at every depth, may hold only the
/// fields the compiler writes for it (`Field`), so nothing it never writes can reach the engine: no services, rule sets,
/// listeners, relays or advertised routes, no interface outside the tunnel, no system proxy, no remote-control API or log
/// file. Only the protocol types the compiler uses (some engine types run programs or write files); the tun as the compiler
/// writes it and at most one authenticated proxy on loopback, on an unprivileged port; the compiler's own cache file and
/// Tailscale's state in its own folder, and no other file path anywhere; at most 4 MB; at most one Tailscale node. What the
/// compiler always writes must be there, and its fixed values as it writes them: one tun, a final route and resolvers, every
/// name pointing at something defined, and, with any endpoint, the rules that refuse what comes in through one. The engine reads field names without regard to case (Unicode folding included:
/// "ſ" reads as "s"), so names must be plain ASCII, every check ignores case, and an object holding two names that differ
/// only in case is refused. A Shadowsocks plugin can't name a file to read (cert=).
nonisolated enum ConfigVet {
    /// What a field may hold: a value (text, a number, true or false, or a list of those), an object or a list of objects
    /// with only these fields, or a list of objects checked on their own (`.list`).
    private enum Field { case value, object([String: Field]), objects([String: Field]), list }

    private static let sections: [String: Field] = [
        "log": .object(["level": .value, "timestamp": .value]),
        "dns": .object(["servers": .list, "rules": .list, "final": .value, "strategy": .value, "timeout": .value, "cache_capacity": .value,
                        "optimistic": .object(["enabled": .value, "timeout": .value])]),
        "inbounds": .list, "endpoints": .list, "outbounds": .list,
        "route": .object(["rules": .list, "final": .value, "auto_detect_interface": .value, "default_domain_resolver": .value]),
        "experimental": .object(["cache_file": .object(["enabled": .value, "path": .value, "store_fakeip": .value])]),
    ]

    private static func fields(_ names: String...) -> [String: Field] { Dictionary(uniqueKeysWithValues: names.map { ($0, .value) }) }

    private static let servers: [String: [String: Field]] = [
        "fakeip": fields("type", "tag", "inet4_range"),
        "local": fields("type", "tag"),
        "udp": fields("type", "tag", "server", "server_port", "detour"),
        "https": fields("type", "tag", "server", "server_port", "path", "detour", "domain_resolver").merging(["tls": .object(fields("enabled", "server_name"))]) { $1 },
        "tls": fields("type", "tag", "server", "server_port", "detour", "domain_resolver").merging(["tls": .object(fields("enabled", "server_name"))]) { $1 },
        "openvpn": fields("type", "tag", "endpoint", "accept_default_resolvers", "fallback_server"),
        "tailscale": fields("type", "tag", "endpoint", "accept_default_resolvers"),
    ]

    private static let inbounds: [String: [String: Field]] = [
        "tun": fields("type", "tag", "address", "mtu", "auto_route", "strict_route", "stack", "udp_mapping", "udp_timeout", "route_address",
                      "route_exclude_address"),
        "mixed": fields("type", "tag", "listen", "listen_port").merging(["users": .objects(fields("username", "password"))]) { $1 },
    ]

    private static let endpoints: [String: [String: Field]] = [
        "wireguard": fields("type", "tag", "mtu", "address", "private_key").merging([
            "peers": .objects(fields("address", "port", "public_key", "pre_shared_key", "allowed_ips", "persistent_keepalive_interval")),
        ]) { $1 },
        // Everything Manual's OpenVPN import writes.
        "openvpn-client": fields(
            "type", "tag", "server", "server_port", "network", "remote_random", "username", "password", "auth_retry", "data_ciphers",
            "data_ciphers_fallback", "auth", "compression_lzo", "compression", "allow_compression", "mss_fix_disabled", "mss_fix",
            "mss_fix_mode", "fragment", "mtu", "renegotiate_disabled", "renegotiate_interval", "renegotiate_bytes", "renegotiate_packets",
            "ping_interval", "ping_restart_disabled", "ping_restart", "tls_timeout", "handshake_window", "explicit_exit_notify",
            "block_ipv6", "replay_window", "replay_window_time", "route_no_pull"
        ).merging([
            "servers": .objects(fields("server", "server_port", "network")),
            "pull_filters": .objects(fields("action", "text")),
            "tls": .object(fields(
                "server_name", "server_name_type", "certificate", "client_certificate", "client_key", "peer_fingerprint",
                "remote_certificate_ku", "remote_certificate_tls", "remote_certificate_eku", "ns_certificate_type", "version_min",
                "version_max", "cipher", "certificate_profile"
            ).merging(["control_wrap": .object(fields("type", "key", "direction"))]) { $1 }),
        ]) { $1 },
        // No relay, advertised routes or exit node, SSH server or interface of its own.
        "tailscale": fields("type", "tag", "state_directory", "hostname", "accept_routes", "auth_key", "control_url", "exit_node",
                            "exit_node_allow_lan_access"),
    ]

    private static let outbounds: [String: [String: Field]] = [
        "direct": fields("type", "tag"),
        "shadowsocks": fields("type", "tag", "server", "server_port", "method", "password", "plugin", "plugin_opts"),
    ]

    /// What a routing rule may match on, and in a logical rule each of its own rules (those may also be inverted).
    private static let routeMatch = fields("inbound", "auth_user", "process_path_regex", "ip_cidr", "domain", "domain_suffix", "port",
                                           "network", "protocol", "ip_version")
    /// What each routing action may say beyond its matches.
    private static let routeActions: [String: Set<String>] = ["route": ["outbound"], "reject": ["no_drop"], "hijack-dns": [], "resolve": ["server"]]
    private static let dnsMatch = fields("inbound", "process_path_regex", "domain_suffix", "query_type")
    private static let dnsActions: [String: Set<String>] = ["route": ["server", "rewrite_ttl"], "predefined": ["rcode"]]

    /// The tun as the compiler writes it: its addresses (the resolver the system is given is the next one), every address
    /// routed into it but local networks (`route_exclude_address` may only leave out those), gVisor's stack (the system
    /// stack listens on the tun's address), and a UDP session per destination.
    private static let tunAddress = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
    /// Everything, and the tun's own subnet (where the resolver is) even inside an excluded local range.
    private static let tunRoutes: Set = ["0.0.0.0/0", "::/0", "172.19.0.0/30"]
    private static let localNetworks: Set = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
                                             "255.255.255.255/32", "fc00::/7", "fe80::/10", "ff00::/8"]
    /// The engine's lookup cache: the only file the compiler names, which the extension removes before each start
    /// (any other name would outlive the connection, or replace a file of the engine's own there).
    static let cacheFile = "cache.db"
    static let fakeRanges = (0..<8).map { "198.\(18 + $0 / 4).\($0 % 4 * 64).0/18" }
    static func nextFakeBlock(_ last: Int) -> Int { (last + 1) % fakeRanges.count }
    #if DEBUG
    /// Debug builds may log at debug level (DebugHooks.engineConfig).
    private static let logLevels: Set = ["warn", "debug"]
    #else
    private static let logLevels: Set = ["warn"]
    #endif

    /// Returns the config as checked, re-serialised: the engine runs exactly that, so names a parser would see twice
    /// (duplicates resolved differently by Foundation and Go) can't carry anything past the check.
    @discardableResult
    static func check(_ config: String) throws -> String {
        let refused = Fail("The configuration was refused")
        guard config.utf8.count <= 4 << 20, let parsed = try? JSONSerialization.jsonObject(with: Data(config.utf8)),
              walk(parsed, cachePathAllowed: false), let root = parsed as? [String: Any], let r = folded(root),
              fits(r, sections), ["dns", "inbounds", "outbounds", "route"].allSatisfy({ r[$0] != nil }) else { throw refused }
        func object(_ v: Any?) throws -> [String: Any] {
            guard let v else { return [:] }
            guard let o = v as? [String: Any], let f = folded(o) else { throw refused }
            return f
        }
        // A section of the wrong shape is refused, not skipped.
        func objects(_ v: Any?) throws -> [[String: Any]] {
            guard let v else { return [] }
            guard let a = v as? [Any] else { throw refused }
            return try a.map { try object($0) }
        }
        func type(_ o: [String: Any]) -> String { (o["type"] as? String)?.lowercased() ?? "" }
        /// Each item a known type holding only that type's fields.
        func typed(_ items: [[String: Any]], _ known: [String: [String: Field]]) throws {
            guard items.allSatisfy({ item in known[type(item)].map { fits(item, $0) } ?? false }) else { throw refused }
        }

        let dns = try object(r["dns"]), route = try object(r["route"])
        let servers = try objects(dns["servers"]), inbounds = try objects(r["inbounds"])
        let endpoints = try objects(r["endpoints"]), outbounds = try objects(r["outbounds"]), exits = endpoints + outbounds
        try typed(servers, Self.servers)
        guard servers.allSatisfy({ server in
            guard let value = server["fallback_server"] else { return true }
            guard type(server) == "openvpn", let ip = value as? String else { return false }
            return ipv4(ip)
        }) else { throw refused }
        try typed(inbounds, Self.inbounds)
        try typed(endpoints, Self.endpoints)
        try typed(outbounds, Self.outbounds)

        let tuns = inbounds.filter { type($0) == "tun" }, proxies = inbounds.filter { type($0) == "mixed" }
        guard tuns.count == 1, let tun = tuns.first, tun["address"] as? [String] == tunAddress, isFlag(tun["auto_route"]), tun["auto_route"] as? Bool == true,
              tun["stack"] as? String == "gvisor", tun["udp_mapping"] as? String == "address_and_port_dependent",
              let routed = tun["route_address"] as? [String], Set(routed).isSuperset(of: tunRoutes),
              Set(tun["route_exclude_address"] as? [String] ?? []).isSubset(of: localNetworks),
              tun["route_exclude_address"] == nil || tun["route_exclude_address"] is [String] else { throw refused }
        // What the compiler writes the same every time: the fake addresses' range, the log level, IPv4 lookups only, and
        // Direct leaving through the network's own interface with names resolved locally.
        let log = try object(r["log"])
        guard logLevels.contains(log["level"] as? String ?? ""), dns["strategy"] as? String == "ipv4_only",
              isFlag(route["auto_detect_interface"]), route["auto_detect_interface"] as? Bool == true,
              route["default_domain_resolver"] as? String == "local",
              servers.allSatisfy({ type($0) != "fakeip" || (["198.18.0.0/15"] + fakeRanges).contains($0["inet4_range"] as? String ?? "") }) else { throw refused }
        // The app's own way into each exit: loopback only, on a port of the app's choosing (never a privileged one root
        // alone could take), and never without a password.
        guard proxies.count <= 1, proxies.allSatisfy({ p in
            let port = p["listen_port"] == nil ? 0 : isFlag(p["listen_port"]) ? nil : p["listen_port"] as? Int
            guard p["listen"] as? String == "127.0.0.1", let port, port == 0 || (1024...65_535).contains(port),
                  let users = p["users"] as? [Any], !users.isEmpty else { return false }
            return users.allSatisfy { u in
                guard let u = (u as? [String: Any]).flatMap(folded) else { return false }
                return !(u["username"] as? String ?? "").isEmpty && !(u["password"] as? String ?? "").isEmpty
            }
        }) else { throw refused }
        for item in exits {
            // Tailscale writes its state as root: only into its own folder. Its control server only over HTTPS: over
            // plain HTTP a network attacker could hand it a fake control-server key.
            if let dir = item["state_directory"], dir as? String != "tailscale" { throw refused }
            if let url = item["control_url"] {
                guard let c = URLComponents(string: url as? String ?? ""), c.scheme == "https", !(c.host ?? "").isEmpty, c.user == nil,
                      c.password == nil else { throw refused }
            }
            if type(item) == "shadowsocks" { try checkPlugin(item) }
        }
        // What the compiler always writes, so nothing is left to the engine's defaults: a final route and resolvers, every
        // name pointing at something that exists.
        // At most one Tailscale endpoint: each user's engine has one sealed Tailscale state, and two nodes would take
        // turns overwriting it.
        guard exits.count(where: { type($0) == "tailscale" }) <= 1,
              let exitTags = tags(exits), let serverTags = tags(servers), !serverTags.isEmpty,
              let final = route["final"] as? String, exitTags.contains(final),
              servers.allSatisfy({ s in s["detour"] == nil || exitTags.contains(s["detour"] as? String ?? "") }),
              servers.allSatisfy({ s in s["domain_resolver"] == nil || (serverTags.contains(s["domain_resolver"] as? String ?? "") && s["domain_resolver"] as? String != s["tag"] as? String) }),
              // A tunnel's own resolver asks through an endpoint of its kind.
              servers.allSatisfy({ s in
                  s["endpoint"] == nil || endpoints.contains { $0["tag"] as? String == s["endpoint"] as? String && type($0) == (type(s) == "openvpn" ? "openvpn-client" : type(s)) }
              }),
              serverTags.contains(dns["final"] as? String ?? ""),
              serverTags.contains(route["default_domain_resolver"] as? String ?? ""),
              namesOnly(serverTags, in: dns["rules"]), namesOnly(serverTags, in: route["rules"]) else { throw refused }
        for server in servers where ["https", "tls"].contains(type(server)) {
            guard let address = server["server"] as? String, !address.isEmpty,
                  let port = server["server_port"] as? Int, !isFlag(server["server_port"]), (1...65535).contains(port),
                  let tls = (server["tls"] as? [String: Any]).flatMap(folded), isFlag(tls["enabled"]), tls["enabled"] as? Bool == true,
                  tls["server_name"] == nil || (tls["server_name"] as? String)?.isEmpty == false,
                  type(server) != "https" || ((server["path"] as? String)?.hasPrefix("/") == true) else { throw refused }
            guard ipv4(address) || server["domain_resolver"] is String else { throw refused }
            if let resolver = server["domain_resolver"] as? String {
                guard let boot = servers.first(where: { $0["tag"] as? String == resolver }),
                      ["udp", "openvpn", "local"].contains(type(boot)) else { throw refused }
                if let detour = server["detour"] as? String {
                    guard boot["detour"] as? String == detour || type(boot) == "openvpn" && boot["endpoint"] as? String == detour else { throw refused }
                } else if type(boot) != "local" { throw refused }
            }
        }
        let routeRules = try objects(route["rules"]), dnsRules = try objects(dns["rules"])
        guard routeRules.allSatisfy({ routeRule($0, exits: exitTags) }), dnsRules.allSatisfy(dnsRule) else { throw refused }
        let fake = servers.filter { type($0) == "fakeip" }
        guard fake.count == 1, let range = fake[0]["inet4_range"] as? String else { throw refused }
        let noDrop = routeRules.filter { $0["no_drop"] != nil }
        guard noDrop.allSatisfy({ rule in
            let keys = Set(rule.keys)
            return rule["action"] as? String == "reject" && isFlag(rule["no_drop"]) && rule["no_drop"] as? Bool == true
                && (keys == ["action", "no_drop"] || keys == ["process_path_regex", "action", "no_drop"] || keys == ["ip_cidr", "action", "no_drop"])
        }) else { throw refused }
        let cidrRefusals = noDrop.filter { $0["ip_cidr"] != nil }
        let unspecified = Set(["0.0.0.0/32", "::/128"])
        func isUnspecified(_ rule: [String: Any]) -> Bool {
            guard let ranges = rule["ip_cidr"] as? [String] else { return false }
            return ranges.count == 2 && Set(ranges) == unspecified
        }
        let guards = cidrRefusals.filter { !isUnspecified($0) }
        if range == "198.18.0.0/15" {
            guard guards.isEmpty else { throw refused }
        } else {
            let expected = Set(fakeRanges.filter { $0 != range })
            guard guards.count == 1, let rule = guards.first,
                  Set(rule.keys) == ["ip_cidr", "action", "no_drop"], rule["action"] as? String == "reject",
                  isFlag(rule["no_drop"]), rule["no_drop"] as? Bool == true,
                  let ranges = rule["ip_cidr"] as? [String], ranges.count == 7, Set(ranges) == expected,
                  let position = routeRules.firstIndex(where: { $0["no_drop"] != nil && $0["ip_cidr"] != nil && !isUnspecified($0) }),
                  position == (endpoints.isEmpty ? 0 : 1) else { throw refused }
        }
        // Whatever a tunnel's far side sends into it is refused before any other rule, connections and lookups alike. A
        // copy sealed by an older version without these rules is refused too, until the app seals a current one.
        if let tunnels = tags(endpoints), !tunnels.isEmpty {
            func refusesTunnels(_ rule: [String: Any]?, _ fields: [String: String]) -> Bool {
                guard let rule, Set(rule.keys) == Set(fields.keys).union(["inbound"]), let inbound = rule["inbound"] as? [String],
                      Set(inbound) == tunnels else { return false }
                return fields.allSatisfy { rule[$0.key] as? String == $0.value }
            }
            guard refusesTunnels(routeRules.first, ["action": "reject"]),
                  refusesTunnels(dnsRules.first, ["action": "predefined", "rcode": "REFUSED"]) else { throw refused }
        }
        let cache = try object(try object(r["experimental"])["cache_file"])
        guard cache["path"] == nil || cache["path"] as? String == cacheFile,
              let data = try? JSONSerialization.data(withJSONObject: parsed, options: [.withoutEscapingSlashes, .sortedKeys]),
              let canonical = String(data: data, encoding: .utf8) else { throw refused }
        return canonical
    }

    /// Select the table's block after checking the original policy, then check the exact config that will run.
    static func fakeBlock(_ checked: String, _ block: Int) throws -> String {
        let refused = Fail("The configuration was refused")
        guard fakeRanges.indices.contains(block),
              var root = try JSONSerialization.jsonObject(with: Data(checked.utf8)) as? [String: Any],
              let dnsKey = root.keys.first(where: { $0.lowercased() == "dns" }),
              let routeKey = root.keys.first(where: { $0.lowercased() == "route" }),
              var dns = root[dnsKey] as? [String: Any], var route = root[routeKey] as? [String: Any],
              let serversKey = dns.keys.first(where: { $0.lowercased() == "servers" }),
              let rulesKey = route.keys.first(where: { $0.lowercased() == "rules" }),
              var servers = dns[serversKey] as? [[String: Any]], var rules = route[rulesKey] as? [[String: Any]],
              let index = servers.firstIndex(where: { ($0.first { $0.key.lowercased() == "type" }?.value as? String)?.lowercased() == "fakeip" }),
              let rangeKey = servers[index].keys.first(where: { $0.lowercased() == "inet4_range" }) else { throw refused }
        servers[index][rangeKey] = fakeRanges[block]
        rules.removeAll { rule in
            guard let rule = folded(rule), Set(rule.keys) == ["ip_cidr", "action", "no_drop"],
                  let ranges = rule["ip_cidr"] as? [String] else { return false }
            return ranges.count == 7 && Set(ranges).count == 7 && Set(ranges).isSubset(of: Set(fakeRanges))
        }
        let first = rules.first.flatMap(folded)
        let insertion = first?["inbound"] != nil && first?["action"] as? String == "reject" ? 1 : 0
        rules.insert(["ip_cidr": fakeRanges.enumerated().filter { $0.offset != block }.map(\.element),
                      "action": "reject", "no_drop": true], at: insertion)
        dns[serversKey] = servers; route[rulesKey] = rules
        root[dnsKey] = dns; root[routeKey] = route
        let data = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes, .sortedKeys])
        return try check(String(decoding: data, as: UTF8.self))
    }

    /// Fields that can carry a secret or name a server, at any depth: none may appear in a credential-free configuration.
    /// (A rule's "server" names a resolver by its tag.)
    private static let secretFields: Set = ["auth_key", "private_key", "pre_shared_key", "password", "username", "users", "key",
                                            "client_key", "client_certificate", "certificate", "control_url", "state_directory",
                                            "server_port", "servers", "peers", "endpoint", "detour"]

    /// Whether [checked] (as `check` returns it) is a Connect on Demand fallback (`PacketTunnelProvider.sealFallback`): it
    /// can use no account and reaches no server (no endpoint, no outbound but direct, no inbound but the tun, only the
    /// local and fake resolvers, none of `secretFields` anywhere, DNS servers aside, which are listed under "servers"), and
    /// it lets traffic out as Direct does: everything leaves through direct (routing's final) and nothing is refused but
    /// IPv6 and stale fake addresses; no lookup is refused, and every one is answered (only address lookups go
    /// to the fake resolver, which answers nothing else). Values aren't read: a tag or a match may hold any text, which
    /// nothing here can send anywhere.
    static func isFallback(_ checked: String) -> Bool {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(checked.utf8)), let root = (parsed as? [String: Any]).flatMap(folded) else { return false }
        /// Each item of a list section, names case-folded; nil when the section isn't a list of objects.
        func items(_ v: Any?) -> [[String: Any]]? {
            guard let v else { return [] }
            guard let list = v as? [Any] else { return nil }
            let objects = list.compactMap { ($0 as? [String: Any]).flatMap(folded) }
            return objects.count == list.count ? objects : nil
        }
        func types(_ list: [[String: Any]]) -> Set<String> { Set(list.map { ($0["type"] as? String)?.lowercased() ?? "" }) }
        guard let dns = (root["dns"] as? [String: Any]).flatMap(folded), let servers = items(dns["servers"]), let dnsRules = items(dns["rules"]),
              let route = (root["route"] as? [String: Any]).flatMap(folded), let routeRules = items(route["rules"]),
              let endpoints = items(root["endpoints"]), let outbounds = items(root["outbounds"]), let inbounds = items(root["inbounds"]),
              endpoints.isEmpty, types(outbounds).isSubset(of: ["direct"]), types(inbounds) == ["tun"],
              types(servers).isSubset(of: ["local", "fakeip"]) else { return false }
        // Resolvers by tag: lookups are answered by the local one, and only address lookups by the fake one, as the
        // compiler writes them (it answers nothing else, so every other lookup sent there would fail); whatever no rule
        // claims, by the local one.
        var resolvers: [String: String] = [:]
        for server in servers {
            guard let tag = server["tag"] as? String, resolvers[tag] == nil else { return false }
            resolvers[tag] = (server["type"] as? String)?.lowercased()
        }
        func addresses(_ v: Any?) -> Bool {
            guard let v else { return false }
            let list = v as? [Any] ?? [v]
            return !list.isEmpty && list.allSatisfy { ["A", "AAAA"].contains($0 as? String ?? "") }
        }
        // Domains are resolved with the local resolver too, by default, when routing connects to them.
        guard resolvers[dns["final"] as? String ?? ""] == "local", resolvers[route["default_domain_resolver"] as? String ?? ""] == "local",
              dnsRules.allSatisfy({ r in
                  guard (r["action"] as? String)?.lowercased() ?? "route" == "route" else { return false }
                  switch resolvers[r["server"] as? String ?? ""] {
                  case "local": return true
                  case "fakeip": return addresses(r["query_type"])
                  default: return false
                  }
              }) else { return false }
        // Out through direct, whatever no rule claims; IPv6, stale fake addresses and unspecified addresses are refused.
        let direct = Set(outbounds.compactMap { $0["tag"] as? String })
        guard let final = route["final"] as? String, direct.contains(final),
              routeRules.allSatisfy({ r in
                  switch (r["action"] as? String)?.lowercased() ?? "route" {
                  case "route": return r["type"] == nil && direct.contains(r["outbound"] as? String ?? "")
                  case "reject": return Set(r.keys) == ["ip_version", "action"] && (r["ip_version"] as? Int) == 6
                          || Set(r.keys) == ["ip_cidr", "action", "no_drop"] && r["no_drop"] as? Bool == true
                              && Set(r["ip_cidr"] as? [String] ?? []).count == 7
                              && Set(r["ip_cidr"] as? [String] ?? []).isSubset(of: Set(fakeRanges))
                          || Set(r.keys) == ["ip_cidr", "action", "no_drop"] && r["no_drop"] as? Bool == true
                              && (r["ip_cidr"] as? [String])?.count == 2
                              && Set(r["ip_cidr"] as? [String] ?? []) == ["0.0.0.0/32", "::/128"]
                  // Only DNS is taken for the engine's resolver, as the compiler writes it.
                  case "hijack-dns":
                      return Set(r.keys) == ["protocol", "action"] && (r["protocol"] as? String)?.lowercased() == "dns"
                          || Set(r.keys) == ["port", "network", "action"] && r["port"] as? Int == 53 && (r["network"] as? String)?.lowercased() == "udp"
                  // With the local resolver: the fake one would send everything to addresses that lead nowhere.
                  case "resolve": return r["type"] == nil && resolvers[r["server"] as? String ?? ""] == "local"
                  default: return false
                  }
              }) else { return false }
        func clean(_ v: Any, _ name: String?) -> Bool {
            if let a = v as? [Any] { return a.allSatisfy { clean($0, nil) } }
            guard let o = v as? [String: Any] else { return true }
            return o.allSatisfy { k, value in
                let key = k.lowercased()
                // The resolvers were checked above: only the local and fake ones.
                if key == "servers", name == "dns" { return true }
                return !secretFields.contains(key) && clean(value, key)
            }
        }
        return clean(root, nil)
    }

    /// A routing rule: its matches, then one of the actions the compiler uses with only what that action takes. A logical
    /// rule's own rules only match, one level deep.
    private static func routeRule(_ rule: [String: Any], exits: Set<String>) -> Bool {
        var match = routeMatch
        if let t = rule["type"] {
            guard t as? String == "logical", ["and", "or"].contains(rule["mode"] as? String ?? ""), let own = rule["rules"] as? [Any], !own.isEmpty,
                  own.allSatisfy({ fits($0, .object(routeMatch.merging(["invert": .value]) { $1 })) })
            else { return false }
            match = ["type": .value, "mode": .value, "rules": .list]
        }
        let action = rule["action"] as? String ?? "route"
        guard rule["action"] == nil || rule["action"] is String, let extra = routeActions[action],
              fits(rule, match.merging(fields("action")) { $1 }.merging(extra.map { ($0, Field.value) }) { $1 }) else { return false }
        switch action {
        case "route": return exits.contains(rule["outbound"] as? String ?? "")
        case "resolve": return rule["server"] != nil
        default: return true
        }
    }

    /// A DNS rule: its matches, then a resolver (with how long its answers are kept) or a fixed refusal.
    private static func dnsRule(_ rule: [String: Any]) -> Bool {
        let action = rule["action"] as? String ?? "route"
        guard rule["action"] == nil || rule["action"] is String, let extra = dnsActions[action],
              fits(rule, dnsMatch.merging(fields("action")) { $1 }.merging(extra.map { ($0, Field.value) }) { $1 }) else { return false }
        return action == "route" ? rule["server"] != nil : ["REFUSED", "NXDOMAIN", "NOERROR"].contains(rule["rcode"] as? String ?? "")
    }

    /// tsnet's own folder for [uid]'s engine (tailnet lock state, certificates), beside the engine's working files.
    static func tailscaleDirectory(_ uid: uid_t) -> String { "tailscale-\(uid)" }

    /// What the engine runs for [uid]: the checked config with every Tailscale endpoint's folder that user's own, as its
    /// node identity already is. The compiler writes (and `check` allows) only "tailscale"; the revision and the sealed copy
    /// stay those of the checked config, so this is applied to what runs and nothing else.
    static func owned(_ checked: String, by uid: uid_t) throws -> String {
        let refused = Fail("The configuration was refused")
        guard var root = try? JSONSerialization.jsonObject(with: Data(checked.utf8)) as? [String: Any] else { throw refused }
        // Names were checked ASCII and unique regardless of case, which is how the engine reads them.
        for section in Array(root.keys) where ["endpoints", "outbounds"].contains(section.lowercased()) {
            guard let items = root[section] as? [Any] else { continue }
            root[section] = items.map { item -> Any in
                guard var o = item as? [String: Any], (o.first { $0.key.lowercased() == "type" }?.value as? String)?.lowercased() == "tailscale" else { return item }
                for key in Array(o.keys) where key.lowercased() == "state_directory" { o[key] = nil }
                o["state_directory"] = tailscaleDirectory(uid)
                return o
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { throw refused }
        return text
    }

    private static func ipv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil && ($0 == "0" || $0.first != "0") }
    }

    /// Each item's tag: nil if one is missing, empty or given twice.
    private static func tags(_ items: [[String: Any]]) -> Set<String>? {
        var out: Set<String> = []
        for item in items {
            guard let tag = item["tag"] as? String, !tag.isEmpty, out.insert(tag).inserted else { return nil }
        }
        return out
    }

    /// Every rule naming a resolver (`server`), logical rules' own rules included, names one of `servers`.
    private static func namesOnly(_ servers: Set<String>, in rules: Any?) -> Bool {
        guard let rules else { return true }
        guard let list = rules as? [Any] else { return false }
        for case let rule as [String: Any] in list {
            guard let r = folded(rule) else { return false }
            if let s = r["server"], !servers.contains(s as? String ?? "") { return false }
            if !namesOnly(servers, in: r["rules"]) { return false }
        }
        return list.allSatisfy { $0 is [String: Any] }
    }

    /// The plugins the importer takes, and never v2ray-plugin's cert= (a file the engine would read as root). SIP003
    /// escapes with backslashes, which are dropped first so "c\ert=" can't slip past (as Manual.parseSs does).
    private static func checkPlugin(_ ss: [String: Any]) throws {
        let refused = Fail("The configuration was refused")
        if let plugin = ss["plugin"], !["obfs-local", "v2ray-plugin"].contains(plugin as? String ?? "") { throw refused }
        guard let opts = ss["plugin_opts"] else { return }
        guard let text = opts as? String else { throw refused }
        let names = text.replacingOccurrences(of: "\\", with: "").split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }
        if names.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "cert" }) { throw refused }
    }

    /// Every object at every depth: plain ASCII names, no two differing only in case, and no file path but the cache's.
    private static func walk(_ v: Any, cachePathAllowed: Bool) -> Bool {
        if let a = v as? [Any] { return a.allSatisfy { walk($0, cachePathAllowed: false) } }
        guard let o = v as? [String: Any] else { return true }
        guard o.keys.allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) }), folded(o) != nil else { return false }
        for (k, value) in o {
            let key = k.lowercased()
            let isPath = key == "path" || key.hasSuffix("_path") || key.hasSuffix("_directory") || key == "directory" || key == "torrc"
            let dohPath = key == "path" && (o.first { $0.key.lowercased() == "type" }?.value as? String)?.lowercased() == "https" && (value as? String)?.hasPrefix("/") == true
            if isPath && !(cachePathAllowed && key == "path") && !dohPath && key != "state_directory" { return false }
            if !walk(value, cachePathAllowed: key == "cache_file") { return false }
        }
        return true
    }

    /// Whether [o] (names lowercased) holds only [schema]'s fields, each of its shape.
    private static func fits(_ o: [String: Any], _ schema: [String: Field]) -> Bool {
        o.allSatisfy { k, v in schema[k].map { fits(v, $0) } ?? false }
    }

    private static func fits(_ v: Any, _ field: Field) -> Bool {
        func scalar(_ v: Any) -> Bool { v is String || v is NSNumber }
        switch field {
        case .value: return scalar(v) || (v as? [Any])?.allSatisfy(scalar) == true
        case .object(let schema): return (v as? [String: Any]).flatMap(folded).map { fits($0, schema) } ?? false
        case .objects(let schema): return (v as? [Any])?.allSatisfy { fits($0, .object(schema)) } == true
        case .list: return v is [Any]
        }
    }

    /// Whether [v] is JSON's true or false: Foundation reads those as numbers too (and numbers as them).
    private static func isFlag(_ v: Any?) -> Bool {
        (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }

    /// The object with lowercased names, or nil if two names differ only in case.
    private static func folded(_ o: [String: Any]) -> [String: Any]? {
        var out: [String: Any] = [:]
        for (k, v) in o {
            let key = k.lowercased()
            guard out[key] == nil else { return nil }
            out[key] = v
        }
        return out
    }
}
