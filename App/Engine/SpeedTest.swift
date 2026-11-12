import Foundation
import Observation
import Network

/// On-demand speed test through one exit with M-Lab's ndt7 (`Ndt7`), on a server in the exit's own country. Results go
/// to `Stats` with the exit, provider and VPN server they were taken on.
///
/// A Tailscale exit node that no route uses is tested by switching Tailscale to it for the test and back afterwards
/// (Tailscale has one exit node at a time); `Store.tsTestNode` remembers a switch a quit app couldn't undo.
@Observable
final class SpeedTest {
    static let shared = SpeedTest()

    enum Phase: Sendable { case preparing, deciding, download, upload, done, failed }

    /// Exit id of a Tailscale exit node tested without a route: "ts:" and its tailnet IP.
    nonisolated static let node = StatsMath.tsNode
    /// M-Lab's limit for interactive users (measurementlab.net/aup).
    static let perDay = 40
    /// Ten seconds each way.
    static let maxSeconds = 20

    /// Speeds in bits/s, `ping` in ms (median, low, high); nil = not measured yet. `server` is the M-Lab server once
    /// located; `missing` names the exit's country when M-Lab has no server there (the user may then test with the
    /// nearest one).
    struct Run: Sendable {
        var exit: String
        var phase = Phase.preparing
        var down: Int64?
        var up: Int64?
        var ping: Ndt7.Ping?
        var server: Ndt7.Server?
        var missing: String?
        var error: String?
    }

    /// The test under way, or the last one until `clear()`.
    struct Leg: Sendable {
        var exit: String
        var server: Ndt7.Server?
        var missing = false
        var limited = false
        var error: String?
        var ping: Ndt7.Ping?
        var down: Int64?
        var up: Int64?
        var now: Int64 = 0
        var share: Double?
    }
    struct All: Sendable {
        var legs: [Leg]
        var phase = Phase.preparing
        var metered = false
        var down: Int64?
        var up: Int64?
        var windowMs: Int64 = 0
        var elapsedMs: Int64 = 0
        var error: String?
        var notice: String?
    }
    private(set) var all: All?
    private var allJobs: [Job] = []
    private var testingToken: UUID?
    private var cleanups = 0
    private var pathMonitor: NWPathMonitor?
    private var metered = true
    private(set) var run: Run?
    /// The readings of the test under way. Apart from `run`, so four readings a second redraw what shows them and not the page.
    let trace = SpeedTrace()

    /// A test is under way (Tailscale may be on its test node on purpose).
    var testing: Bool { (run.map { [.preparing, .download, .upload].contains($0.phase) } ?? false) || (all.map { [.preparing, .deciding, .download, .upload].contains($0.phase) } ?? false) }
    /// A Tailscale node test is under way: Tailscale is on its test node on purpose.
    var testingNode: Bool { testing && run?.exit.hasPrefix(Self.node) == true }
    var phase: Phase? { run?.phase }
    /// The user agreed to M-Lab's terms (results, with the exit's IP address, are published); `start` refuses without.
    var consented: Bool {
        get { Store.shared.mlabConsent }
        set { Store.shared.mlabConsent = newValue }
    }

    private var attempt = 0
    /// Tests started so far: a health check during which one started says nothing about the exit.
    private(set) var tests = 0
    /// Tailscale exit-node switches, in order: a restore never overtakes the next test's switch.
    private var tsTail: Task<Void, Never>?
    private var task: Task<Void, Never>?

    /// Tailscale exit nodes the test can switch to: online, and not already carrying a route (those test as the route).
    static func nodes() -> [TsNode] {
        // The setup that runs: an edit the engine didn't take doesn't move Tailscale's exit node.
        let c = Connection.shared, s = c.running ?? Store.shared.setup
        if !c.tags.values.contains(Compiler.tsTag) && !s.tailscale { return [] }
        return c.state.tsExitNodes.filter { $0.online && !$0.id.isEmpty && $0.ip != s.tsExit }
    }

    /// The exit a running test measures through tunnel `tag`, so its traffic is counted there; nil = none.
    func exitOn(_ tag: String?) -> String? {
        if testing, let e = all?.legs.first(where: { Connection.shared.tags[$0.exit] == tag })?.exit, tag != nil { return e }
        guard testing, let e = run?.exit else { return nil }
        return tag == (e.hasPrefix(Self.node) ? Compiler.tsTag : Connection.shared.tags[e]) ? e : nil
    }

    private struct Job {
        var exit: String, tag: String, country: String?, missing: String?
        var via: String, name: String, ip: String
        var epoch: Int, mine: Int, recordAs: String
        /// A Tailscale node test: what the engine ran when it switched (`Connection.engineEpoch`). Anything else since, and
        /// the result isn't the node's.
        var engine: [Int]? = nil
    }

