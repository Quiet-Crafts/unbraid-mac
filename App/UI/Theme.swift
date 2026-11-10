import SwiftUI

// The look shared by every window: page and sidebar backgrounds, button styles, sheet frames and consent sheets,
// fonts, and the view that keeps sign-in and key windows out of screen captures.

private struct WindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct PageGround: ViewModifier {
    @AppStorage(Transparency.pageKey) private var clearness = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let value = Transparency.allowed(reduceTransparency: reduceTransparency, contrast: contrast) ? Transparency.bounded(clearness) : 0
        content.background {
            ZStack {
                if value > 0 { WindowBlur() }
                Ink.ground.opacity(Transparency.wash(value))
            }
            // Under the toolbar too, as the plain colour it replaces did.
            .ignoresSafeArea()
        }
    }
}

private struct SidebarGround: ViewModifier {
    @AppStorage(Transparency.sidebarKey) private var solidity = 0.0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let value = Transparency.allowed(reduceTransparency: reduceTransparency, contrast: contrast) ? Transparency.bounded(solidity) : 0
        content.background(Ink.surface.opacity(value), ignoresSafeAreaEdges: .all)
    }
}

/// A small icon button that answers the pointer: a soft wash on hover, a little more and a slight give when pressed.
/// Plain ink, never orange, and not for glass: it draws a fill.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lit = enabled && (hover || configuration.isPressed)
            configuration.label
                .frame(minWidth: 24, minHeight: 24)
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : lit ? 0.07 : 0), in: .rect(cornerRadius: Corner.mark))
                .contentShape(.rect(cornerRadius: Corner.mark))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: lit ? 0.11 : 0.18), value: lit)
                .onHover { hover = $0 }
        }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// Fades in where it appears. Only the opacity moves, so the page below takes its new place at once and never animates.
private struct FadesIn: ViewModifier {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.opacity(shown || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
    }
}

extension View {
    func fadesIn() -> some View { modifier(FadesIn()) }
    func pageGround() -> some View { modifier(PageGround()) }
    func sidebarGround() -> some View { modifier(SidebarGround()) }
}

/// Keep sensitive windows out of ordinary window capture while their contents are visible.
/// ScreenCaptureKit on recent macOS may still capture them, so this is best effort.
struct CaptureExclusion: NSViewRepresentable {
    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {}
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.releaseWindow() }

    final class CaptureView: NSView {
        /// Keyed by address, so each entry also holds its window: an entry left by a freed window is not another's.
        private static var windows: [ObjectIdentifier: (window: Weak, count: Int, old: NSWindow.SharingType)] = [:]
        private struct Weak { weak var window: NSWindow? }
        private weak var protectedWindow: NSWindow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if protectedWindow === window { return }
            releaseWindow()
            guard let window else { return }
            #if DEBUG
            // Layout checks of sign-in sheets in a development build; release builds always hide them.
            if UserDefaults.standard.bool(forKey: "debugAllowCapture") { return }
            #endif
            let id = ObjectIdentifier(window)
            if let entry = Self.windows[id], entry.window.window === window { Self.windows[id] = (entry.window, entry.count + 1, entry.old) }
            else { Self.windows[id] = (Weak(window: window), 1, window.sharingType); window.sharingType = .none }
            protectedWindow = window
        }
        func releaseWindow() {
            guard let window = protectedWindow else { return }
            let id = ObjectIdentifier(window)
            if let entry = Self.windows[id], entry.window.window === window {
                if entry.count == 1 { window.sharingType = entry.old; Self.windows.removeValue(forKey: id) }
                else { Self.windows[id] = (entry.window, entry.count - 1, entry.old) }
            }
            protectedWindow = nil
        }
    }
}

enum SheetWidth {
    static let form: CGFloat = 480
    static let browser: CGFloat = 640
}

