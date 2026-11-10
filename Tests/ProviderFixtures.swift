import CryptoKit
import XCTest
import Synchronization

/// Synthetic keys and recorded responses from the Android tests. All provider I/O is replaced locally.
enum ProviderFixtures {
    static let priv = "dW5icmFpZC10ZXN0LXByaXZhdGUta2V5LTAwMDAwMDE="
    static let psk = "dW5icmFpZC10ZXN0LXByZXNoYXJlZC1rZXktMDAwMDE="
    static let key = "vOgsnvam/Xc6w8zfQeGcynOr8RMxYzpki3b0EaOkEoI="
    static let key2 = "PyLCXAQT8KkM4T+dUsOQfn+Ub3pGxfGlxkIApuig+hk="
    static let evil = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    static let iso = Set(Locale.Region.isoRegions.map(\.identifier))
    static func data(_ s: String) -> Data { Data(s.utf8) }
    static func catalog(_ name: String) throws -> [Catalog.Entry] {
        try Catalog.parse(Fixture.data("catalog_\(name).json"), vpn: name == "expressvpn" ? "openvpn" : "wireguard")
    }
    static func conf(_ address: String = "10.2.0.2/32", dns: String = "10.2.0.1", endpoint: String = "1.2.3.4:51820",
                     preshared: Bool = false, extra: String = "", publicKey: String = key) -> String {
        """
        [Interface]
        # Key for Android
        PrivateKey = \(priv)
        Address = \(address)
        DNS = \(dns)
        \(extra)

        [Peer]
        PublicKey = \(publicKey)
        \(preshared ? "PresharedKey = \(psk)" : "")
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = \(endpoint)
        """
    }
    static var airConf: String {
        conf("10.164.20.6/32, fd7d:76ee:e68f:a993:1:2:3:4/128", dns: "10.128.0.1", endpoint: "at.vpn.airdns.org:1637", preshared: true)
    }
    static func wsConf(_ port: Int = 443, endpoint: String? = nil, preshared: Bool = true) -> String {
        conf("100.96.12.34/32", dns: "10.255.255.1", endpoint: endpoint ?? "us-central-117.whiskergalaxy.com:\(port)", preshared: preshared)
    }
    static func surfshark() -> Surfshark {
        var p = Surfshark()
        p.live = { throw Fail("offline") }
        p.catalogue = { throw Fail("offline") }
        p.snapshot = .memory()
        p.addressBook = Surfshark.AddressBook(snapshot: .memory())
        return p
    }
    /// The fixture list as both Proton's bundled snapshot, which vouches for keys, and its live copy (or `live`).
    static func protonSource(live: (@Sendable () throws -> [Catalog.Entry])? = nil) -> Catalog.Source {
        Catalog.Source(live: { try live?() ?? catalog("protonvpn") }, pinned: { Catalog.Pinned(try catalog("protonvpn"), vpn: "wireguard") })
    }
    static func proton(live: (@Sendable () throws -> [Catalog.Entry])? = nil) -> Proton {
        var p = Proton(); p.catalogue = protonSource(live: live); return p
    }
    static func protonFree(live: (@Sendable () throws -> [Catalog.Entry])? = nil) -> ProtonFree {
        var p = ProtonFree(); p.catalogue = protonSource(live: live); return p
    }
    static func air() -> AirVpn {
        var p = AirVpn()
        p.status = { throw Fail("offline") }
        p.catalogue = { throw Fail("offline") }
        return p
    }
    static func windscribe() -> Windscribe { var p = Windscribe(); p.nodeHosts = { nil }; p.catalogue = { throw Fail("offline") }; return p }
    /// ExpressVPN with GitHub blocked: the fixture list as its bundled snapshot.
    static func express() -> ExpressVpn {
        var p = ExpressVpn()
        p.catalogue = Catalog.Source(live: { throw Fail("offline") }, pinned: { Catalog.Pinned(try catalog("expressvpn"), vpn: "openvpn") })
        return p
    }
    static func signed(_ p: any KeyProvider, _ text: String = priv) async throws -> KeyAccount {
        try await p.keyAccount(p.signIn(["key": text]))
    }
    static func ws(_ port: Int = 443) async throws -> Windscribe.Account {
        try await Windscribe.account(windscribe().signIn(["config": wsConf(port)]))
    }
    static func wg(_ link: Link, file: StaticString = #filePath, line: UInt = #line) throws -> (server: Server, peer: WgPeer) {
        guard case .wg(let sv, let peer, _, _) = link else {
            XCTFail("Expected WireGuard", file: file, line: line); throw Fail("Expected WireGuard")
        }
        return (sv, peer)
    }
    static func ovpn(_ link: Link, file: StaticString = #filePath, line: UInt = #line) throws -> (server: Server, profile: OvpnProfile) {
        guard case .ovpn(let sv, let profile) = link else {
            XCTFail("Expected OpenVPN", file: file, line: line); throw Fail("Expected OpenVPN")
        }
        return (sv, profile)
    }
    static func cityLoc(_ provider: String, _ entries: [Catalog.Entry]) throws -> Location {
        let c = try XCTUnwrap(Catalog.countries(entries).first { !$0.cities.isEmpty })
        let city = c.cities[0]
        return Location(provider: provider, countryCode: c.code, country: c.name, city: city.name, region: city.key)
    }
    static func rejects(_ message: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                        _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected failure", file: file, line: line) }
        catch {
            XCTAssertTrue(error is Fail || error is AuthError || error is Catalog.Gone, "\(type(of: error))", file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains(priv), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("SECRET"), file: file, line: line)
            if let message { XCTAssertEqual(error.localizedDescription, message, file: file, line: line) }
        }
    }

