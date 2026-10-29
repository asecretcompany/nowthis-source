import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Snapshot Liveness Tests
//
// Second wave of the account-delete crash class. `TaskRowData`/`JournalRowData`
// covered the task and journal rows, but four model types render in retained
// views with no snapshot at all: `ServerAccount` (Settings), `TaskList`, `Tag`
// and `SavedFilter` (sidebar). All four are hard-deleted on the **main**
// context — the account cascade reaches `TaskList`, and the sidebar's own
// swipe-to-delete reaches every one of them — so a retained row that reads
// `list.name` on the next layout pass trips:
//
//   SwiftData/BackingData.swift:249: Fatal error: This backing data was
//   detached from a context without resolving attribute faults
//
// Each snapshot must refuse to read an invalidated model, and must carry every
// field its row renders — including the finished VoiceOver string's inputs.

@Suite("Sidebar and settings row snapshots")
struct SidebarSnapshotTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    // MARK: - Account rows

    @Test("Account snapshot is nil once the account is deleted")
    @MainActor
    func accountSnapshotIsNilAfterDelete() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        context.insert(account)
        try context.save()

        context.delete(account)
        try context.save()

        // The row is still on screen underneath the pushed AccountEditView that
        // triggered the delete; without the guard this traps in `mode.getter`.
        #expect(AccountRowData(account: account) == nil)
    }

    @Test("Account snapshot carries the fields the row renders")
    @MainActor
    func accountSnapshotCarriesFields() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        context.insert(account)
        try context.save()

        let snapshot = try #require(AccountRowData(account: account))
        #expect(snapshot.displayName == "Home")
        #expect(snapshot.serverBaseURL == "https://cloud.test")
        #expect(snapshot.isVault == false)
        #expect(snapshot.id == account.id)
    }

    // MARK: - Task list rows

    @Test("Task list snapshot is nil after an account-delete cascade")
    @MainActor
    func taskListSnapshotIsNilAfterAccountCascade() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        let list = TaskList(serverURL: "https://cloud.test", name: "Groceries", colorHex: "#FF0000")
        list.account = account
        context.insert(account)
        context.insert(list)
        try context.save()

        context.delete(account)
        try context.save()

        #expect(list.modelContext == nil, "cascade must invalidate the list")
        #expect(TaskListRowData(list: list) == nil)
    }

    @Test("Task list snapshot carries name, colour and task count")
    @MainActor
    func taskListSnapshotCarriesFields() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "https://cloud.test", name: "Groceries", colorHex: "#FF0000")
        context.insert(list)
        let task = TaskItem(title: "Milk", priority: .none)
        task.taskList = list
        context.insert(task)
        try context.save()

        let snapshot = try #require(TaskListRowData(list: list))
        #expect(snapshot.name == "Groceries")
        #expect(snapshot.colorHex == "#FF0000")
        #expect(snapshot.taskCount == 1, "the badge count must be snapshotted, not read later")
        #expect(snapshot.id == list.id)
    }

    // MARK: - Tag rows

    @Test("Tag snapshot is nil once the tag is deleted")
    @MainActor
    func tagSnapshotIsNilAfterDelete() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let tag = NowThis.Tag(name: "urgent", color: "#AF52DE")
        context.insert(tag)
        try context.save()

        context.delete(tag)
        try context.save()

        #expect(TagRowData(tag: tag) == nil)
    }

    @Test("Tag snapshot carries name, colour and task count")
    @MainActor
    func tagSnapshotCarriesFields() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let tag = NowThis.Tag(name: "urgent", color: "#AF52DE")
        context.insert(tag)
        let task = TaskItem(title: "Ship", priority: .none)
        task.tags.append(tag)
        context.insert(task)
        try context.save()

        let snapshot = try #require(TagRowData(tag: tag))
        #expect(snapshot.name == "urgent")
        #expect(snapshot.colorHex == "#AF52DE")
        #expect(snapshot.taskCount == 1)
        #expect(snapshot.id == tag.id)
    }

    // MARK: - Saved filter rows

    @Test("Saved filter snapshot is nil once the filter is deleted")
    @MainActor
    func savedFilterSnapshotIsNilAfterDelete() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let filter = SavedFilter(name: "Next up")
        context.insert(filter)
        try context.save()

        context.delete(filter)
        try context.save()

        #expect(SavedFilterRowData(filter: filter) == nil)
    }

    @Test("Saved filter snapshot carries the already-resolved logic name")
    @MainActor
    func savedFilterSnapshotCarriesFields() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let filter = SavedFilter(
            name: "Next up", icon: "bolt", colorHex: "#00FF00", logicOperator: .or
        )
        context.insert(filter)
        try context.save()

        let snapshot = try #require(SavedFilterRowData(filter: filter))
        #expect(snapshot.name == "Next up")
        #expect(snapshot.icon == "bolt")
        #expect(snapshot.colorHex == "#00FF00")
        // `logic` is a computed getter over the stored `logicOperator`, so it is a
        // real attribute read — the row must not perform it after invalidation.
        #expect(snapshot.logicDisplayName == FilterLogic.or.displayName)
    }
}

