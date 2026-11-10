import Foundation

/// Whether a tunnel still carries traffic: a STUN binding round trip (a ~100-byte UDP query) through it to both STUN
/// servers at once, then HTTPS if neither has answered after 3 s. A WireGuard tunnel whose server stopped answering
/// (a key now used by another device on that server, a server taken down) otherwise stays up but silent, and its apps
/// just time out. Health.kt, ported.
nonisolated enum Health {
    private static let servers = ["stun.l.google.com:19302", "stun.cloudflare.com:3478"]

    /// STUN and HTTPS race through the tunnel, with a shared eight second budget.
    static func reachable(_ tag: String, probe: Probe.Endpoint?, dns: String? = nil) async -> Bool {
        await withTaskGroup(of: Int.self) { group in
            if let dns, !dns.isEmpty {
                for server in servers {
                    group.addTask { await binding("\(dns)|\(server)", tag) ? 1 : 0 }
                }
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(3)) } catch { return 0 }
                return await https(tag, probe) ? 1 : 0
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return -1
            }
            while let result = await group.next() {
                if result == 1 { group.cancelAll(); return true }
                if result == -1 { group.cancelAll(); return false }
                // The timeout task ends the race even when the other requests remain in flight.
                if Task.isCancelled { group.cancelAll(); return false }
            }
            return false
        }
    }

    /// A TLS handshake with a well-known site through `tag`, over the app's own way into that exit (`Probe`).
    private static func https(_ tag: String, _ probe: Probe.Endpoint?) async -> Bool {
        (try? await Probe.tls(tag: tag, host: "www.google.com", timeout: 5, probe: probe)) != nil
    }

    /// The extension stops the test when its answer comes, or when this gives up (8 s, or cancelled).
    private static func binding(_ server: String, _ tag: String) async -> Bool {
        await EngineLink.call(timeout: 8) { $0.stunTest(server, outboundTag: tag, reply: $1) } ?? false
    }
}
