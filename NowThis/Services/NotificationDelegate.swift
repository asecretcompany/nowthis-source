import UserNotifications
import Foundation

/// Handles notification delegate callbacks for reminder notifications.
///
/// Required because `NowThisApp` is a struct and cannot conform to
/// `UNUserNotificationCenterDelegate` (which requires `NSObject`).
///
/// Posts a `Notification` with the task ID when the user taps a reminder
/// notification, enabling deep linking from `NowThisApp`.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Notification name posted when a reminder notification is tapped.
    static let didTapReminderNotification = Notification.Name("didTapReminderNotification")

    /// Handles the user tapping a notification.
    /// Extracts `taskID` from `userInfo` and posts a `NotificationCenter` notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let taskID = userInfo["taskID"] as? String {
            NotificationCenter.default.post(
                name: Self.didTapReminderNotification,
                object: nil,
                userInfo: ["taskID": taskID]
            )
        }
        completionHandler()
    }

    /// Shows the notification banner even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(NotificationPreferences.presentationOptions)
    }
}
