import Foundation

/// A destination in the app's tab bar.
///
/// Order and visibility are user-configurable; the two ends of the bar are not.
/// ``pinned`` — `.tasks` first and `.settings` last — is excluded from
/// ``customizable``, stripped by ``decodeVisible(from:)``, and rendered by
/// `ContentView` around the user's chosen tabs, which is what "pinned" means
/// here and mirrors how `SidebarView` pins Smart Lists first.
///
/// `.tasks` is pinned because it is the **only** host for user Lists, Tags,
/// Saved Filters and Journals. While it could be hidden, the title menu offered
/// it back as a sheet — and a `NavigationSplitView` inside that sheet's
/// `NavigationStack` does not perform its compact-width push, so the sheet
/// rendered the sidebar and stayed there. Tapping a List only moved the
/// highlight. Every one of those destinations was unreachable in the whole app.
///
/// iOS collapses a six-item tab bar to four items plus a "More" list,
/// regardless of screen width — measured on both a 375pt iPhone SE and a 440pt
/// iPhone 17 Pro Max. ``maxVisible`` is 3 so that the two pinned tabs and three
/// chosen ones come to five, and "More" never appears.
enum AppTab: Hashable, Identifiable {
    case tasks
    case board
    case calendar
    case matrix
    case settings
    case smart(SmartList)

    var id: String { token }

    // MARK: - Token codec

    /// Stable identity for persistence.
    ///
    /// **These strings are frozen.** They are written to `@AppStorage` and
    /// `@SceneStorage`; changing one silently resets a user's tab bar. The
    /// `smart:` form matches `SidebarSelection.encoded` on purpose so the two
    /// stay legible side by side in a defaults dump.
    var token: String {
        switch self {
        case .tasks: return "tasks"
        case .board: return "board"
        case .calendar: return "calendar"
        case .matrix: return "matrix"
        case .settings: return "settings"
        case .smart(let list): return "smart:\(list.rawValue)"
        }
    }

    /// Decodes a token, returning `nil` for anything unrecognised.
    ///
    /// `nil` rather than a default on purpose: the caller drops the one bad
    /// entry instead of discarding the user's whole configuration.
    static func decode(from token: String) -> AppTab? {
        switch token {
        case "tasks": return .tasks
        case "board": return .board
        case "calendar": return .calendar
        case "matrix": return .matrix
        case "settings": return .settings
        default:
            let parts = token.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "smart",
                  let list = SmartList(rawValue: String(parts[1])) else { return nil }
            return .smart(list)
        }
    }

    // MARK: - Presentation

    var displayName: String {
        switch self {
        case .tasks:
            return String(localized: "tab.tasks", defaultValue: "Tasks",
                          comment: "Tab bar label for the app's main tasks screen. One or two words — it sits under an icon in a narrow tab.")
        case .board:
            return String(localized: "tab.board", defaultValue: "Board",
                          comment: "Tab bar label for the Kanban board screen. One or two words — it sits under an icon in a narrow tab.")
        case .calendar:
            return String(localized: "tab.calendar", defaultValue: "Calendar",
                          comment: "Tab bar label for the calendar screen showing tasks by date. This is the calendar view, not a CalDAV collection — a collection is a List.")
        case .matrix:
            return String(localized: "tab.matrix", defaultValue: "Matrix",
                          comment: "Tab bar label for the Eisenhower urgency/importance matrix screen. One or two words.")
        case .settings:
            return String(localized: "tab.settings", defaultValue: "Settings",
                          comment: "Tab bar label for the app's settings screen. One or two words.")
        case .smart(let list):
            return list.displayName
        }
    }

    /// SF Symbol for the tab item.
    ///
    /// `.smart(.upcoming)` deliberately does **not** reuse `SmartList.icon`,
    /// which is "calendar" — identical to ``calendar``'s symbol. Two tab items
    /// with the same icon are indistinguishable, and on iPad the bar is
    /// text-only so the collision is invisible in review there.
    var icon: String {
        switch self {
        case .tasks: return "checklist"
        case .board: return "rectangle.split.3x1"
        case .calendar: return "calendar"
        case .matrix: return "square.grid.2x2"
        case .settings: return "gear"
        case .smart(.upcoming): return "calendar.badge.clock"
        case .smart(let list): return list.icon
        }
    }

    // MARK: - Order and visibility

    /// The tabs that are always in the bar, in the order they are rendered:
    /// `.tasks` before the user's chosen tabs, `.settings` after them. Neither
    /// can be hidden, reordered, or stored — see the type's documentation.
    static let pinned: [AppTab] = [.tasks, .settings]

