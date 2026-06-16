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
}