    /// Tests `exit`; `anywhere` = with the nearest M-Lab server even outside the exit's country.
    @discardableResult
    func start(exit: String, anywhere: Bool = false) -> Bool {
        let store = Store.shared, conn = Connection.shared
        let node = exit.hasPrefix(Self.node) ? Self.nodes().first { Self.node + $0.ip == exit } : nil
        if exit.hasPrefix(Self.node) && node == nil { return false }
        guard let tag = node != nil ? Compiler.tsTag : conn.tags[exit] else { return false }
        cancel()
        all = nil
        guard consented, !settling else { return false }
        if store.testsToday >= Self.perDay {
            run = Run(exit: exit, phase: .failed, error: "M-Lab allows \(Self.perDay) tests a day. Try again tomorrow.")
            return false
        }
        let setup = conn.running ?? store.setup
        let route = setup.route(exit)
        let vpnServer = conn.state.servers[exit]
        // Provider routes know their country; imported servers and Tailscale nodes are located by their address alone.
        let country = anywhere ? nil : route.flatMap { !$0.imported && $0.tsExit == nil ? $0.loc.countryCode?.uppercased() : nil }
        attempt += 1
        tests += 1
        let job = Job(exit: exit, tag: tag, country: country, missing: route?.loc.country ?? country,
                      via: node != nil ? "Tailscale" : route?.source ?? "", name: node?.name ?? vpnServer?.name ?? route?.name ?? "",
                      ip: node?.ip ?? vpnServer?.ip ?? "", epoch: Stats.shared.epoch, mine: attempt, recordAs: StatsMath.idOf(exit, setup: setup))
        run = Run(exit: exit)
        trace.reset()
        task = Task { [self] in
            defer { if attempt == job.mine { task = nil } }
            guard let node else {
                if job.tag == Compiler.tsTag && store.tsTestNode {
                    guard await restoreNode(), attempt == job.mine else {
                        update(job.mine) { $0.phase = .failed; $0.error = "Tailscale couldn't restore the route. Try again." }
                        return
                    }
                }
                guard attempt == job.mine else { return }
                await measure(job)
                return
            }
            store.tsTestNode = true
            // Measured only through the configuration it switched: a reload or a pause meanwhile ends the test.
            var job = job
            job.engine = Connection.shared.engineEpoch
            var (ok, sent) = await switchNode(node.id, job.mine)
            // No answer in time: it may still land, or not. Tailscale's status says which (for a few seconds).
            if ok == nil, let sent, attempt == job.mine, await Self.shown(node.id, after: sent, within: .seconds(5)) { ok = true }
            let switched = ok == true
            // Switching is a blocking call; give Tailscale a moment to reach the new node before measuring.
            if switched { try? await Task.sleep(for: .milliseconds(1500)) }
            if attempt != job.mine { return }
            if switched { await measure(job) } else {
                run = Run(exit: exit, phase: .failed, error: ok == false ? "Tailscale couldn't switch to \(node.name)." : "Tailscale didn't confirm the switch to \(node.name).")
            }
            // A test stopped meanwhile was put back by `cancel()`; this one mustn't undo the next test's switch.
            if attempt == job.mine { await restoreNode() }
        }
        return true
    }

