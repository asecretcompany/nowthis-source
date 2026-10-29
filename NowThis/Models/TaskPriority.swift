import Foundation

/// Maps to the iCalendar PRIORITY property (RFC-5545 §3.8.1.9).
/// RFC-5545 defines priority as an integer 0-9 where:
/// - 0 = undefined/none
/// - 1 = highest priority
/// - 9 = lowest priority
///
/// This enum collapses the 0-9 range into four user-friendly tiers.
enum TaskPriority: Int, Codable, CaseIterable, Comparable, Identifiable {
    case none   = 0   // iCal 0: undefined
    case high   = 1   // iCal 1-4: high urgency
    case medium = 5   // iCal 5: normal
    case low    = 9   // iCal 6-9: low urgency

    var id: Int { rawValue }

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        // Lower raw value = higher priority, so "less than" means
        // "higher priority" for sorting purposes.
        lhs.rawValue < rhs.rawValue
    }

    /// Maps a raw RFC-5545 priority integer (0-9) to the app's priority enum.
    /// - Parameter value: The raw integer from the iCalendar PRIORITY property.
    /// - Returns: The corresponding `TaskPriority` tier.
    ///
    /// Mapping:
    /// - 0 → `.none`
    /// - 1...4 → `.high`
    /// - 5 → `.medium`
    /// - 6...9 → `.low`
    /// - Any other value → `.none` (defensive)
    static func fromRFC5545(_ value: Int) -> TaskPriority {
        switch value {
        case 0: return .none
        case 1...4: return .high
        case 5: return .medium
        case 6...9: return .low
        default: return .none
        }
    }

    /// A user-facing localized display name for this priority.
    var displayName: String {
        switch self {
        case .none:   return String(localized: "priority.none", defaultValue: "None",
                                    comment: "Priority value meaning the task has no priority set. Answers 'Priority: ?', so the word agrees with the target language's word for priority — feminine in Spanish, French and Italian. Do not share this key with the reminder, location or empty-quadrant 'None'.")
        case .high:   return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low:    return String(localized: "Low")
        }
    }

    /// A **stable, never-localized** token identifying this priority in persisted data.
    ///
    /// Saved filters store their comparison value as a string inside
    /// `SavedFilter.rulesData` (JSON, on disk). That value used to be `displayName`, which is
    /// `String(localized:)` — so a device-language change silently made every saved priority
    /// filter match nothing. Display and identity are separate concerns; this is identity.
    ///
    /// Changing any of these values is a data migration, not a rename.
    var filterToken: String {
        switch self {
        case .none:   return "none"
        case .high:   return "high"
        case .medium: return "medium"
        case .low:    return "low"
        }
    }

    /// Resolves a stored filter value back to a priority.
    ///
    /// Accepts today's token and, case-insensitively, the **English display names** written by
    /// builds before this fix — filters already on disk must keep working, and there is no UI
    /// that would tell a user to re-create one. The legacy spellings are frozen English on
    /// purpose: they are what those builds wrote, in the only language they could write.
    init?(filterToken token: String) {
        switch token.lowercased() {
        case "none":   self = .none
        case "high":   self = .high
        case "medium": self = .medium
        case "low":    self = .low
        default:       return nil
        }
    }

    /// SF Symbol name appropriate for this priority level.
    var systemImageName: String {
        switch self {
        case .none:   return "minus"
        case .high:   return "exclamationmark.3"
        case .medium: return "exclamationmark.2"
        case .low:    return "exclamationmark"
        }
    }
}
