import UserNotifications

/// Reads user preferences for notification delivery types (banner, badge)
/// and provides the computed `UNNotificationPresentationOptions`.
///
/// Backed by `UserDefaults` so both the `NotificationDelegate` and
/// `ReminderScheduler` can read the same values without SwiftUI.
struct NotificationPreferences {

    // MARK: - UserDefaults Keys

    static let bannerEnabledKey = "notificationBannerEnabled"
    static let badgeEnabledKey = "notificationBadgeEnabled"

    // MARK: - Read

    /// Whether banner notifications are enabled. Defaults to `true`.
    static var isBannerEnabled: Bool {
        // UserDefaults returns false for unregistered keys, so we need
        // to treat "never set" as true (default on).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: bannerEnabledKey) == nil { return true }
        return defaults.bool(forKey: bannerEnabledKey)
    }

    /// Whether badge notifications are enabled. Defaults to `true`.
    static var isBadgeEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: badgeEnabledKey) == nil { return true }
        return defaults.bool(forKey: badgeEnabledKey)
    }

    // MARK: - Presentation Options

    /// Computes `UNNotificationPresentationOptions` from current preferences.
    /// Always includes `.sound`.
    static var presentationOptions: UNNotificationPresentationOptions {
        var options: UNNotificationPresentationOptions = [.sound]
        if isBannerEnabled { options.insert(.banner) }
        if isBadgeEnabled { options.insert(.badge) }
        return options
    }
}