    /// Finds servers through running routes before asking to use data.
    @discardableResult
    func startAll(_ exits: [String]) -> Bool {
        let conn = Connection.shared
        var setup = conn.running ?? Store.shared.setup
        setup.testing = []
        let ids = Array(Set(exits)).sorted()
        guard consented, !settling, conn.state.phase == .on, (2...10).contains(ids.count), conn.probe != nil,
              ids.allSatisfy({ !$0.hasPrefix(Self.node) && setup.route($0) != nil }) else { return false }
        cancel()
        run = nil; all = nil
        attempt += 1; tests += 1
        let mine = attempt
        allJobs = []
        all = All(legs: ids.map { Leg(exit: $0) })
        metered = true
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let costly = path.status != .satisfied || path.isExpensive || path.isConstrained
            Task { @MainActor in if self?.attempt == mine { self?.metered = costly } }
        }
        monitor.start(queue: DispatchQueue(label: "app.unbraid.speedtest.path"))
        task = Task { [self] in
            defer { if attempt == mine { task = nil; if all?.phase != .deciding { releaseTesting() } } }
            let accounts = Store.shared.accounts
            var limits: [String: Limit] = [:]
            for provider in Set(ids.compactMap { setup.route($0)?.loc.provider }) {
                if let account = accounts[provider], let p = Providers.get(provider), let limit = try? await p.limit(account) { limits[provider] = limit }
            }
            guard attempt == mine, !Task.isCancelled else { return }
            let choice = TestingRoutes.choose(ids, setup: setup) { limits[$0] }
            for (id, error) in choice.errors { updateLeg(mine, id) { $0.error = error } }
            if !choice.routes.isEmpty {
                let token = await conn.beginTesting(choice.routes)
                guard attempt == mine, !Task.isCancelled else { if let token { conn.endTesting(token) }; return }
                testingToken = token
                if token == nil { for id in choice.routes { updateLeg(mine, id) { $0.error = "It didn't connect for the test." } } }
            }
            let active = conn.running ?? setup
            allJobs = ids.compactMap { id in
                guard all?.legs.first(where: { $0.exit == id })?.error == nil, let tag = conn.tags[id], let route = active.route(id) else {
                    updateLeg(mine, id) { if $0.error == nil { $0.error = "It didn't connect for the test." } }; return nil
                }
                let server = conn.state.servers[id]
                return Job(exit: id, tag: tag, country: !route.imported && route.tsExit == nil ? route.loc.countryCode?.uppercased() : nil,
                           missing: route.loc.country, via: route.source, name: server?.name ?? route.name, ip: server?.ip ?? "",
                           epoch: Stats.shared.epoch, mine: mine, recordAs: StatsMath.idOf(id, setup: active), engine: conn.engineEpoch)
            }
            if allJobs.contains(where: { $0.tag == Compiler.tsTag }) && Store.shared.tsTestNode {
                guard await restoreNode(), attempt == mine else { failAll(mine, "Tailscale couldn't restore the route. Try again."); return }
            }
            let jobs = allJobs, probe = conn.probe
            await withTaskGroup(of: Leg.self) { group in
                for j in jobs {
                    group.addTask {
                        var leg = Leg(exit: j.exit)
                        do {
                            leg.server = try await Ndt7.locate(tag: j.tag, country: j.country, probe: probe)
                            if leg.server == nil && j.country != nil {
                                leg.missing = true
                                leg.server = try? await Ndt7.locate(tag: j.tag, country: nil, probe: probe)
                            }
                            if leg.server == nil && !leg.missing { leg.error = "M-Lab couldn't be reached through it." }
                        } catch is Ndt7.Limited { leg.limited = true }
                        catch { leg.error = "M-Lab couldn't be reached through it." }
                        return leg
                    }
                }
                for await leg in group { self.updateLeg(mine, leg.exit) { $0 = leg } }
            }
            guard attempt == mine, let current = all else { return }
            if metered || current.legs.contains(where: { $0.missing || $0.limited || $0.error != nil }) {
                all?.metered = metered; all?.phase = .deciding
            } else { await measureAll(mine, nearest: [], approvedMetered: false) }
        }
        return true
    }

    func goAll(nearest: Set<String>) {
        guard all?.phase == .deciding else { return }
        let mine = attempt, approved = all?.metered == true
        all?.phase = .preparing
        task = Task {
            defer { if attempt == mine { task = nil; if all?.phase != .deciding { releaseTesting() } } }
            await measureAll(mine, nearest: nearest, approvedMetered: approved)
        }
    }

    private func updateLeg(_ mine: Int, _ exit: String, _ f: (inout Leg) -> Void) {
        guard attempt == mine, let i = all?.legs.firstIndex(where: { $0.exit == exit }) else { return }
        f(&all!.legs[i])
    }
    private func failAll(_ mine: Int, _ message: String) {
        guard attempt == mine else { return }
        all?.phase = .failed; all?.error = message
        releaseTesting()
    }

    private func releaseTesting() {
        if let token = testingToken {
            testingToken = nil
            let conn = Connection.shared, failures = conn.testingFailures, mine = attempt
            if let cleanup = conn.endTesting(token) {
                cleanups += 1
                Task {
                    await cleanup.value
                    cleanups -= 1
                    if attempt == mine, conn.testingFailures != failures, all != nil {
                        if all?.phase == .done {
                            all?.notice = "The test finished, but its temporary routes couldn't be removed. Check the connection."
                        } else {
                            all?.phase = .failed
                            all?.error = "The test couldn't finish. Check the connection and try again."
                        }
                    }
                }
            }
        }
    }

    private func markChanged(_ mine: Int, jobs: [Job]) {
        let conn = Connection.shared, setup = conn.running ?? Store.shared.setup
        for j in jobs where j.engine != conn.engineEpoch || !Ndt7.sameRoute(running: conn.state.phase == .on, originalTag: j.tag, tag: conn.tags[j.exit], originalID: j.recordAs, id: StatsMath.idOf(j.exit, setup: setup), originalIP: j.ip, ip: conn.state.servers[j.exit]?.ip) {
            updateLeg(mine, j.exit) { $0.error = "The route changed during the test. Not counted." }
        }
    }

    private func measureAll(_ mine: Int, nearest: Set<String>, approvedMetered: Bool) async {
        markChanged(mine, jobs: allJobs)
        guard attempt == mine, let current = all else { return }
        if metered && !approvedMetered { all?.metered = true; all?.phase = .deciding; return }
        let legs = current.legs.filter { Ndt7.includeInParallel(hasServer: $0.server != nil, missing: $0.missing, limited: $0.limited, failed: $0.error != nil, useNearest: nearest.contains($0.exit)) }
        guard legs.count >= 2 else { failAll(mine, "At least two exits need a test server to run together."); return }
        guard Ndt7.canReserveParallel(legs.count, used: Store.shared.testsToday, limit: Self.perDay) else { failAll(mine, "M-Lab allows \(Self.perDay) tests a day; this run needs \(legs.count) of them. Try fewer exits, or tomorrow."); return }
        Store.shared.testsToday += legs.count
        all?.legs = legs; all?.phase = .preparing
        let jobs = allJobs.filter { j in legs.contains { $0.exit == j.exit } }, probe = Connection.shared.probe
        await withTaskGroup(of: (String, Ndt7.Ping?).self) { group in
            for j in jobs { if let server = legs.first(where: { $0.exit == j.exit })?.server { group.addTask { (j.exit, try? await Ndt7.ping(tag: j.tag, server: server, probe: probe)) } } }
            for await (id, ping) in group { updateLeg(mine, id) { $0.ping = ping } }
        }
        guard attempt == mine else { return }
        markChanged(mine, jobs: jobs)
        all?.phase = .download
        let started = Ndt7.uptimeMs()
        var downSamples: [String: [(time: Int64, bytes: Int64)]] = [:]
        var used: [String: Ndt7.Server] = [:]
        await withTaskGroup(of: ParallelResult.self) { group in
            for j in jobs { if all?.legs.first(where: { $0.exit == j.exit })?.error == nil, let server = legs.first(where: { $0.exit == j.exit })?.server {
                group.addTask {
                    let samples = SpeedSamples()
                    do {
                        let (chosen, value) = try await Ndt7.anyOf(server) { candidate in
                            samples.clear()
                            guard let url = Ndt7.concurrentURL(candidate.download, count: legs.count) else { throw Ndt7.Refused() }
                            return try await Ndt7.download(tag: j.tag, url: url, probe: probe, sample: { samples.add($0, $1) }) { rate in if self.all?.phase == .download { self.updateLeg(mine, j.exit) { $0.now = rate }; if self.attempt == mine { self.all?.elapsedMs = Ndt7.uptimeMs() - started } } }
                        }
                        return ParallelResult(exit: j.exit, server: chosen, value: value, samples: samples.read())
                    } catch { return ParallelResult(exit: j.exit, refused: error is Ndt7.Refused) }
                }
            } }
            for await result in group {
                downSamples[result.exit] = result.samples; used[result.exit] = result.server
                updateLeg(mine, result.exit) { l in
                    l.now = 0; l.down = result.value
                    if let server = result.server { if l.server?.download != server.download { l.ping = nil }; l.server = server }
                    if result.value == nil { l.error = result.refused ? Ndt7.unreachableText : "Stopped during the download: the exit stopped answering. Not in the totals." }
                }
            }
        }
        guard attempt == mine else { return }
        markChanged(mine, jobs: jobs)
        guard (all?.legs.filter { $0.error == nil && $0.down != nil }.count ?? 0) >= 2 else {
            failAll(mine, "Only one exit kept going, so there's nothing to add up. Try again."); return
        }
        all?.phase = .upload
        var upSamples: [String: [(time: Int64, bytes: Int64)]] = [:]
        await withTaskGroup(of: ParallelResult.self) { group in
            for j in jobs { if all?.legs.first(where: { $0.exit == j.exit })?.error == nil, let server = used[j.exit] {
                group.addTask {
                    let samples = SpeedSamples()
                    do {
                        guard let url = Ndt7.concurrentURL(server.upload, count: legs.count) else { throw Ndt7.Refused() }
                        let value = try await Ndt7.upload(tag: j.tag, url: url, probe: probe, sample: { samples.add($0, $1) }) { rate in if self.all?.phase == .upload { self.updateLeg(mine, j.exit) { $0.now = rate }; if self.attempt == mine { self.all?.elapsedMs = Ndt7.uptimeMs() - started } } }
                        return ParallelResult(exit: j.exit, value: value, samples: samples.read())
                    } catch { return ParallelResult(exit: j.exit) }
                }
            } }
            for await result in group {
                upSamples[result.exit] = result.samples
                updateLeg(mine, result.exit) { $0.now = 0; $0.up = result.value; if result.value == nil { $0.error = "Stopped during the upload: the exit stopped answering. Not in the totals." } }
            }
        }
        guard attempt == mine else { return }
        markChanged(mine, jobs: jobs)
        let good = all?.legs.filter { $0.error == nil && $0.down != nil && $0.up != nil } ?? []
        guard good.count >= 2, let down = Ndt7.combined(good.map { downSamples[$0.exit] ?? [] }),
              let up = Ndt7.combined(good.map { upSamples[$0.exit] ?? [] }) else {
            failAll(mine, good.count < 2 ? "Only one exit kept going, so there's nothing to add up. Try again." : "The exits didn't run together long enough to add them up. Try again."); return
        }
        let commonStart = good.compactMap { downSamples[$0.exit]?.first?.time }.max() ?? 0
        let commonEnd = good.compactMap { downSamples[$0.exit]?.last?.time }.min() ?? 0
        let amounts = good.map { leg -> (String, Int64) in
            let samples = downSamples[leg.exit] ?? []
            return (leg.exit, (Ndt7.bytesAt(samples, commonEnd) ?? 0) - (Ndt7.bytesAt(samples, commonStart) ?? 0))
        }
        let total = amounts.reduce(0.0) { $0 + Double($1.1) }
        for (id, bytes) in amounts where total > 0 { updateLeg(mine, id) { $0.share = Double(bytes) / total } }
        all?.down = down.bps; all?.up = up.bps; all?.windowMs = min(down.ms, up.ms); all?.phase = .done
        let id = Int64(Date.now.timeIntervalSince1970 * 1000)
        var rows = [TestResult(at: id, exit: "all", via: "", server: "", ip: "", down: down.bps, up: up.bps, idle: 0, grp: id, n: good.count)]
        for (i, leg) in good.enumerated() { if let j = jobs.first(where: { $0.exit == leg.exit }) {
            rows.append(TestResult(at: id + Int64(i + 1), exit: j.recordAs, via: j.via, server: j.name, ip: j.ip, down: leg.down ?? 0, up: leg.up ?? 0, idle: leg.ping?.median ?? 0, grp: id, n: good.count))
        } }
        if let first = jobs.first { Stats.shared.saveTests(rows, startedIn: first.epoch, attempt: mine) }
    }

    #if DEBUG
    /// The smoothness matrix: a test's readings at the engine's rate, ten seconds each way, with no network.
    func perfSimulate(exit: String) async {
        attempt += 1
        trace.reset()
        run = Run(exit: exit, phase: .download)
        let t0 = Ndt7.uptimeMs()
        for i in 1...80 {
            try? await Task.sleep(for: .milliseconds(250))
            if i == 41 { let down = trace.bps; run?.down = down; run?.phase = .upload }
            let wave = 180 + 90 * sin(Double(i) / 3) + Double(i % 7) * 12
            trace.add(bps: Int64(wave * 1_000_000), ms: Ndt7.uptimeMs() - t0, upload: i > 40, at: Date.now.timeIntervalSinceReferenceDate)
        }
        let up = trace.bps
        run?.up = up; run?.phase = .done
    }
    #endif

    private func reading(_ mine: Int, _ phase: Phase, bps: Int64, ms: Int64) {
        guard attempt == mine, run?.phase == phase else { return }
        trace.add(bps: bps, ms: ms, upload: phase == .upload, at: Date.now.timeIntervalSinceReferenceDate)
    }

    private func update(_ mine: Int, _ f: (inout Run) -> Void) {
        if attempt == mine, run != nil { f(&run!) }
    }

    /// A route changed while its result waited to be saved.
    func routeChanged(_ mine: Int) {
        update(mine) { $0.phase = .failed; $0.error = "The route changed during the test. Try again." }
        if all != nil { failAll(mine, "The route changed during the test. Not counted.") }
    }

    /// The test itself: locate, ping, ten seconds down, ten seconds up, save.
    private func measure(_ j: Job) async {
        // Stopped, or (a node test) the engine changed under it: what it would measure isn't the node.
        let changed = { j.engine.map { $0 != Connection.shared.engineEpoch } ?? false }
        let stop = {
            if self.attempt == j.mine, changed() { self.update(j.mine) { $0.phase = .failed; $0.error = "The connection changed during the test. Try again." } }
            return self.attempt != j.mine || changed()
        }
        let probe = { Connection.shared.probe }
        let sameRoute = {
            let conn = Connection.shared
            return Ndt7.sameRoute(running: conn.state.phase == .on, originalTag: j.tag, tag: conn.tags[j.exit],
                                  originalID: j.recordAs, id: StatsMath.idOf(j.exit, setup: conn.running ?? Store.shared.setup),
                                  originalIP: j.ip, ip: conn.state.servers[j.exit]?.ip)
        }
        do {
            let server = try await Ndt7.locate(tag: j.tag, country: j.country, probe: probe())
            if stop() { return }
            // Only a test held to the exit's country can lack a server there; anywhere, none is a failure.
            guard let server else {
                if j.country == nil { throw Fail("M-Lab found no test server") }
                update(j.mine) { $0.phase = .failed; $0.missing = j.missing }
                return
            }
            Store.shared.testsToday += 1
            update(j.mine) { $0.server = server }
            let ping = try await Ndt7.optionalPing { try await Ndt7.ping(tag: j.tag, server: server, probe: probe()) }
            if stop() { return }
            update(j.mine) { $0.ping = ping; $0.phase = .download }
            let t0 = Ndt7.uptimeMs()
            // Readings arrive without holding up the transfer, so one may land after its phase ended.
            let (used, down) = try await Ndt7.anyOf(server) { candidate in
                if stop() { throw CancellationError() }
                return try await Ndt7.download(tag: j.tag, url: candidate.download, probe: probe()) { bps in
                    self.reading(j.mine, .download, bps: bps, ms: Ndt7.uptimeMs() - t0)
                }
            }
            if stop() { return }
            if j.engine == nil && !sameRoute() { routeChanged(j.mine); return }
            update(j.mine) { $0.phase = .upload; $0.down = down; $0.server = used; if used.download != server.download { $0.ping = nil } }
            let up = try await Ndt7.upload(tag: j.tag, url: used.upload, probe: probe()) { bps in
                self.reading(j.mine, .upload, bps: bps, ms: Ndt7.uptimeMs() - t0)
            }
            if stop() { return }
            if j.engine == nil && !sameRoute() { routeChanged(j.mine); return }
            update(j.mine) { $0.phase = .done; $0.up = up }
            guard let done = run else { return }
            Stats.shared.saveTest(TestResult(at: Int64(Date.now.timeIntervalSince1970 * 1000), exit: j.recordAs, via: j.via, server: j.name, ip: j.ip,
                                             down: down, up: up, idle: done.ping?.median ?? 0), startedIn: j.epoch, attempt: j.mine)
        } catch is Ndt7.Limited {
            update(j.mine) { $0.phase = .failed; $0.error = "M-Lab is limiting tests from this exit's address right now (VPN servers share theirs). Try again later." }
        } catch is CancellationError where stop() {
            // Stopped, or `stop()` has already said why: the connection changed.
            return
        } catch {
            Log.error("speed test", error: error)
            update(j.mine) { $0.phase = .failed; $0.error = error is Ndt7.Refused ? Ndt7.unreachableText : "The test couldn't finish. Check the connection and try again." }
        }
    }

    // MARK: Tailscale exit node

    private func serial<T: Sendable>(_ f: @escaping @MainActor () async -> T) async -> T {
        let prev = tsTail
        let t = Task { await prev?.value; return await f() }
        tsTail = Task { _ = await t.value }
        return await t.value
    }

    /// What Tailscale was last confirmed on, and how long a switch or restore that got no answer may still land (the
    /// extension cuts one off only after 5 seconds, and even then it may still be made): until then a restore is repeated now and then, so a late one can't leave the routed
    /// apps on the test node; and how long nothing is sent after one went unanswered.
    private var tsr = TsRestore()
    /// When the last switch or restore was sent.
    private var lastCall: ContinuousClock.Instant?
    private var followUp: Task<Void, Never>?
    private var restoring: Task<Bool, Never>?
    /// The app is quitting: no new test starts.
    private var settling = false

    /// True done, false refused (or skipped: the test was stopped while the switch waited its turn), nil no answer; and
    /// when it was sent.
    private func switchNode(_ id: String, _ mine: Int) async -> (Bool?, ContinuousClock.Instant?) {
        await serial { [self] in
            guard attempt == mine, !settling else { return (false, nil) }
            // Asked again once no engine change is under way: the test may have been stopped while it waited.
            return await Connection.shared.steady { _ -> (Bool?, ContinuousClock.Instant?) in
                guard attempt == mine, !settling else { return (false, nil) }
                let r = await set(id, switching: true)
                return (r, lastCall)
            } ?? (false, nil)
        }
    }

    /// Whether a status of Tailscale's received after [after] shows exit node [id] within [limit].
    private static func shown(_ id: String, after: ContinuousClock.Instant, within limit: Duration) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if Connection.shared.tsShows(id, after: after) == true { return true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    /// One switch, in order with the others: true done, false refused, nil no answer (it may still happen).
    private func set(_ id: String, switching: Bool) async -> Bool? {
        // A status from before this says nothing about it.
        lastCall = .now
        let r = await Self.setNode(id)
        tsr.answered(r, id, switching: switching, now: .now)
        return r
    }

    /// Made between engine changes (`Connection.steady`), which wait meanwhile: an answer is waited for briefly.
    private nonisolated static func setNode(_ id: String) async -> Bool? {
        await EngineLink.call(timeout: 3) { $0.setTailscaleExitNode(Compiler.tsTag, stableID: id, reply: $1) }
    }

    /// Puts Tailscale back on the exit node the routes use (or none); true once that is confirmed and nothing sent
    /// earlier can still land. Safe to call any time and from several places at once: they share one attempt.
    @discardableResult
    func restoreNode() async -> Bool {
        if let r = restoring { return await r.value }
        let r = Task { await serial { [self] in await putBack() } }
        restoring = r
        defer { restoring = nil }
        return await r.value
    }

    /// Between engine changes: put back on what the configuration running then routes through.
    private func putBack() async -> Bool {
        await Connection.shared.steady { [self] running in await putBack(running?.tsExit) } ?? false
    }

    /// [routed]: the exit node of the configuration that runs, not of an edit the engine hasn't taken.
    private func putBack(_ routed: String?) async -> Bool {
        // The routed node isn't listed (yet): no exit node at all, so the routed apps lose the internet rather than use
        // the test node; the flag stays and the next Tailscale status puts the routed node back.
        let node = routed.flatMap { ip in Connection.shared.state.tsExitNodes.first { $0.ip == ip && !$0.id.isEmpty } }
        // Never under a node test that started since this restore was asked for: its own end puts the node back.
        guard !testingNode else { return false }
        let want = node?.id ?? "", shows = Connection.shared.tsShows(want, after: lastCall)
        let ok: Bool, seen: Bool
        switch tsr.next(want: want, shows: shows, now: .now) {
        case .skip(let done): ok = done; seen = shows == true
        // Shown only by a status after this answer: the next one comes back here.
        case .send(let want): ok = await set(want, switching: false) == true; seen = false
        }
        let (done, pending) = tsr.final(ok: ok, routed: routed != nil, listed: node != nil, seen: seen, now: .now)
        if done { Store.shared.tsTestNode = false }
        if pending { repeatRestore() }
        return done
    }

    /// Restores again a little later while an unanswered switch may still land, a few times at most; a test started
    /// meanwhile restores at its own end.
    private func repeatRestore() {
        guard followUp == nil, let wait = tsr.again(now: .now) else { return }
        followUp = Task { [self] in
            try? await Task.sleep(for: wait)
            followUp = nil
            if !testingNode { await restoreNode() }
        }
    }

    /// Quitting: a running test is stopped and Tailscale put back on the routed exit node, waiting at most [limit]
    /// (an extension that doesn't answer mustn't hold up the quit). Whatever is left is done at the next launch, from
    /// `Store.tsTestNode`. Safe to call more than once.
    func settle(within limit: Duration) async {
        settling = true
        let work = task
        cancel()
        // The restore isn't cancelled at the deadline (it may still finish): only the wait for it ends.
        let race = Race()
        await withCheckedContinuation { k in
            race.k = k
            Task {
                async let restored: Bool = Store.shared.tsTestNode ? restoreNode() : true
                await work?.value
                await Connection.shared.waitForTestingCleanup()
                _ = await restored
                race.finish()
            }
            Task { try? await Task.sleep(for: limit); race.finish() }
        }
    }

    /// Stops a running test; its sockets close as soon as they notice.
    func cancel() {
        trace.reset()
        let wasNode = run?.exit.hasPrefix(Self.node) == true
        attempt += 1
        if let work = task {
            let mine = attempt
            work.cancel()
            Task {
                await work.value
                if attempt == mine { task = nil }
            }
        }
        releaseTesting()
        pathMonitor?.cancel(); pathMonitor = nil
        if testing {
            Ndt7.abort()
            run = nil; all = nil
            if wasNode { Task { await restoreNode() } }
        }
    }

    /// Leaving the result screen forgets the last run (it's in History if stats are on).
    func clear() { if !testing { run = nil; all = nil; trace.reset(); pathMonitor?.cancel(); pathMonitor = nil } }
}

