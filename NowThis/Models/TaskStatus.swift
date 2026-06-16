import Foundation

/// Maps to the iCalendar STATUS property for VTODO components.
/// Raw values match RFC-5545 §3.8.1.11 exactly.
enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case needsAction = "NEEDS-ACTION"
    case inProcess   = "IN-PROCESS"
    case completed   = "COMPLETED"
    case cancelled   = "CANCELLED"

    var id: String { rawValue }

    /// A user-facing localized display name for this status.
    var displayName: String {
        switch self {
        case .needsAction: return String(localized: "Needs Action")
        case .inProcess:   return String(localized: "In Progress")
        case .completed:   return String(localized: "Completed")
        case .cancelled:   return String(localized: "Cancelled")
        }
    }

    /// SF Symbol name appropriate for this status.
    var systemImageName: String {
        switch self {
        case .needsAction: return "circle"
        case .inProcess:   return "circle.dotted.circle"
        case .completed:   return "checkmark.circle.fill"
        case .cancelled:   return "xmark.circle"
        }
    }
}