/// Every sheet's frame. Cards inside use Ink.surface so they show against the ground. The bar holds Cancel
/// (.cancelAction) and one primary action (.defaultAction, .contentButton(prominent: true)), never Done at the top.
struct SheetFrame<Content: View, Status: View, Actions: View>: View {
    let title: String
    var subtitle = ""
    var width: CGFloat = SheetWidth.form
    @ViewBuilder var content: Content
    @ViewBuilder var status: Status
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.heading)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Ink.dim) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.gutter).padding(.top, 20).padding(.bottom, 14)
            content
            Divider()
            HStack(spacing: 8) {
                status.font(.system(size: 12)).foregroundStyle(Ink.dim)
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, Layout.gutter).padding(.vertical, 12)
        }
        .frame(width: width).foregroundStyle(Ink.text).background(Ink.ground)
    }
}

extension SheetFrame where Status == EmptyView {
    init(title: String, subtitle: String = "", width: CGFloat = SheetWidth.form,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, width: width, content: content, status: { EmptyView() }, actions: actions)
    }
}

/// Shared grouped sheet frame; each editor keeps its own actions and validation.
struct FormSheet<Content: View, Actions: View>: View {
    var title = ""
    var width: CGFloat = SheetWidth.form
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 0) {
            // The same title as SheetFrame's; the grouped form below brings its own top inset.
            if !title.isEmpty {
                Text(title).font(.heading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Layout.gutter).padding(.top, 20)
            }
            Form { content }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack { Spacer(); actions }.padding(.horizontal, Layout.gutter).padding(.vertical, 12)
        }
        .frame(width: width).foregroundStyle(Ink.text).background(Ink.ground)
    }
}

/// Consent sheets share their mechanics while keeping each disclosure's type, spacing and extra link explicit.
struct ConsentSheet<Extra: View>: View {
    let title: Text
    let rows: [(String, String)]
    let action: String
    var width: CGFloat = SheetWidth.form
    var buttonSpacing: CGFloat?
    var footerTop: CGFloat = 4
    let accept: () -> Void
    @ViewBuilder var extra: Extra
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            ForEach(rows, id: \.0) { icon, text in
                Label { Text(text) } icon: { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22) }
            }
            extra
            HStack(spacing: buttonSpacing) {
                Spacer()
                Button("Not Now", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action) { accept(); dismiss() }.keyboardShortcut(.defaultAction)
                    .contentButton(prominent: true)
            }
            .padding(.top, footerTop)
        }
        .padding(24).frame(width: width).foregroundStyle(Ink.text).background(Ink.ground)
    }
}

extension Font {
    /// The brand's display face (Big Shoulders, as on unbraid.app): hero words and big numbers only.
    static func display(_ size: CGFloat) -> Font { .custom("BigShouldersDisplay-ExtraBold", size: size).weight(.black) }
    static let heroNumeral = display(44)
    /// Measurements: SF Mono with tabular digits, so columns of numbers line up and never jitter.
    static let figure = Font.system(size: 22, weight: .semibold, design: .monospaced)
    static let heading = Font.system(size: 15, weight: .semibold)
}

extension View {
    /// A small section label in the secondary colour.
    func overline() -> some View {
        font(.system(size: 11, weight: .semibold)).tracking(0.4).textCase(.uppercase).foregroundStyle(Ink.dim)
    }
}

/// Opaque content colours; native chrome keeps the system appearance.
enum Ink {
    static let ground = Palette.ground
    static let surface = Palette.surface
    static let high = Palette.high
    static let separator = Palette.separator
    static let text = Palette.text
    static let dim = Palette.dim
    /// The one colour of an "off" dot everywhere.
    static let off = Palette.dim
    /// The brand orange of the logo's slash (unbraid.app), the same in both appearances. Fills carry `onAccent` text.
    static let accent = Palette.accent
    static let onAccent = Palette.onAccent
    /// The accent as text or a thin symbol on a light ground, deepened there to keep 4.5:1.
    static let accentText = Palette.adaptive((0xA94B0E, 0xFFA66B))

    /// Route identities, by `Route.hue`, for exits and nothing else (never for status); see Palette.
    static func route(_ hue: Int) -> Color { Palette.route(hue) }
    static func mark(_ hue: Int) -> Color { Palette.mark(hue) }