/// The first of a restore and its deadline ends the quit's wait.
private final class Race {
    var k: CheckedContinuation<Void, Never>?
    func finish() { k?.resume(); k = nil }
}

// MARK: - The network half of ndt7

/// ndt7 through one exit: `URLSessionWebSocketTask` on the probe session (the engine's loopback proxy), so the
/// WebSocket, its pings and its TLS are the system's. Ndt7.kt, ported.
nonisolated extension Ndt7 {
    static func uptimeMs() -> Int64 { Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000) }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The tests' open sessions, so a cancel can close them under a blocked read or write.
    private static let live = Sessions()

    /// Ends whatever a test is doing on the network now.
    static func abort() { live.cancelAll() }

    /// The M-Lab server nearest the exit's own address, inside `country` when given; nil if M-Lab found none there.
    static func locate(tag: String, country: String?, probe: Probe.Endpoint?) async throws -> Server? {
        let (status, body) = try await Probe.fetch(tag: tag, host: locateHost, path: locatePath(version: version, country: country), probe: probe)
        return try locateReply(status: status, body: body, country: country)
    }

    /// Ookla-style ping: five TCP handshakes with the test server through the exit, after one untimed connection that
    /// resolves its name. Measured by the Mac: many M-Lab sites sit behind a cloud proxy, so the server's own
    /// round-trip figure only sees the proxy next to it.
    static func ping(tag: String, server: Server, probe: Probe.Endpoint?) async throws -> Ping {
        guard let host = host(server.download) else { throw Fail("The test server refused the test") }
        _ = try await Probe.handshakeMs(tag: tag, host: host, probe: probe)
        var ms: [Int] = []
        for _ in 0..<5 { ms.append(Int(try await Probe.handshakeMs(tag: tag, host: host, probe: probe).rounded())) }
        return ping(ms)
    }

    /// Receives until the server ends the test; `rate` gets bits/s every quarter second. Off the main actor: early
    /// messages are 8 KiB, thousands a second, and waiting behind SwiftUI's redraws throttled the transfer itself.
    @concurrent static func download(tag: String, url: String, probe: Probe.Endpoint?, sample: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }, rate: @escaping @MainActor @Sendable (Int64) -> Void) async throws -> Int64 {
        let (task, session) = try socket(tag, url, probe)
        defer { close(task, session) }
        let cap = Task { if (try? await Task.sleep(for: .seconds(downloadCap))) != nil { task.cancel(with: .goingAway, reason: nil) } }
        defer { cap.cancel() }
        // The clock starts with the first message, as when ndt7's own clients see the socket open: the proxy, TLS and
        // WebSocket handshakes are not download time.
        var start = uptimeMs()
        var bytes: Int64 = 0, told = start, noted = start
        sample(start, 0)
        do {
            try await withTaskCancellationHandler {
                while true {
                    let m = try await task.receive()
                    if bytes == 0 { start = uptimeMs(); told = start }
                    switch m {
                    case .data(let d): bytes += Int64(d.count)
                    case .string(let s):
                        // The server's own reports; the Mac counts what it receives.
                        guard frameOk(text: true, length: s.utf8.count) else { throw Fail("Bad frame from the test server") }
                        bytes += Int64(s.utf8.count)
                    @unknown default: break
                    }
                    let now = uptimeMs()
                    if now - noted >= 20 { noted = now; sample(now, bytes) }
                    if now - told >= 250 { told = now; let bps = bitsPerSecond(bytes: bytes, ms: now - start); Task { @MainActor in rate(bps) } }
                }
            } onCancel: { task.cancel(with: .goingAway, reason: nil) }
        } catch let f as Fail {
            throw f
        } catch {
            try Task.checkCancellation()
            if task.closeCode == .messageTooBig { throw Fail("Bad frame from the test server") }
            if bytes == 0 { throw Refused() }
            if transportFailed(elapsedMs: uptimeMs() - start, normalClose: task.closeCode == .normalClosure) { throw error }
        }
        sample(uptimeMs(), bytes)
        guard let bps = downloadRate(bytes: bytes, ms: uptimeMs() - start) else { throw Refused() }
        return bps
    }

    /// Sends for ten seconds; the rate is what the server says it received (its TCPInfo), not what left the Mac's
    /// buffers. The live figure falls back to bytes sent until the server's first report. Off the main actor, like
    /// the download.
    @concurrent static func upload(tag: String, url: String, probe: Probe.Endpoint?, sample: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }, rate: @escaping @MainActor @Sendable (Int64) -> Void) async throws -> Int64 {
        let (task, session) = try socket(tag, url, probe)
        defer { close(task, session) }
        let server = Latest()
        let opened = uptimeMs()
        sample(opened, 0)
        // The server reports what it has received a few times a second, as text messages; read them alongside.
        // Data isn't expected while uploading: never buffered.
        let reader = Task {
            while let m = try? await task.receive() {
                if case .string(let s) = m, frameOk(text: true, length: s.utf8.count), let reading = serverSample(s), let bps = serverRate(reading) {
                    server.set(bps)
                    sample(opened + reading.us / 1000, reading.bytes)
                }
            }
        }
        var data = Data(count: 1 << 20)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        let start = uptimeMs()
        var size = 1 << 13, sent: Int64 = 0, told = start
        // A few messages queued at once, as ndt7's browser client keeps its buffer topped up: one at a time left the
        // link idle between them.
        let window = InFlight(4)
        // A server that stops reading leaves every send pending, and the loop waiting for a free slot: cut the socket
        // a moment after the test's time, as the download does. The server's last count still stands.
        let cap = Task {
            guard (try? await Task.sleep(for: .seconds(seconds + 2))) != nil else { return }
            window.put(Fail("Upload past its time"))
            task.cancel()
        }
        defer { cap.cancel() }
        try await withTaskCancellationHandler {
            while uptimeMs() - start < seconds * 1000 {
                try Task.checkCancellation()
                await window.take()
                // The server may close first (its own clock, or a fault on the way); its last count still stands.
                if let error = window.error {
                    try Task.checkCancellation()
                    Log.error("speed test: upload ended early", facts: "after \(uptimeMs() - start) ms, \(type(of: error)) \((error as NSError).code)")
                    if transportFailed(elapsedMs: uptimeMs() - start, normalClose: task.closeCode == .normalClosure) { throw error }
                    break
                }
                // A slot freed after the test's time: no more sends.
                if uptimeMs() - start >= seconds * 1000 { break }
                task.send(.data(data.prefix(size))) { window.put($0) }
                sent += Int64(size)
                size = nextSize(size, sent: sent, buffer: data.count) // the spec's message scaling
                let now = uptimeMs()
                if now - told >= 250 {
                    told = now
                    let bps = server.get().flatMap { $0 > 0 ? $0 : nil } ?? bitsPerSecond(bytes: sent, ms: now - start)
                    Task { @MainActor in rate(bps) }
                }
            }
        } onCancel: { task.cancel(with: .goingAway, reason: nil); window.put(CancellationError()) }
        task.cancel(with: .normalClosure, reason: nil)
        await reader.value
        // What left the Mac may still sit in buffers: without the server's own count there is no honest result.
        guard let got = server.get(), got > 0 else { throw Fail("The test server didn't report the upload") }
        return got
    }

    /// Opens the test's WebSocket through the exit.
    private static func socket(_ tag: String, _ url: String, _ probe: Probe.Endpoint?) throws -> (URLSessionWebSocketTask, URLSession) {
        // A candidate without a usable address is skipped like one that refuses (M-Lab may leave a URL out).
        guard let u = testURL(url) else { throw Refused() }
        let session = Probe.session(tag: tag, probe: try Probe.endpoint(probe), headers: ["User-Agent": userAgent(version)])
        live.add(session)
        let task = session.webSocketTask(with: u, protocols: [subprotocol])
        task.maximumMessageSize = maxData
        task.resume()
        return (task, session)
    }

    private static func close(_ task: URLSessionWebSocketTask, _ session: URLSession) {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
        live.remove(session)
    }
}

