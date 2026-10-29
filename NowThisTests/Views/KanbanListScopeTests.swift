import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - KanbanListScope Tests
//
// Regression coverage for the Board losing the selected list when the user
// switched between Status and Lists mode. The two modes each held their own
// `@State` for the selected list — `selectedListID` on `KanbanBoardView` and
// `selectedPage` on `KanbanListSwipeView` — and nothing copied a value between
// them, so a list chosen in one mode was invisible to the other and both fell
// back to whichever list sorted first alphabetically.
//
// Both modes now resolve the one persisted id through `KanbanListScope`. These
// tests pin the resolution rule; the SwiftUI wiring that carries the value
// between the two modes is verified in the simulator.

@Suite("Kanban List Scope")
struct KanbanListScopeTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Inserts lists in the given order and returns them. The board's `@Query`
    /// sorts by name, so the array order here stands in for that ordering.
    @MainActor
    private func makeLists(_ names: [String], in context: ModelContext) throws -> [TaskList] {
        let lists = names.map {
            TaskList(serverURL: "https://example.test/dav", name: $0, colorHex: "#3478F6")
        }
        for list in lists { context.insert(list) }
        try context.save()
        return lists
    }

    @Test("A stored id resolves to the list it names")
    @MainActor
    func storedIDResolvesToItsList() throws {
        let container = try makeContainer()
        let lists = try makeLists(["Arbeit", "Familie", "Privat"], in: container.mainContext)

        let resolved = KanbanListScope.resolvedList(id: lists[1].id, in: lists)

        #expect(resolved?.id == lists[1].id)
        #expect(resolved?.name == "Familie")
    }

    /// The heart of the reported bug: picking a list in one mode has to survive
    /// into the other. Both modes ask this one function, so a non-first list
    /// must resolve to itself and never collapse back to `lists.first`.
    @Test("A non-first list survives instead of collapsing to the first list")
    @MainActor
    func nonFirstListDoesNotCollapseToFirst() throws {
        let container = try makeContainer()
        let lists = try makeLists(["Arbeit", "Familie", "Privat"], in: container.mainContext)

        for list in lists {
            #expect(KanbanListScope.resolvedList(id: list.id, in: lists)?.id == list.id)
        }
    }

    @Test("The unset id falls back to the first list")
    @MainActor
    func unsetIDFallsBackToFirstList() throws {
        let container = try makeContainer()
        let lists = try makeLists(["Arbeit", "Familie"], in: container.mainContext)

        let resolved = KanbanListScope.resolvedList(id: KanbanListScope.unset, in: lists)

        #expect(resolved?.id == lists[0].id)
    }

    /// The stored id outlives the list it points at: it is persisted across
    /// launches, and a list can be deleted locally or by an inbound sync. The
    /// board's label and its column filter used to disagree here — the label
    /// fell back on "no match", the filter only on "nil" — so the toolbar
    /// showed a real list's name above three empty columns.
    @Test("An id naming no existing list falls back to the first list")
    @MainActor
    func staleIDFallsBackToFirstList() throws {
        let container = try makeContainer()
        let lists = try makeLists(["Arbeit", "Familie"], in: container.mainContext)

        let resolved = KanbanListScope.resolvedList(id: "not-a-list-id", in: lists)

        #expect(resolved?.id == lists[0].id)
    }

    @Test("The label and the column filter agree on a stale id")
    @MainActor
    func labelAndFilterAgreeOnStaleID() throws {
        let container = try makeContainer()
        let lists = try makeLists(["Arbeit", "Familie"], in: container.mainContext)

        // One call site names the list in the toolbar, the other scopes the
        // columns. Both go through the same resolution, so they cannot diverge.
        let labelled = KanbanListScope.resolvedList(id: "not-a-list-id", in: lists)
        let scoped = KanbanListScope.resolvedList(id: "not-a-list-id", in: lists)

        #expect(labelled?.id == scoped?.id)
        #expect(scoped?.id != nil)
    }

    @Test("With no lists there is nothing to resolve")
    @MainActor
    func noListsResolvesToNil() throws {
        let container = try makeContainer()
        _ = container.mainContext

        #expect(KanbanListScope.resolvedList(id: KanbanListScope.unset, in: []) == nil)
        #expect(KanbanListScope.resolvedList(id: "anything", in: []) == nil)
    }

    // MARK: - Which tasks a list contains
    //
    // Resolving the same *list* in both modes was only half of it: the two modes
    // then applied their own, different rules for which tasks that list holds.
    // Status mode filtered on the list alone, so a subtask appeared as a card in
    // its own right beside its parent, and read `task.status` on a raw `@Query`
    // array with no liveness guard at all — the last flat presentation in the app
    // still doing that. Both modes now scope through `scopedTasks` and layer only
    // their own status rule on top.

    @MainActor
    private func makeTask(_ title: String,
                          in list: TaskList?,
                          status: TaskStatus = .needsAction,
                          parent: TaskItem? = nil,
                          context: ModelContext) throws -> TaskItem {
        let task = TaskItem(title: title, status: status)
        context.insert(task)
        task.taskList = list
        task.parentTask = parent
        try context.save()
        return task
    }

    @Test("A subtask is not a card of its own")
    @MainActor
    func subtaskIsNotScopedAsTopLevel() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)

        let parent = try makeTask("Umzug", in: lists[0], context: context)
        let child = try makeTask("Kartons kaufen", in: lists[0], parent: parent, context: context)

        let scoped = KanbanListScope.scopedTasks([parent, child], inListWithID: lists[0].id)

        #expect(scoped.map(\.id) == [parent.id])
        #expect(!scoped.contains { $0.id == child.id })
    }

    @Test("A task in another list is not scoped")
    @MainActor
    func otherListsAreNotScoped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit", "Privat"], in: context)

        let mine = try makeTask("Bericht", in: lists[0], context: context)
        let theirs = try makeTask("Einkaufen", in: lists[1], context: context)
        let loose = try makeTask("Ohne Liste", in: nil, context: context)

        let scoped = KanbanListScope.scopedTasks([mine, theirs, loose], inListWithID: lists[0].id)

        #expect(scoped.map(\.id) == [mine.id])
    }

    /// The crash this guards is reachable from Settings: deleting an account
    /// cascades `ServerAccount` -> `TaskList` -> `TaskItem` on the **main**
    /// context, while the Board tab is still realized and about to re-render.
    ///
    /// Deleted here rather than merely constructed, because `modelContext == nil`
    /// is also true of a model that was never inserted — which is safe to read,
    /// and is how the fixtures above are built. A test that conflated the two
    /// would assert nothing.
    @Test("A task the context has deleted is dropped instead of read")
    @MainActor
    func deletedTaskIsNotScoped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)

        let alive = try makeTask("Bleibt", in: lists[0], context: context)
        let doomed = try makeTask("Verschwindet", in: lists[0], context: context)
        let listID = lists[0].id

        context.delete(doomed)
        try context.save()
        #expect(doomed.modelContext == nil)

        // Must not trap: previously read `task.status` on the deleted model.
        let scoped = KanbanListScope.scopedTasks([alive, doomed], inListWithID: listID)

        #expect(scoped.map(\.id) == [alive.id])
    }

    @Test("With no list resolved, nothing is scoped")
    @MainActor
    func noListScopesNothing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)
        let task = try makeTask("Bericht", in: lists[0], context: context)

        #expect(KanbanListScope.scopedTasks([task], inListWithID: nil).isEmpty)
    }

    /// The reported bug in its general form: the same list, asked of both modes,
    /// answers with the same tasks. Only the status rule may differ — Status mode
    /// has a Done column, so it always shows completed tasks, where the Lists
    /// pages hide them behind `showCompletedTasks`.
    @Test("Both board modes see the same tasks for one list")
    @MainActor
    func bothModesAgreeOnOneList() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)

        let todo = try makeTask("Offen", in: lists[0], context: context)
        let doing = try makeTask("Läuft", in: lists[0], status: .inProcess, context: context)
        let done = try makeTask("Fertig", in: lists[0], status: .completed, context: context)
        let sub = try makeTask("Teilaufgabe", in: lists[0], parent: todo, context: context)
        let all = [todo, doing, done, sub]

        let scoped = KanbanListScope.scopedTasks(all, inListWithID: lists[0].id)

        // Status mode: every column, concatenated.
        let columns: [TaskStatus] = [.needsAction, .inProcess, .completed]
        let statusMode = columns.flatMap { status in scoped.filter { $0.status == status } }
        // Lists mode, with `showCompletedTasks` on — the only setting under which
        // the two are meant to match.
        let showCompleted = true
        let listsMode = scoped.filter { showCompleted || $0.status != .completed }

        #expect(Set(statusMode.map(\.id)) == Set(listsMode.map(\.id)))
        #expect(Set(statusMode.map(\.id)) == Set([todo.id, doing.id, done.id]))
        #expect(!statusMode.contains { $0.id == sub.id })
    }

    // MARK: - Why a page is empty

    /// A page with no rows has two quite different causes, and the swipe view
    /// told the user the wrong one: it said *"All tasks in X are completed."*
    /// whenever the page was empty, including for a list that has never held a
    /// task. A list showing `0 tasks` claimed every task in it was finished.
    ///
    /// The two are exactly distinguishable, because the completed filter is the
    /// only thing between the scoped tasks and the visible ones: if the scope
    /// holds anything while the page shows nothing, what it holds is completed
    /// and hidden. Nothing else can produce that combination.
    @Test("A list holding only completed tasks is not an empty list")
    @MainActor
    func aListOfCompletedTasksIsNotEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let lists = try makeLists(["Arbeit"], in: context)
        let done = try makeTask("Fertig", in: lists[0], status: .completed, context: context)

        let scoped = KanbanListScope.scopedTasks([done], inListWithID: lists[0].id)
        let visible = scoped.filter { false || $0.status != .completed }

        #expect(visible.isEmpty, "the page shows nothing")
        #expect(!KanbanListScope.listIsEmpty([done], inListWithID: lists[0].id),
                "but the list is not empty, so 'all completed' is the true description")
    }

    @Test("A list holding nothing is an empty list")
    @MainActor
    func aListHoldingNothingIsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let lists = try makeLists(["Arbeit", "Privat"], in: context)
        let elsewhere = try makeTask("Woanders", in: lists[1], context: context)

        #expect(KanbanListScope.listIsEmpty([elsewhere], inListWithID: lists[0].id),
                "another list's task must not make this one look occupied")
        #expect(KanbanListScope.listIsEmpty([], inListWithID: lists[0].id))
    }

    /// A cancelled task is still a task the list holds, and it is not completed,
    /// so it shows — the empty state must not claim otherwise.
    @Test("A cancelled task keeps the list non-empty and visible")
    @MainActor
    func aCancelledTaskKeepsTheListOccupied() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let lists = try makeLists(["Arbeit"], in: context)
        let cancelled = try makeTask("Abgesagt", in: lists[0], status: .cancelled, context: context)

        #expect(!KanbanListScope.listIsEmpty([cancelled], inListWithID: lists[0].id))
        let visible = KanbanListScope.scopedTasks([cancelled], inListWithID: lists[0].id)
            .filter { false || $0.status != .completed }
        #expect(!visible.isEmpty, "so the empty state never appears for it at all")
    }

    // MARK: - Page order

    /// The Lists pages kept the `@Query`'s order, newest first by creation date,
    /// while the Status columns follow the list's manual order. So a card moved
    /// to the top of To Do on the Status board could sit anywhere on its page.
    @Test("A Lists page follows the list's manual order, as the Status columns do")
    @MainActor
    func pageFollowsManualOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)

        let first = try makeTask("Erste", in: lists[0], context: context)
        let second = try makeTask("Zweite", in: lists[0], status: .inProcess, context: context)
        let third = try makeTask("Dritte", in: lists[0], context: context)
        first.manualSortOrder = 3_000
        second.manualSortOrder = 1_000
        third.manualSortOrder = 2_000
        // The board's @Query order: newest first by creation date.
        let queryOrder = [third, second, first]

        let page = KanbanListScope.pageTasks(queryOrder, inListWithID: lists[0].id,
                                             showCompleted: true)

        #expect(page.map(\.title) == ["Zweite", "Dritte", "Erste"])
        // Within each status, the same order its Status column shows.
        let todoColumn = KanbanReorder.columnOrder(
            KanbanListScope.scopedTasks(queryOrder, inListWithID: lists[0].id)
                .filter { $0.status == .needsAction })
        #expect(page.filter { $0.status == .needsAction }.map(\.id) == todoColumn.map(\.id))
    }

    @Test("A Lists page hides completed tasks unless they are shown")
    @MainActor
    func pageHidesCompletedUnlessShown() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let lists = try makeLists(["Arbeit"], in: context)
        let open = try makeTask("Offen", in: lists[0], context: context)
        let done = try makeTask("Fertig", in: lists[0], status: .completed, context: context)

        #expect(KanbanListScope.pageTasks([done, open], inListWithID: lists[0].id,
                                          showCompleted: false).map(\.id) == [open.id])
        #expect(Set(KanbanListScope.pageTasks([done, open], inListWithID: lists[0].id,
                                              showCompleted: true).map(\.id))
                == Set([open.id, done.id]))
    }
}