    /// Whether this tab is in the bar regardless of what the user chose.
    var isPinned: Bool { AppTab.pinned.contains(self) }

    /// Every destination the user may place in the bar. Excludes ``pinned``.
    static let customizable: [AppTab] =
        [.board, .calendar, .matrix] + SmartList.allCases.map { .smart($0) }

    /// The chosen tabs as the bar shipped before it became configurable —
    /// rendered between pinned Tasks and pinned Settings, so the bar reads
    /// Tasks, Board, Calendar, Matrix, Settings exactly as it always did.
    static let defaultVisible: [AppTab] = [.board, .calendar, .matrix]

    /// Chosen tabs that may be visible at once. The two pinned tabs take the
    /// first and fifth slots iOS will render without a "More" list.
    static let maxVisible = 3

    /// Decodes the user's visible tabs, repairing anything a hand-edited or
    /// stale blob could contain. Every repair is covered by a test.
    ///
    /// **An empty result is an answer, not a failure.** Only a blob that is not
    /// a JSON array of strings falls back to ``defaultVisible`` — which covers
    /// the case that matters, since the `@AppStorage` default is `""` and
    /// nothing but the editor ever writes the key. A well-formed `"[]"` means
    /// the user chose no tabs and gets the two pinned ones, and a blob whose
    /// entries all strip away means the same thing. Conflating those with
    /// "never configured" is what used to force ``canHide(_:from:)`` to protect
    /// the last chosen tab.
    static func decodeVisible(from json: String) -> [AppTab] {
        guard let data = json.data(using: .utf8),
              let tokens = try? JSONDecoder().decode([String].self, from: data)
        else { return defaultVisible }

        var seen = Set<AppTab>()
        var result: [AppTab] = []
        for token in tokens {
            // Both pinned tabs are stripped, not honoured. Dev builds of the
            // pre-pinning branch stored `["tasks","board","calendar","matrix"]`
            // — dropping "tasks" leaves the other three, and `ContentView` pins
            // Tasks back in front of them, so it is the same five tabs in the
            // same order. A blob of nothing *but* pinned tokens strips to empty,
            // which is now honoured as the empty bar it describes.
            guard let tab = decode(from: token), !tab.isPinned,
                  customizable.contains(tab), seen.insert(tab).inserted else { continue }
            result.append(tab)
            if result.count == maxVisible { break }
        }

        return result
    }

    static func encodeVisible(_ tabs: [AppTab]) -> String {
        let tokens = tabs.map(\.token)
        guard let data = try? JSONEncoder().encode(tokens) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Customizable destinations the user has not placed in the bar.
    static func hidden(given visible: [AppTab]) -> [AppTab] {
        let shown = Set(visible)
        return customizable.filter { !shown.contains($0) }
    }

    /// Whether another tab will fit. The bar is capped so iOS never renders a
    /// "More" list — see ``maxVisible``.
    static func canAdd(to visible: [AppTab]) -> Bool {
        visible.count < maxVisible
    }

    /// Whether `tab` may be hidden. Every chosen tab may, the last one included.
    ///
    /// The last remaining tab used to be protected, and never for the user's
    /// sake — pinned Tasks always hosts the title menu, so nothing is stranded
    /// by an empty bar. It was protected because ``decodeVisible(from:)`` read
    /// an empty stored list as "never configured" and answered with
    /// ``defaultVisible``: the editor could describe an empty bar, but the
    /// loader would hand the default three straight back. That distinction now
    /// lives in the loader, so hiding everything means what it says — a bar of
    /// pinned Tasks and pinned Settings, which is what users asked for.
    ///
    /// The predicate is membership because that is the real precondition: a tab
    /// you can hide is one that is currently in the bar. It answers `false` for
    /// a tab that is already out and for either ``pinned`` tab, neither of which
    /// is ever in `visible` — which is what keeps Settings mandatory here as
    /// well as in the editor, where it is not offered in the first place.
    static func canHide(_ tab: AppTab, from visible: [AppTab]) -> Bool {
        visible.contains(tab)
    }

    /// Non-smart-list destinations the user has hidden.
    ///
    /// `ContentView` is the only construction site for the board, calendar and
    /// matrix screens, so without this they would be unreachable when hidden.
    /// Only those three can ever appear: smart lists are filtered out because
    /// pinned Tasks shows any of them, and neither pinned tab is customizable,
    /// so neither is ever hidden.
    static func titleMenuHiddenPresentations(visible: [AppTab]) -> [AppTab] {
        hidden(given: visible).filter { tab in
            if case .smart = tab { return false }
            return true
        }
    }
}
