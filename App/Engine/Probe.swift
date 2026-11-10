import Foundation
import Network

/// The app's own connections out through one chosen exit: the engine's loopback `mixed` inbound (`Compiler.probeTag`)
/// takes an HTTP CONNECT or a SOCKS5 login whose user name is the exit's tunnel tag and whose password is random per
/// engine start (`Connection.probe`), then dials the target through that tunnel. TLS stays end to end, checked against
/// the system's certificates and the host name. Probe.kt, ported.
nonisolated enum Probe {
    /// Loopback port and password of the engine's `probe` inbound.
    typealias Endpoint = (port: Int, password: String)

    /// The endpoint, or "Connect first" when no engine runs with one.
    static func endpoint(_ p: Endpoint?) throws -> Endpoint {
        guard let p else { throw Fail("Connect first") }
        return p
    }

    private static func proxy(_ tag: String, _ p: Endpoint) -> ProxyConfiguration {
        var c = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(clamping: p.port)) ?? 1))
        c.applyCredential(username: tag, password: p.password)
        c.allowFailover = false // never fall back to a direct connection: that would measure (and expose) the wrong exit
        return c
    }

    /// A session whose every request goes out through the tunnel `tag`. Invalidate it when done.
    static func session(tag: String, probe: Endpoint, headers: [String: String] = [:]) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = headers
        c.proxyConfigurations = [proxy(tag, probe)]
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }

    /// A small HTTPS GET through `tag`; the body, at most `max` bytes (the server is trusted no further).
    static func get(tag: String, host: String, path: String, probe: Endpoint?, max: Int = 256 * 1024) async throws -> Data {
        let (code, body) = try await fetch(tag: tag, host: host, path: path, probe: probe, max: max)
        guard code == 200 else { throw Http.Status(code: code) }
        return body
    }

    /// The same, whatever the status: the status and the whole body, at most `max` bytes, for a caller that reads an
    /// error's body.
    static func fetch(tag: String, host: String, path: String, probe: Endpoint?, max: Int = 256 * 1024) async throws -> (status: Int, body: Data) {
        let s = session(tag: tag, probe: try endpoint(probe))
        defer { s.invalidateAndCancel() }
        guard let url = URL(string: "https://\(host)\(path)") else { throw Fail("Bad address") }
        var r = URLRequest(url: url)
        r.setValue("unbraid", forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await s.bytes(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        var body = Data()
        for try await b in bytes {
            body.append(b)
            if body.count > max { throw Fail("Response too large") }
        }
        return (code, body)
    }

    /// A TLS handshake with `host` through `tag`, nothing sent after it; throws if the VPN isn't on, the exit doesn't
    /// answer in `timeout` seconds or the certificate doesn't match.
    static func tls(tag: String, host: String, port: Int = 443, timeout: Double = 10, probe: Endpoint?) async throws {
        let context = NWParameters.PrivacyContext(description: "unbraid probe")
        context.proxyConfigurations = [proxy(tag, try endpoint(probe))]
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        params.setPrivacyContext(context)
        let w = Wire(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 443, using: params))
        try await w.within(timeout) { try await w.open() }
    }

    /// One TCP handshake with `host` through `tag`, in ms: the engine's SOCKS5 side answers only once its own connection
    /// to the server is up, so the wait is one round trip through the tunnel (Ookla's "ping"). No data, no TLS.
    static func handshakeMs(tag: String, host: String, port: Int = 443, probe: Endpoint?) async throws -> Double {
        let p = try endpoint(probe)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let w = Wire(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(clamping: p.port)) ?? 1, using: NWParameters(tls: nil, tcp: tcp)))
        return try await w.within(5) {
            try await w.open()
            try await w.send(Data([5, 1, 2])) // SOCKS5, user name and password (RFC 1929)
            guard try await w.read(2).starts(with: [5, 2]) else { throw Fail("Proxy refused") }
            let u = Array(tag.utf8), pw = Array(p.password.utf8)
            try await w.send(Data([1, UInt8(u.count)] + u + [UInt8(pw.count)] + pw))
            guard try await w.read(2).starts(with: [1, 0]) else { throw Fail("Proxy refused") }
            let h = Array(host.utf8)
            // The host comes from M-Lab's reply; SOCKS gives its length one byte.
            guard h.count <= 255 else { throw Fail("The server's name is too long") }
            let start = clock_gettime_nsec_np(CLOCK_MONOTONIC)
            try await w.send(Data([5, 1, 0, 3, UInt8(h.count)] + h + [UInt8(port >> 8 & 0xff), UInt8(port & 0xff)]))
            let reply = try await w.read(2)
            guard reply[reply.startIndex + 1] == 0 else { throw Fail("The server didn't answer") }
            return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC) - start) / 1_000_000
        }
    }
}

/// A Network.framework connection with async calls. Closing it fails every call in flight, which is how timeouts and
/// cancellation reach a blocked read.
private nonisolated final class Wire: @unchecked Sendable {
    private let c: NWConnection
    private let q = DispatchQueue(label: "app.unbraid.probe")
    private let lock = NSLock()
    private var closed = false
    private var cancelPending: (@Sendable () -> Void)?

    init(_ c: NWConnection) { self.c = c }

    /// Register before starting any framework work. Closing before registration fails the call too.
    private func perform<T: Sendable>(_ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let result = ProbeResult<T>()
        let admitted = lock.withLock {
            guard !closed else { return false }
            cancelPending = { result.finish(.failure(CancellationError())) }
            return true
        }
        if admitted { start { result.finish($0) } }
        else { result.finish(.failure(CancellationError())) }
        return try await result.wait()
    }

    func open() async throws {
        return try await perform { done in
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: done(.success(()))
                // Waiting is a refused or unreachable connection; the framework would retry for ever.
                case .waiting(let e), .failed(let e): done(.failure(e))
                case .cancelled: done(.failure(Fail("The exit didn't connect")))
                default: break
                }
            }
            c.start(queue: q)
        }
    }

    func send(_ d: Data) async throws {
        return try await perform { done in
            c.send(content: d, completion: .contentProcessed { e in
                if let e { done(.failure(e)) } else { done(.success(())) }
            })
        }
    }

    /// At least `n` bytes.
    func read(_ n: Int) async throws -> Data {
        try await perform { done in
            c.receive(minimumIncompleteLength: n, maximumLength: 512) { d, _, _, e in
                if let e { done(.failure(e)) }
                else if let d, d.count >= n { done(.success(d)) }
                else { done(.failure(Fail("Proxy refused"))) }
            }
        }
    }

    func close() {
        let pending = lock.withLock {
            closed = true
            defer { cancelPending = nil }
            return cancelPending
        }
        pending?()
        c.cancel()
    }

    /// Runs `f`, closing the connection when it ends, when `seconds` pass or when the caller is cancelled.
    func within<T: Sendable>(_ seconds: Double, _ f: () async throws -> T) async throws -> T {
        let timer = Task { if (try? await Task.sleep(for: .seconds(seconds))) != nil { close() } }
        defer { timer.cancel(); close() }
        return try await withTaskCancellationHandler(operation: f, onCancel: { close() })
    }
}

/// Fires once.
nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

/// Runs a blocking call (libbox's command client is one) on a background thread without tying up the async pool.
nonisolated func offThread<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { k in DispatchQueue.global(qos: .utility).async { k.resume(returning: f()) } }
}

/// Carries a value across threads that its owner promises not to touch concurrently.
nonisolated struct Unchecked<T>: @unchecked Sendable { var value: T }