// MARK: - Compact Task Snapshot

@Suite("Compact task snapshot")
struct TaskGlanceDataTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    @Test("Glance snapshot is nil after an account-delete cascade")
    @MainActor
    func glanceIsNilAfterAccountCascade() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        let list = TaskList(serverURL: "https://cloud.test", name: "L", colorHex: "#FF0000")
        list.account = account
        let task = TaskItem(title: "On the calendar", priority: .high)
        task.taskList = list
        context.insert(account)
        context.insert(list)
        context.insert(task)
        try context.save()

        context.delete(account)
        try context.save()

        #expect(TaskGlanceData(task: task) == nil)
    }

    @Test("Glance snapshot carries the fields the compact rows render")
    @MainActor
    func glanceCarriesFields() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let task = TaskItem(title: "Ship it", priority: .high, status: .inProcess)
        task.dueDate = due
        task.isDueDateOnly = true
        context.insert(task)
        try context.save()

        let snapshot = try #require(TaskGlanceData(task: task))
        #expect(snapshot.id == task.id)
        #expect(snapshot.title == "Ship it")
        #expect(snapshot.status == .inProcess)
        #expect(snapshot.priority == .high)
        #expect(snapshot.dueDate == due)
        #expect(snapshot.isDueDateOnly == true)
    }

    /// The compact presentations show no tags and no subtask progress, so the
    /// snapshot must not walk the subtree the way `TaskRowData` does — a matrix
    /// quadrant re-snapshots on every scroll tick.
    @Test("Glance snapshot does not depend on the subtask hierarchy")
    @MainActor
    func glanceIgnoresSubtasks() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let root = TaskItem(title: "Root", priority: .none)
        context.insert(root)
        let child = TaskItem(title: "Child", priority: .none, status: .completed)
        child.parentTask = root
        context.insert(child)
        try context.save()

        let withChildren = try #require(TaskGlanceData(task: root))
        child.parentTask = nil
        try context.save()
        let withoutChildren = try #require(TaskGlanceData(task: root))

        #expect(withChildren == withoutChildren)
    }
}

// MARK: - Relationship Traversal Guard

@Suite("Subtask ordering guard")
struct OrderedSubtasksGuardTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// `RecursiveTaskRow` asks for its children *above* its own liveness guard —
    /// three separate times — so the traversal itself has to be safe. Without the
    /// guard this reads `parent.subtasks` on an invalidated model and aborts the
    /// process.
    @Test("Ordering an invalidated parent's subtasks yields an empty list")
    @MainActor
    func orderedSubtasksIfLiveIsEmptyAfterCascade() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        let list = TaskList(serverURL: "https://cloud.test", name: "L", colorHex: "#FF0000")
        list.account = account
        let parent = TaskItem(title: "Parent", priority: .none)
        parent.taskList = list
        context.insert(account)
        context.insert(list)
        context.insert(parent)
        let child = TaskItem(title: "Child", priority: .none)
        child.parentTask = parent
        child.taskList = list
        context.insert(child)
        try context.save()

        context.delete(account)
        try context.save()

        #expect(parent.modelContext == nil, "cascade must invalidate the parent")
        #expect(
            TaskListHelpers.orderedSubtasksIfLive(of: parent, by: .dueDate, ascending: true).isEmpty
        )
    }

    /// The guard must not change ordering for a live parent.
    @Test("A live parent still orders its subtasks with completed last")
    @MainActor
    func orderedSubtasksUnchangedForLiveParent() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let parent = TaskItem(title: "Parent", priority: .none)
        context.insert(parent)
        let done = TaskItem(title: "Done", priority: .none, status: .completed)
        done.parentTask = parent
        context.insert(done)
        let open = TaskItem(title: "Open", priority: .none)
        open.parentTask = parent
        context.insert(open)
        try context.save()

        let ordered = TaskListHelpers.orderedSubtasksIfLive(
            of: parent, by: .title, ascending: true
        )
        #expect(ordered.map(\.title) == ["Open", "Done"])
    }

    /// Pins the split that keeps the two concerns apart. `modelContext == nil` is
    /// true of a model that was never inserted as well as one that was deleted, so
    /// putting the liveness guard in the *pure* `orderedSubtasks` would make every
    /// detached-fixture test in `TaskListSortingTests` assert nothing at all —
    /// silently, since an empty result compares equal to an empty expectation only
    /// when the expectation is also empty. Three of them caught it; a fourth added
    /// later might not.
    @Test("The unguarded helper still orders a parent that was never inserted")
    func orderedSubtasksWorksOnDetachedModels() {
        let parent = TaskItem(title: "Parent", priority: .none)
        let done = TaskItem(title: "Done", priority: .none, status: .completed)
        let open = TaskItem(title: "Open", priority: .none)
        parent.subtasks = [done, open]

        #expect(parent.modelContext == nil, "fixture is deliberately context-free")
        let ordered = TaskListHelpers.orderedSubtasks(of: parent, by: .title, ascending: true)
        #expect(ordered.map(\.title) == ["Open", "Done"])
    }
}