/// The latest rate the server reported (bits/s); nil until its first report.
private nonisolated final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int64?
    func set(_ x: Int64) { lock.lock(); v = x; lock.unlock() }
    func get() -> Int64? { lock.lock(); defer { lock.unlock() }; return v }
}

private nonisolated final class Sessions: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ObjectIdentifier: URLSession] = [:]
    func add(_ s: URLSession) { lock.lock(); all[ObjectIdentifier(s)] = s; lock.unlock() }
    func remove(_ s: URLSession) { lock.lock(); all[ObjectIdentifier(s)] = nil; lock.unlock() }
    func cancelAll() { lock.lock(); let a = Array(all.values); lock.unlock(); a.forEach { $0.invalidateAndCancel() } }
}

private nonisolated struct ParallelResult: Sendable {
    var exit: String
    var server: Ndt7.Server? = nil
    var value: Int64? = nil
    var samples: [(time: Int64, bytes: Int64)] = []
    /// No test server accepted a connection through this exit.
    var refused = false
}

private nonisolated final class SpeedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: Int64, bytes: Int64)] = []
    func add(_ time: Int64, _ bytes: Int64) { lock.withLock { if let last = samples.last, time <= last.time || bytes < last.bytes { return }; samples.append((time, bytes)) } }
    func clear() { lock.withLock { samples.removeAll() } }
    func read() -> [(time: Int64, bytes: Int64)] { lock.withLock { samples } }
}

