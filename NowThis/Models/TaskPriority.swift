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
        case .none:   return String(localized: "None")
        case .high:   return String(localized: "High")
        case .medium: return String(localized: "Medium")
        case .low:    return String(localized: "Low")
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
