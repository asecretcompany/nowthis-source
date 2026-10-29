import Foundation
import SwiftData

/// A user-created filter preset that appears as a "smart list" in the sidebar.
///
/// Each saved filter stores criteria that can be combined with AND/OR logic
/// to create complex queries across status, priority, tag, list, and date range.
///
/// Criteria are stored as JSON-encoded `FilterCriteria` for flexibility.
@Model
final class SavedFilter {

    // MARK: - Identity

    @Attribute(.unique) var id: String

    /// User-facing name displayed in the sidebar.
    var name: String

    /// SF Symbol name for the sidebar icon.
    var icon: String

    /// Hex color for the sidebar icon tint.
    var colorHex: String

    /// Sort order for display in the sidebar.
    var sortOrder: Int

    // MARK: - Criteria

    /// JSON-encoded array of `FilterRule` objects.
    var rulesData: Data

    /// Logical operator: "AND" or "OR".
    var logicOperator: String

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "line.3.horizontal.decrease.circle",
        colorHex: String = "#8E8E93",
        sortOrder: Int = 0,
        rules: [FilterRule] = [],
        logicOperator: FilterLogic = .and
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        self.logicOperator = logicOperator.rawValue
    }

    // MARK: - Computed

    /// Decoded filter rules.
    var rules: [FilterRule] {
        get {
            (try? JSONDecoder().decode([FilterRule].self, from: rulesData)) ?? []
        }
        set {
            rulesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    var logic: FilterLogic {
        get { FilterLogic(rawValue: logicOperator) ?? .and }
        set { logicOperator = newValue.rawValue }
    }
}

// MARK: - Filter Logic

/// Logical operator for combining filter rules.
enum FilterLogic: String, Codable, CaseIterable {
    case and = "AND"
    case or = "OR"

    /// User-facing label. The rawValue ("AND"/"OR") is persisted in
    /// `SavedFilter.logicOperator` and must stay English.
    var displayName: String {
        switch self {
        case .and:
            return String(localized: "filter.logic.and", defaultValue: "All of",
                          comment: "Saved filter: a task must match every rule. Reads as the start of 'All of these rules'.")
        case .or:
            return String(localized: "filter.logic.or", defaultValue: "Any of",
                          comment: "Saved filter: a task must match at least one rule. Reads as the start of 'Any of these rules'.")
        }
    }
}

// MARK: - Filter Rule

/// A single filter criterion in a saved filter.
///
/// Each rule specifies a field, comparison, and value.
struct FilterRule: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var field: FilterField
    var comparison: FilterComparison
    var value: String

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// Evaluates this rule against a task.
    func matches(_ task: TaskItem, allLists: [TaskList]) -> Bool {
        switch field {
        case .status:
            let taskStatus = task.status.rawValue.lowercased()
            return compare(taskStatus, to: value.lowercased())

        case .priority:
            // Compare stable tokens, never display names. `value` was written to disk by a
            // build that may have been running any language; `TaskPriority(filterToken:)`
            // accepts both today's token and the legacy English spellings.
            guard let wanted = TaskPriority(filterToken: value) else { return false }
            let taskToken = task.priority.filterToken
            return compare(taskToken, to: wanted.filterToken)

        case .tag:
            let tagNames = task.tags.map { $0.name.lowercased() }
            switch comparison {
            case .equals:
                return tagNames.contains(value.lowercased())
            case .notEquals:
                return !tagNames.contains(value.lowercased())
            default:
                return false
            }

        case .list:
            let listName = task.taskList?.name.lowercased() ?? ""
            return compare(listName, to: value.lowercased())

        case .dueDateBefore:
            guard let due = task.dueDate,
                  let target = Self.isoFormatter.date(from: value) else { return false }
            return due < target

        case .dueDateAfter:
            guard let due = task.dueDate,
                  let target = Self.isoFormatter.date(from: value) else { return false }
            return due > target

        case .hasDueDate:
            let expected = (value.lowercased() == "true")
            return (task.dueDate != nil) == expected

        case .title:
            return compare(task.title.lowercased(), to: value.lowercased())
        }
    }

    private func compare(_ actual: String, to expected: String) -> Bool {
        switch comparison {
        case .equals: return actual == expected
        case .notEquals: return actual != expected
        case .contains: return actual.contains(expected)
        case .notContains: return !actual.contains(expected)
        }
    }
}

