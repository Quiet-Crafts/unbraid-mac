import Foundation

/// Manually configured servers: OpenVPN (.ovpn) and Shadowsocks (ss:// links) → sing-box JSON.
nonisolated enum Manual {
    private static let maxOvpn = 256 * 1024
    private static let defaultCiphers = ["AES-256-GCM", "AES-128-GCM", "CHACHA20-POLY1305"]
    private static let digests = words("SHA1 SHA224 SHA256 SHA384 SHA512")
    private static let tlsVersions = words("1.0 1.1 1.2 1.3")
    private static let profiles = words("legacy preferred insecure suiteb")
    private static let maxSsLink = 8 * 1024
    private static let maxSsUserinfo = 1024
    private static let maxSsName = 128
    private static let maxHost = 253

    nonisolated(unsafe) private static let pem = /-----BEGIN ([A-Za-z0-9 ]+)-----[\s\S]*?-----END \1-----/
    nonisolated(unsafe) private static let cipher = /AES-(128|192|256)-(CBC|GCM)|CHACHA20-POLY1305|(CAMELLIA|ARIA)-(128|192|256)-CBC/

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    /// The TLS 1.2 suites sing-openvpn's `tls.cipher` accepts, by OpenSSL and by IANA name.
    private static let tlsCiphers = words(
        "RC4-SHA DES-CBC3-SHA AES128-SHA AES256-SHA AES128-SHA256 AES128-GCM-SHA256 AES256-GCM-SHA384 "
            + "ECDHE-ECDSA-AES128-SHA ECDHE-ECDSA-AES256-SHA ECDHE-ECDSA-RC4-SHA ECDHE-RSA-RC4-SHA ECDHE-RSA-DES-CBC3-SHA "
            + "ECDHE-RSA-AES128-SHA ECDHE-RSA-AES256-SHA ECDHE-ECDSA-AES128-SHA256 ECDHE-RSA-AES128-SHA256 "
            + "ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-RSA-AES128-GCM-SHA256 ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-RSA-AES256-GCM-SHA384 "
            + "ECDHE-ECDSA-CHACHA20-POLY1305 ECDHE-RSA-CHACHA20-POLY1305 "
            + "TLS_RSA_WITH_RC4_128_SHA TLS_RSA_WITH_3DES_EDE_CBC_SHA TLS_RSA_WITH_AES_128_CBC_SHA TLS_RSA_WITH_AES_256_CBC_SHA "
            + "TLS_RSA_WITH_AES_128_CBC_SHA256 TLS_RSA_WITH_AES_128_GCM_SHA256 TLS_RSA_WITH_AES_256_GCM_SHA384 "
            + "TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA TLS_ECDHE_ECDSA_WITH_RC4_128_SHA "
            + "TLS_ECDHE_RSA_WITH_RC4_128_SHA TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA "
            + "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256 TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256 "
            + "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256 TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 "
            + "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256")

    private static let used = words(
        "client tls-client pull remote remote-random port rport proto dev dev-type ca cert key "
            + "tls-auth tls-crypt tls-crypt-v2 key-direction auth-user-pass auth-retry cipher data-ciphers ncp-ciphers "
            + "data-ciphers-fallback ncp-disable auth remote-cert-tls remote-cert-eku remote-cert-ku ns-cert-type "
            + "verify-x509-name tls-version-min tls-version-max tls-cert-profile comp-lzo compress allow-compression "
            + "mssfix fragment tun-mtu reneg-sec reneg-bytes reneg-pkts ping ping-restart keepalive tls-timeout "
            + "hand-window explicit-exit-notify replay-window peer-fingerprint key-method tls-cipher pull-filter compat-mode block-ipv6")

    /// Directives that only affect the host OS, routing, logging or scripts; sing-box decides routing itself, scripts never run.
    private static let ignored = words(
        "nobind persist-key persist-tun persist-local-ip persist-remote-ip resolv-retry verb mute mute-replay-warnings "
            + "connect-retry connect-retry-max connect-timeout server-poll-timeout auth-nocache fast-io float sndbuf rcvbuf "
            + "socket-flags tcp-nodelay tcp-queue-limit txqueuelen user group daemon log log-append syslog status "
            + "suppress-timestamps script-security up down up-restart down-pre route-up route-pre-down ipchange setenv "
            + "setenv-safe route route-ipv6 route-gateway route-metric route-delay route-method route-noexec route-nopull "
            + "redirect-gateway redirect-private block-outside-dns dhcp-option dhcp-renew dhcp-release register-dns "
            + "ifconfig-noexec ifconfig-nowarn push-peer-info disable-occ ignore-unknown-option remote-random-hostname "
            + "tls-exit ping-exit ping-timer-rem inactive lport local bind topology "
            + "tun-ipv6 mlock mtu-disc mtu-test link-mtu tun-mtu-extra dev-node ip-win32 win-sys keysize "
            + "x509-username-field opt-verify dns allow-pull-fqdn tran-window auth-token show-ciphers")

    private static let rejected = [
        "pkcs12": "PKCS#12 bundles aren't supported; use a .ovpn with inline <ca>, <cert> and <key> blocks",
        "secret": "Static-key (secret) profiles aren't supported",
        "mode": "Only client profiles are supported",
        "tls-server": "Only client profiles are supported",
        "server": "Only client profiles are supported",
        "http-proxy": "OpenVPN over an HTTP proxy isn't supported",
        "socks-proxy": "OpenVPN over a SOCKS proxy isn't supported",
        "plugin": "OpenVPN plugins aren't supported",
        "crl-verify": "crl-verify isn't supported",
        "static-challenge": "Interactive (2FA) logins aren't supported",
        "auth-user-pass-verify": "Only client profiles are supported",
        "ifconfig": "Static tunnel addresses aren't supported",
        "connection": "<connection> blocks aren't supported",
        "askpass": "Encrypted private keys aren't supported",
        "capath": "capath isn't supported; embed the CA in a <ca> block",
        "cryptoapicert": "Windows certificate store isn't supported",
        "management": "Management interface isn't supported",
        "tls-ciphersuites": "tls-ciphersuites (a TLS 1.3 cipher restriction) can't be enforced; remove it from the profile",
    ]

    private static let blockNames = words("ca cert key tls-auth tls-crypt tls-crypt-v2 dh extra-certs auth-user-pass peer-fingerprint")
    private static let pullActions = words("accept ignore reject")
    private static let serverEku: Set = ["serverauth", "tls web server authentication", "1.3.6.1.5.5.7.3.1"]
    private static let clientEku: Set = ["clientauth", "tls web client authentication", "1.3.6.1.5.5.7.3.2"]

    /// `seq` keeps every directive in file order, for options where a later one overrides an earlier one of another name.
    private struct Cfg {
        var d: [String: [[String]]] = [:]
        var keys: [String] = []
        var blocks: [String: String] = [:]
        var blockKeys: [String] = []
        var seq: [(String, [String])] = []

        func has(_ k: String) -> Bool { d[k] != nil }
        func arg(_ k: String, _ i: Int = 0) -> String? { d[k]?.last.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        func last(_ k: String...) -> (String, [String])? { seq.last { k.contains($0.0) } }
    }

    private static func req(_ ok: Bool, _ message: @autoclosure () -> String) throws { if !ok { throw Fail(message()) } }
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Kotlin's `lines()`: keeps empty lines, splits on \n, \r\n and \r.
    private static func lines(_ s: String) -> [String] { s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) }

    private static func tokens(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var active = false
        let cs = Array(line)
        var i = 0
        while i < cs.count {
            let c = cs[i]
            i += 1
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && i < cs.count { cur.append(cs[i]); i += 1 } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; active = true
            } else if c.isWhitespace {
                if active { out.append(cur); cur = ""; active = false }
            } else if !active && (c == "#" || c == ";") {
                return out
            } else if c == "\\" && i < cs.count {
                cur.append(cs[i]); i += 1; active = true
            } else {
                cur.append(c); active = true
            }
        }
        if active { out.append(cur) }
        return out
    }

    private static func read(_ text: String) throws -> Cfg {
        var c = Cfg()
        var open: String?
        var buf = ""
        for raw in lines(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text) {
            let line = trim(raw)
            if let o = open {
                if line == "</\(o)>" {
                    if c.blocks.updateValue(buf, forKey: o) == nil { c.blockKeys.append(o) }
                    buf = ""; open = nil
                } else { buf += (o == "auth-user-pass" ? raw : line) + "\n" }
                continue
            }
            let t = tokens(line)
            guard let first = t.first else { continue }
            if t.count == 1 && first.hasPrefix("<") && first.hasSuffix(">") && !first.hasPrefix("</") { open = String(first.dropFirst().dropLast()); continue }
            let name = first.hasPrefix("--") ? String(first.dropFirst(2)) : first
            if c.d[name] == nil { c.keys.append(name) }
            let args = Array(t.dropFirst())
            c.d[name, default: []].append(args)
            c.seq.append((name, args))
        }
        if let open { throw Fail("Unterminated <\(open)> block") }
        return c
    }

    private static func pems(_ name: String, _ block: String) throws -> String {
        try req(block.firstMatch(of: /ENCRYPTED|Proc-Type/) == nil, "Encrypted private keys aren't supported")
        let found = block.matches(of: pem).map { lines(String($0.output.0)).map(trim).joined(separator: "\n") }
        try req(!found.isEmpty, "The <\(name)> block is empty or malformed")
        return found.joined(separator: "\n")
    }

    private static func network(_ s: String) throws -> String {
        var n = s.lowercased()
        if n.hasSuffix("-client") { n.removeLast(7) }
        try req(words("udp udp4 udp6 tcp tcp4 tcp6").contains(n), "Unsupported protocol: \(s)")
        return n
    }

    private static func seconds(_ k: String, _ v: String?) throws -> String {
        guard let n = v.flatMap({ Int($0) }), n >= 0 else { throw Fail("Invalid \(k) value") }
        return "\(n)s"
    }

    private static func ciphers(_ k: String, _ v: String) throws -> [String] {
        try v.uppercased().split(separator: ":").map(String.init).map {
            try req($0.wholeMatch(of: cipher) != nil, "Unsupported cipher in \(k): \($0) (use AES-GCM, ChaCha20 or an AES/Camellia/ARIA CBC cipher)")
            return $0
        }
    }

    /// Validates a .ovpn and keeps it with its login. Throws Fail with a readable reason.
    static func parseOvpn(_ text: String, name: String, username: String, password: String) throws -> OvpnProfile {
        let p = OvpnProfile(name: name, config: text, username: username, password: password)
        _ = try build("check", p)
        return p
    }

    struct WarningConfirmation {
        private(set) var warning: String?
        mutating func allows(_ next: String?) -> Bool {
            guard let next else { warning = nil; return true }
            guard warning != next else { return true }
            warning = next
            return false
        }
        mutating func clear() { warning = nil }
    }

    private static let risk = " Someone between you and this server may be able to read or change your traffic. Import it only if the server can't be updated."

    static func weakness(_ p: OvpnProfile) throws -> String? {
        let c = try read(p.config)
        var issues: [String] = []
        if ["1.0", "1.1"].contains(c.arg("tls-version-min") ?? "") { issues.append("allows TLS 1.0 or 1.1") }
        if (c.arg("tls-cipher") ?? "").split(separator: ":").contains(where: { $0.contains("RC4") || $0.contains("3DES") || $0.contains("DES-CBC3") }) {
            issues.append("allows the broken RC4 or 3DES ciphers")
        }
        if c.arg("tls-cert-profile") == "insecure" { issues.append("accepts weak server certificates (tls-cert-profile insecure)") }
        let role = c.last("remote-cert-eku", "remote-cert-tls").map { key, args in
            args.count == 1 && (key == "remote-cert-tls" ? args[0].lowercased() == "server" : serverEku.contains(args[0].lowercased()))
        } ?? false
        let fingerprint = c.d["peer-fingerprint", default: []].contains { !$0.isEmpty } || !(c.blocks["peer-fingerprint"].map(trim) ?? "").isEmpty
        if !role && c.arg("ns-cert-type") != "server" && (c.arg("verify-x509-name") ?? "").isEmpty && !fingerprint {
            issues.append("doesn't check that it reaches the right server (no remote-cert-tls server, verify-x509-name or peer-fingerprint)")
        }
        return issues.isEmpty ? nil : "This config \(issues.joined(separator: ", "))." + risk
    }

    static func weakness(_ p: SsProfile) -> String? {
        p.method.contains("gcm") || p.method.contains("poly1305") ? nil : "\(p.method) has no integrity check." + risk
    }

    /// A sing-box `openvpn-client` endpoint for `p`.
    static func ovpnEndpoint(_ tag: String, _ p: OvpnProfile) throws -> J { try build(tag, p) }

    /// The login to use: what was typed wins; otherwise the profile's inline `<auth-user-pass>` block (username line, password line).
    private static func login(_ p: OvpnProfile, _ inline: String?) -> (String, String) {
        guard let inline, p.username.allSatisfy(\.isWhitespace), p.password.isEmpty else { return (p.username, p.password) }
        let l = lines(inline).filter { !trim($0).isEmpty }
        return l.count >= 2 ? (trim(l[0]), l[1]) : ("", "")
    }

    private static func build(_ tag: String, _ p: OvpnProfile) throws -> J {
        try req(p.config.utf16.count <= maxOvpn, "That file is too large for an OpenVPN config")
        let c = try read(p.config)
        for k in c.keys {
            if let why = rejected[k] { throw Fail(why) }
            try req(used.contains(k) || ignored.contains(k), "Unsupported OpenVPN option: \(k)")
        }
        for k in c.blockKeys {
            if let why = rejected[k] { throw Fail(why) }
            try req(blockNames.contains(k), "Unsupported OpenVPN block: <\(k)>")
        }
        try req(c.has("client") || (c.has("tls-client") && c.has("pull")), "Not a client profile (no 'client' line)")
        let dev = c.arg("dev"), devType = c.arg("dev-type")
        try req((devType == nil || devType == "tun") && (dev.map { $0.hasPrefix("tun") } ?? (devType == "tun")), "Only tun (layer 3) profiles are supported")
        try req(c.arg("key-method") == nil || c.arg("key-method") == "2", "Unsupported key-method")

        var defaultPort = 1194
        if let v = c.last("port", "rport")?.1.first {
            guard let n = Int(v) else { throw Fail("Invalid port: \(v)") }
            defaultPort = n
        }
        let defaultNet = try network(c.arg("proto") ?? "udp")
        var remotes: [(host: String, port: Int, net: String)] = []
        for a in c.d["remote"] ?? [] {
            let host = a.first ?? ""
            try req(!trim(host).isEmpty, "Empty remote host")
            var port = defaultPort
            if a.count > 1 {
                guard let n = Int(a[1]) else { throw Fail("Invalid remote port: \(a[1])") }
                port = n
            }
            try req((1...65535).contains(port), "Remote port out of range: \(port)")
            let net = try a.count > 2 ? network(a[2]) : defaultNet
            remotes.append((host, port, net))
        }
        try req(!remotes.isEmpty, "The profile has no 'remote' server")

        try req(!c.has("ca") || c.blocks["ca"] != nil, "The CA must be inline (<ca> block), not a file path")
        for k in ["cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2"] {
            try req(!c.has(k) || c.blocks[k] != nil, "\(k) must be inline (<\(k)> block), not a file path")
        }
        let fingerprints = (c.d["peer-fingerprint"] ?? []).compactMap(\.first) + lines(c.blocks["peer-fingerprint"] ?? "").map(trim).filter { !$0.isEmpty }
        try req(c.blocks["ca"] != nil || !fingerprints.isEmpty, "The profile has no <ca> block")
        try req((c.blocks["cert"] != nil) == (c.blocks["key"] != nil), "The profile needs both <cert> and <key>, or neither")
        let wraps = ["tls-auth", "tls-crypt", "tls-crypt-v2"].filter { c.blocks[$0] != nil }
        try req(wraps.count <= 1, "Use only one of tls-auth, tls-crypt and tls-crypt-v2")

        try req(c.blocks["extra-certs"] == nil || c.blocks["cert"] != nil, "<extra-certs> needs a <cert> block")

        let needsLogin = c.has("auth-user-pass") || c.blocks["auth-user-pass"] != nil
        let (user, pass) = login(p, c.blocks["auth-user-pass"])
        try req(!needsLogin || (!trim(user).isEmpty && !pass.isEmpty), "This profile needs a username and password")

        var compat = 0
        if let v = c.arg("compat-mode") {
            guard let m = v.wholeMatch(of: /([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/) else { throw Fail("Invalid compat-mode: \(v)") }
            compat = Int(m.1)! * 10000 + Int(m.2)! * 100 + Int(m.3)!
        }
        let before24 = compat > 0 && compat < 20400
        let before25 = compat > 0 && compat < 20500
        func single(_ k: String, _ a: [String]) throws -> String {
            let l = try ciphers(k, a.first ?? "")
            guard l.count == 1 else { throw Fail("Invalid \(k) value") }
            return l[0]
        }
        // OpenVPN stores `cipher` and `data-ciphers-fallback` in one slot, so whichever comes last names the cipher.
        var named: String?
        for (k, a) in c.seq where k == "cipher" || k == "data-ciphers-fallback" { named = try single(k, a) }
        let explicit = try (c.arg("data-ciphers") ?? c.arg("ncp-ciphers")).map { try ciphers("data-ciphers", $0) }
        var pinned: [String]?
        if c.has("ncp-disable") {
            guard let cip = c.arg("cipher") else { throw Fail("ncp-disable needs a cipher line") }
            pinned = [try single("cipher", [cip])]
        }
        try req(!before24 || named != nil, "compat-mode below 2.4.0 needs a cipher line (the old BF-CBC default isn't supported)")
        // OpenVPN 2.6 negotiates only from data-ciphers; a lone `cipher` is the fallback only for compat-mode < 2.4.0 or data-ciphers-fallback.
        let fallback = pinned?[0] ?? (c.has("data-ciphers-fallback") || before24 ? named : nil)
        let base = explicit ?? defaultCiphers
        var dataCiphers = pinned
        if dataCiphers == nil {
            let l = before25 && named != nil && !base.contains(named!) ? base + [named!] : base
            dataCiphers = explicit != nil || l != defaultCiphers ? l : nil
        }
        // OpenVPN also takes IANA names with dashes ("TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384"); the engine knows the
        // underscore form.
        let tlsCipher = c.arg("tls-cipher").map { v in
            v.split(separator: ":", omittingEmptySubsequences: false).map { s in
                s.hasPrefix("TLS-") && s.contains("-WITH-") ? s.replacingOccurrences(of: "-", with: "_") : String(s)
            }.joined(separator: ":")
        }
        if let v = tlsCipher, let bad = v.split(separator: ":", omittingEmptySubsequences: false).first(where: { !tlsCiphers.contains(String($0)) }) {
            throw Fail("Unsupported tls-cipher: \(bad) (only the TLS 1.2 suites sing-box implements, by OpenSSL or IANA name)")
        }
        let auth = c.arg("auth")?.uppercased()
        if let auth { try req(digests.contains(auth), "Unsupported auth digest: \(auth)") }

        var lzo: String?
        if c.has("comp-lzo") {
            let v = (c.arg("comp-lzo") ?? "adaptive").lowercased()
            try req(words("yes no adaptive asym").contains(v), "Unsupported comp-lzo value: \(v)")
            lzo = v
        }
        var compress: String?
        if c.has("compress") {
            let v = (c.arg("compress") ?? "stub").lowercased()
            try req(words("stub stub-v2 lz4 lz4-v2").contains(v), "Unsupported compression: compress \(v)")
            compress = v
        }
        let compressing = (lzo != nil && lzo != "no") || compress?.hasPrefix("lz4") == true
        let allow = c.arg("allow-compression")
        if let allow { try req(words("no asym yes").contains(allow), "Invalid allow-compression") }
        try req(!compressing || allow != "no", "allow-compression no conflicts with the compression in this profile")

        let tcp = remotes.contains { $0.net.hasPrefix("tcp") }
        var fragment: Int?
        if let f = c.arg("fragment") {
            guard let n = Int(f), n >= 68 else { throw Fail("Invalid fragment value") }
            fragment = n
        }
        try req(fragment == nil || !tcp, "fragment only works over UDP")
        var mtu: Int?
        if let m = c.arg("tun-mtu") {
            guard let n = Int(m), (576...9000).contains(n) else { throw Fail("Invalid tun-mtu value") }
            mtu = n
        }

        var o: [String: J] = ["type": "openvpn-client", "tag": .s(tag)]
        if remotes.count == 1 {
            o["server"] = .s(remotes[0].host); o["server_port"] = .i(remotes[0].port); o["network"] = .s(remotes[0].net)
        } else {
            o["servers"] = .a(remotes.map { .o(["server": .s($0.host), "server_port": .i($0.port), "network": .s($0.net)]) })
            if c.has("remote-random") { o["remote_random"] = true }
        }
        if needsLogin { o["username"] = .s(user); o["password"] = .s(pass) }
        if let r = c.arg("auth-retry") {
            try req(words("none nointeract interact").contains(r), "Invalid auth-retry")
            o["auth_retry"] = .s(r)
        }

        var tls: [String: J] = [:]
        if let a = c.d["verify-x509-name"]?.last {
            guard let name = a.first else { throw Fail("Invalid verify-x509-name") }
            let type = a.count > 1 ? a[1] : "subject"
            try req(words("subject name name-prefix").contains(type), "Invalid verify-x509-name type: \(type)")
            if let fields = c.d["x509-username-field"]?.last {
                try req(type == "subject" || (fields.count == 1 && fields[0].lowercased() == "cn"),
                        "verify-x509-name with x509-username-field \(fields.joined(separator: " ")) isn't supported: only the certificate's CN can be checked")
            }
            tls["server_name"] = .s(name); tls["server_name_type"] = .s(type)
        }
        if let ca = c.blocks["ca"] { tls["certificate"] = .s(try pems("ca", ca)) }
        // A client certificate chain is the leaf followed by its intermediates, which is how <extra-certs> is meant.
        if let cert = c.blocks["cert"] {
            let chain = [try pems("cert", cert)] + (try c.blocks["extra-certs"].map { [try pems("extra-certs", $0)] } ?? [])
            tls["client_certificate"] = .s(chain.joined(separator: "\n"))
        }
        if let key = c.blocks["key"] { tls["client_key"] = .s(try pems("key", key)) }
        if !fingerprints.isEmpty {
            tls["peer_fingerprint"] = .strings(try fingerprints.map { f in
                let h = f.replacingOccurrences(of: ":", with: "").lowercased()
                try req(h.wholeMatch(of: /[0-9a-f]{64}/) != nil, "Invalid peer-fingerprint")
                return h
            })
        }
        let ku = c.d["remote-cert-ku"]?.last
        if let ku, !ku.isEmpty {
            for v in ku { try req(v.wholeMatch(of: /(0x)?[0-9a-fA-F]+/) != nil, "Invalid remote-cert-ku value") }
            tls["remote_certificate_ku"] = .strings(ku)
        }
        // The last of remote-cert-tls / remote-cert-eku sets the EKU; remote-cert-tls and a bare remote-cert-ku also require a KU extension.
        let kuEmpty = ku?.isEmpty ?? true
        let eku = c.last("remote-cert-eku", "remote-cert-tls")
        if let (k, a) = eku {
            guard a.count == 1 else { throw Fail("Invalid \(k)") }
            let v = a[0]
            let needsKu = (ku != nil && ku!.isEmpty) || c.has("remote-cert-tls")
            let shorthand: String? = k == "remote-cert-tls" ? v : {
                let l = v.lowercased()
                guard needsKu && kuEmpty else { return nil }
                return serverEku.contains(l) ? "server" : clientEku.contains(l) ? "client" : nil
            }()
            if let shorthand {
                try req(shorthand == "server" || shorthand == "client", "Invalid remote-cert-tls")
                tls["remote_certificate_tls"] = .s(shorthand)
            } else if needsKu && kuEmpty {
                throw Fail("remote-cert-eku \(v) can't be combined with remote-cert-tls or a bare remote-cert-ku (which require a key-usage extension); list the key usages (remote-cert-ku a0 88) or drop one")
            } else { tls["remote_certificate_eku"] = .s(v) }
        }
        // Alone, a bare remote-cert-ku only demands that a key-usage extension exist: no engine field says that.
        if let ku, ku.isEmpty, eku == nil {
            throw Fail("A bare remote-cert-ku isn't supported on its own; list the key usages (remote-cert-ku a0 88) or add remote-cert-tls server")
        }
        if let v = c.arg("ns-cert-type") {
            try req(v == "server" || v == "client", "Invalid ns-cert-type")
            tls["ns_certificate_type"] = .s(v)
        }
        if let v = c.arg("tls-version-min") { try req(tlsVersions.contains(v), "Invalid tls-version-min"); tls["version_min"] = .s(v) }
        if let v = c.arg("tls-version-max") { try req(tlsVersions.contains(v), "Invalid tls-version-max"); tls["version_max"] = .s(v) }
        if let v = tlsCipher { tls["cipher"] = .s(v) }
        if let v = c.arg("tls-cert-profile") { try req(profiles.contains(v), "Unsupported tls-cert-profile: \(v)"); tls["certificate_profile"] = .s(v) }
        if let w = wraps.first {
            var wrap: [String: J] = ["type": .s(w.replacingOccurrences(of: "-", with: "_")), "key": .s(try pems(w, c.blocks[w]!))]
            if w == "tls-auth", let dir = c.arg("tls-auth", 1).flatMap({ $0 != "[inline]" ? $0 : nil }) ?? c.arg("key-direction") {
                switch dir {
                case "0": wrap["direction"] = "server"
                case "1": wrap["direction"] = "client"
                default: throw Fail("Invalid key-direction: \(dir)")
                }
            }
            tls["control_wrap"] = .o(wrap)
        }
        o["tls"] = .o(tls)

        o["data_ciphers"] = dataCiphers.map(J.strings)
        o["data_ciphers_fallback"] = fallback.map(J.s)
        o["auth"] = auth.map(J.s)
        o["compression_lzo"] = lzo.map(J.s)
        o["compression"] = compress.map(J.s)
        if compressing || allow == "yes" || allow == "asym" { o["allow_compression"] = "asym" }
        if let a = c.d["mssfix"]?.last {
            var n: Int?
            if let v = a.first {
                guard let x = Int(v), x >= 0 else { throw Fail("Invalid mssfix value") }
                n = x
            }
            if n == 0 { o["mss_fix_disabled"] = true } else if let n {
                o["mss_fix"] = .i(n)
                if a.count > 1 { try req(a[1] == "mtu" || a[1] == "fixed", "Invalid mssfix mode"); o["mss_fix_mode"] = .s(a[1]) }
            }
        }
        o["fragment"] = fragment.map(J.i)
        o["mtu"] = mtu.map(J.i)
        if let v = c.arg("reneg-sec") {
            if Int(v) == 0 { o["renegotiate_disabled"] = true } else { o["renegotiate_interval"] = .s(try seconds("reneg-sec", v)) }
        }
        if let v = c.arg("reneg-bytes") {
            guard let n = Int(v), n >= 0 else { throw Fail("Invalid reneg-bytes") }
            o["renegotiate_bytes"] = .i(n)
        }
        if let v = c.arg("reneg-pkts") {
            guard let n = Int(v), n >= 0 else { throw Fail("Invalid reneg-pkts") }
            o["renegotiate_packets"] = .i(n)
        }
        let ka = c.d["keepalive"]?.last
        if let v = c.arg("ping") ?? ka?.first, v != "0" { o["ping_interval"] = .s(try seconds("ping", v)) }
        if let v = c.arg("ping-restart") ?? (ka.flatMap { $0.count > 1 ? $0[1] : nil }) {
            if Int(v) == 0 { o["ping_restart_disabled"] = true } else { o["ping_restart"] = .s(try seconds("ping-restart", v)) }
        }
        if let v = c.arg("tls-timeout") { o["tls_timeout"] = .s(try seconds("tls-timeout", v)) }
        if let v = c.arg("hand-window") { o["handshake_window"] = .s(try seconds("hand-window", v)) }
        if c.has("explicit-exit-notify") {
            guard let n = Int(c.arg("explicit-exit-notify") ?? "1"), n >= 0 else { throw Fail("Invalid explicit-exit-notify") }
            // The engine sends them a second apart while it stops, and nothing else stops until it's done.
            o["explicit_exit_notify"] = .i(min(n, 5))
        }
        // The profile's own setting stands; one a server pushes is ignored (it could ask for hours of them).
        var filters: [J] = [["action": "ignore", "text": "explicit-exit-notify"]]
        if c.has("block-ipv6") { o["block_ipv6"] = true }
        if let w = c.arg("replay-window") {
            guard let n = Int(w), (1...65536).contains(n) else { throw Fail("Invalid replay-window") }
            o["replay_window"] = .i(n)
            if let t = c.arg("replay-window", 1) { o["replay_window_time"] = .s(try seconds("replay-window", t)) }
        }
        // First, so a profile's own "accept" can't undo it: the first matching filter decides.
        if let own = c.d["pull-filter"] {
            filters += try own.map { a in
                try req(a.count == 2 && pullActions.contains(a[0]) && !a[1].isEmpty, "Invalid pull-filter: expected accept, ignore or reject and one text")
                return .o(["action": .s(a[0]), "text": .s(a[1])])
            }
        }
        o["pull_filters"] = .a(filters)
        o["route_no_pull"] = true
        return .o(o)
    }

    private static let ssMethods = words(
        "2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 "
            + "aes-128-gcm aes-192-gcm aes-256-gcm chacha20-ietf-poly1305 xchacha20-ietf-poly1305 "
            + "aes-128-ctr aes-192-ctr aes-256-ctr aes-128-cfb aes-192-cfb aes-256-cfb rc4-md5 chacha20-ietf xchacha20")
    private static let ssPlugins = ["obfs-local": "obfs-local", "simple-obfs": "obfs-local", "v2ray-plugin": "v2ray-plugin"]

    private static func unpercent(_ s: String) throws -> String {
        guard let r = s.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding else { throw Fail("The link has a malformed %-escape") }
        return r
    }

    private static func b64(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.hasSuffix("=") { t.removeLast() }
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Parses a SIP002 (`ss://base64(method:password)@host:port/?plugin=…#name`, or with plain userinfo) or legacy `ss://base64(method:password@host:port)#name` link.
    static func parseSs(_ link: String, name: String = "") throws -> SsProfile {
        try req(link.utf16.count <= maxSsLink, "That link is too long to be a Shadowsocks key")
        let s = trim(link)
        try req(!s.lowercased().hasPrefix("ssconf://"), "Dynamic ssconf:// keys aren't supported; use the ss:// key")
        try req(s.lowercased().hasPrefix("ss://"), "Not a Shadowsocks link (expected ss://…)")
        let rest = String(s.dropFirst(5))
        let tag = trim(try unpercent(rest.after("#")))
        let noFrag = rest.before("#")
        let query = noFrag.after("?")
        var body = noFrag.before("?")
        while body.hasSuffix("/") { body.removeLast() }

        let userinfo: String, hostPort: String
        if body.contains("@") {
            let u = try unpercent(body.beforeLast("@"))
            if u.contains(":") { userinfo = u } else if let d = b64(u) { userinfo = d } else { throw Fail("Can't decode the link's credentials") }
            hostPort = body.afterLast("@")
        } else {
            guard let decoded = b64(try unpercent(body)) else { throw Fail("Can't decode the link") }
            try req(decoded.contains("@"), "The link has no server address")
            userinfo = decoded.beforeLast("@")
            hostPort = decoded.afterLast("@")
        }
        try req(userinfo.utf16.count <= maxSsUserinfo, "The link's credentials are too long")
        try req(userinfo.contains(":"), "The link has no method or password")
        let method = userinfo.before(":").lowercased()
        let password = userinfo.after(":")
        try req(ssMethods.contains(method), "Unsupported Shadowsocks cipher: \(method)")
        try req(!password.isEmpty, "The link has an empty password")

        let host = hostPort.hasPrefix("[") ? hostPort.after("[").before("]") : hostPort.beforeLast(":")
        let port = Int(hostPort.afterLast(":", missing: ""))
        try req(!trim(host).isEmpty && !host.contains { $0.isWhitespace || $0 == "/" }, "The link has no server host")
        try req(host.utf16.count <= maxHost, "The link's server host is too long")
        guard let port, (1...65535).contains(port) else { throw Fail("The link has an invalid port") }

        var params: [String: String] = [:]
        for kv in query.split(separator: "&") { params[kv.before("=")] = try unpercent(kv.after("=")) }
        try req(params["prefix"] == nil, "Outline connection prefixes aren't supported")
        let spec = params["plugin"].flatMap { trim($0).isEmpty ? nil : $0 }
        let pluginName = try spec.map { s in
            let n = s.before(";")
            guard let p = ssPlugins[n] else { throw Fail("Unsupported Shadowsocks plugin: \(n) (only obfs-local and v2ray-plugin)") }
            return p
        }
        let label = [name, tag].first { !trim($0).isEmpty } ?? host
        try req(label.utf16.count <= maxSsName || label == host, "The server name is too long (at most \(maxSsName) characters)")
        let opts = spec.map { $0.after(";") }.flatMap { $0.isEmpty ? nil : $0 }
        // v2ray-plugin's cert= names a file on the device, which the engine would read: only an inline certificate is taken.
        // SIP003 escapes with backslashes; they're dropped first so "c\ert=" can't slip past.
        if let opts {
            try req(!opts.replacingOccurrences(of: "\\", with: "").split(separator: ";", omittingEmptySubsequences: false).contains { trim($0.before("=")).lowercased() == "cert" },
                    "The plugin's cert= option reads a file on this Mac; paste the certificate as certRaw= instead")
        }
        return SsProfile(name: label, server: host, port: port, method: method, password: password, plugin: pluginName, pluginOpts: opts)
    }

    /// A sing-box `shadowsocks` outbound for `p`.
    static func ssOutbound(_ tag: String, _ p: SsProfile) -> J {
        var o: [String: J] = ["type": "shadowsocks", "tag": .s(tag), "server": .s(p.server), "server_port": .i(p.port), "method": .s(p.method), "password": .s(p.password)]
        o["plugin"] = p.plugin.map(J.s)
        o["plugin_opts"] = p.pluginOpts.map(J.s)
        return .o(o)
    }
}

/// Kotlin-style substring helpers: the whole string (or `missing`) when the delimiter is absent.
private nonisolated extension StringProtocol {
    func before(_ c: Character) -> String { firstIndex(of: c).map { String(self[..<$0]) } ?? String(self) }
    func after(_ c: Character, missing: String = "") -> String { firstIndex(of: c).map { String(self[index(after: $0)...]) } ?? missing }
    func beforeLast(_ c: Character) -> String { lastIndex(of: c).map { String(self[..<$0]) } ?? String(self) }
    func afterLast(_ c: Character, missing: String? = nil) -> String { lastIndex(of: c).map { String(self[index(after: $0)...]) } ?? missing ?? String(self) }
}