    static let connected = Color(nsColor: .systemGreen)
    /// Green text needs more contrast in light mode; marks keep the system green.
    static let successText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen : NSColor(srgbRed: 0.14, green: 0.44, blue: 0.24, alpha: 1)
    })
    static let paused = Color(nsColor: .systemOrange)
    static let failed = Color(nsColor: .systemRed)
    /// Red and orange as text: the system tones are about 3:1 and 2:1 on a light ground, so text deepens there to 4.5:1.
    static let failedText = Palette.adaptive((0xB3261E, 0xFF6961))
    static let warningText = Color(nsColor: Palette.nsWarning)
    static let direct = Color.secondary
}

extension Route {
    var color: Color { Ink.route(hue) }
}

/// Ad and tracker blocking each provider runs in its own tunnel DNS (Route.filter).
let providerBlocking = [
    "mullvad": ("Block ads, trackers and malware", "Mullvad's DNS blocklists, for this route"),
    "pia": ("MACE", "PIA's ad, tracker and malware blocking, for this route"),
    "ivpn": ("AntiTracker", "IVPN's ad and tracker blocking, for this route"),
]

/// "un/braid", with the slash in the brand tint.
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        Text("\(Text("un").foregroundStyle(.primary))\(Text("/").foregroundStyle(Ink.accent))\(Text("braid").foregroundStyle(.primary))")
            .font(.custom("BigShouldersDisplay-ExtraBold", size: size).weight(.black))
            .accessibilityLabel("unbraid")
    }
}

/// A route's mark in lists, menus and legends: the slash (see Slash), so every place draws routes the same way.
struct RouteDot: View {
    let color: Color
    var body: some View { Slash(color: color, height: 12) }
}

/// A status dot; its accompanying text provides the accessible state.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: Measure.dot, height: Measure.dot).accessibilityHidden(true) }
}

/// An app's icon from its bundle, or a terminal glyph for a command-line tool.
struct AppIconView: View {
    let app: AppInfo?
    var size: CGFloat = 22
    var body: some View {
        if let app, app.path.hasSuffix(".app") {
            Image(nsImage: AppCatalog.shared.icon(app)).resizable().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Image(systemName: "terminal").font(.system(size: size * 0.5)).frame(width: size, height: size)
                .background(.quaternary, in: .rect(cornerRadius: size * 0.22)).accessibilityHidden(true)
        }
    }
}

/// Names for a route id in menus and labels.
extension Setup {
    func label(_ id: String) -> String {
        if id == DIRECT { return "Direct" }
        if id == BLOCK { return "Blocked" }
        guard let r = route(id) else { return "Removed route" }
        // Two routes with one name (same country, another city or provider) are told apart in every menu.
        guard routes.contains(where: { $0.id != id && $0.name == r.name }) else { return r.name }
        let detail = r.loc.city ?? r.loc.group ?? Providers.get(r.loc.provider)?.name
        return detail.map { "\(r.name) · \($0)" } ?? r.name
    }

    /// "Netherlands · Default" for apps that follow the default.
    var defaultLabel: String { "\(label(defaultRoute)) · Default" }

    /// A route's identity colour; Direct and Block have fixed tones, a removed route reads as Direct.
    func color(_ id: String) -> Color {
        switch id {
        case BLOCK: Palette.block
        default: route(id)?.color ?? Palette.direct
        }
    }

    /// The same as an AppKit colour.
    func nsColor(_ id: String) -> NSColor {
        switch id {
        case BLOCK: Palette.nsBlock
        default: route(id).map { Palette.nsRoute($0.hue) } ?? Palette.nsDirect
        }
    }
}

/// One set of measures for every page, so titles, controls, cards and rows stay put when moving between pages.
enum Layout {
    /// Where titles, cards and table rows start, and where trailing controls end.
    static let gutter: CGFloat = 20
    /// Between cards and sections.
    static let gap: CGFloat = 20
    /// Inside every card.
    static let inset: CGFloat = 20
    /// Above and below a page title.
    static let header: CGFloat = 16
}

/// Shared sizes for icons and rows, so related content lines up.
enum Measure {
    /// App icons in tables and lists.
    static let tableIcon: CGFloat = 24
    /// Icon slot of a list row, app icon in a panel header.
    static let rowIcon: CGFloat = 28
    /// Table, sidebar and panel rows.
    static let tableRow: CGFloat = 32
    /// Settings and list rows with a caption.
    static let listRow: CGFloat = 44
    /// The column a route's slash or a sidebar symbol sits in, so names line up.
    static let slashColumn: CGFloat = 16
    /// Status dots.
    static let dot: CGFloat = 8
}

