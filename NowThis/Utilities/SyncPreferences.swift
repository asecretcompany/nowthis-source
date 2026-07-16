import Foundation

/// Reads the user's sync preferences from `UserDefaults` so both SwiftUI
/// (`@AppStorage`) and the non-SwiftUI sync paths (`SyncScheduler`,
/// `BackgroundSyncManager`) agree on the same values and defaults.
///
/// Mirrors the `object(forKey:) == nil` convention used by
/// `NotificationPreferences`: an unset key falls back to the documented
/// default, while an explicit choice (including `0` = "All") is preserved.
enum SyncPreferences {

    /// UserDefaults key for how many months of completed-task history to sync.
    static let windowMonthsKey = "syncWindowMonths"

    /// Default sync-history window for fresh installs and users who have never
    /// changed the setting: the last 3 months of completed tasks.
    static let defaultWindowMonths = 3

    /// The sync-history window in months. `0` means "All" (no filtering).
    ///
    /// Returns `defaultWindowMonths` when the key has never been set so the
    /// initial sync only pulls recent completed tasks; an explicitly stored
    /// value (including `0`) is returned unchanged.
    static func windowMonths(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: windowMonthsKey) != nil else {
            return defaultWindowMonths
        }
        return defaults.integer(forKey: windowMonthsKey)
    }
}
