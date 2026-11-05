import AppKit
@preconcurrency import UserNotifications

/// Tells someone who has gone to another app that a long run ended: a system notice (it names the tab, never the SQL,
/// which may hold values not meant for a lock screen) and one bounce of the Dock icon.
@MainActor
enum LongQueryNotice {
    /// A run shorter than this was still being watched.
    static let threshold: TimeInterval = 10

    static func shouldTell(after seconds: TimeInterval, appActive: Bool) -> Bool { !appActive && seconds >= threshold }

    static func runEnded(after seconds: TimeInterval, failed: Bool, place: String) {
        guard shouldTell(after: seconds, appActive: NSApp.isActive) else { return }
        NSApp.requestUserAttention(.informationalRequest)
        // Outside an app bundle (the tests) the notification centre stops the process.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = failed ? "Query failed" : "Query finished"
        content.body = place + String(format: " · %.0f s", seconds)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
