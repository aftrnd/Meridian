import UserNotifications
import Foundation

/// Thin wrapper around `UNUserNotificationCenter` for Meridian's local notifications.
///
/// Call `requestAuthorization()` once at app launch (from AppDelegate).
/// All notification methods are safe to call from any thread/actor.
enum MeridianNotifications {

    /// Requests macOS notification permission on first call.
    /// Subsequent calls are no-ops (the system remembers the user's choice).
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a banner telling the user their game finished installing and is ready to play.
    static func sendInstallComplete(gameName: String) {
        let content = UNMutableNotificationContent()
        content.title = "\(gameName) is ready to play"
        content.body = "Installation complete. Hit Play whenever you're ready."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "meridian.install-complete.\(gameName)",
            content: content,
            trigger: nil // nil = deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
