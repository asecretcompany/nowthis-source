import Foundation

/// Sort criteria for task lists.
///
/// Each option defines how tasks are ordered in the list view.
/// Raw value is used for persistence in UserDefaults.
enum TaskSortOption: String, CaseIterable, Identifiable {
    case dueDate = "Due Date"
    case startDate = "Start Date"
    case priority = "Priority"
    case title = "Title"
    case createdDate = "Created"
    case modifiedDate = "Modified"
    case completedDate = "Completed Date"
    case tags = "Tags"
    case relevance = "Relevance"
    case manually = "Manually"

    var id: String { rawValue }

    /// SF Symbol for the sort option.
    var icon: String {
        switch self {
        case .dueDate: return "calendar"
        case .startDate: return "calendar.badge.clock"
        case .priority: return "flag"
        case .title: return "textformat"
        case .createdDate: return "clock"
        case .modifiedDate: return "pencil.circle"
        case .completedDate: return "checkmark.circle"
        case .tags: return "tag"
        case .relevance: return "sparkles"
        case .manually: return "hand.draw"
        }
    }

    /// Comparator for sorting TaskItems by this option.
    ///
    /// - Parameter ascending: Sort direction.
    /// - Returns: A closure comparing two TaskItems.
    func comparator(ascending: Bool) -> (TaskItem, TaskItem) -> Bool {
        switch self {
        case .dueDate:
            return { lhs, rhs in
                let lDate = lhs.dueDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                let rDate = rhs.dueDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                return ascending ? lDate < rDate : lDate > rDate
            }
        case .startDate:
            return { lhs, rhs in
                let lDate = lhs.startDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                let rDate = rhs.startDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                return ascending ? lDate < rDate : lDate > rDate
            }
        case .priority:
            return { lhs, rhs in
                // Lower rawValue = higher priority
                return ascending
                    ? lhs.priority.rawValue < rhs.priority.rawValue
                    : lhs.priority.rawValue > rhs.priority.rawValue
            }
        case .title:
            return { lhs, rhs in
                ascending
                    ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                    : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
        case .createdDate:
            return { lhs, rhs in
                ascending
                    ? lhs.createdDate < rhs.createdDate
                    : lhs.createdDate > rhs.createdDate
            }
        case .modifiedDate:
            return { lhs, rhs in
                let lMod = lhs.lastModifiedDate ?? lhs.createdDate
                let rMod = rhs.lastModifiedDate ?? rhs.createdDate
                return ascending ? lMod < rMod : lMod > rMod
            }
        case .completedDate:
            return { lhs, rhs in
                let lDate = lhs.completedDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                let rDate = rhs.completedDate ?? (ascending ? Date.distantFuture : Date.distantPast)
                return ascending ? lDate < rDate : lDate > rDate
            }
        case .tags:
            return { lhs, rhs in
                let lTag = lhs.tags.map(\.name).min() ?? (ascending ? "\u{FFFF}" : "")
                let rTag = rhs.tags.map(\.name).min() ?? (ascending ? "\u{FFFF}" : "")
                return ascending
                    ? lTag.localizedCaseInsensitiveCompare(rTag) == .orderedAscending
                    : lTag.localizedCaseInsensitiveCompare(rTag) == .orderedDescending
            }
        case .relevance:
            // Composite: priority weight + due date proximity.
            // Lower score = more relevant.
            return { lhs, rhs in
                let lScore = Self.relevanceScore(for: lhs)
                let rScore = Self.relevanceScore(for: rhs)
                return ascending ? lScore < rScore : lScore > rScore
            }
        case .manually:
            return { lhs, rhs in
                ascending
                    ? lhs.manualSortOrder < rhs.manualSortOrder
                    : lhs.manualSortOrder > rhs.manualSortOrder
            }
        }
    }

    /// Computes a relevance score for composite sorting.
    ///
    /// Lower score = more relevant. Combines priority weight (0-90)
    /// with days until due (0-365). Tasks with no due date are penalized.
    private static func relevanceScore(for task: TaskItem) -> Double {
        let priorityWeight = Double(task.priority.rawValue) * 10.0
        let dueWeight: Double
        if let due = task.dueDate {
            let days = due.timeIntervalSinceNow / 86400.0
            dueWeight = max(0, min(days, 365))
        } else {
            dueWeight = 365.0
        }
        return priorityWeight + dueWeight
    }
}

/// Sort direction toggle.
enum SortDirection: String, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    var isAscending: Bool { self == .ascending }

    var icon: String {
        switch self {
        case .ascending: return "arrow.up"
        case .descending: return "arrow.down"
        }
    }

    mutating func toggle() {
        self = (self == .ascending) ? .descending : .ascending
    }
}
