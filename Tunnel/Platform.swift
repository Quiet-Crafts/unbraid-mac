import Foundation
@preconcurrency import Libbox
import Network
import NetworkExtension
import Synchronization

/// What sing-box asks of macOS: the tunnel interface, the underlying network, and who owns each connection.
final class Platform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol, @unchecked Sendable {
    private weak var tunnel: PacketTunnelProvider?
    private var settings: NEPacketTunnelNetworkSettings?
    private let settingsLock = NSLock()
    private let stateLock = NSLock()
    private var active = true
    private var path: NWPath?
    private var monitor: NWPathMonitor?
    private var listener: LibboxInterfaceUpdateListenerProtocol?
    private let queue = DispatchQueue(label: "app.unbraid.net")
    private var pushed: Pushed?
    private var loss: DispatchWorkItem?
    private var generation = 0

    /// The user whose engine this is: its Tailscale identity is theirs alone.
    private let owner: uid_t
    /// The tailnet's search domain for the tunnel's resolver ("" for none), set with each configuration before the engine
    /// opens the tun.
    private let search = Mutex("")
    /// The node identity of the Tailscale state this engine last read or sealed (see `TailscaleIdentity.Tracker`), with
    /// the platform it is from (an older engine's close leaves a newer one's alone), the engine it was read or sealed by
    /// (`PacketTunnelProvider.engine`) and the node it names.
    private static let identity = Mutex<(platform: ObjectIdentifier, owner: uid_t, engine: Int, node: String, sealed: EngineWire.Tailscale.SealedIdentity)?>(nil)
    /// Under stateLock.
    private var tracker: TailscaleIdentity.Tracker

    init(_ tunnel: PacketTunnelProvider, owner: uid_t) {
        self.tunnel = tunnel
        self.owner = owner
        tracker = .init(owner: owner)
    }
    deinit { monitor?.cancel() }

    func close() {
        stateLock.withLock {
            active = false
            note { $0.reset() }
        }
        queue.sync { closeMonitor() }
        settingsLock.withLock { settings = nil }
    }

    // MARK: Tunnel interface

