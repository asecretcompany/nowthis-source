import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Siri Add Widget Reload Tests

/// Completing or deleting a task from Siri reloads the widgets; adding one did not. The gap
/// was invisible while Siri-added tasks had no due date, and became a daily sight once they
/// took the default: a task spoken with a Today default sat in the store while the Today
/// widget kept showing the list without it, until its next timeline refresh.
///
/// The reload is injected the way `TaskCompletionCoordinator` injects it, so a test can
/// count it without a `WidgetCenter`.
@Suite("Siri Add Widget Reload")
struct SiriAddWidgetReloadTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    private func clearStoredList() {
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.defaultListIDKey)
        UserDefaults.standard.removeObject(forKey: TaskDefaultsPreferences.legacySiriListIDKey)
    }

    @MainActor
    private func insertList(_ context: ModelContext) throws {
        let list = TaskList(serverURL: "", name: "Inbox", colorHex: "#FF0000")
        list.defaultDueDateRule = .today
        context.insert(list)
        try context.save()
    }

    @Test("Add Task reloads the widgets once the task is saved")
    @MainActor
    func createTaskReloadsWidgets() async throws {
        let container = try makeContainer()
        try insertList(container.mainContext)
        clearStoredList()
        defer { clearStoredList() }

        var reloads = 0
        let intent = CreateTaskIntent()
        intent.taskTitle = "Call the dentist"
        _ = try await intent.performWithContainer(container, onWidgetReload: { reloads += 1 })

        #expect(reloads == 1)
    }

    @Test("Quick Add reloads the widgets once the task is saved")
    @MainActor
    func quickAddReloadsWidgets() async throws {
        let container = try makeContainer()
        try insertList(container.mainContext)
        clearStoredList()
        defer { clearStoredList() }

        var reloads = 0
        let intent = QuickAddTaskIntent()
        intent.text = "Buy milk"
        _ = try await intent.performWithContainer(container, onWidgetReload: { reloads += 1 })

        #expect(reloads == 1)
    }

    @Test("An add that fails reloads nothing")
    @MainActor
    func failedAddDoesNotReload() async throws {
        // No lists at all: the add throws before anything is saved.
        let container = try makeContainer()
        clearStoredList()
        defer { clearStoredList() }

        var reloads = 0
        let intent = CreateTaskIntent()
        intent.taskTitle = "Homeless task"
        await #expect(throws: IntentError.self) {
            _ = try await intent.performWithContainer(container, onWidgetReload: { reloads += 1 })
        }

        #expect(reloads == 0)
    }

    @Test("Siri saves reminder recovery work before refreshing widgets", arguments: [false, true])
    @MainActor
    func savesRecoveryBeforeWidgetReload(quickAdd: Bool) async throws {
        let container = try DAVSyncScenario.container()
        try insertList(container.mainContext)
        clearStoredList()
        defer { clearStoredList() }

        var reloads = 0
        let onReload = {
            reloads += 1
            do {
                // Inspect a separate context at the reload boundary, before reconciliation
                // can acknowledge anything. An interrupted intent must leave saved work.
                let saved = ModelContext(container)
                #expect(try saved.fetchCount(FetchDescriptor<TaskItem>()) == 1)
                #expect(try !ReminderSchedulingJournal.capture(in: saved).isEmpty)
            } catch {
                Issue.record(error)
            }
        }
        if quickAdd {
            let intent = QuickAddTaskIntent()
            intent.text = "Buy milk"
            _ = try await intent.performWithContainer(container, onWidgetReload: onReload)
        } else {
            let intent = CreateTaskIntent()
            intent.taskTitle = "Call the dentist"
            _ = try await intent.performWithContainer(container, onWidgetReload: onReload)
        }
        #expect(reloads == 1)
    }
}
