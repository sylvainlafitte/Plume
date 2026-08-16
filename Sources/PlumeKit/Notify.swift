import Foundation
import UserNotifications

/// User-visible notifications, posted **as Plume**.
///
/// This used to shell out to `osascript -e 'display notification'`, which needs
/// no bundle — the right call when Plume was a bare binary. The cost only became
/// visible once notifications were clicked: a script-posted notification belongs
/// to *Script Editor*, so macOS attributes it there, and clicking one opens
/// Script Editor rather than Plume. Observed 2026-08-16.
///
/// `UNUserNotificationCenter` requires a bundle identifier and a valid
/// signature, which Plume.app now has. The fallback survives for the CLI
/// (`plume doctor`, `plume summarize`), where there is no bundle and a
/// misattributed notification beats no notification at all.
enum Notify {

    /// Requested once, lazily, on the first notification rather than at launch:
    /// a permission prompt on first run, before the user has done anything, is
    /// the kind of thing that gets an app dismissed.
    /// Computed, not stored: `UNUserNotificationCenter` is not `Sendable`, so a
    /// static of it is shared mutable state under Swift 6. `current()` is cheap
    /// and returns the same singleton.
    private static var center: UNUserNotificationCenter? {
        // `current()` traps when there is no bundle, so this is a real guard,
        // not defensive habit.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Categories give a notification its buttons *and* decide what a click on
    /// the body does. Registered once, before anything is posted.
    enum Category: String {
        /// "Your camera turned on and Plume isn't recording." Clicking it — or
        /// its button — starts the recording, because that is the only thing
        /// anyone wants from that notification. The detector still never starts
        /// one on its own; a click is the consent.
        case callDetected = "plume.call-detected"

        var actionTitle: String? {
            switch self {
            case .callDetected: return "Start recording"
            }
        }
    }

    static func post(title: String, body: String, category: Category? = nil) {
        guard let center else {
            postViaScript(title: title, body: body)
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                // Denied notifications are a legitimate choice; the menu bar
                // still carries every failure as a sticky line, so nothing is
                // lost silently.
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category.rawValue }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    /// CLI path only. Kept because `plume doctor` and friends have no bundle.
    private static func postViaScript(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

func notifyUser(title: String, body: String) {
    Notify.post(title: title, body: body)
}

/// Routes notification clicks. Without a delegate, macOS merely *activates* the
/// app — which for an accessory app with no main window means bringing forward
/// whatever window happens to exist, so a "you aren't recording" reminder ended
/// up opening Settings. Observed 2026-08-16.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let onStartRecording: () -> Void

    init(onStartRecording: @escaping () -> Void) {
        self.onStartRecording = onStartRecording
        super.init()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Notify.Category.callDetected.rawValue,
                actions: [
                    UNNotificationAction(
                        identifier: "start",
                        title: Notify.Category.callDetected.actionTitle ?? "",
                        options: [.foreground])
                ],
                intentIdentifiers: [],
                options: [])
        ])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        // Both the body click and the button do the same thing: there is exactly
        // one useful response to this notification.
        let shouldStart = category == Notify.Category.callDetected.rawValue
            && (action == UNNotificationDefaultActionIdentifier || action == "start")
        // Called before the hop, not inside it: the handler is task-isolated,
        // and capturing it in a main-actor closure is a data race under Swift 6.
        completionHandler()
        guard shouldStart else { return }
        Task { @MainActor in onStartRecording() }
    }

    /// Accessory apps are rarely frontmost, but when Settings is open they are —
    /// and a reminder that silently drops because the app is active is the case
    /// where the user is *most* likely to be looking at Plume.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
