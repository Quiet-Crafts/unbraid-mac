import AppKit

/// The update check's wording, in one place so the question, Settings and the disclosure say the same thing.
enum UpdateText {
    static let notice = "About once a day, unbraid asks unbraid.app whether a new version is out and tells you here and in the menu bar, because new versions often carry security fixes. It never downloads or installs anything by itself. Only the app's version is sent, nothing about you, this Mac or your setup: the site sees your IP address, like any visit, because the check uses your normal connection, not the VPN. If you turn it off, unbraid won't ask again; you can turn it back on any time in Settings › About."
    static let setting = "About once a day (an hour later after a check that got no answer), asks unbraid.app for the newest version number over your normal connection. It sends only the app's version, and unbraid.app sees your IP address."

    /// Opens the release page, and only it: the address is the app's own, never one from the answer.
    @MainActor static func openReleasePage() {
        guard let url = URL(string: UpdateCheck.releasePage), UpdateCheck.isReleasePage(url) else { return }
        NSWorkspace.shared.open(url)
    }
}
