import SwiftUI

// The small rounded, coloured tile behind an SF Symbol, as in the rows of Settings.

struct IconTile: View {
    enum Tile {
        static let gray = Color(nsColor: .systemGray)
        static let blue = Color(nsColor: .systemBlue)
        static let green = Color(nsColor: .systemGreen)
        static let indigo = Color(nsColor: .systemIndigo)
        static let red = Color(nsColor: .systemRed)
        static let purple = Color(nsColor: .systemPurple)
        static let teal = Color(nsColor: .systemTeal)
        static let pink = Color(nsColor: .systemPink)
    }

    var symbol: String? = nil
    var text: String? = nil
    let color: Color
    let size: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            shape.fill(color)
            if contrast != .increased {
                shape.fill(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom))
            }
            shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            if let text {
                Text(text).font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.55, weight: .semibold)).symbolRenderingMode(.monochrome)
            }
        }
        .foregroundStyle(.white).frame(width: size, height: size).accessibilityHidden(true)
    }
}