/// The readings of the test under way and the clock that carries a graph between them. The engine reports four times a
/// second; what is drawn moves on every frame, so all of this is read by the views that draw it and by nothing else.
@Observable
final class SpeedTrace {
    /// Seconds into the test, Mbit/s.
    struct Point: Equatable {
        var t: Double
        var mbps: Double
        var upload: Bool
    }

    /// How long one reading lasts on screen: the graph runs this far behind the newest, always between two readings.
    static let beat = 0.25

    private(set) var points: [Point] = []
    private(set) var bps: Int64 = 0
    /// The top of the graph's scale.
    private(set) var ceiling = 10.0
    @ObservationIgnored private(set) var downloadCurve = MonotoneCurve([])
    @ObservationIgnored private(set) var uploadCurve = MonotoneCurve([])
    @ObservationIgnored private var previousBps: Int64 = 0
    @ObservationIgnored private var heardAt = 0.0
    @ObservationIgnored private var phaseStart = 0.0
    @ObservationIgnored private var phaseFlip = -Double.infinity
    @ObservationIgnored private var oldCeiling = 10.0
    @ObservationIgnored private var ceilingAt = -Double.infinity

    func reset() {
        points = []; bps = 0; ceiling = 10; oldCeiling = 10; ceilingAt = -.infinity
        downloadCurve = MonotoneCurve([]); uploadCurve = MonotoneCurve([])
        previousBps = 0; heardAt = 0; phaseStart = 0; phaseFlip = -.infinity
    }

