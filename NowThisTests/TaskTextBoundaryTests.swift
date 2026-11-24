import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Task entry text boundaries", .serialized)
@MainActor
struct TaskTextBoundaryTests {
    private func container() throws -> ModelContainer {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(TaskList(serverURL: "", name: "Inbox", colorHex: ""))
        try context.save()
        return container
    }

    @Test("Create intent rejects oversized title or notes before insert, tags, and effects",
          arguments: ["title", "titleBytes", "notes", "notesBytes"])
    func createRejects(field: String) async throws {
        let container = try container()
        let context = container.mainContext
        let intent = CreateTaskIntent()
        intent.taskTitle = field == "title" ? String(repeating: "x", count: 100_000)
            : field == "titleBytes" ? "a" + String(repeating: "\u{301}", count: 32_000) : "Valid"
        intent.notes = field == "notes" ? String(repeating: "x", count: 20_001)
            : field == "notesBytes" ? "a" + String(repeating: "\u{301}", count: 500_000) : nil
        intent.tag = "Must not create"
        var effects = 0
        var rejected = false
        do { _ = try await intent.perform(in: context, onWidgetReload: { effects += 1 }) }
        catch { rejected = true }
        #expect(rejected)
        #expect(effects == 0)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
        #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
    }

    @Test("Quick add rejects parsed title and raw input byte overflow", arguments: [false, true])
    func quickRejects(raw: Bool) async throws {
        let container = try container()
        let context = container.mainContext
        let intent = QuickAddTaskIntent()
        intent.text = raw ? "a" + String(repeating: "\u{301}", count: 32_000)
            : String(repeating: "x", count: 501)
        var rejected = false
        var effects = 0
        do { _ = try await intent.perform(in: context, onWidgetReload: { effects += 1 }) }
        catch { rejected = true }
        #expect(rejected)
        #expect(effects == 0)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
        #expect(try ReminderSchedulingJournal.capture(in: context).isEmpty)
    }

    @Test("Phone rejects Watch parsed title without inserting")
    func watchRejects() throws {
        let container = try container()
        let context = container.mainContext
        let outcome = WatchEditApplier.stage(.add(rawText: String(repeating: "x", count: 501),
            listID: nil, dueDate: nil, priorityRaw: nil), modelContext: context,
            isProUnlocked: true, now: Date())
        #expect(outcome == .invalid)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    }
}

@Suite("Task text drafts", .serialized)
@MainActor
struct TaskTextDraftTests {
    @Test("Inline and Quick Add creation draft rejects without changing a retry model")
    func creationRejectsAndRetries() throws {
        let container = try DAVSyncScenario.container()
        let draft = TaskCreationDraft()
        let first = try draft.task(title: "First")
        container.mainContext.insert(first)
        #expect(throws: TaskTextValidation.Failure.self) {
            _ = try draft.task(title: String(repeating: "x", count: 501))
        }
        #expect(first.title == "First")
        let corrected = try draft.task(title: "  Corrected  ")
        #expect(corrected === first)
        #expect(corrected.title == "Corrected")
    }

    @Test("Invalid notes remain editable and cannot reach the model or save")
    func notesRetained() throws {
        let task = TaskItem(title: "Title")
        task.descriptionText = "Original"
        let draft = TaskTextDraft(task)
        draft.title = "Changed title"
        let long = String(repeating: "x", count: 20_001)
        draft.notes = long
        var saves = 0
        #expect(throws: TaskTextValidation.Failure.self) { try draft.commit(to: task) { saves += 1 } }
        #expect(saves == 0)
        #expect(task.title == "Title" && task.descriptionText == "Original")
        #expect(draft.notes == long)
        draft.notes = "Corrected"
        try draft.commit(to: task) { saves += 1 }
        #expect(task.title == "Changed title" && task.descriptionText == "Corrected")
        #expect(saves == 1 && !draft.hasChanges)
    }

    @Test("Save failure retains draft and restores model; corrected retry saves once")
    func detailSaveRetry() throws {
        struct Failure: Error {}
        let task = TaskItem(title: "Original")
        let draft = TaskTextDraft(task)
        draft.title = "Draft"
        #expect(throws: Failure.self) { try draft.commit(to: task) { throw Failure() } }
        #expect(task.title == "Original")
        #expect(draft.title == "Draft" && draft.hasChanges)
        try draft.commit(to: task) {}
        #expect(task.title == "Draft" && !draft.hasChanges)
    }

    @Test("Unchanged imported fields survive unrelated edits without normalization")
    func legacyUnchanged() throws {
        let title = "  " + String(repeating: "x", count: 501) + "  "
        let notes = String(repeating: "🦉", count: 20_001)
        let task = TaskItem(title: title)
        task.descriptionText = notes
        let draft = TaskTextDraft(task)
        task.priority = .high
        try draft.commit(to: task) {}
        #expect(task.title == title && task.descriptionText == notes)
        draft.title = "Corrected title"
        try draft.commit(to: task) {}
        #expect(task.descriptionText == notes)
    }

    @Test("Grapheme limits accept emoji and reject complex single characters by bytes")
    func unicodeBoundaries() throws {
        #expect(try TaskTextValidation.title(String(repeating: "👨‍👩‍👧‍👦", count: 500)).count == 500)
        #expect(throws: TaskTextValidation.Failure.self) {
            _ = try TaskTextValidation.title("a" + String(repeating: "\u{301}", count: 32_000))
        }
        try TaskTextValidation.notes(String(repeating: "🦉", count: 20_000))
        #expect(throws: TaskTextValidation.Failure.self) {
            try TaskTextValidation.notes("a" + String(repeating: "\u{301}", count: 500_000))
        }
        #expect(throws: TaskTextValidation.Failure.self) {
            _ = try TaskTextValidation.quickAdd(String(repeating: " ", count: 64_001))
        }
    }
    @Test("Untouched draft fields track sync without overwriting remote text")
    func syncRefresh() throws {
        let task = TaskItem(title: "Original")
        task.descriptionText = "Original notes"
        let draft = TaskTextDraft(task)
        task.title = "Remote title"
        task.descriptionText = "Remote notes"
        draft.refresh(from: task)
        #expect(draft.title == "Remote title" && draft.notes == "Remote notes")
        #expect(!draft.hasChanges)
        draft.title = "Local draft"
        task.title = "New remote title"
        task.descriptionText = "New remote notes"
        draft.refresh(from: task)
        #expect(draft.title == "Local draft" && draft.notes == "New remote notes")
        try draft.commit(to: task) {}
        #expect(task.title == "Local draft" && task.descriptionText == "New remote notes")
        // A remote update without an observation callback must also survive Done.
        task.descriptionText = "Last remote notes"
        try draft.commit(to: task) {}
        #expect(task.descriptionText == "Last remote notes" && draft.notes == "Last remote notes")
    }

    @Test("Imported oversized title and notes survive a real status and date save")
    func legacyUnrelatedPersistence() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let title = String(repeating: "x", count: 501)
        let notes = String(repeating: "x", count: 20_001)
        let task = TaskItem(title: title)
        task.descriptionText = notes
        context.insert(task)
        try context.save()
        let draft = TaskTextDraft(task)
        task.dueDate = Date(timeIntervalSince1970: 2_000_000_000)
        try TaskDetailView.applyStatusChange(.inProcess, to: task, in: context,
            requestReconcile: { _ in }, cancelReminder: { _ in })
        try draft.commit(to: task) { try context.save() }
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(saved.title == title && saved.descriptionText == notes)
        #expect(saved.status == .inProcess && saved.dueDate == task.dueDate)
    }

}