// MARK: - Filter Field

/// Fields available for filtering.
enum FilterField: String, Codable, CaseIterable, Identifiable {
    case status = "Status"
    case priority = "Priority"
    case tag = "Tag"
    case list = "List"
    case dueDateBefore = "Due Before"
    case dueDateAfter = "Due After"
    case hasDueDate = "Has Due Date"
    case title = "Title"

    var id: String { rawValue }

    /// User-facing label. The rawValue is Codable-encoded into `SavedFilter.rulesData`
    /// on disk and must stay English.
    var displayName: String {
        switch self {
        case .status:
            return String(localized: "filter.field.status", defaultValue: "Status",
                          comment: "Saved filter field: the task's status (Needs Action / In Progress / Completed / Cancelled).")
        case .priority:
            return String(localized: "filter.field.priority", defaultValue: "Priority",
                          comment: "Saved filter field: the task's High/Medium/Low priority.")
        case .tag:
            return String(localized: "filter.field.tag", defaultValue: "Tag",
                          comment: "Saved filter field: one of the task's tags. Singular.")
        case .list:
            return String(localized: "filter.field.list", defaultValue: "List",
                          comment: "Saved filter field: which list the task is in. 'List' is the app's word for a CalDAV collection.")
        case .dueDateBefore:
            return String(localized: "filter.field.dueBefore", defaultValue: "Due Before",
                          comment: "Saved filter field: the task is due earlier than a given date.")
        case .dueDateAfter:
            return String(localized: "filter.field.dueAfter", defaultValue: "Due After",
                          comment: "Saved filter field: the task is due later than a given date.")
        case .hasDueDate:
            return String(localized: "filter.field.hasDueDate", defaultValue: "Has Due Date",
                          comment: "Saved filter field: whether the task has a due date at all.")
        case .title:
            return String(localized: "filter.field.title", defaultValue: "Title",
                          comment: "Saved filter field: the task's name.")
        }
    }

    var icon: String {
        switch self {
        case .status: return "circle.dashed"
        case .priority: return "flag"
        case .tag: return "tag"
        case .list: return "list.bullet"
        case .dueDateBefore, .dueDateAfter: return "calendar"
        case .hasDueDate: return "calendar.badge.checkmark"
        case .title: return "textformat"
        }
    }

    /// Available comparisons for this field.
    var comparisons: [FilterComparison] {
        switch self {
        case .status, .priority, .list:
            return [.equals, .notEquals]
        case .tag:
            return [.equals, .notEquals]
        case .dueDateBefore, .dueDateAfter, .hasDueDate:
            return [.equals]
        case .title:
            return [.equals, .notEquals, .contains, .notContains]
        }
    }
}

// MARK: - Filter Comparison

/// Comparison operators for filter rules.
enum FilterComparison: String, Codable, CaseIterable, Identifiable {
    case equals = "is"
    case notEquals = "is not"
    case contains = "contains"
    case notContains = "does not contain"

    var id: String { rawValue }

    /// User-facing label. The rawValue is Codable-encoded into `SavedFilter.rulesData`
    /// on disk and must stay English.
    var displayName: String {
        switch self {
        case .equals:
            return String(localized: "filter.comparison.equals", defaultValue: "is",
                          comment: "Saved filter comparison, read as the middle of a sentence: '<field> is <value>'. Lowercase, no punctuation.")
        case .notEquals:
            return String(localized: "filter.comparison.notEquals", defaultValue: "is not",
                          comment: "Saved filter comparison: '<field> is not <value>'. Lowercase, no punctuation.")
        case .contains:
            return String(localized: "filter.comparison.contains", defaultValue: "contains",
                          comment: "Saved filter comparison: '<field> contains <value>' — substring match. Lowercase, no punctuation.")
        case .notContains:
            return String(localized: "filter.comparison.notContains", defaultValue: "does not contain",
                          comment: "Saved filter comparison: '<field> does not contain <value>'. Lowercase, no punctuation.")
        }
    }
}