    func add(bps: Int64, ms: Int64, upload: Bool, at now: Double) {
        let t = Double(ms) / 1000
        if let last = points.last, last.upload != upload { phaseStart = last.t; phaseFlip = now; previousBps = 0 }
        else { previousBps = self.bps }
        guard t > (points.last?.t ?? -1) else { return }
        points.append(Point(t: t, mbps: Double(bps) / 1e6, upload: upload))
        self.bps = bps
        heardAt = now
        let ours = points.filter { $0.upload == upload }.map { (x: $0.t, y: $0.mbps) }
        if upload { uploadCurve = MonotoneCurve(ours) } else { downloadCurve = MonotoneCurve(ours) }
        let top = speedCeiling(points.map(\.mbps).max() ?? 0)
        if top != ceiling { oldCeiling = scale(at: now); ceilingAt = now; ceiling = top }
    }

    /// Where the newest reading's clock has got to.
    private func seconds(at now: Double, limit: Double) -> Double {
        (points.last?.t ?? 0) + min(max(0, now - heardAt), limit)
    }

    /// The graph's head: one beat behind the clock, so it always has a reading ahead of it.
    func head(at now: Double) -> Double { seconds(at: now, limit: Self.beat) - Self.beat }

    /// How far the ten seconds of the phase under way have run, 0 to 1. When upload starts the ring runs back first.
    func progress(at now: Double) -> Double {
        guard !points.isEmpty else { return 0 }
        let run = min(1, max(0, (seconds(at: now, limit: 0.4) - phaseStart) / 10))
        return max(run, 1 - (now - phaseFlip) / 0.3)
    }

    /// The speed to show, gliding from one reading to the next.
    func speed(at now: Double) -> Double {
        let t = min(1, max(0, (now - heardAt) / Self.beat))
        return Double(previousBps) + (Double(bps) - Double(previousBps)) * t
    }

    /// The scale, eased when a reading raises it, so the curve rescales instead of jumping.
    func scale(at now: Double) -> Double {
        let t = min(1, max(0, (now - ceilingAt) / 0.35)), eased = t * t * (3 - 2 * t)
        return oldCeiling + (ceiling - oldCeiling) * eased
    }
}