    func use(search: String) { self.search.withLock { $0 = search } }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let o = options, let ret0_, let tunnel else { throw Fail("No tunnel") }
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        s.mtu = NSNumber(value: o.getMTU())
        let v4 = prefixes(o.getInet4Address())
        s.ipv4Settings = NEIPv4Settings(addresses: v4.map(\.0), subnetMasks: v4.map(\.1))
        s.ipv4Settings?.includedRoutes = prefixes(o.getInet4RouteAddress()).map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
            .nilIfEmpty ?? [NEIPv4Route.default()]
        s.ipv4Settings?.excludedRoutes = prefixes(o.getInet4RouteExcludeAddress()).map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
        // IPv6 is captured whole and refused by the engine: exits are IPv4, so nothing may leave beside the tunnel.
        let v6 = prefixes(o.getInet6Address()) { ($0.address(), $0.prefix()) }
        if !v6.isEmpty {
            s.ipv6Settings = NEIPv6Settings(addresses: v6.map(\.0), networkPrefixLengths: v6.map { NSNumber(value: $0.1) })
            s.ipv6Settings?.includedRoutes = [NEIPv6Route.default()]
        }
        // The engine answers every query (fake IPs, then each app's own exit): make it the only resolver.
        var dns: [String] = []
        if let it = try? o.getDNSServerAddress() { while it.hasNext() { dns.append(it.next()) } }
        if !dns.isEmpty {
            let d = NEDNSSettings(servers: dns)
            // Every name, with no fallback to the network's own resolver: a query macOS retried there would skip the
            // exits and leak which sites are looked up.
            d.matchDomains = [""]
            d.matchDomainsNoSearch = true
            d.allowFailover = false
            let search = self.search.withLock { $0 }
            if !search.isEmpty { d.searchDomains = [search] }
            s.dnsSettings = d
        }
        // Go calls synchronously while the engine queue is occupied, so these callbacks use their own lock.
        try settingsLock.withLock {
            try wait { done in tunnel.setTunnelNetworkSettings(s) { done($0) } }
            settings = s
        }
        // NetworkExtension keeps the utun descriptor private; libbox finds it by scanning its own descriptors.
        // Private keys: checked before use, since a missing one raises an exception Swift can't catch (every start would
        // crash) instead of falling back to the scan.
        let flow = tunnel.packetFlow as NSObject
        let socket = flow.responds(to: NSSelectorFromString("socket")) ? flow.value(forKey: "socket") as? NSObject : nil
        let fd = (socket?.responds(to: NSSelectorFromString("fileDescriptor")) == true ? socket?.value(forKey: "fileDescriptor") as? Int32 : nil)
            ?? LibboxGetTunnelFileDescriptor()
        guard fd >= 0 else { throw Fail("Missing tunnel descriptor") }
        ret0_.pointee = fd
    }

    func clearDNSCache() {
        settingsLock.withLock {
            guard let tunnel, let settings else { return }
            // Re-applying the same settings makes macOS flush its resolver cache.
            try? wait { done in tunnel.setTunnelNetworkSettings(settings) { done($0) } }
        }
    }

    func includeAllNetworks() -> Bool { (tunnel?.protocolConfiguration as? NETunnelProviderProtocol)?.includeAllNetworks ?? false }
    func underNetworkExtension() -> Bool { true }

    // MARK: Underlying network

    /// Every update the engine sees as a new interface closes all connections, and a loss waits three seconds for the
    /// network to come back. The engine itself keeps connections when only addresses change (same interface and
    /// resolvers), but it rereads the interface table on every update: another Wi-Fi on the same interface (new
    /// addresses, router or cost) goes through, or local addresses and subnets would stay those of the last network.
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let first = DispatchSemaphore(value: 0)
        queue.sync {
            closeMonitor()
            let monitor = NWPathMonitor()
            self.monitor = monitor
            self.listener = listener
            let generation = self.generation
            monitor.pathUpdateHandler = { [weak self] path in
                defer { first.signal() }
                guard let self, self.generation == generation else { return }
                self.stateLock.withLock { self.path = path }
                self.loss?.cancel()
                self.loss = nil
                if path.status == .satisfied, let i = path.availableInterfaces.first {
                    self.push(listener, Pushed(i, path), generation)
                } else {
                    let w = DispatchWorkItem { [weak self] in self?.push(listener, Pushed(), generation) }
                    self.loss = w
                    self.queue.asyncAfter(deadline: .now() + 3, execute: w)
                }
            }
            monitor.start(queue: queue)
        }
        first.wait()
    }

    private func push(_ l: LibboxInterfaceUpdateListenerProtocol, _ now: Pushed, _ generation: Int) {
        guard generation == self.generation, now != pushed else { return }
        pushed = now
        l.updateDefaultInterface(now.name, interfaceIndex: now.index, isExpensive: now.expensive, isConstrained: now.constrained)
    }

    /// What the engine was last told about the default interface, and what it can't see changing under the same name:
    /// cost, routers, and every usable interface's addresses and masks (it matches local sources against them all).
    private struct Pushed: Equatable {
        var name = ""
        var index: Int32 = -1
        var expensive = false
        var constrained = false
        var gateways: [String] = []
        var addresses: [String] = []

        init() {}

        init(_ i: NWInterface, _ path: NWPath) {
            name = i.name
            index = Int32(i.index)
            expensive = path.isExpensive
            constrained = path.isConstrained
            gateways = path.gateways.map(\.debugDescription).sorted()
            addresses = Self.addresses(of: Set(path.availableInterfaces.map(\.name)))
        }

        /// "interface address/mask" for each IPv4 and IPv6 address of `names`.
        private static func addresses(of names: Set<String>) -> [String] {
            var list: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&list) == 0, let first = list else { return [] }
            defer { freeifaddrs(list) }
            func text(_ a: UnsafeMutablePointer<sockaddr>?) -> String {
                guard let a, [sa_family_t(AF_INET), sa_family_t(AF_INET6)].contains(a.pointee.sa_family) else { return "" }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
                return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
            var out: [String] = []
            for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let name = String(cString: p.pointee.ifa_name), address = text(p.pointee.ifa_addr)
                guard names.contains(name), !address.isEmpty else { continue }
                // A mask's sockaddr can be short or carry no family: compared as raw bytes, not formatted.
                let mask = p.pointee.ifa_netmask.map { Data(bytes: $0, count: Int($0.pointee.sa_len)).map { String(format: "%02x", $0) }.joined() } ?? ""
                out.append("\(name) \(address)/\(mask)")
            }
            return out.sorted()
        }
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        queue.sync {
            if let listener, let current = self.listener {
                // gomobile may wrap the same Go listener in a new Objective-C object.
                let same = Self.reference(listener).map { $0 == Self.reference(current) } ?? listener.isEqual(current)
                guard same else { return }
            }
            closeMonitor()
        }
    }

    private static func reference(_ listener: LibboxInterfaceUpdateListenerProtocol) -> Int32? {
        (listener as? LibboxInterfaceUpdateListener).flatMap { ($0._ref as? GoSeqRef)?.refnum }
    }

    private func closeMonitor() {
        generation += 1
        loss?.cancel()
        loss = nil
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
        listener = nil
        pushed = nil
        stateLock.withLock { path = nil }
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let path = stateLock.withLock({ path }) else { return Interfaces([]) }
        let list: [LibboxNetworkInterface] = path.status == .unsatisfied ? [] : path.availableInterfaces.map { i in
            let n = LibboxNetworkInterface()
            n.name = i.name
            n.index = Int32(i.index)
            n.type = switch i.type {
            case .wifi: LibboxInterfaceTypeWIFI
            case .cellular: LibboxInterfaceTypeCellular
            case .wiredEthernet: LibboxInterfaceTypeEthernet
            default: LibboxInterfaceTypeOther
            }
            return n
        }
        return Interfaces(list)
    }

    // MARK: Connection owners

    /// The process behind a connection, for the per-app rules. Root sees every socket in `pcblist_n`.
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        try call { LibboxFindConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort, $0) }
    }

    func useProcFS() -> Bool { false }

    // MARK: Tailscale state, sealed (tsnet would keep node keys in plaintext), one per user

    static func tailscaleState(_ uid: uid_t) -> String { "tailscale-\(uid)" }

    /// Empty only when there is no state yet. A state that can't be read now (the keychain key unavailable, a damaged
    /// file) fails the start instead: as no state, tsnet would register a new node and later overwrite the real one.
    func readTailscaleState(_ error: NSErrorPointer) -> String {
        stateLock.withLock {
            func fail(_ text: String) -> String {
                error?.pointee = NSError(domain: "app.unbraid", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
                if active { note { $0.read(nil) } }
                return ""
            }
            guard active else { return fail("Tunnel stopped") }
            do {
                guard let data = try PacketTunnelProvider.vault.open(Self.tailscaleState(owner)) else { note { $0.read(nil) }; return "" }
                guard let state = String(data: data, encoding: .utf8) else { return fail("The Tailscale state can't be read") }
                note { $0.read(state) }
                return state
            } catch {
                Log.error("tailscale state", error: error)
                return fail("The Tailscale state can't be read. Reconnect, or sign out of Tailscale to start over.")
            }
        }
    }

    func writeTailscaleState(_ state: String?) throws {
        try stateLock.withLock {
            guard active else { throw Fail("Tailscale state not saved") }
            // Whatever the engine holds now may differ from what is sealed: no acknowledgement until a write succeeds.
            guard PacketTunnelProvider.vault.write(Self.tailscaleState(owner), state.map { Data($0.utf8) }) else {
                note { $0.failed() }
                throw Fail("Tailscale state not saved")
            }
            note { $0.wrote(state) }
        }
    }

    /// At a reload: the new engine reads its state again, and its identity is told once it has.
    func forgetIdentity() {
        stateLock.withLock { note { $0.reset() } }
    }

    /// Applies one event to the tracker and publishes what it now tells, for the app (see `sealedIdentity`). Under stateLock.
    private func note(_ event: (inout TailscaleIdentity.Tracker) -> Void) {
        event(&tracker)
        let me = ObjectIdentifier(self), told = tracker.told, engine = PacketTunnelProvider.engine
        let changed = Self.identity.withLock { current in
            let before = current?.sealed
            if let told {
                current = (me, owner, engine, told.node, told.sealed)
            } else if current?.platform == me {
                current = nil
            }
            return current?.sealed != before
        }
        // Status goes out on the engine's events, which a seal alone doesn't cause; never from under this lock.
        if changed { TailscaleWatch.refresh() }
    }

    /// The node identity [uid]'s engine has sealed, when it was read or sealed by the engine counted [engine] and names the
    /// node that engine runs as ([node], its stable id); nil for anyone else, and while there is none.
    static func sealedIdentity(for uid: uid_t, engine: Int, node: String) -> EngineWire.Tailscale.SealedIdentity? {
        identity.withLock { $0?.owner == uid && $0?.engine == engine && $0?.node == node && !node.isEmpty ? $0?.sealed : nil }
    }

    func tailscaleHostname() -> String { "unbraid" }

    // MARK: Unused by unbraid

    func autoDetectControl(_ fd: Int32) throws {}
    func usePlatformAutoDetectControl() -> Bool { false }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func registerMyInterface(_ name: String?) {}
    func usePlatformShell() -> Bool { false }
    func checkPlatformShell() throws { throw Fail("Unsupported") }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: (any LibboxStringIteratorProtocol)?, term: String?, rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol { throw Fail("Unsupported") }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw Fail("Unsupported") }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String { "" }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { "" }
    func usePlatformBridge() -> Bool { false }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol { throw Fail("Unsupported") }

    // MARK: Command server

    func serviceStop() throws { tunnel?.cancelTunnelWithError(nil) }
    func serviceReload() throws {}
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ isEnabled: Bool) throws {}
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws { throw Fail("Unsupported") }
    func triggerNativeCrash() throws {}
    func writeDebugMessage(_ message: String?) { Log.info("engine", detail: Redact.clean(message)) }

    // MARK: Helpers

    private func prefixes(_ it: LibboxRoutePrefixIteratorProtocol?) -> [(String, String)] {
        prefixes(it) { ($0.address(), $0.mask()) }
    }

    private func prefixes<T>(_ it: LibboxRoutePrefixIteratorProtocol?, _ transform: (LibboxRoutePrefix) -> T) -> [T] {
        var out: [T] = []
        while let it, it.hasNext(), let p = it.next() { out.append(transform(p)) }
        return out
    }

    /// Blocks an engine thread on a completion-handler API (the engine calls in synchronously).
    private func wait(_ f: (@escaping @Sendable (Error?) -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        f { failure = $0; done.signal() }
        done.wait()
        if let failure { throw failure }
    }
}

private final class Interfaces: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var items: [LibboxNetworkInterface]
    init(_ items: [LibboxNetworkInterface]) { self.items = items.reversed() }
    func hasNext() -> Bool { !items.isEmpty }
    func next() -> LibboxNetworkInterface? { items.popLast() }
}
