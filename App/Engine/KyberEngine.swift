import UnbraidKyber

/// IVPN's quantum-safe key exchange, done by a small library of Round-3 Kyber-1024 (tools/kyber; the app links it for
/// this alone, the engine runs in the tunnel extension). The functions are pure: no setup and no network.
nonisolated struct KyberLibrary: Ivpn.Kyber {
    func keyPair() throws -> (public: String, private: String) {
        let both = try call { unbraid_kyber_keypair(&$0) }
        let parts = both.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Fail("The library made no quantum-safe key") }
        return (String(parts[0]), String(parts[1]))
    }

    func psk(private key: String, cipher: String) throws -> String {
        try call { unbraid_kyber_psk(key, cipher, &$0) }
    }

    /// Runs one library call and copies its result out; the library wipes and frees its own string.
    private func call(_ body: (inout UnsafeMutablePointer<CChar>?) -> Int32) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        let status = body(&out)
        guard let out else { throw Fail("The Kyber library returned nothing") }
        defer { unbraid_kyber_free(out) }
        let text = String(cString: out)
        if status != 0 { throw Fail(text) }
        return text
    }
}
