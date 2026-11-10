import Foundation
import Security

/// Minimal HTTPS client shared by providers: HTTPS only, size-capped bodies, short timeouts, one retry on a transient
/// DNS failure, optional pinned CA. A 401 to a request that carries `credentials` means they were refused (AuthError,
/// so the user signs in again); from a public list it is only an error status, like any other.
nonisolated enum Http {
    private static let maxBody = 8 << 20

    struct Status: LocalizedError {
        let code: Int
        var errorDescription: String? { "HTTP \(code)" }
    }

    /// Not private: a test checks that it keeps refusing redirects.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 60
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "unbraid"]
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func get(_ url: String, headers: [String: String] = [:], pin: Pin? = nil, credentials: Bool = false) async throws -> Data {
        try await call("GET", url, headers, nil, pin, credentials)
    }

    static func delete(_ url: String, headers: [String: String] = [:], credentials: Bool = false) async throws -> Data {
        try await call("DELETE", url, headers, nil, nil, credentials)
    }

    static func postForm(_ url: String, _ form: [String: String], headers: [String: String] = [:], credentials: Bool = false) async throws -> Data {
        let body = form.sorted { $0.key < $1.key }.map { enc($0.key) + "=" + enc($0.value) }.joined(separator: "&")
        return try await call("POST", url, headers.merging(["Content-Type": "application/x-www-form-urlencoded"]) { $1 }, Data(body.utf8), nil, credentials)
    }

    /// What a status means for a request: refused credentials only when it sent some.
    static func check(_ code: Int, credentials: Bool) throws {
        if code == 401 && credentials { throw AuthError() }
        guard (200..<300).contains(code) else { throw Status(code: code) }
    }

    /// Form and query encoding (RFC 3986 unreserved characters only).
    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    // Approachable concurrency otherwise keeps body accumulation on the caller's actor.
    @concurrent private static func call(_ method: String, _ url: String, _ headers: [String: String], _ body: Data?, _ pin: Pin?, _ credentials: Bool) async throws -> Data {
        do { return try await once(method, url, headers, body, pin, credentials) } catch let e as URLError where e.code == .cannotFindHost || e.code == .dnsLookupFailed {
            try await Task.sleep(for: .milliseconds(1500))
            return try await once(method, url, headers, body, pin, credentials)
        }
    }

    private static func once(_ method: String, _ url: String, _ headers: [String: String], _ body: Data?, _ pin: Pin?, _ credentials: Bool) async throws -> Data {
        guard let u = URL(string: url), u.scheme == "https" else { throw Fail("HTTPS only") }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.httpBody = body
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        let (bytes, response) = try await session.bytes(for: r, delegate: pin)
        try check((response as? HTTPURLResponse)?.statusCode ?? 0, credentials: credentials)
        // Stop at the cap while reading, so a hostile or broken server can't fill memory.
        var data = Data(capacity: Int(min(max(0, response.expectedContentLength), Int64(maxBody))))
        for try await b in bytes {
            data.append(b)
            if data.count > maxBody { throw Fail("Response too large") }
        }
        return data
    }

    class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Trusts only `ca` (a provider's own root) and checks the certificate against `host` rather than the URL, for
    /// servers reached by IP address (PIA's WireGuard API).
    final class Pin: NoRedirect, @unchecked Sendable {
        let ca: SecCertificate
        let host: String
        init(ca: SecCertificate, host: String) { self.ca = ca; self.host = host }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard let trust = challenge.protectionSpace.serverTrust else { return (.cancelAuthenticationChallenge, nil) }
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            return SecTrustEvaluateWithError(trust, nil) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }
}

