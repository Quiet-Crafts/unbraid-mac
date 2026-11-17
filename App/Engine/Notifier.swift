@preconcurrency import UserNotifications

/// User notifications for what must not pass unnoticed: the VPN stopping on its own, and a profile that didn't switch by
/// itself. Nothing else is notified.
/// A notification is an extra: whether it shows (allowed, alerts on, Focus) isn't known here, so anything the user must
/// learn is also said in the window.
enum Notifier {
    static func post(title: String, body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            c.add(UNNotificationRequest(identifier: identifier(title: title, body: body), content: content, trigger: nil))
        }
    }

    /// One identifier per message: only a repeat of the same notice replaces the one still showing, never another
    /// message under the same title.
    static func identifier(title: String, body: String) -> String { "unbraid." + title + "|" + body }
}