    /// Same endpoint shape as the Android tests, checked by the pinned engine (see `engine`), without connecting.
    static func wgEndpoint(_ p: WgPeer) -> J {
        var peer: J = [
            "address": .s(String(p.endpoint.prefix(upTo: p.endpoint.lastIndex(of: ":")!))),
            "port": .i(Int(p.endpoint.split(separator: ":").last!)!),
            "public_key": .s(p.publicKey), "allowed_ips": ["0.0.0.0/0"], "persistent_keepalive_interval": 25,
        ]
        if let psk = p.presharedKey { peer["pre_shared_key"] = .s(psk) }
        return ["type": "wireguard", "tag": "exit", "mtu": .i(p.mtu), "address": .strings(p.address),
                "private_key": .s(p.privateKey), "peers": .a([peer])]
    }
    static func check(_ endpoint: J) throws {
        let config: J = ["log": ["level": "info"], "endpoints": .a([endpoint]),
                         "outbounds": [["type": "direct", "tag": "direct"]], "route": ["final": "exit"]]
        guard let engine = try engine() else { throw XCTSkip("sing-box-cli-mac not found: run tools/build-cli.sh") }
        XCTAssertNil(engineRefusal(config.string, engine), "sing-box rejected the generated endpoint")
    }

    /// The command-line build of the engine unbraid ships (tools/build-cli.sh): UNBRAID_SING_BOX (TEST_RUNNER_UNBRAID_SING_BOX
    /// through xcodebuild), else its default place. Nil only when nothing is there; anything else that isn't that engine
    /// (the Android fork's, another version, toolchain, set of build tags or engine patches, a file that won't run) fails
    /// rather than passing as a check it isn't.
    static func engine() throws -> URL? { try pinnedEngine.get() }

    private static let pinnedEngine: Result<URL?, Fail> = {
        let env = ProcessInfo.processInfo.environment["UNBRAID_SING_BOX"].flatMap { $0.isEmpty ? nil : $0 }
        let bin = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Development/unbraid-mac-deps/sing-box-cli-mac")
        if env == nil && !FileManager.default.fileExists(atPath: bin.path) { return .success(nil) }
        let refused = Fail("\(bin.path) is not unbraid's sing-box 1.14.4 build with this checkout's engine patches: rebuild it with tools/build-cli.sh")
        guard FileManager.default.isExecutableFile(atPath: bin.path), let expected = expectedVersion(),
              let (status, out) = run(bin, ["version"]), status == 0,
              out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == expected + [""],
              let source = enginePin(), let patches = enginePatches(),
              matchesStamp(bin, source: source, patches: patches) else { return .failure(refused) }
        return .success(bin)
    }()

