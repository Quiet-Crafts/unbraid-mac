@preconcurrency import Libbox

/// IVPN's quantum-safe key exchange, done by the engine's own Round-3 Kyber-1024 (the app links the library for this
/// alone; the tunnel itself runs in the extension). The functions are pure: no setup and no network.
nonisolated struct LibboxKyber: Ivpn.Kyber {
    func keyPair() throws -> (public: String, private: String) {
        var error: NSError?
        let both = LibboxKyber1024KeyPair(&error)
        if let error { throw error }
        let parts = both.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw Fail("The engine made no quantum-safe key") }
        return (String(parts[0]), String(parts[1]))
    }

    func psk(private key: String, cipher: String) throws -> String {
        var error: NSError?
        let psk = LibboxKyber1024PSK(key, cipher, &error)
        if let error { throw error }
        return psk
    }
}
