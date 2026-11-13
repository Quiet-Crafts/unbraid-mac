import AppKit

/// The update check's wording, in one place so the question, Settings and the disclosure say the same thing.
enum UpdateText {
    static let question = """
        unbraid can check unbraid.app about once a day and tell you when a new version is out. It never downloads or \
        installs anything by itself.

        Nothing about you, this Mac or your setup is sent. The site sees your IP address, like any visit, because the \
        check uses your normal connection, not the VPN. Change this any time in Settings › About.
        """
    static let setting = "Once a day, asks unbraid.app for the newest version number over your normal connection. Nothing else is sent."

    /// Opens the release page, and only it: the address is the app's own, never one from the answer.
    @MainActor static func openReleasePage() {
        guard let url = URL(string: UpdateCheck.releasePage), UpdateCheck.isReleasePage(url) else { return }
        NSWorkspace.shared.open(url)
    }
}
