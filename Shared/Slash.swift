import SwiftUI

/// A route's mark: a short bar cut at the angle of the logo's slash, in the route's colour. It always sits beside the
/// route's name, since colours repeat once there are more than seven routes. Shared by the app and the widgets.
struct Slash: View {
    let color: Color
    /// The bar's height; it is a fifth as wide (3 pt at least). 12 beside body text, 22 beside a page title.
    var height: CGFloat = 12

    var body: some View {
        Capsule().fill(color).frame(width: max(3, height * 0.2), height: height)
            .rotationEffect(.degrees(18)).frame(width: height * 0.5).accessibilityHidden(true)
    }
}
