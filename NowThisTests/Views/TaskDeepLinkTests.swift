import SwiftUI
import SwiftData
import Testing
@testable import NowThis

@Suite("Task deep links")
@MainActor
struct TaskDeepLinkTests {
    @Test("A task link takes precedence over every startup tab")
    func linkWinsOverStartup() {
        for startup in ["last", "tab:settings", "tab:matrix", "smart:Overdue", "invalid"] {
            #expect(MainTabView.resolveStartupTab(startup, visible: AppTab.defaultVisible, hasDeepLink: true) == .tasks)
        }
    }

    @Test("Task links obtain a list host without replacing an active list")
    func linkObtainsTaskListHost() {
        #expect(MainShellView.selectionForDeepLink(current: nil) == .smart(.today))
        #expect(MainShellView.selectionForDeepLink(current: .journals) == .smart(.today))
        #expect(MainShellView.selectionForDeepLink(current: .tag("chosen")) == .tag("chosen"))
        #expect(MainShellView.selectionForDeepLink(current: .taskList("chosen")) == .taskList("chosen"))
    }

    @Test("A link resolves an exact task including a subtask outside the current list filter")
    func resolvesSubtask() throws {
        let container = try DAVSyncScenario.container()
        let parent = TaskItem(title: "Parent")
        let child = TaskItem(title: "Linked child")
        child.parentTask = parent
        container.mainContext.insert(parent)
        container.mainContext.insert(child)
        try container.mainContext.save()
        let probe = Probe(request: child.id)
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.task === child)
        #expect(probe.request == nil)
    }

    @Test("Busy editors retain the pending request and current task identity")
    func busyEditorDefersRequest() throws {
        let container = try DAVSyncScenario.container()
        let first = TaskItem(title: "Current editor")
        let next = TaskItem(title: "Requested task")
        container.mainContext.insert(first)
        container.mainContext.insert(next)
        try container.mainContext.save()
        let probe = Probe(request: next.id)
        try probe.route(in: container.mainContext, isBusy: true)
        #expect(probe.request == next.id)
        #expect(probe.selected == nil)
        probe.selected = SelectedTask(first)
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.task === first)
        #expect(probe.request == next.id)
        probe.selected = nil
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.task === next)
        #expect(probe.request == nil)
    }

    @Test("An already open task satisfies the request without replacing its editor")
    func sameTaskDoesNotReplaceEditor() throws {
        let container = try DAVSyncScenario.container()
        let task = TaskItem(title: "Current editor")
        container.mainContext.insert(task)
        try container.mainContext.save()
        let probe = Probe(request: task.id)
        probe.selected = SelectedTask(task)
        try probe.route(in: container.mainContext, isBusy: true)
        #expect(probe.request == nil)
        #expect(probe.selected?.task === task)
    }

    @Test("Missing and soft-deleted tasks are consumed without presenting an invalid editor")
    func absentTasksAreSafe() throws {
        let container = try DAVSyncScenario.container()
        let deleted = TaskItem(title: "Deleted")
        deleted.isDeletedLocally = true
        container.mainContext.insert(deleted)
        try container.mainContext.save()
        for id in [UUID().uuidString, deleted.id] {
            let probe = Probe(request: id)
            try probe.route(in: container.mainContext)
            #expect(probe.request == nil)
            #expect(probe.selected == nil)
        }
    }

    @Test("The same URL can reopen a task after the previous editor is dismissed")
    func repeatedLinkCanReopen() throws {
        let container = try DAVSyncScenario.container()
        let task = TaskItem(title: "Repeated target")
        container.mainContext.insert(task)
        try container.mainContext.save()
        let probe = Probe(request: task.id)
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.id == task.id)
        #expect(probe.request == nil)
        probe.selected = nil
        probe.request = task.id
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.id == task.id)
        #expect(probe.request == nil)
    }

    @Test("Resolving a link does not save unrelated pending changes")
    func lookupIsReadOnly() throws {
        let container = try DAVSyncScenario.container()
        let target = TaskItem(title: "Saved target")
        container.mainContext.insert(target)
        try container.mainContext.save()
        let pending = TaskItem(title: "Unrelated unsaved draft")
        let pendingID = pending.id
        container.mainContext.insert(pending)
        let probe = Probe(request: target.id)
        try probe.route(in: container.mainContext)
        #expect(probe.selected?.task === target)
        #expect(container.mainContext.hasChanges)
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == pendingID })) == 0)
    }

    @Test("Nested or repeated editor appearances keep links blocked until every editor closes")
    func presentationBlockersAreIdempotent() {
        let state = TaskLinkPresentationState()
        let first = UUID(), nested = UUID()
        #expect(!state.isBlocked)
        state.setActive(true, token: first)
        state.setActive(true, token: first)
        #expect(state.isBlocked)
        state.setActive(true, token: nested)
        state.setActive(false, token: first)
        #expect(state.isBlocked)
        state.setActive(false, token: nested)
        #expect(!state.isBlocked)
        state.setActive(false, token: UUID())
        #expect(!state.isBlocked)
    }

    @Test("Blocked journal navigation stays put until the editor closes")
    func journalSelectionDefersLink() {
        #expect(MainShellView.selectionForDeepLink(current: .journals, allowsPresentation: false) == .journals)
        #expect(MainShellView.selectionForDeepLink(current: nil, allowsPresentation: false) == nil)
        #expect(MainShellView.selectionForDeepLink(current: .journals, allowsPresentation: true) == .smart(.today))
    }

    @Test("Cancelling a failed inline addition releases a link without saving unrelated edits")
    func failedInlineCancellationReleasesLink() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let target = TaskItem(title: "Link target")
        context.insert(target)
        try context.save()
        let unrelated = TaskItem(title: "Unrelated pending edit")
        context.insert(unrelated)
        let draft = TaskCreationDraft()
        let pending = try draft.task(title: "Failed then erased")
        let pendingID = pending.id
        context.insert(pending)
        #expect(!ViewPersistence.saveOrReport(in: context, errorState: ErrorState(), save: { throw CancellationFailure() }))
        let retry = try draft.task(title: "Corrected before cancelling")
        #expect(retry === pending)
        #expect(TaskListView.showsInlineComposer(verticalSizeClass: .compact,
            dynamicTypeSize: .accessibility3, isFocused: false, title: "", hasPendingTask: draft.hasPendingTask),
            "A failed addition must keep its explicit cancellation reachable even after clearing text")
        let probe = Probe(request: target.id)
        try probe.route(in: context, isBusy: draft.hasPendingTask)
        #expect(probe.request == target.id && probe.selected == nil)
        try draft.cancelInlineAddition(in: context)
        #expect(!draft.hasPendingTask)
        try probe.route(in: context, isBusy: draft.hasPendingTask)
        #expect(probe.request == nil && probe.selected?.task === target)
        #expect(context.hasChanges)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 1)
        try context.save()
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == pendingID })) == 0)
        #expect(try fresh.fetch(FetchDescriptor<TaskItem>()).map(\.title).sorted() == ["Link target", "Unrelated pending edit"])
    }

    @Test("Cancelling inline recovery never deletes a task whose primary save succeeded")
    func committedInlineCancellationKeepsTask() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let draft = TaskCreationDraft()
        let saved = try draft.task(title: "Already committed")
        context.insert(saved)
        try context.save()
        context.insert(TaskItem(title: "Unrelated pending edit"))
        try draft.cancelInlineAddition(in: context)
        #expect(!draft.hasPendingTask)
        #expect(saved.modelContext != nil && !saved.isDeleted)
        #expect(context.hasChanges)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).map(\.title) == ["Already committed"])
    }

    private struct CancellationFailure: Error {}

    @MainActor
    private final class Probe {
        var request: String?
        var selected: SelectedTask?
        init(request: String?) { self.request = request }
        func route(in context: ModelContext, isBusy: Bool = false) throws {
            try TaskListView.routeDeepLink(
                request: Binding(get: { self.request }, set: { self.request = $0 }),
                selectedTask: Binding(get: { self.selected }, set: { self.selected = $0 }),
                context: context, isBusy: isBusy)
        }
    }
}
