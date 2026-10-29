import AppIntents
import SwiftData

/// Focus Filter integration that hides/shows specific task lists when a Focus mode activates.
///
/// Users configure which lists are visible in each Focus mode via Settings → Focus → NowThis.
/// When the Focus activates, the filter is applied and only the selected lists appear in the
/// sidebar.
///
/// The filter state is read by the UI via `FocusFilterState.shared`.
///
/// ## Why this selects entities rather than typed names
///
/// The original parameter was free text: a comma-separated list of **names**, matched with
/// `visibleListNames.contains(list.name)`. Default list names are localized
/// (`AccountManager` "Inbox", `SyncEngine` "Tasks"), so a German user's filter configured
/// against "Inbox" would stop matching "Posteingang" and their Focus mode would silently show
/// everything.
///
/// That bug is **unmigratable**: a Focus filter's configuration lives in the *system's* Focus
/// database, outside the app container, so no app update can rewrite it after the fact. It had
/// to be fixed before localized list names ship, not after.
///
/// `visibleListEntities` stores stable IDs. `visibleLists` is kept only so configurations made
/// by earlier builds keep working; it is not offered for new configuration.
struct NowThisFocusFilter: SetFocusFilterIntent {

    nonisolated(unsafe) static var title: LocalizedStringResource = "NowThis Lists"
    nonisolated(unsafe) static var description: IntentDescription? = "Choose which lists to show in this Focus."

    /// Lists to show. Empty means show all. Stores IDs, so renaming or translating a list
    /// does not break the filter.
    @Parameter(title: "Visible Lists")
    var visibleListEntities: [WidgetListEntity]?

    /// Legacy free-text parameter from builds before entity selection.
    ///
    /// Read-only in practice: existing Focus configurations still carry it, and dropping it
    /// would silently turn those filters into "show everything". Any value here was written by
    /// an English-only build, which is why matching it by name is still correct.
    @Parameter(title: "Visible Lists (comma-separated, legacy)")
    var visibleLists: String?

    var displayRepresentation: DisplayRepresentation {
        let names = (visibleListEntities ?? []).map(\.name)
            + Self.parseLegacyNames(visibleLists)
        guard !names.isEmpty else {
            // defaultValue is mandatory for an explicit key. The app ships no English string
            // table — English comes from this argument — so a key without one renders as the
            // key itself. Asserted by LocalizationKeyStyleGuardTests.
            return DisplayRepresentation(title: LocalizedStringResource(
                "focus.allLists", defaultValue: "All Lists",
                comment: "Focus filter summary shown in Settings > Focus when no list is selected, meaning every list stays visible."))
        }
        // User data, so it must not become a catalog key: the localizing initializer would
        // extract the bare key "%@" and share it with every other interpolated title.
        return DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: names.joined(separator: ", ")))
    }

    func perform() async throws -> some IntentResult {
        await FocusFilterState.shared.update(
            visibleListIDs: (visibleListEntities ?? []).map(\.id),
            legacyNames: Self.parseLegacyNames(visibleLists))
        return .result()
    }

    /// Splits the legacy free-text parameter.
    ///
    /// Accepts `;` as well as `,`: the original assumed a comma, and German and Dutch users
    /// routinely separate with a semicolon. Both are stripped of surrounding whitespace and
    /// empty fragments are dropped, so `"Inbox ,, Work "` yields two names rather than three.
    static func parseLegacyNames(_ raw: String?) -> [String] {
        (raw ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Observable state for the active Focus filter.
///
/// Read by `SidebarView` to hide/show task lists based on the active Focus mode.
/// When nothing is selected, all lists are shown.
@MainActor
@Observable
final class FocusFilterState {
    static let shared = FocusFilterState()

    /// IDs of lists that should be visible. Empty = no ID-based restriction.
    private(set) var visibleListIDs: [String] = []

    /// Names from a legacy configuration. English by construction — see `NowThisFocusFilter`.
    private(set) var visibleListNames: [String] = []

    /// Whether a focus filter is actively restricting lists.
    var isActive: Bool { !visibleListIDs.isEmpty || !visibleListNames.isEmpty }

    func update(visibleListIDs: [String], legacyNames: [String]) {
        self.visibleListIDs = visibleListIDs
        self.visibleListNames = legacyNames
    }

    /// Whether a list should be visible under the current focus.
    ///
    /// Identity first. The name path exists only for configurations made before entity
    /// selection, and is the reason this method is not a plain ID comparison.
    func isVisible(_ list: TaskList) -> Bool {
        guard isActive else { return true }
        if visibleListIDs.contains(list.id) { return true }
        return visibleListNames.contains(list.name)
    }
}