    /// The sing-box commit tools/build-libbox.sh builds the engine from (its one `PIN=` line), which tools/build-cli.sh
    /// reads too.
    static func enginePin() -> String? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "tools/build-libbox.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        let pins = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { $0.wholeMatch(of: /PIN=([0-9a-f]{40})/)?.1 }
        return pins.count == 1 ? String(pins[0]) : nil
    }

    /// tools/sing-box-*.patch and tools/sing-openvpn-*.patch of this checkout: the patches the engine is built with
    /// (sing-box's own, and its OpenVPN module's).
    static func enginePatches() -> [(name: String, data: Data)]? {
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "tools")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tools.path) else { return nil }
        let patches = names.filter { ($0.hasPrefix("sing-box-") || $0.hasPrefix("sing-openvpn-")) && $0.hasSuffix(".patch") }
        let read = patches.compactMap { n in (try? Data(contentsOf: tools.appending(path: n))).map { (name: n, data: $0) } }
        return read.count == patches.count && read.contains(where: { $0.name.hasPrefix("sing-box-") })
            && read.contains(where: { $0.name.hasPrefix("sing-openvpn-") }) ? read : nil
    }

    /// Whether the stamp tools/build-cli.sh wrote beside the CLI (<cli>.patches) says it was built from this source commit
    /// with exactly these patches, and is this very binary's: a version line can't tell a build that lacks a newer patch,
    /// or one from an older commit of the same release.
    static func matchesStamp(_ bin: URL, source: String, patches: [(name: String, data: Data)]) -> Bool {
        guard let binary = try? Data(contentsOf: bin, options: .alwaysMapped),
              let stamped = try? Data(contentsOf: URL(fileURLWithPath: bin.path + ".patches")) else { return false }
        return stamped == Data(stamp(source: source, patches: patches, binary: binary).utf8)
    }

    /// What tools/build-cli.sh writes: the source commit, one line per patch, by name in byte order, with its SHA-256,
    /// then the binary's.
    static func stamp(source: String, patches: [(name: String, data: Data)], binary: Data) -> String {
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        let lines = patches.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }.map { "patch \($0.name) \(sha($0.data))" }
        return (["source \(source)"] + lines + ["binary \(sha(binary))"]).map { $0 + "\n" }.joined()
    }

    /// What `sing-box version` prints for a build made the way tools/build-libbox.sh makes the engine: its version, Go
    /// toolchain and build tags, read from that script so the two can't drift apart.
    private static func expectedVersion() -> [String]? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "tools/build-libbox.sh")
        guard let text = try? String(contentsOf: script, encoding: .utf8),
              let go = text.firstMatch(of: /GOTOOLCHAIN=(go[0-9.]+)/)?.1, let tags = text.firstMatch(of: /-tags ([a-z0-9_,]+)/)?.1,
              let version = text.firstMatch(of: /constant\.Version=([0-9.]+)/)?.1 else { return nil }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return ["sing-box version \(version)", "", "Environment: \(go) darwin/\(arch)", "Tags: \(tags)", "CGO: enabled"]
    }

    /// Nil when the engine accepts the config, else why not. `check` builds every inbound, endpoint, outbound and DNS
    /// server and decodes every field, but doesn't start anything, so a tag that names nothing still passes.
    static func engineRefusal(_ config: String, _ engine: URL) -> String? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "unbraid-engine-\(UUID())")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return "no temporary folder" }
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json")
        do { try Data(config.utf8).write(to: url) } catch { return "config not written" }
        // Its own working directory: the Tailscale state and cache file paths are relative.
        guard let (status, out) = run(engine, ["check", "-D", dir.path, "-c", url.path]) else { return "sing-box check timed out" }
        guard status != 0 else { return nil }
        return refusalReason(out, status)
    }

    /// Only the name of the field the engine refused: its message goes on to quote the value, which can be a key.
    static func refusalReason(_ out: String, _ status: Int32) -> String {
        if let line = out.split(separator: "\n").first(where: { $0.contains("decode config at ") }),
           let at = line.range(of: "config.json: "), let field = line[at.upperBound...].split(separator: ":").first,
           field.wholeMatch(of: /[a-z0-9_]+(\[[0-9]+\])?(\.[a-z0-9_]+(\[[0-9]+\])?)*/) != nil {
            return "refused at \(field)"
        }
        return "refused (exit \(status)); run sing-box check on the config by hand for the engine's message"
    }

    /// Runs a short engine command and returns its exit status and (the first 64 KB of) its output, or nil when it
    /// wouldn't start or finish. The output is read while it runs: an engine error can be long enough to fill the pipe.
    private static func run(_ bin: URL, _ args: [String]) -> (Int32, String)? {
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = bin
        process.arguments = args
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        let collected = Collected(), reader = output.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                collected.lock.withLock { if collected.data.count < 65_536 { collected.data.append(chunk.prefix(65_536 - collected.data.count)) } }
            }
            drained.signal()
        }
        if finished.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            return nil
        }
        guard drained.wait(timeout: .now() + 5) == .success else { return nil }
        return (process.terminationStatus, collected.lock.withLock { String(decoding: collected.data, as: UTF8.self) })
    }
}
