import AppKit
import SwiftUI

// Light, dark or system appearance, and how see-through the page and sidebar are; both are chosen in Settings ›
// General and the View menu, and give way to the system's Reduce Transparency and Increase Contrast.

enum Transparency {
    static let pageKey = "pageClearness"
    static let sidebarKey = "sidebarSolidity"

    static func allowed(reduceTransparency: Bool, contrast: ColorSchemeContrast) -> Bool {
        !reduceTransparency && contrast != .increased
    }

    static func bounded(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }

    /// How much of the page's own ground stays at a clearness: never under 70 %, so text on it stays readable on any
    /// wallpaper. Lists and headers sit directly on it.
    static func wash(_ clearness: Double) -> Double { 1 - 0.3 * clearness }
}

/// Ready-made pairs of the page and sidebar settings. Any other pair reads as Custom.
enum TransparencyLook: CaseIterable {
    case standard, frosted, clear, solid

    var label: String {
        switch self {
        case .standard: "Standard"
        case .frosted: "Frosted"
        case .clear: "Clear"
        case .solid: "Solid"
        }
    }
    var page: Double {
        switch self {
        case .standard, .solid: 0
        case .frosted: 0.5
        case .clear: 1
        }
    }
    var sidebar: Double { self == .solid ? 1 : 0 }
    func matches(page: Double, sidebar: Double) -> Bool { abs(page - self.page) < 0.01 && abs(sidebar - self.sidebar) < 0.01 }
}

/// The looks as small windows on a wallpaper, the chosen one ringed, like the Appearance tiles.
struct TransparencyTiles: View {
    @AppStorage(Transparency.pageKey) private var page = 0.0
    @AppStorage(Transparency.sidebarKey) private var sidebar = 0.0
    let allowed: Bool

    var body: some View {
        let chosen = TransparencyLook.allCases.first { $0.matches(page: Transparency.bounded(page), sidebar: Transparency.bounded(sidebar)) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                ForEach(TransparencyLook.allCases, id: \.self) { look in
                    Button { page = look.page; sidebar = look.sidebar } label: {
                        VStack(spacing: 6) {
                            preview(look).frame(width: 84, height: 56)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(look == chosen ? Ink.accentText : Ink.separator, lineWidth: look == chosen ? 3 : 1))
                            Text(look.label).font(.system(size: 12, weight: look == chosen ? .semibold : .regular))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain).accessibilityLabel(look.label).accessibilityAddTraits(look == chosen ? .isSelected : [])
                }
            }
            if chosen == nil { Text("Custom").font(.system(size: 12)).foregroundStyle(Ink.dim) }
        }
        .disabled(!allowed).opacity(allowed ? 1 : 0.4)
    }

    private func preview(_ look: TransparencyLook) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.33, green: 0.45, blue: 0.75), Color(red: 0.76, green: 0.47, blue: 0.53)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 0) {
                Ink.surface.opacity(look.sidebar == 1 ? 1 : 0.6).frame(width: 24)
                Ink.ground.opacity(Transparency.wash(look.page))
            }
        }
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
    }
}

/// The app's appearance: the system's, or always light or dark. Remembered across launches; set from the sidebar or
/// View > Appearance, and applied to every window, the menu bar panel and sheets alike.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); newValue.apply() }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// System, Light and Dark as a choice, for menus. Reads the stored value, so every copy shows the same tick.
struct AppearanceItems: View {
    @AppStorage(Appearance.key) private var raw = Appearance.system.rawValue

    var body: some View {
        Picker("Appearance", selection: Binding(get: { Appearance(rawValue: raw) ?? .system }, set: { Appearance.current = $0 })) {
            ForEach(Appearance.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.inline).labelsHidden()
    }
}

/// System, Light and Dark as System Settings draws them: a small window in each look, the chosen one ringed.
struct AppearanceTiles: View {
    @AppStorage(Appearance.key) private var raw = Appearance.system.rawValue

    var body: some View {
        let now = Appearance(rawValue: raw) ?? .system
        HStack(spacing: 20) {
            ForEach(Appearance.allCases, id: \.self) { a in
                Button { Appearance.current = a } label: {
                    VStack(spacing: 6) {
                        preview(a).frame(width: 84, height: 56)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(a == now ? Ink.accentText : Ink.separator, lineWidth: a == now ? 3 : 1))
                        Text(a.label).font(.system(size: 12, weight: a == now ? .semibold : .regular))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityLabel(a.label).accessibilityAddTraits(a == now ? .isSelected : [])
            }
        }
    }

    /// A miniature window: a sidebar with the slash, and a page with one card.
    private func preview(_ a: Appearance) -> some View {
        let light = mini(dark: false), dark = mini(dark: true)
        return Group {
            switch a {
            case .light: light
            case .dark: dark
            case .system: ZStack { light; dark.mask(HStack(spacing: 0) { Color.clear; Color.black }) }
            }
        }
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
    }

    private func mini(dark: Bool) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Color(white: dark ? 0.17 : 0.92)
                Capsule().fill(Ink.accent).frame(width: 3, height: 10).rotationEffect(.degrees(18)).padding(8)
            }
            .frame(width: 24)
            ZStack(alignment: .topLeading) {
                Color(white: dark ? 0.07 : 1)
                RoundedRectangle(cornerRadius: 4).fill(Color(white: dark ? 0.12 : 0.95)).padding(8).padding(.top, 10)
            }
        }
    }
}
