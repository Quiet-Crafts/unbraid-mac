@preconcurrency import UserNotifications

/// User notifications for what must not pass unnoticed: the VPN stopping on its own, and a profile that didn't switch by
/// itself. Nothing else is notified.
enum Notifier {
    /// `otherwise`: run on the main actor when notifications aren't allowed, to say it in the window instead.
    static func post(title: String, body: String, otherwise: (@MainActor @Sendable () -> Void)? = nil) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { if let otherwise { Task { @MainActor in otherwise() } }; return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // One identifier per message: only a repeat of the same notice replaces the one still showing.
            c.add(UNNotificationRequest(identifier: "unbraid." + title, content: content, trigger: nil))
        }
    }
}
