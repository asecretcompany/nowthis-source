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

    /// User-facing label. The rawValue is persisted in `@AppStorage` (`TaskListView`)
    /// and must stay English.
    var displayName: String {
        switch self {
        case .dueDate:
            return String(localized: "sort.dueDate", defaultValue: "Due Date",
                          comment: "Sort option: order tasks by when they are due.")
        case .startDate:
            return String(localized: "sort.startDate", defaultValue: "Start Date",
                          comment: "Sort option: order tasks by when work on them may begin.")
        case .priority:
            return String(localized: "sort.priority", defaultValue: "Priority",
                          comment: "Sort option: order tasks by High/Medium/Low priority.")
        case .title:
            return String(localized: "sort.title", defaultValue: "Title",
                          comment: "Sort option: order tasks alphabetically by name.")
        case .createdDate:
            return String(localized: "sort.created", defaultValue: "Created",
                          comment: "Sort option: order tasks by when they were created. Past participle used as a label, not a sentence.")
        case .modifiedDate:
            return String(localized: "sort.modified", defaultValue: "Modified",
                          comment: "Sort option: order tasks by when they were last changed. Past participle used as a label.")
        case .completedDate:
            return String(localized: "sort.completedDate", defaultValue: "Completed Date",
                          comment: "Sort option: order tasks by when they were completed.")
        case .tags:
            return String(localized: "sort.tags", defaultValue: "Tags",
                          comment: "Sort option: order tasks by their first tag.")
        case .relevance:
            return String(localized: "sort.relevance", defaultValue: "Relevance",
                          comment: "Sort option: a combined score of priority and how soon a task is due.")
        case .manually:
            return String(localized: "sort.manually", defaultValue: "Manually",
                          comment: "Sort option: the order the user dragged tasks into. Adverb answering 'sorted how?'.")
        }
    }

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

    /// User-facing label. The rawValue is persisted in `@AppStorage` and must stay English.
    var displayName: String {
        switch self {
        case .ascending:
            return String(localized: "sort.direction.ascending", defaultValue: "Ascending",
                          comment: "Sort direction: smallest or earliest first.")
        case .descending:
            return String(localized: "sort.direction.descending", defaultValue: "Descending",
                          comment: "Sort direction: largest or latest first.")
        }
    }

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
