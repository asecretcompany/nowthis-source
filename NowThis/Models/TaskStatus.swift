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
        // One task's status, never a collection of them. The bare `Completed`
        // key that used to be here read as the completed-tasks filter, and
        // Spanish, French and Italian all shipped a plural for it while its
        // three siblings stayed singular — so a single task's status picker
        // offered "Pendiente / En curso / Completadas / Cancelada".
        case .needsAction:
            return String(localized: "status.needsAction", defaultValue: "Needs Action",
                          comment: "Status of a SINGLE task: not started yet. Agrees with the word for task, which is feminine in Spanish, French and Italian. Also used as a Kanban column header, where the singular still reads correctly.")
        case .inProcess:
            return String(localized: "status.inProgress", defaultValue: "In Progress",
                          comment: "Status of a SINGLE task: started but not finished. Agrees with the word for task, which is feminine in Spanish, French and Italian.")
        case .completed:
            return String(localized: "status.completed", defaultValue: "Completed",
                          comment: "Status of a SINGLE task: finished. Singular — this labels one task, not the list of completed ones, which has its own key. Agrees with the word for task, which is feminine in Spanish, French and Italian.")
        case .cancelled:
            return String(localized: "status.cancelled", defaultValue: "Cancelled",
                          comment: "Status of a SINGLE task: abandoned without being done. Agrees with the word for task, which is feminine in Spanish, French and Italian.")
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
