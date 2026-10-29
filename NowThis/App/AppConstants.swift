import Foundation

/// Global constants used across the NowThis app, widget, and watchOS targets.
enum AppConstants {

    /// Shared App Group identifier for SwiftData container access
    /// across the main app, widget extension, and watchOS companion.
    static let appGroupID = "group.com.asecretcompany.nowthis"

    /// Keychain service identifier for CalDAV credential storage.
    static let keychainService = "com.asecretcompany.nowthis.caldav"

    /// iCalendar PRODID used in serialized .ics output (RFC-5545 §3.7.3).
    static let prodID = "-//NowThis//iOS//EN"

    /// iCalendar version (RFC-5545 §3.7.4).
    static let iCalVersion = "2.0"

    /// Existing lifetime SKU: Watch writes and cosmetic art; viewing stays free.
    static let proProductID = "com.asecretcompany.nowthis.pro"
}

/// Local-notification identifier scheme, shared by the app and the widget extension.
///
/// Lives here rather than on `ReminderScheduler` because `CompleteTaskIntent` needs it and is
/// compiled into NowThisWidget, whose sources do not include `NowThis/Services/`.
///
/// **The invariant these constants exist to make assertable: every prefix that can be
/// *scheduled* must also be *swept*.** `nag-` was schedulable and not sweepable, so an hourly
/// repeating reminder on a completed task fired until the app was deleted.
enum NotificationIdentifiers {
    static let reminderPrefix = "reminder-"
    static let overduePrefix = "overdue-"
    static let nagPrefix = "nag-"

    /// Every prefix the scheduler can create. The bulk sweep filters on exactly this list.
    static let allPrefixes = [reminderPrefix, overduePrefix, nagPrefix]

    /// Every notification identifier belonging to a task, in prefix order.
    static func all(forTaskID taskID: String) -> [String] {
        allPrefixes.map { "\($0)\(taskID)" }
    }
}
