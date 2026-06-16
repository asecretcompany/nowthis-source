import AppIntents
import SwiftData

/// Focus Filter integration that hides/shows specific task lists when a Focus mode activates.
///
/// Users configure which task lists are visible in each Focus mode via
/// Settings → Focus → NowThis. When the Focus activates, the filter is
/// applied and only the selected lists appear in the sidebar.
///
/// The filter state is read by the UI via `FocusFilterState.shared`.
struct NowThisFocusFilter: SetFocusFilterIntent {

    nonisolated(unsafe) static var title: LocalizedStringResource = "NowThis Task Lists"
    nonisolated(unsafe) static var description: IntentDescription? = "Choose which task lists to show in this Focus."

    /// Comma-separated list names to show. Empty means show all.
    @Parameter(title: "Visible Lists (comma-separated)")
    var visibleLists: String?

    var displayRepresentation: DisplayRepresentation {
        let summary = visibleLists?.isEmpty == false ? visibleLists! : "All Lists"
        return DisplayRepresentation(title: "\(summary)")
    }

    func perform() async throws -> some IntentResult {
        let names = (visibleLists ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        await FocusFilterState.shared.update(visibleListNames: names)
        return .result()
    }
}

/// Observable state for the active Focus filter.
///
/// Read by `SidebarView` to hide/show task lists based on the active Focus mode.
/// When `visibleListNames` is empty, all lists are shown.
@MainActor
@Observable
final class FocusFilterState {
    static let shared = FocusFilterState()

    /// Names of task lists that should be visible. Empty = show all.
    var visibleListNames: [String] = []

    /// Whether a focus filter is actively restricting lists.
    var isActive: Bool { !visibleListNames.isEmpty }

    func update(visibleListNames: [String]) {
        self.visibleListNames = visibleListNames
    }

    /// Checks if a task list should be visible under the current focus.
    func isVisible(_ list: TaskList) -> Bool {
        guard isActive else { return true }
        return visibleListNames.contains(list.name)
    }
}
