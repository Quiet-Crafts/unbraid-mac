@preconcurrency import UserNotifications

/// User notifications for what must not pass unnoticed: the VPN stopping on its own. Nothing else is notified.
enum Notifier {
    static func post(title: String, body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // One identifier per message: only a repeat of the same notice replaces the one still showing.
            c.add(UNNotificationRequest(identifier: "unbraid." + title, content: content, trigger: nil))
        }
    }
}
