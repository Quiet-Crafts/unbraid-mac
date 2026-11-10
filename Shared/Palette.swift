import AppKit
import SwiftUI

/// Opaque content colours and route identities, shared by the app and widgets.
nonisolated enum Palette {
    /// A white page with soft grey cards in light mode, a deep page with lighter cards in dark: cards read as raised
    /// in both without a border.
    static let ground = adaptive((0xFFFFFF, 0x0F1214))
    static let surface = adaptive((0xF3F5F6, 0x171B1E))
    nonisolated(unsafe) static let nsHigh = dynamic((0xE6EAEC, 0x232A2F))
    nonisolated(unsafe) static let nsSeparator = dynamic((0xCBD3D5, 0x2C3439), contrast: (0x8A969C, 0x6B777E))
    nonisolated(unsafe) static let nsText = dynamic((0x182025, 0xECEFF1))
    nonisolated(unsafe) static let nsDim = dynamic((0x56636B, 0x9AA5AD), contrast: (0x3E4A52, 0xB8C2C8))
    static let high = Color(nsColor: nsHigh)
    static let separator = Color(nsColor: nsSeparator)
    static let text = Color(nsColor: nsText)
    static let dim = Color(nsColor: nsDim)
    /// Route identities. No orange: that is the brand's, for the wordmark, actions and selection only.
    private static let routes: [(UInt32, UInt32)] = [(0x1467A3, 0x7CC4FF), (0x7143B5, 0xC9A7FF), (0x24713F, 0x8EE0A8), (0x856300, 0xFFD36B),
                                                    (0xA63260, 0xFF9EBB), (0x126F69, 0x6BE3DC), (0x3F4FC4, 0xA3AEFF)]

    /// The brand accent, shared with the widgets.
    static let accent = adaptive((0xFFA66B, 0xFFA66B))
    /// Text and symbols on the accent: the website's ink, 10:1 on it in both appearances.
    nonisolated(unsafe) static let nsOnAccent = dynamic((0x1A1006, 0x1A1006))
    static let onAccent = Color(nsColor: nsOnAccent)
    nonisolated(unsafe) private static let nsRoutes = routes.map { dynamic($0) }
    static func nsRoute(_ hue: Int) -> NSColor { nsRoutes[((hue % 7) + 7) % 7] }
    static func route(_ hue: Int) -> Color { Color(nsColor: nsRoute(hue)) }
    static func mark(_ hue: Int) -> Color { route(hue) }
    /// Direct (no VPN) and Block, which are not routes but sit beside them.
    nonisolated(unsafe) static let nsDirect = dynamic((0x56636B, 0x9AA5AD))
    nonisolated(unsafe) static let nsBlock = dynamic((0xD70015, 0xFF6961))
    nonisolated(unsafe) static let nsWarning = dynamic((0x8A5300, 0xFFB340))
    static let direct = Color(nsColor: nsDirect)
    static let block = Color(nsColor: nsBlock)

    /// A colour with its own light and dark values.
    /// `contrast`: stronger values for Increase Contrast (lines and secondary text that must hold their edge).
    static func adaptive(_ c: (light: UInt32, dark: UInt32), contrast: (light: UInt32, dark: UInt32)? = nil) -> Color {
        Color(nsColor: dynamic(c, contrast: contrast))
    }

    /// The same as an AppKit colour, for what AppKit draws by hand.
    static func dynamic(_ c: (light: UInt32, dark: UInt32), contrast: (light: UInt32, dark: UInt32)? = nil) -> NSColor {
        NSColor(name: nil) { a in
            switch a.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
            case .accessibilityHighContrastDarkAqua: rgb(contrast?.dark ?? c.dark)
            case .accessibilityHighContrastAqua: rgb(contrast?.light ?? c.light)
            case .darkAqua: rgb(c.dark)
            default: rgb(c.light)
            }
        }
    }

    private static func rgb(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
