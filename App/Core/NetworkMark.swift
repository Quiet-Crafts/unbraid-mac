import CryptoKit
import Darwin
import Foundation

/// Recognises the network the Mac is on by its router, without the Wi-Fi's name (which macOS gives only with Location
/// permission): a scrambled fingerprint of something only that router has. Nothing of it is kept.
///
/// What the router is told by: on a network with IPv6, the routing table (which any app may read) names the router by
/// its own link-local address, made from its hardware or drawn once at random, and so its own on all but the routers
/// that call themselves "1". Other devices' hardware addresses, the router's included, macOS shows only to apps allowed
/// on the local network: on a network without IPv6, or with such a router, there is a fingerprint only with that
/// access, which unbraid doesn't ask for.
nonisolated enum NetworkMark {
    /// The fingerprint of a network: what its router is told by, scrambled with this install's own salt so it means
    /// nothing anywhere else.
    static func mark(salt: String, router: String) -> String {
        SHA256.hash(data: Data("\(salt)|\(router)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The network the Mac is on now, as a reading: the fingerprints of its routers (`NetworkRules.members`); nil when it
    /// has no router to tell it by (no network, one whose router hasn't answered yet, or one this app can't tell apart:
    /// see above). `interface`: the one macOS prefers (Wi-Fi or Ethernet, never a tunnel). The IPv6 routers first,
    /// always: the two ways would otherwise take turns naming one network.
    static func current(salt: String, interface: String) async -> String? {
        let routers = routers6(on: interface, routes: table(AF_INET6, RTF_GATEWAY))
        if !routers.isEmpty { return reading(routers.map { mark(salt: salt, router: "v6 " + $0) }) }
        guard let gateway = gateway(on: interface, routes: routes()), let hardware = await hardware(of: gateway, on: interface) else { return nil }
        return mark(salt: salt, router: "mac " + hardware)
    }

    /// Several routers' fingerprints as one reading, the same in any order; one router's is its fingerprint alone.
    static func reading(_ marks: [String]) -> String { Set(marks).sorted().joined(separator: ",") }

    /// One routing message: its flags, its interface, and the addresses it carries as the kernel wrote them (by their
    /// place in `rtm_addrs`: 0 the destination, 1 the gateway).
    struct Record: Equatable {
        var flags: Int32
        var interface: String
        var addresses: [Int: [UInt8]]
    }

    /// The kernel's routing or neighbour table of one address family, filtered by `flags`.
    static func table(_ family: Int32, _ flags: Int32) -> [Record] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, flags]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [] }
        return records(Array(buffer.prefix(length)))
    }

    /// Reads routing messages as the kernel writes them: a header, then the addresses its `rtm_addrs` names, each
    /// padded to four bytes. Anything that doesn't fit its own lengths ends the reading.
    static func records(_ buffer: [UInt8]) -> [Record] {
        var out: [Record] = []
        let header = MemoryLayout<rt_msghdr>.size
        var offset = 0
        while offset + header <= buffer.count {
            let h = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(h.rtm_msglen)
            guard length >= header, offset + length <= buffer.count else { break }
            var at = offset + header
            var addresses: [Int: [UInt8]] = [:]
            for bit in 0..<8 where h.rtm_addrs & (1 << Int32(bit)) != 0 {
                guard at + 2 <= offset + length else { break }
                let size = Int(buffer[at])
                addresses[bit] = Array(buffer[at..<min(at + max(size, 2), offset + length)])
                at += size == 0 ? 4 : (size + 3) & ~3
            }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            if if_indextoname(UInt32(h.rtm_index), &name) != nil { out.append(Record(flags: h.rtm_flags, interface: String(cString: name), addresses: addresses)) }
            offset += length
        }
        return out
    }

    /// An IPv4 address out of a socket address as the kernel wrote it; the default route's destination may be cut short.
    private static func v4(_ a: [UInt8]?, short: String? = nil) -> String? {
        guard let a else { return nil }
        if a.count >= 8, a[1] == UInt8(AF_INET) { return a[4..<8].map(String.init).joined(separator: ".") }
        return a.count < 8 ? short : nil
    }

    /// An IPv6 address out of a socket address, without the interface number the kernel tucks into a link-local one
    /// (it differs between tables); all zeros for a destination cut short.
    private static func v6(_ a: [UInt8]?, short: Bool = false) -> [UInt8]? {
        guard let a else { return nil }
        guard a.count >= 24, a[1] == UInt8(AF_INET6) else { return short && a.count < 24 ? [UInt8](repeating: 0, count: 16) : nil }
        var address = Array(a[8..<24])
        if address[0] == 0xfe, address[1] & 0xc0 == 0x80 { address[2] = 0; address[3] = 0 }
        return address
    }

    /// The IPv6 default routers on `interface`, by their link-local addresses: who the default routes go through (a
    /// mesh or a second box beside the provider's adds one), sorted, each once. Empty when there is none. An address
    /// any router may have ("fe80::1" and the like: fewer than four parts of its own) is left out, since it would make
    /// two networks look the same.
    static func routers6(on interface: String, routes: [Record]) -> [String] {
        let none = [UInt8](repeating: 0, count: 16)
        return Set(routes.filter { $0.interface == interface && $0.flags & RTF_GATEWAY != 0 && v6($0.addresses[0], short: true) == none }
            .compactMap { v6($0.addresses[1]) }
            .filter { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 && $0[8...].filter { $0 != 0 }.count >= 4 }
            .map { $0.map { String(format: "%02x", $0) }.joined() }).sorted()
    }

    /// The default router on `interface`, from the routing table (as `route -n get default -ifscope` reads it).
    static func gateway(on interface: String, routes: [(interface: String, destination: String, gateway: String)]) -> String? {
        routes.first { $0.interface == interface && $0.destination == "0.0.0.0" }?.gateway
    }

    /// IPv4 routes that go through a router: where to, through whom, on which interface.
    static func routes() -> [(interface: String, destination: String, gateway: String)] { routes(table(AF_INET, RTF_GATEWAY)) }

    static func parse(_ buffer: [UInt8]) -> [(interface: String, destination: String, gateway: String)] { routes(records(buffer)) }

    private static func routes(_ records: [Record]) -> [(interface: String, destination: String, gateway: String)] {
        records.compactMap { r in
            guard r.flags & RTF_GATEWAY != 0, let to = v4(r.addresses[0], short: "0.0.0.0"), let via = v4(r.addresses[1]) else { return nil }
            return (r.interface, to, via)
        }
    }

    /// The hardware address of IPv4 `address` on the local network, as macOS's own `arp` reports it; nil when it isn't
    /// known, which it never is to an app without access to the local network. The interface's whole table is
    /// listed: asked for one address, `arp` looks it up through the routing table, which sends it into the VPN's tunnel
    /// while one runs, and finds no entry.
    static func hardware(of address: String, on interface: String) async -> String? {
        guard address.split(separator: ".").count == 4, address.allSatisfy({ $0.isNumber || $0 == "." }),
              interface.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
                p.arguments = ["-a", "-n", "-i", interface]
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return done.resume(returning: nil) }
                // It only reads a table: a few milliseconds. One that hangs is ended, and counts as no answer.
                let limit = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: limit)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); limit.cancel()
                done.resume(returning: p.terminationStatus == 0 ? parseArp(String(decoding: data.prefix(1 << 20), as: UTF8.self), for: address) : nil)
            }
        }
    }

    /// The hardware address in `arp -n` output, each part two digits ("0:1b:…" → "00:1b:…"): on the line for `address`
    /// when one is given (a listing), else the first; nil for none or an address still being looked for.
    static func parseArp(_ output: String, for address: String? = nil) -> String? {
        let line = address.map { a in output.split(separator: "\n").first { $0.contains("(\(a)) at ") }.map(String.init) ?? "" } ?? output
        guard let at = line.range(of: " at ") else { return nil }
        let token = line[at.upperBound...].prefix { !$0.isWhitespace }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ (1...2).contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        let hardware = parts.map { ($0.count == 1 ? "0" : "") + $0.lowercased() }.joined(separator: ":")
        // All zeros or all ones names no device.
        return ["00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"].contains(hardware) ? nil : hardware
    }
}