private struct ProminentForeground: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder func body(content: Content) -> some View {
        if appearsActive && isEnabled { content.foregroundStyle(Ink.onAccent) }
        else { content }
    }
}

extension View {
    func prominentForeground() -> some View { modifier(ProminentForeground()) }

    /// Controls inside content (cards, page body, sheets, the menu bar panel); glass is for the toolbar and dock only.
    @ViewBuilder func contentButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Ink.accent).prominentForeground()
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// An opaque surface for a tooltip above content.
    func tooltipSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: Corner.inner, style: .continuous)
        return padding(12).background(Ink.high, in: shape).overlay(shape.stroke(Ink.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    /// A page's content: inside the gutters, across the whole window.
    func pageContent() -> some View {
        padding(.horizontal, Layout.gutter).padding(.bottom, Layout.gutter).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Something that sets its own gutters (a header, a table), as wide as page content.
    func pageWidth() -> some View { frame(maxWidth: .infinity, alignment: .leading) }
}

/// A menu on Liquid Glass for the toolbar and dock, or an opaque content control with glass set to false.
/// Padding and shape are part of the label, so the whole capsule or circle opens the menu.
struct GlassMenu<Content: View, Label: View>: View {
    /// A route's slash before the label.
    var slash: Color?
    var glass = true
    var chevron = true
    /// A 32 pt circle for a lone symbol (the dock's options, "More routes"); else a 28 pt capsule.
    var circle = false
    var padding: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = circle ? AnyShape(Circle()) : AnyShape(Capsule())
        let menu = Menu { content } label: {
            HStack(spacing: 6) {
                if let slash { RouteDot(color: slash) }
                label
                if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Ink.dim) }
            }
            .padding(.horizontal, circle ? 0 : padding)
            .frame(width: circle ? 32 : nil, height: circle ? 32 : 28)
            .contentShape(shape)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        if glass {
            menu.glassEffect(reduceMotion ? .regular : .regular.interactive(), in: shape)
        } else {
            menu.background(Ink.high, in: shape)
                .overlay { if contrast == .increased { shape.stroke(Ink.separator) } }
        }
    }
}

/// Corners in the window's own language (Liquid Glass): generous and continuous, smaller for things inside a card.
enum Corner {
    static let card: CGFloat = 16
    static let inner: CGFloat = 10
    /// Bars, cells, swatches and small tiles.
    static let mark: CGFloat = 6
}

struct Hairline: View {
    @Environment(\.displayScale) private var scale
    var body: some View { Rectangle().fill(Ink.separator).frame(height: 1 / scale).accessibilityHidden(true) }
}

/// A measured number and its unit, with motion only while the scene is active.
struct Figure: View {
    let value: String
    let unit: String
    var font: Font = .figure

    /// No rolling digits: on a Mac they redraw on the main thread for every frame of the roll (about 250 ms for each
    /// new number), and these numbers change every second on live pages.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(font).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.system(size: 13, design: .monospaced)).foregroundStyle(Ink.dim) }
        }
        .foregroundStyle(Ink.text)
        .accessibilityElement(children: .combine)
    }
}

/// Every page opens the same way: its name (with its slash, for a route), one line of facts, and the page's own
/// controls at the trailing edge. The toolbar keeps search and window controls only.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle = ""
    var slash: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3).lineLimit(1).accessibilityAddTraits(.isHeader)
                    // A route's slash hangs in the gutter, so every page's title starts at the same place.
                    .overlay(alignment: .leading) { if let slash { Slash(color: slash, height: 24).offset(x: -16) } }
                // The line is kept while a subtitle loads, so the page below doesn't move.
                Text(subtitle.isEmpty ? " " : subtitle).font(.system(size: 13)).foregroundStyle(Ink.dim).lineLimit(1).help(subtitle)
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, Layout.gutter).padding(.vertical, Layout.header)
        .pageWidth()
        // Header controls are Liquid Glass capsules, as in the toolbar above them.
        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String = "", slash: Color? = nil) {
        self.init(title: title, subtitle: subtitle, slash: slash) { EmptyView() }
    }
}
