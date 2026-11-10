import SwiftUI

/// Both sign-in surfaces apply the same control-server trust check and confirmation.
struct TailscaleSignIn: View {
    let url: String
    private let model = AppModel.shared
    @State private var ask: TsLogin.Result?

    var body: some View {
        Button("Sign In to Tailscale") {
            let r = TsLogin.check(url, controlUrl: model.setup.home.tsControlUrl)
            switch r.verdict {
            case .open: if let u = r.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
            case .ask: ask = r
            case .refuse: model.notice = "The sign-in link from the control server wasn't opened: it isn't a web address."
            }
        }
        .alert("Open sign-in link?", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            Button("Open") { if let u = ask?.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Tailscale's control server sent a link to \(ask?.host ?? "another site"). Open it only if you trust that server.") }
    }
}