// MARK: - Array-Boundary Guards

/// The snapshot types are only half the fix. Every parent that hands a leaf its
/// rows has to drop invalidated models *before* `ForEach` reads their `id` to
/// diff identity — that read happens before any row body, so a guard inside the
/// leaf runs too late. These pin the predicate each boundary uses.
@Suite("Array-boundary liveness filters")
struct ArrayBoundaryGuardTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Builds an account with a list and one task, then cascades it all away.
    private func cascadedFixture(
        _ context: ModelContext
    ) throws -> (list: TaskList, task: TaskItem, survivor: TaskItem) {
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "u"
        )
        let list = TaskList(serverURL: "https://cloud.test", name: "L", colorHex: "#FF0000")
        list.account = account
        let doomed = TaskItem(title: "Doomed", priority: .none)
        doomed.taskList = list
        let survivor = TaskItem(title: "Survivor", priority: .none)
        context.insert(account)
        context.insert(list)
        context.insert(doomed)
        context.insert(survivor)
        try context.save()

        context.delete(account)
        try context.save()
        return (list, doomed, survivor)
    }

    @Test("A cascade invalidates the list and its tasks but not unrelated tasks")
    @MainActor
    func cascadeScopeIsWhatTheFiltersAssume() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try cascadedFixture(context)

        #expect(fixture.list.modelContext == nil)
        #expect(fixture.task.modelContext == nil)
        #expect(fixture.survivor.modelContext != nil, "an unrelated task must survive")
    }

    /// The predicate every task-array boundary now leads with — `displayedTasks`,
    /// `sectionedOccurrences`, `filteredTasks`, `tasksForList`, and `glanceRows()`.
    /// (The sidebar's smart-list counts no longer need this filter: they fetch
    /// value-type rows on a background context instead of reading main-context
    /// models.) Filtering must drop exactly the cascaded task and keep the
    /// rest, without trapping on the way through.
    @Test("Filtering a mixed array on liveness drops only the invalidated tasks")
    @MainActor
    func livenessFilterKeepsSurvivors() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try cascadedFixture(context)

        let mixed = [fixture.task, fixture.survivor]
        let live = mixed.filter { $0.modelContext != nil }

        #expect(live.count == 1)
        // Reading `.title` on the unfiltered array would trap; on the filtered
        // one it must not.
        #expect(live.map(\.title) == ["Survivor"])
    }

    /// `glanceRows()` is that same filter plus the snapshot, and it is what the
    /// calendar and matrix boundaries call.
    @Test("glanceRows drops invalidated tasks instead of trapping on them")
    @MainActor
    func glanceRowsDropsInvalidated() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try cascadedFixture(context)

        let rows = [fixture.task, fixture.survivor].glanceRows()

        #expect(rows.count == 1)
        #expect(rows.map(\.data.title) == ["Survivor"])
        // `id` must come from the snapshot, since ForEach reads it before any body.
        #expect(rows[0].id == rows[0].data.id)
    }

    /// `EditListSheet` holds `@Bindable var list`, so it can't snapshot — it takes
    /// the same dismiss-guard as the other three editors. This pins the signal it
    /// keys off.
    @Test("A cascaded list reports the nil context the editor guard dismisses on")
    @MainActor
    func editorGuardSignalForTaskList() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let fixture = try cascadedFixture(context)

        #expect(fixture.list.modelContext == nil)
    }
}

// MARK: - Sync Account Capture

@Suite("Sync account value capture")
struct SyncAccountTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// A sync pass awaits the keychain and then a multi-second network round trip
    /// per account. Holding the `ServerAccount` across those suspensions means a
    /// delete landing mid-sync invalidates it; the captured value survives.
    @Test("A captured account still reads after its model is deleted")
    @MainActor
    func capturedAccountSurvivesDelete() throws {
        // The container must be held for the test's lifetime: binding only
        // `.mainContext` lets the temporary container deallocate and takes the
        // store with it, which traps on the next access.
        let container = try makeContainer()
        let context = container.mainContext
        let account = ServerAccount(
            displayName: "Home", serverBaseURL: "https://cloud.test", username: "alice"
        )
        context.insert(account)
        try context.save()

        let captured = SyncAccount(account: account)

        context.delete(account)
        try context.save()

        // Reading `account.displayName` here would trap; the value does not.
        #expect(captured.displayName == "Home")
        #expect(captured.serverBaseURL == "https://cloud.test")
        #expect(captured.username == "alice")
        #expect(captured.id.isEmpty == false)
    }
}
