import CryptoKit
import Darwin
import Foundation

/// Recognises the network the Mac is on by its router, without the Wi-Fi's name (which macOS gives only with Location
/// permission): a scrambled fingerprint of the router's address and hardware address. Nothing of either is kept.
nonisolated enum NetworkMark {
    /// The fingerprint of a network: its router's address and hardware address, scrambled with this install's own
    /// salt so it means nothing anywhere else.
    static func mark(salt: String, gateway: String, hardware: String) -> String {
        SHA256.hash(data: Data("\(salt)|\(gateway)|\(hardware)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The network the Mac is on now, as a fingerprint; nil when it has no router to tell it by (no network, or one
    /// whose router hasn't answered yet). `interface`: the one macOS prefers (Wi-Fi or Ethernet, never a tunnel).
    static func current(salt: String, interface: String) async -> String? {
        guard let gateway = gateway(on: interface, routes: routes()), let hardware = await hardware(of: gateway, on: interface) else { return nil }
        return mark(salt: salt, gateway: gateway, hardware: hardware)
    }

    /// The default router on `interface`, from the routing table (as `route -n get default -ifscope` reads it).
    static func gateway(on interface: String, routes: [(interface: String, destination: String, gateway: String)]) -> String? {
        routes.first { $0.interface == interface && $0.destination == "0.0.0.0" }?.gateway
    }

    /// IPv4 routes that go through a router: where to, through whom, on which interface.
    static func routes() -> [(interface: String, destination: String, gateway: String)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }
        return parse(Array(buffer.prefix(length)))
    }

    /// Reads routing messages as the kernel writes them: a header, then the addresses its `rtm_addrs` names, each
    /// padded to four bytes. Anything that doesn't fit its own lengths ends the reading.
    static func parse(_ buffer: [UInt8]) -> [(interface: String, destination: String, gateway: String)] {
        var out: [(interface: String, destination: String, gateway: String)] = []
        let header = MemoryLayout<rt_msghdr>.size
        var offset = 0
        while offset + header <= buffer.count {
            let h = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(h.rtm_msglen)
            guard length >= header, offset + length <= buffer.count else { break }
            var at = offset + header
            var addresses: [Int: String] = [:]
            for bit in 0..<8 where h.rtm_addrs & (1 << Int32(bit)) != 0 {
                guard at + 2 <= offset + length else { break }
                let size = Int(buffer[at])
                if buffer[at + 1] == UInt8(AF_INET), size >= 8, at + 8 <= offset + length {
                    addresses[bit] = buffer[(at + 4)..<(at + 8)].map(String.init).joined(separator: ".")
                } else if bit == 0, size < 8 { addresses[bit] = "0.0.0.0" }   // the default route's destination may be cut short
                at += size == 0 ? 4 : (size + 3) & ~3
            }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if h.rtm_flags & RTF_GATEWAY != 0, let to = addresses[0], let via = addresses[1], if_indextoname(UInt32(h.rtm_index), &name) != nil {
                out.append((String(cString: name), to, via))
            }
            offset += length
        }
        return out
    }

    /// The hardware address of `address` on the local network, as macOS's own `arp` reports it (the neighbour table
    /// isn't readable any other way without a permission); nil when it isn't known.
    static func hardware(of address: String, on interface: String) async -> String? {
        guard address.split(separator: ".").count == 4, address.allSatisfy({ $0.isNumber || $0 == "." }),
              interface.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
                p.arguments = ["-n", "-i", interface, address]
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return done.resume(returning: nil) }
                // It only reads a table: a few milliseconds. One that hangs is ended, and counts as no answer.
                let limit = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: limit)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); limit.cancel()
                done.resume(returning: p.terminationStatus == 0 ? parseArp(String(decoding: data.prefix(4096), as: UTF8.self)) : nil)
            }
        }
    }

    /// The hardware address in a line of `arp -n`, each part two digits ("0:1b:…" → "00:1b:…"); nil for none or an
    /// address still being looked for.
    static func parseArp(_ output: String) -> String? {
        guard let at = output.range(of: " at ") else { return nil }
        let token = output[at.upperBound...].prefix { !$0.isWhitespace }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        let hardware = parts.map { ($0.count == 1 ? "0" : "") + $0.lowercased() }.joined(separator: ":")
        // All zeros or all ones names no device.
        return ["00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"].contains(hardware) ? nil : hardware
    }
}
