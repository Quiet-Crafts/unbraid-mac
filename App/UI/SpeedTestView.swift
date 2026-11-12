import SwiftUI

/// One M-Lab speed test through an exit you pick: a big reading over a live trace, cards for ping, download, upload and
/// the test server, and the saved history in a sheet.
struct SpeedTestView: View {
    private let model = AppModel.shared
    private let test = SpeedTest.shared
    /// The exit picked; the running or finished test's exit wins while there is one.
    @State private var chosen: String?
    @State private var selected: Set<String> = []
    @State private var nearest: Set<String> = []
    @State private var pastTests: [TestResult] = []
    @State private var consent = false
    @State private var confirmNode = false
    /// Set while the consent sheet closes after "Agree and Test", so the node warning appears once it is gone.
    @State private var nodeWarningAfterConsent = false
    @State private var history = false
    @State private var width: CGFloat = 800

    /// An exit the test can go through: a running routed exit, or a Tailscale node no route uses.
    fileprivate struct Choice: Identifiable {
        var id: String, name: String, via: String, node: Bool
        /// Route colour for marks and for text (the text one is deeper in light mode).
        var mark: Color, text: Color
    }

    var body: some View {
        let options = choices()
        // A test whose exit went away while it runs keeps that exit's name, never another's (it is cleared as it ends).
        let gone = test.testing ? test.run.map(\.exit).flatMap { e in options.contains { $0.id == e } ? nil : e } : nil
        let picked = if let gone { ran(gone) } else { options.first { $0.id == (test.run?.exit ?? chosen) } ?? options.first }
        VStack(spacing: 0) {
            PageHeader(title: "Speed Test", subtitle: "Measure a route's speed with M-Lab")
            Group {
                if model.vpn.state.phase != .on {
                    preparation
                } else if let picked {
                    content(options, picked)
                } else if model.setup.prefs.testAllRoutes, (Connection.shared.running ?? model.setup).routes.count >= 2 {
                    content(options, Choice(id: "all", name: "All", via: "", node: false, mark: Palette.direct, text: Palette.direct))
                } else {
                    ContentUnavailableView("No VPN routes to test", systemImage: "gauge.with.dots.needle.33percent", description: Text("Move an app to a VPN route, or make one the default, to test its speed."))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .font(.system(size: 13)).monospacedDigit()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { history = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }.help("Saved speed tests")
            }
        }
        .focusedSceneValue(\.sceneActions, SceneActions(showHistory: { history = true }))
        // A finished test whose exit went away (its last app moved, a node offline) is cleared, never shown under another.
        .onChange(of: options.map(\.id)) { _, ids in
            if let e = test.run?.exit, !ids.contains(e), !test.testing { test.clear() }
        }
        // A ticked exit whose route went away leaves the selection as it goes, so the count stays true. Watched here, not
        // read in the body, which redraws with every reading.
        .task { for await _ in Observations({ (Connection.shared.running ?? model.setup).routes.map(\.id) }) { pruneSelected() } }
        // ...and one that went away while it ran is cleared as it ends.
        .onChange(of: test.testing) { _, running in
            if !running, let e = test.run?.exit, !options.contains(where: { $0.id == e }) { test.clear() }
        }
        .sheet(isPresented: Binding(get: { test.all?.phase == .deciding }, set: { if !$0 && test.all?.phase == .deciding { test.cancel() } })) {
            SheetFrame(title: "Before the test", width: SheetWidth.form) {
                VStack(alignment: .leading, spacing: 16) {
                    if test.all?.metered == true {
                        let going = (test.all?.legs ?? []).filter { $0.server != nil && !$0.limited && $0.error == nil && (!$0.missing || nearest.contains($0.exit)) }
                        let setup = Connection.shared.running ?? model.setup
                        let best = going.compactMap { leg in pastTests.filter { $0.exit == StatsMath.idOf(leg.exit, setup: setup) }.max { $0.down + $0.up < $1.down + $1.up } }
                        if best.count == going.count && !best.isEmpty {
                            let gb = best.reduce(0.0) { $0 + Double($1.down + $1.up) * 10 / 8 / 1_000_000_000 }
                            Text("On a metered connection: about \(gb.formatted(.number.precision(.fractionLength(1)))) GB in 20 seconds, from each exit's best test. Actual use may differ.")
                        } else { Text("This network is metered. Data use can't be estimated for every exit and may be several GB.") }
                    }
                    Text("Up to \(max(0, SpeedTest.perDay - Store.shared.testsToday)) tests left today.")
                    ForEach(test.all?.legs ?? [], id: \.exit) { leg in
                        let name = options.first(where: { $0.id == leg.exit })?.name ?? leg.exit
                        if leg.missing && leg.server != nil {
                            Toggle("\(name): use the nearest server", isOn: Binding(get: { nearest.contains(leg.exit) }, set: { if $0 { nearest.insert(leg.exit) } else { nearest.remove(leg.exit) } }))
                        } else if leg.limited { Text("\(name): M-Lab is limiting tests from this exit.") }
                        else if let error = leg.error { Text("\(name): \(error)") }
                        else if leg.server == nil { Text("\(name): no test server found.") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
            } actions: {
                Button("Cancel") { test.cancel() }.keyboardShortcut(.cancelAction).contentButton()
                Button("Start Test") { test.goAll(nearest: nearest) }.keyboardShortcut(.defaultAction).contentButton(prominent: true)
            }
            .task { pastTests = await Stats.shared.tests() }
        }
        .sheet(isPresented: $history) { HistorySheet().environment(model) }
        .sheet(isPresented: $consent, onDismiss: {
            if nodeWarningAfterConsent { nodeWarningAfterConsent = false; confirmNode = true }
        }) {
            ConsentSheet(title: Text("Speed tests use M-Lab").font(.system(size: 15, weight: .semibold)), rows: [
                ("speedometer", "Measurement Lab (M-Lab) is an open platform run by researchers. A test asks for one of its servers in the exit's country; for your own servers and Tailscale nodes M-Lab picks a nearby one. Ten seconds each way."),
                ("clock.arrow.circlepath", "M-Lab publishes every test's results openly and keeps them, with the public IP address of the exit you test: a VPN server's, or your home's for a home or Tailscale exit."),
                ("nosign", "Also sent: the time, the app's name and version, and the exit's country when it's known. Nothing about your Mac or accounts. Up to \(SpeedTest.perDay) tests a day."),
            ], action: "Agree and Test", width: 480, buttonSpacing: 12, footerTop: 8, accept: {
                test.consented = true
                if chosen == "all" || options.isEmpty { beginAll() }
                else if let picked { if needsNodeWarning(picked) { nodeWarningAfterConsent = true } else { start(picked) } }
            }) {
                SwiftUI.Link("M-Lab privacy policy", destination: URL(string: "https://www.measurementlab.net/privacy/")!)
            }
            .font(.system(size: 13)).monospacedDigit()
        }
        .alert("Test through \(picked?.name ?? "this node")?", isPresented: $confirmNode) {
            Button("Test") { if let picked { begin(picked) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("During the test, every app on your Tailscale exit route goes through \(picked?.name ?? "this node"). Measuring takes about 20 seconds; switching there and back can take a little longer. If switching back fails, those apps may keep using it, or have no internet, until unbraid can. Test only through a node you trust with their traffic.")
        }
        // Statistics sample every second while this is on screen; leaving it stops a running test and forgets the run,
        // as on Android (the result is in History if statistics are on).
        .background(StatsVisibility())
        .onDisappear { test.cancel(); test.clear() }
    }

    // MARK: Exits and starting

    private func choices() -> [Choice] {
        let conn = Connection.shared
        let s: Setup = conn.running ?? model.setup
        let routed = conn.tags.keys.filter { $0 != DIRECT }.map { choice($0, s.route($0)) }.sorted { $0.name < $1.name }
        return routed + SpeedTest.nodes().map(choice)
    }

    private func choice(_ id: String, _ r: Route?) -> Choice {
        Choice(id: id, name: r?.name ?? id, via: r?.source ?? "", node: false, mark: r.map { Ink.mark($0.hue) } ?? Palette.direct, text: r.map { Ink.route($0.hue) } ?? Palette.direct)
    }

    private func choice(_ n: TsNode) -> Choice {
        Choice(id: SpeedTest.node + n.ip, name: n.name, via: "Tailscale", node: true, mark: Ink.route(3), text: Ink.route(3))
    }

    /// The exit of a running test that is no longer offered: its route in the setup or its Tailscale node; one neither
    /// knows is named by its id, as `choices()` does.
    private func ran(_ id: String) -> Choice {
        if id.hasPrefix(SpeedTest.node) {
            let ip = String(id.dropFirst(SpeedTest.node.count))
            return choice(Connection.shared.state.tsExitNodes.first { $0.ip == ip } ?? TsNode(name: ip, ip: ip, online: false))
        }
        return choice(id, Connection.shared.running?.route(id) ?? model.setup.route(id))
    }

    /// First the M-Lab terms, then (for a node, while a route uses Tailscale) the warning, then the test.
    private func start(_ c: Choice) {
        if !test.consented { consent = true; return }
        if needsNodeWarning(c) { confirmNode = true; return }
        begin(c)
    }

    private func needsNodeWarning(_ c: Choice) -> Bool {
        c.node && (model.setup.tsExit != nil || Connection.shared.running?.tsExit != nil)
    }

    private func beginAll() {
        if !test.consented { consent = true; return }
        nearest = []
        pruneSelected()
        _ = test.startAll(Array(selected))
    }

    /// Only exits still listed: one whose route went away would make the test refuse them all, and count towards the 10.
    /// Fewer than two left disables Start.
    private func pruneSelected() {
        let ids = (Connection.shared.running ?? model.setup).routes.map(\.id)
        if !selected.isSubset(of: ids) { selected.formIntersection(ids) }
    }

    private func begin(_ c: Choice, anywhere: Bool = false) {
        test.start(exit: c.id, anywhere: anywhere)
    }

    // MARK: Content

    private var preparation: some View {
        let s = model.setup, route = s.route(s.defaultRoute)
        let phase = model.vpn.state.phase
        return ContentUnavailableView {
            Label(phase == .paused ? "Paused" : phase == .connecting ? "Connecting…" : "Ready when you connect", systemImage: "gauge.with.dots.needle.67percent")
        } description: {
            Text(phase == .paused ? "Resume, then choose a route and start a test."
                 : phase == .connecting ? "You can start a test once your routes are connected."
                 : "Connect, then choose a route and start a test.")
        } actions: {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    RouteBadge(route: route, id: s.defaultRoute, size: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default route").overline()
                        Text([s.label(s.defaultRoute), route.map { place($0, [:]) } ?? "Your normal connection"].joined(separator: " · "))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                if phase == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(phase == .paused ? "Resume" : "Connect") { model.connect() }
                        .contentButton(prominent: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ options: [Choice], _ c: Choice) -> some View {
        let run = test.run, testing = test.testing
        // "All" unless a single exit's test is under way: that one keeps its own exit even when no other is left.
        let all = (chosen == "all" || options.isEmpty) && !(testing && run != nil)
        return ScrollView {
            VStack(spacing: Layout.gap) {
                HStack(spacing: 16) {
                    Text("Route").foregroundStyle(Ink.dim)
                    GlassMenu(slash: c.mark, glass: false) {
                        Picker("Route", selection: Binding(get: { all ? "all" : c.id }, set: { chosen = $0; if $0 == "all" { selected = Set((Connection.shared.running ?? model.setup).activeRoutes.map(\.id)).intersection(Set(Connection.shared.tags.keys)) }; test.clear() })) {
                            if model.setup.prefs.testAllRoutes && (Connection.shared.running ?? model.setup).routes.count >= 2 { Text("All").tag("all") }
                            ForEach(options.filter { !$0.node }) { Text($0.name).tag($0.id) }
                            if options.contains(where: \.node) && options.contains(where: { !$0.node }) { Divider() }
                            ForEach(options.filter(\.node)) { Text("\($0.name) · Tailscale").tag($0.id) }
                        }.pickerStyle(.inline).labelsHidden()
                    } label: { Text(all ? "All" : c.name).lineLimit(1) }
                        .disabled(testing).accessibilityLabel("Route")
                    Spacer()
                    if testing {
                        Button("Cancel") { test.cancel() }.contentButton().controlSize(.large).keyboardShortcut(.cancelAction)
                    } else {
                        Button(run?.phase == .done || test.all?.phase == .done ? "Test Again" : "Start Test") { if all { beginAll() } else { start(c) } }
                            .disabled(all && !(2...10).contains(selected.count))
                            .contentButton(prominent: true).controlSize(.large).keyboardShortcut(.defaultAction)
                            .accessibilityLabel(all ? "Start speed test through the selected exits" : "Start speed test through \(c.name)")
                    }
                }

                if all {
                    allContent(options)
                } else {
                Reading(run: run, tint: c.mark)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Layout.gap, alignment: .top), count: max(1, min(4, Int((width + Layout.gap) / 174)))), spacing: Layout.gap) {
                    Tile {
                        Metric(title: "Ping", value: run?.ping.map { "\($0.median)" }, unit: "ms", pending: false,
                               detail: run?.ping.map { "\($0.low) to \($0.high) ms over 5 tries" } ?? (run?.phase == .preparing && run?.server != nil ? "measuring" : ""),
                               active: run?.phase == .preparing && run?.server != nil, tint: c.text)
                    }
                    Tile {
                        LiveMetric(title: "Download", measuring: run?.phase == .download, result: run?.down,
                                   pending: testing && run?.phase == .preparing, tint: c.text)
                    }
                    Tile {
                        LiveMetric(title: "Upload", measuring: run?.phase == .upload, result: run?.up,
                                   pending: testing && (run?.phase == .preparing || run?.phase == .download), tint: c.text)
                    }
                    Tile { ServerInfo(server: run?.server, choice: c, vpnServer: c.node ? nil : model.vpn.state.servers[c.id]?.name) }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let e = run?.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Ink.failedText).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let country = run?.missing {
                    HStack(spacing: 12) {
                        Text("M-Lab couldn't find an available test server in \(country), so this exit can't be tested in its own country.").foregroundStyle(Ink.dim)
                        Spacer()
                        Button("Test With the Nearest Server") { begin(c, anywhere: true) }
                    }
                }
                Text(caption(c, run)).font(.system(size: 12)).foregroundStyle(Ink.dim).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .pageContent()
        }
    }

    private func allContent(_ options: [Choice]) -> some View {
        let setup = Connection.shared.running ?? model.setup
        let running = Set(setup.activeRoutes.map(\.id)).subtracting(setup.testing)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Choose 2 to 10 exits").font(.heading)
            ForEach(setup.routes) { route in
                Toggle(isOn: Binding(get: { selected.contains(route.id) }, set: { if $0 { selected.insert(route.id) } else { selected.remove(route.id) } })) {
                    VStack(alignment: .leading) {
                        Text(route.name)
                        if !running.contains(route.id) { Text("connects for the test").font(.system(size: 12)).foregroundStyle(Ink.dim) }
                    }
                }.disabled(test.testing)
            }
            if let all = test.all {
                Card {
                    Text(all.phase == .done ? "Combined download" : "Testing exits together").overline()
                    let live = all.legs.reduce(Int64(0)) { $0 + $1.now }
                    let reading = all.phase == .download || all.phase == .upload ? live : all.down ?? 0
                    let progress = all.phase == .done ? 1.0 : min(1, max(0, Double(all.elapsedMs - (all.phase == .upload ? 10_000 : 0)) / 10_000))
                    ZStack {
                        Circle().trim(from: 0, to: 0.75).stroke(Ink.separator.opacity(0.7), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        // Readings come four times a second: the arc glides from one to the next.
                        Circle().trim(from: 0, to: 0.75 * progress).stroke(Ink.text, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .animation(.linear(duration: 0.25), value: progress)
                    }.rotationEffect(.degrees(135)).frame(width: 200, height: 200).overlay {
                        Figure(value: reading > 0 ? Units.speed(Double(reading)).0 : "–", unit: reading > 0 ? Units.speed(Double(reading)).1 : "Mbps")
                    }.frame(maxWidth: .infinity)
                    if let up = all.up { Text("Upload \(Units.speed(Double(up)).0) \(Units.speed(Double(up)).1)") }
                    if let error = all.error { Text(error).foregroundStyle(Ink.failedText) }
                    if let notice = all.notice { Text(notice).foregroundStyle(Ink.failedText) }
                    ForEach(all.legs, id: \.exit) { leg in
                        let name = options.first(where: { $0.id == leg.exit })?.name ?? leg.exit
                        HStack {
                            Text(name); Spacer()
                            if let error = leg.error { Text(error).foregroundStyle(Ink.failedText) }
                            else if let down = leg.down, let share = leg.share { Text("\(Int(share * 100))% · \(Units.speed(Double(down)).0) \(Units.speed(Double(down)).1)") }
                            else { Text("–") }
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ c: Choice, _ run: SpeedTest.Run?) -> String {
        if run?.phase == .done { return model.setup.prefs.stats ? "Test complete · saved with your statistics" : "Test complete · not saved: statistics are off" }
        if c.node {
            return "Tailscale switches to \(c.name) for the test, then back." + (model.setup.tsExit != nil ? " Apps on your Tailscale route use it meanwhile." : "")
                + " Tested with M-Lab, about 20 seconds of real data."
        }
        return "Tested with M-Lab on a server in the exit's country: ten seconds each way, real data."
    }
}

// MARK: - Reading and trace

/// The number for the phase under way over the speed by second; download fills 0 to 10 s, upload 10 to 20 s.
/// Only the ring, the number and the trace follow the readings, each in a view of its own that moves with the display.
private struct Reading: View {
    let run: SpeedTest.Run?
    let tint: Color
    private let trace = SpeedTest.shared.trace
    private var measuring: Bool { run?.phase == .download || run?.phase == .upload }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).overline()
                // The result is the hero: the display face inside a ring in the exit's colour.
                Ring(trace: trace, measuring: measuring, finished: run?.phase == .done, tint: tint)
                    .frame(width: 240, height: 240)
                    .overlay { HeroNumber(trace: trace, phase: run?.phase, measuring: measuring, result: run?.down, label: label) }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                TraceGraph(trace: trace, measuring: measuring, tint: tint)
                    .frame(height: 200).padding(.top, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Speed over time in megabits per second")
                    .accessibilityValue(summary)
                HStack(spacing: 16) {
                    traceKey("Download", dashed: false)
                    traceKey("Upload", dashed: true)
                }
            }
        }
    }

    private func traceKey(_ name: String, dashed: Bool) -> some View {
        HStack(spacing: 8) {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 24, y: 0)) }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : [])).frame(width: 24, height: 2)
            Text(name).font(.system(size: 12)).foregroundStyle(Ink.dim)
        }
    }

    private var label: String {
        switch run?.phase {
        case nil: "Ready"
        case .deciding: "Waiting for your choice"
        case .preparing: run?.server != nil ? "Measuring ping" : run?.exit.hasPrefix(SpeedTest.node) == true ? "Switching Tailscale" : "Finding a test server"
        case .download: "Download · measuring"
        case .upload: "Upload · measuring"
        case .done: "Download"
        case .failed: "Stopped"
        }
    }

    private var summary: String {
        guard let run, run.down != nil || run.up != nil else { return "No measurement yet" }
        return [run.down.map { "Download \(Units.speed(Double($0)).0) \(Units.speed(Double($0)).1)" }, run.up.map { "Upload \(Units.speed(Double($0)).0) \(Units.speed(Double($0)).1)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The ring, on every frame while measuring, drawn off the main thread.
private struct Ring: View {
    let trace: SpeedTrace
    let measuring: Bool
    let finished: Bool
    let tint: Color

    var body: some View {
        TimelineView(.animation(paused: !measuring)) { time in
            let now = time.date.timeIntervalSinceReferenceDate
            let progress = finished ? 1 : measuring ? trace.progress(at: now) : 0
            #if DEBUG
            let _ = PerfCount.ring += 1
            #endif
            Canvas(rendersAsynchronously: true) { context, size in
                let inset: CGFloat = 5, centre = CGPoint(x: size.width / 2, y: size.height / 2), radius = min(size.width, size.height) / 2 - inset
                func arc(_ share: Double) -> Path {
                    Path { $0.addArc(center: centre, radius: radius, startAngle: .degrees(135), endAngle: .degrees(135 + 270 * share), clockwise: false) }
                }
                let line = StrokeStyle(lineWidth: 10, lineCap: .round)
                context.stroke(arc(1), with: .color(Ink.separator.opacity(0.7)), style: line)
                guard progress > 0 else { return }
                let reach = 0.75 * progress
                let colours = Gradient(stops: [.init(color: tint.opacity(0.45), location: 0), .init(color: tint, location: max(0.001, min(1, reach)))])
                context.stroke(arc(progress), with: .conicGradient(colours, center: centre, angle: .degrees(135)), style: line)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The big number, gliding between readings, ten times a second: often enough to read as moving, rarely enough to read.
private struct HeroNumber: View {
    let trace: SpeedTrace
    let phase: SpeedTest.Phase?
    let measuring: Bool
    let result: Int64?
    let label: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !measuring)) { time in
            let now = time.date.timeIntervalSinceReferenceDate
            let bits: Double? = measuring ? (trace.bps > 0 ? trace.speed(at: now) : nil) : phase == .done ? result.map(Double.init) : nil
            let reading = bits.map(Units.speed)
            let value = reading?.0 ?? "–"
            let progress = phase == .done ? 1 : measuring ? trace.progress(at: now) : 0
            VStack(spacing: 6) {
                // Before a reading the dash stays faint, so it doesn't read as a value.
                Figure(value: value, unit: reading?.1 ?? "Mbps", font: .display(72)).opacity(bits == nil ? 0.35 : 1)
                Text(phase == .done ? "Download measured" : "\(Int(progress * 10)) of 10 seconds")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(value) megabits per second")
            .accessibilityValue("Ten-second phase progress, \(Int(progress * 100)) percent")
        }
    }
}

/// Speed by second. The axes redraw only when the scale changes; the curve moves on every frame, drawn off the main thread.
private struct TraceGraph: View {
    let trace: SpeedTrace
    let measuring: Bool
    let tint: Color

    var body: some View {
        ZStack {
            TraceAxes(top: trace.ceiling)
            TimelineView(.animation(paused: !measuring)) { time in
                let now = time.date.timeIntervalSinceReferenceDate
                TraceCurve(trace: trace, head: measuring ? trace.head(at: now) : .infinity, scale: trace.scale(at: measuring ? now : .infinity), tint: tint)
            }
        }
    }

    static let span = Double(SpeedTest.maxSeconds)
    /// Room for the speeds on the right and the seconds below.
    static func plot(_ size: CGSize) -> CGRect { CGRect(x: 0, y: 6, width: size.width - 44, height: size.height - 28) }
}

private struct TraceAxes: View {
    let top: Double

    var body: some View {
        Canvas { context, size in
            let plot = TraceGraph.plot(size)
            var grid = Path()
            for i in 0...4 {
                let y = plot.maxY - plot.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                let value = top * Double(i) / 4
                let words = value == value.rounded() ? "\(Int(value))" : value.formatted(.number.precision(.fractionLength(1)))
                context.draw(Text(words).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim), at: CGPoint(x: plot.maxX + 6, y: y), anchor: .leading)
            }
            for seconds in stride(from: 0, through: 20, by: 5) {
                let x = plot.minX + plot.width * CGFloat(seconds) / 20
                grid.move(to: CGPoint(x: x, y: plot.minY)); grid.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.draw(Text("\(seconds) s").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim),
                             at: CGPoint(x: x, y: size.height), anchor: seconds == 0 ? .bottomLeading : seconds == 20 ? .bottomTrailing : .bottom)
            }
            context.stroke(grid, with: .color(Ink.separator), lineWidth: 1)
            // Where download ends and upload begins.
            var middle = Path()
            middle.move(to: CGPoint(x: plot.midX, y: plot.minY)); middle.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
            context.stroke(middle, with: .color(Ink.dim), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

private struct TraceCurve: View {
    let trace: SpeedTrace
    let head: Double
    let scale: Double
    let tint: Color

    var body: some View {
        // Sampled here, on the main actor, for the drawing that runs off it.
        let down = trace.downloadCurve, up = trace.uploadCurve, head = head, scale = scale, tint = tint, span = TraceGraph.span
        #if DEBUG
        let _ = PerfCount.curve += 1
        #endif
        Canvas(rendersAsynchronously: true) { context, size in
            let plot = TraceGraph.plot(size)
            func x(_ t: Double) -> CGFloat { plot.minX + plot.width * CGFloat(min(t, span) / span) }
            func y(_ mbps: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(min(mbps / scale, 1)) }
            func draw(_ curve: MonotoneCurve, dashed: Bool, dot: Bool) {
                guard let first = curve.first, let last = curve.last else { return }
                let end = min(head, last)
                guard end >= first else { return }
                var line = Path()
                line.move(to: CGPoint(x: x(first), y: y(curve.value(at: first))))
                // Two points of width at a time: finer than the eye, and the same work on any frame.
                let step = max(0.01, Double(2 / plot.width) * span)
                var t = first + step
                while t < end { line.addLine(to: CGPoint(x: x(t), y: y(curve.value(at: t)))); t += step }
                let tip = CGPoint(x: x(end), y: y(curve.value(at: end)))
                line.addLine(to: tip)
                var area = line
                area.addLine(to: CGPoint(x: tip.x, y: plot.maxY)); area.addLine(to: CGPoint(x: x(first), y: plot.maxY)); area.closeSubpath()
                context.fill(area, with: .color(tint.opacity(0.16)))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dashed ? [5, 4] : []))
                if head.isFinite, dot {
                    context.fill(Path(ellipseIn: CGRect(x: tip.x - 4.5, y: tip.y - 4.5, width: 9, height: 9)), with: .color(tint))
                }
            }
            draw(down, dashed: false, dot: up.first == nil)
            draw(up, dashed: true, dot: true)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Cards

/// Results use the same quiet surface as the measured trace.
private struct Tile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { Card { content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) } }
}

/// A tile with the phase's speed: its result, or while measuring the latest reading. Reads the readings itself.
private struct LiveMetric: View {
    let title: String
    let measuring: Bool
    let result: Int64?
    let pending: Bool
    let tint: Color
    private let trace = SpeedTest.shared.trace

    var body: some View {
        let bps: Double? = measuring ? (trace.bps > 0 ? Double(trace.bps) : nil) : result.map(Double.init)
        Metric(title: title, value: bps.map { Units.speed($0).0 },
               unit: bps.map { Units.speed($0).1 } ?? "Mbps", pending: pending, detail: measuring ? "measuring" : "", active: measuring, tint: tint)
    }
}

private struct Metric: View {
    let title: String
    let value: String?
    let unit: String
    /// A pending phase is named below its unmeasured value.
    let pending: Bool
    let detail: String
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).overline()
            Figure(value: value ?? "–", unit: unit).frame(maxWidth: .infinity, alignment: .leading)
            Text(value == nil && pending ? "Next · 10 seconds" : detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(active ? tint : Ink.dim)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ServerInfo: View {
    let server: Ndt7.Server?
    let choice: SpeedTestView.Choice
    let vpnServer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = server {
                Text(["M-Lab", s.city].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 15, weight: .semibold))
                Text([Locale.current.localizedString(forRegionCode: s.country) ?? s.country, s.machine.split(separator: ".").first.map(String.init) ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Ink.text)
            } else {
                Text("M-Lab test server").font(.system(size: 15, weight: .semibold))
                Text("Found when the test starts").font(.system(size: 12)).foregroundStyle(Ink.text)
            }
            let via = [choice.via, vpnServer ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            if !via.isEmpty { Text("via \(via)").font(.system(size: 12)).foregroundStyle(Ink.text) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - History

/// The saved tests, newest first, under the best download.
private struct HistorySheet: View {
    private let model = AppModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tests: [TestResult]?

    private struct Row: Identifiable { var id: Int; var t: TestResult }
    /// "21 Oct, 14:05" or "Oct 21, 2:05 PM": the day, month and clock as the user's locale writes them.
    private func date(_ t: TestResult) -> String {
        Date(timeIntervalSince1970: Double(t.at) / 1000).formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        let list = StatsMath.historyRuns(tests ?? [])
        let rows = list.enumerated().map { Row(id: $0.offset, t: $0.element) }
        let best = StatsMath.bestSingleTest(tests ?? [])
        SheetFrame(title: "History", subtitle: "\(list.count) test\(list.count == 1 ? "" : "s")", width: SheetWidth.browser) {
            VStack(spacing: 0) {
                if let best {
                    Card(spacing: 8, padding: Layout.inset) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Best download").overline()
                            Figure(value: Units.mbps(Double(best.down)), unit: "Mbps")
                            Text("\(StatsMath.matchingRoute(best.exit, setup: model.setup)?.name ?? best.server) · \(date(best)) · download").font(.system(size: 12)).foregroundStyle(Ink.text)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .padding(.horizontal, Layout.gutter).padding(.bottom, Layout.inset)
                }
                Table(rows) {
                    TableColumn("Date") { Text(date($0.t)) }.width(min: 110, ideal: 130)
                    TableColumn("↓ Mbps") { Text(Units.mbps(Double($0.t.down))).monospacedDigit() }.width(min: 60, ideal: 70)
                    TableColumn("↑ Mbps") { Text(Units.mbps(Double($0.t.up))).monospacedDigit() }.width(min: 60, ideal: 70)
                    TableColumn("Ping") { Text($0.t.idle == 0 ? "–" : "\($0.t.idle) ms").monospacedDigit() }.width(min: 56, ideal: 64)
                    TableColumn("Via and Server") { row in
                        if row.t.exit == "all" {
                            VStack(alignment: .leading) {
                                Text("All · \(row.t.n) exits")
                                ForEach(StatsMath.historyLegs(row.t, rows: tests ?? []), id: \.at) { leg in
                                    Text("\(StatsMath.matchingRoute(leg.exit, setup: model.setup)?.name ?? leg.server) · with \(max(0, leg.n - 1)) others")
                                }
                            }
                        } else { Text([row.t.via, row.t.server].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1) }
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden).background(Ink.surface)
                .overlay {
                    if tests == nil { ProgressView().accessibilityLabel("Loading history") } else if list.isEmpty { ContentUnavailableView("No speed tests yet.", systemImage: "gauge.with.dots.needle.0percent") }
                }
            }
        } actions: {
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).contentButton(prominent: true)
        }
        .onExitCommand { dismiss() }
        .font(.system(size: 13)).monospacedDigit()
        .frame(height: 520)
        .task { let t = await Stats.shared.tests(); if !Task.isCancelled { tests = t } }
    }
}
