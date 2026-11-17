import SwiftUI

#if DEBUG
/// The test copy's switch to show the card whatever the rules say.
@MainActor @Observable final class SupportCardTesting {
    static let shared = SupportCardTesting()
    var force = false
}
#endif

/// The occasional "Support unbraid" band above the page. It is asked about only while the window is calm
/// (`WindowCalm`), is noted as shown the moment it appears (so it rests 90 days whatever the user does next) and stays
/// up until the user picks something or the window closes.
struct SupportCard: View {
    let calm: Bool
    private let model = AppModel.shared
    @State private var showing = false
    @Environment(\.openURL) private var openURL

    #if DEBUG
    private var forced: Bool { SupportCardTesting.shared.force }
    #else
    private var forced: Bool { false }
    #endif

    private static let text = "Made by one person. If it's useful to you, there are a few ways to help on our website. Some provider links there earn us a commission; they're marked. Everything stays free either way."

    private var buttons: some View {
        HStack {
            Button("Ways to Help") { open(Site.donate) }
            Button("Browse Providers") { open(Site.providers) }
            Button("Not Now") { showing = false }
            Button("Don't Ask Again") { model.store.nudge(Nudges.disable); showing = false }
                .buttonStyle(.link).foregroundStyle(Ink.dim)
        }.contentButton().controlSize(.small).fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        // The empty view is always there so the observers below run while the card is hidden.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if showing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("FREE AND OPEN SOURCE").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Ink.dim)
                    Label { Text("Support unbraid").fontWeight(.semibold) } icon: { Image(systemName: "heart") }
                    Text(Self.text).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
                    buttons
                    Text("We ask a few times a year.").font(.system(size: 11)).foregroundStyle(Ink.dim)
                }
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 10).background(Ink.surface)
                .overlay(alignment: .bottom) { Hairline() }
                .accessibilityElement(children: .contain)
                .fadesIn()
            }
        }
        .onChange(of: calm, initial: true) { _, _ in evaluate() }
        .onChange(of: forced) { _, on in if on { evaluate() } else { showing = false } }
        .onChange(of: showing) { _, on in
            if on { AccessibilityNotification.Announcement("Support unbraid. \(Self.text)").post() }
        }
    }

    private func evaluate() {
        guard !showing else { return }
        if forced { showing = true; return }
        guard Nudges.due(model.store.nudge, now: .now, calm: calm) else { return }
        model.store.nudge { Nudges.shown($0, now: .now) }
        showing = true
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { openURL(u) }
        showing = false
    }
}
