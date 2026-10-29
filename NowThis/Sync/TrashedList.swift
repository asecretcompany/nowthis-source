import Foundation

/// A calendar the server has moved to its trash.
///
/// Deliberately **not** a `TaskList`, and deliberately holding no tasks. `TaskList` is fetched
/// from seventeen places — three `@Query` sites plus fourteen bare `FetchDescriptor<TaskList>()`
/// calls across views, App Intents, `WatchBridge` and `NewTaskDefaults`, most with no predicate
/// at all. A flag on `TaskList` would mean remembering a new exclusion at every one of them,
/// where forgetting one fails silently: a discarded list quietly reappearing in Siri's list
/// picker, the widget configuration, or the watch. Being a separate type makes that
/// unrepresentable rather than merely unlikely, and it is why these carry no `TaskItem`s — so
/// they cannot surface in Today, Upcoming, search, reminders, the badge or the widget either.
struct TrashedList: Sendable, Hashable, Identifiable {
    var id: String { href }

    /// The collection's href on the server. Identity, and stable across renames.
    let href: String

    /// What to call it in the notice.
    let name: String

    /// When the server says it was deleted. `nil` when the server sent no date or one in a
    /// format we do not recognise — the notice then simply omits it.
    let deletedAt: Date?
}

extension TrashedList {
    init(_ calendar: CalDAVClient.RemoteCalendar) {
        // Falls back to the collection's own path segment, never to a translated constant.
        // `TaskList.recoveryListServerURL` documents the trap: a user-facing name that ships
        // translated cannot double as identity, because the same list acquires a different one
        // when the device language changes.
        let fallback = calendar.href.split(separator: "/").last.map(String.init) ?? calendar.href
        self.init(
            href: calendar.href,
            name: calendar.displayName.isEmpty ? fallback : calendar.displayName,
            deletedAt: calendar.deletedAt
        )
    }
}

/// Decides which trashed lists the user has not been told about yet.
///
/// Pure, so the "tell them once, but tell them again about a new one" rule is testable without
/// standing up defaults or a view.
enum TrashedListReporter {
    /// `UserDefaults` key holding the hrefs already shown. App-local UI state, not synced.
    static let defaultsKey = "reportedTrashedListHrefs"

    static func unreported(_ found: [TrashedList], reported: Set<String>) -> [TrashedList] {
        found.filter { !reported.contains($0.href) }
    }

    /// Decodes the stored href set.
    ///
    /// Newline-separated, not comma-separated as `TranslationDisclosure` is: a comma is legal
    /// unencoded in a URL path, so a comma store would split one href into two halves that
    /// match nothing, and the same list would be re-announced after every sync forever. Blanks
    /// are dropped so a stray separator cannot register as a reported list named "".
    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ hrefs: Set<String>) -> String {
        hrefs.sorted().joined(separator: "\n")
    }
}
