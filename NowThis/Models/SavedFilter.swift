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

    var label: String {
        switch self {
        case .and: return "All of"
        case .or: return "Any of"
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
            let taskPri = task.priority.displayName.lowercased()
            return compare(taskPri, to: value.lowercased())

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
}
