import Foundation

/// The pure half of M-Lab's ndt7 speed test (measurementlab.net; protocol: github.com/m-lab/ndt-server,
/// spec/ndt7-protocol.md): the locate request and reply, the ping summary, the byte caps and the rate maths. The
/// network half is in App/Engine/SpeedTest.swift. Ndt7.kt, ported.
nonisolated enum Ndt7 {
    struct Server: Hashable, Sendable {
        var machine: String
        var city: String
        var country: String
        var download: String
        var upload: String
        var others: [Server] = []
    }

    struct Limited: Error {}
    struct Refused: Error {}

    /// Try the remaining candidates only when a server refuses the test.
    static func anyOf<T>(_ server: Server, run: (Server) async throws -> T) async throws -> (Server, T) {
        for candidate in [server] + server.others {
            do { return (candidate, try await run(candidate)) }
            catch is Refused { continue }
        }
        throw Refused()
    }

    /// A decision is needed before a test can use a server outside the exit's country.
    static func includeInParallel(hasServer: Bool, missing: Bool, limited: Bool, failed: Bool, useNearest: Bool) -> Bool {
        hasServer && !limited && !failed && (!missing || useNearest)
    }

    static func canReserveParallel(_ count: Int, used: Int, limit: Int) -> Bool {
        (2...10).contains(count) && used >= 0 && used <= limit && count <= limit - used
    }

    static func sameRoute(running: Bool, originalTag: String, tag: String?, originalID: String, id: String, originalIP: String, ip: String?) -> Bool {
        running && tag == originalTag && id == originalID && (originalIP.isEmpty || ip == originalIP)
    }

    static func optionalPing(_ run: () async throws -> Ping) async throws -> Ping? {
        do { return try await run() }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Ping in ms: the median of five, and the lowest and highest.
    struct Ping: Hashable, Sendable {
        var median: Int
        var low: Int
        var high: Int
    }

    /// Ten seconds each way.
    static let seconds = 10
    static let locateHost = "locate.measurementlab.net"
    static let subprotocol = "net.measurementlab.ndt.v7"
    /// The lengths come from the server, so they are bounded: data frames are streamed past (ndt7's are at most 16 MiB),
    /// but text messages are read into memory (measurement messages are a few hundred bytes).
    static let maxMessage = 1 << 20
    static let maxData = 1 << 25
    /// A download that outlasts the test by this long is cut off.
    static let downloadCap = seconds + 3

    /// A socket that broke well before the test's time, without the server's normal close, is a failed measurement.
    /// A server that drops the socket near the end (no close frame) still counts: its clock started before ours.
    static func transportFailed(elapsedMs: Int64, normalClose: Bool) -> Bool {
        !normalClose && elapsedMs < Int64(seconds) * 800
    }

    static func userAgent(_ version: String) -> String { "unbraid/\(version)" }

    /// The M-Lab server nearest the exit's own address, inside `country` when given.
    static func locatePath(version: String, country: String?) -> String {
        "/v2/nearest/ndt/ndt7?client_name=unbraid&client_version=\(version)" + (country.map { "&country=\($0)&strict=true" } ?? "")
    }

    /// M-Lab's answer to a locate request: its first server; nil when a request held to `country` found none there.
    /// That answer is a 500 of type "nearest" (checked live in October 2026, for countries without servers). M-Lab
    /// gives the same for any failure of its own lookup, so "none there" is as far as it can be read. Anything else
    /// that isn't a 200 (rate limits, proxies, other errors) is a failure, not a missing server.
    static func locateReply(status: Int, body: Data, country: String?) throws -> Server? {
        if status == 204 { throw Limited() }
        if status == 200 { return try parseLocate(body) }
        struct Failure: Decodable { struct Detail: Decodable { var type: String? }; var error: Detail? }
        if status == 500, country != nil, (try? JSONDecoder().decode(Failure.self, from: body))?.error?.type == "nearest" { return nil }
        throw Http.Status(code: status)
    }

    /// The first server of M-Lab's reply; nil if its list is empty.
    static func parseLocate(_ data: Data) throws -> Server? {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Location: Decodable { var city: String?; var country: String? }
                var machine: String?
                var location: Location?
                var urls: [String: String]?
            }
            var results: [Result]?
        }
        guard let results = try JSON.decode(Reply.self, data, "M-Lab").results else { throw Fail("Unexpected reply from M-Lab") }
        let servers = try results.map { r in
            guard let urls = r.urls else { throw Fail("Unexpected reply from M-Lab") }
            return Server(machine: r.machine ?? "", city: r.location?.city ?? "", country: r.location?.country ?? "",
                          download: urls["wss:///ndt/v7/download"] ?? "", upload: urls["wss:///ndt/v7/upload"] ?? "")
        }
        guard var first = servers.first else { return nil }
        first.others = Array(servers.dropFirst())
        return first
    }

    /// Ookla-style ping from handshake times in ms (the first, untimed connection that resolves the name is not among
    /// them): the median shrugs off one slow handshake, unlike the mean.
    static func ping(_ ms: [Int]) -> Ping {
        let s = ms.map { max($0, 1) }.sorted()
        return Ping(median: s[s.count / 2], low: s[0], high: s[s.count - 1])
    }

    /// The test server's host name (where the handshakes go).
    static func host(_ url: String) -> String? { testURL(url)?.host }

    /// A test server's address from M-Lab's reply, if it is one: wss, a host under M-Lab's own domains, the standard
    /// port. The reply names what the app dials through the exit, so nothing else is accepted.
    static func testURL(_ url: String) -> URL? {
        guard let u = URL(string: url), u.scheme == "wss", let host = u.host?.lowercased(), u.port == nil || u.port == 443,
              [".measurement-lab.org", ".measurementlab.net"].contains(where: { host.hasSuffix($0) }) else { return nil }
        return u
    }

    /// Bits per second for `bytes` received or sent in `ms`.
    static func bitsPerSecond(bytes: Int64, ms: Int64) -> Int64 { bytes * 8000 / max(ms, 1) }

    /// A download's final rate; nil when it lasted under a second: a server that sends a frame and closes normally
    /// would otherwise turn a few kilobytes over a few milliseconds into an absurd figure.
    static func downloadRate(bytes: Int64, ms: Int64) -> Int64? { ms < 1000 ? nil : bitsPerSecond(bytes: bytes, ms: ms) }

    /// Cumulative bytes at a point in a sampled phase, interpolated between readings.
    static func bytesAt(_ samples: [(time: Int64, bytes: Int64)], _ time: Int64) -> Int64? {
        // Strictly increasing times are what keep the interpolation below from dividing by zero.
        guard let first = samples.first, let last = samples.last,
              samples.allSatisfy({ $0.time >= 0 && $0.bytes >= 0 }),
              zip(samples, samples.dropFirst()).allSatisfy({ $0.time < $1.time && $0.bytes <= $1.bytes }) else { return nil }
        if time <= first.time { return first.bytes }
        if time >= last.time { return last.bytes }
        for (a, b) in zip(samples, samples.dropFirst()) where time <= b.time {
            let (amount, overflow) = (b.bytes - a.bytes).multipliedReportingOverflow(by: time - a.time)
            guard !overflow else { return nil }
            return a.bytes + amount / (b.time - a.time)
        }
        return nil
    }

    /// Sum only the common window of every phase, provided it lasted at least three seconds.
    static func combined(_ legs: [[(time: Int64, bytes: Int64)]]) -> (bps: Int64, ms: Int64)? {
        guard !legs.isEmpty, legs.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.time >= 0 && $0.bytes >= 0 } }),
              let from = legs.compactMap({ $0.first?.time }).max(),
              let to = legs.compactMap({ $0.last?.time }).min(), to >= from, to - from >= 3000 else { return nil }
        var total: Int64 = 0
        for samples in legs {
            guard let start = bytesAt(samples, from), let end = bytesAt(samples, to), end >= start else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(end - start)
            guard !overflow else { return nil }
            total = sum
        }
        let (bits, overflow) = total.multipliedReportingOverflow(by: 8000)
        return overflow ? nil : (bits / (to - from), to - from)
    }

    /// The upload rate in bits/s from a server measurement message: what the server says it received (its TCPInfo),
    /// not what left the Mac's buffers. nil for any other message.
    static func serverRate(_ text: String) -> Int64? {
        guard let sample = serverSample(text) else { return nil }
        return serverRate(sample)
    }

    static func serverRate(_ sample: (bytes: Int64, us: Int64)) -> Int64? {
        // The server's numbers are untrusted: an absurd byte count must not trap the multiply.
        let (bits, overflow) = sample.bytes.multipliedReportingOverflow(by: 8_000_000)
        return overflow ? nil : bits / sample.us
    }

    static func serverSample(_ text: String) -> (bytes: Int64, us: Int64)? {
        guard let t = text.range(of: "\"TCPInfo\"").map({ text[$0.upperBound...] }),
              let got = number("\"BytesReceived\":", in: t), let us = number("\"ElapsedTime\":", in: t), us > 0 else { return nil }
        return (got, us)
    }

    static func concurrentURL(_ url: String, count: Int) -> String? {
        guard (2...10).contains(count), var parts = URLComponents(string: url), parts.scheme == "wss" else { return nil }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "concurrent" }
        items.append(URLQueryItem(name: "concurrent", value: String(count)))
        parts.queryItems = items
        return parts.url?.absoluteString
    }

    private static func number(_ key: String, in s: Substring) -> Int64? {
        guard let r = s.range(of: key) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int64(digits)
    }

    /// Whether a message of `length` bytes from the server is within bounds.
    static func frameOk(text: Bool, length: Int) -> Bool { length >= 0 && length <= (text ? maxMessage : maxData) }

    /// The size of the next upload message: the spec's message scaling, doubling while it is under a sixteenth of what
    /// was sent so far, up to the buffer.
    static func nextSize(_ size: Int, sent: Int64, buffer: Int) -> Int { size < buffer && Int64(size) < sent / 16 ? size * 2 : size }
}

/// Upload messages in flight: `take` waits for a free slot, a send's completion `put`s it back with its error. After
/// an error every `take` returns at once.
nonisolated final class InFlight: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var waiter: CheckedContinuation<Void, Never>?
    private var failed: Error?
    init(_ slots: Int) { free = slots }
    var error: Error? { lock.withLock { failed } }
    func take() async {
        await withCheckedContinuation { k in
            lock.lock()
            if free > 0 || failed != nil { free -= 1; lock.unlock(); k.resume() } else { waiter = k; lock.unlock() }
        }
    }
    func put(_ e: Error?) {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            if let e, failed == nil { failed = e }
            free += 1
            defer { waiter = nil }
            if waiter != nil { free -= 1 }
            return waiter
        }
        w?.resume()
    }
}
