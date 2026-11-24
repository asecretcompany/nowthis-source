import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import NowThis

@Suite("Journal editor liveness", .serialized)
@MainActor
struct JournalEditorLivenessTests {
    @Test("A retained journal route cannot expose a deleted row, even in a reopened store", arguments: [false, true])
    func rejectsTombstone(reopen: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Journal.store")
        let original = try openStore(at: url)
        let context = original.mainContext
        let task = TaskItem(title: "Journal route task")
        let hidden = JournalEntry(title: "Deleted title marker", content: "Deleted content marker")
        let live = JournalEntry(title: "Live title marker", content: "Live content marker")
        context.insert(task)
        context.insert(hidden)
        context.insert(live)
        hidden.associatedTasks = [task]
        live.associatedTasks = [task]
        try context.save()

        let retainedID = hidden.id
        let liveID = live.id
        hidden.isDeletedLocally = true
        hidden.isDirty = true
        try context.save()

        let container = reopen ? try openStore(at: url) : original
        let reopened = container.mainContext
        let entries = try reopened.fetch(FetchDescriptor<JournalEntry>())
        let tombstone = try #require(entries.first { $0.id == retainedID })
        #expect(tombstone.modelContext != nil)
        #expect(tombstone.isDeletedLocally && tombstone.isDirty)
        #expect(try reopened.fetch(FetchDescriptor<TaskItem>()).first?.associatedJournals.count == 2)
        try await exerciseEditor(tombstone, in: container, mustOpen: false)
        let peer = try #require(entries.first { $0.id == liveID })
        try await exerciseEditor(peer, in: container, mustOpen: true)
    }

    @Test("Deleting an open journal in another context revokes the editor", arguments: [false, true])
    func revokesOpenRoute(hardDelete: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let entry = JournalEntry(title: "Live title marker", content: "Live content marker")
        context.insert(entry)
        try context.save()
        let id = entry.id
        try await exerciseEditor(entry, in: container, mustOpen: true, afterOpen: {
            let worker = ModelContext(container)
            let candidate = try #require(try worker.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })).first)
            if hardDelete { worker.delete(candidate) } else { candidate.isDeletedLocally = true }
            try worker.save()
        })
    }

    @Test("A pending local tombstone is already hidden from editor admission")
    func rejectsPendingDeletion() async throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let entry = JournalEntry(title: "Deleted title marker", content: "Deleted content marker")
        context.insert(entry)
        try context.save()
        entry.isDeletedLocally = true
        #expect(JournalVisibility.live([entry], in: context).isEmpty)
        try await exerciseEditor(entry, in: container, mustOpen: false)
    }

    @Test("One Link Tasks snapshot admits the journal once and reflects pending link changes")
    func linkTaskSnapshot() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        context.autosaveEnabled = false
        let entry = JournalEntry(title: "Membership snapshot")
        context.insert(entry)
        let tasks = (0..<128).map { index in
            let task = TaskItem(title: "Picker row \(index)")
            context.insert(task)
            return task
        }
        entry.associatedTasks = [tasks[4], tasks[84]]
        try context.save()

        var admissions = 0
        func resolve(_ entry: JournalEntry, _ context: ModelContext) -> JournalEntry? {
            admissions += 1
            return JournalVisibility.resolve(entry, in: context)
        }
        let first = try #require(JournalTaskLinks(entry: entry, in: context, resolve: resolve))
        #expect(tasks.filter { first.taskIDs.contains($0.persistentModelID) }.map(\.persistentModelID)
                == [tasks[4].persistentModelID, tasks[84].persistentModelID])
        #expect(admissions == 1)
        entry.associatedTasks = [tasks[15]]
        let changed = try #require(JournalTaskLinks(entry: entry, in: context, resolve: resolve))
        #expect(changed.taskIDs == [tasks[15].persistentModelID])
        #expect(admissions == 2)
        entry.isDeletedLocally = true
        #expect(JournalTaskLinks(entry: entry, in: context, resolve: resolve) == nil)
        #expect(admissions == 3)
    }

    private func openStore(at url: URL) throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func exerciseEditor(_ entry: JournalEntry, in container: ModelContainer, mustOpen: Bool,
                                afterOpen: (() throws -> Void)? = nil) async throws {
        let blockers = TaskLinkPresentationState()
        let probe = JournalRouteProbe()
        let root = NavigationStack {
            Color.clear.navigationDestination(isPresented: Binding(get: { probe.isPresented }, set: { probe.isPresented = $0 })) {
                JournalEditorView(mode: .edit(entry))
            }
        }
        .modelContainer(container)
        .environment(\.taskLinkPresentations, blockers)
        let controller = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await settle(window)
        probe.isPresented = true
        try await settle(window)
        #expect(blockers.isBlocked == mustOpen)
        let texts = editorTexts(in: controller.view)
        if mustOpen {
            #expect(texts.contains("Live title marker"))
            #expect(texts.contains("Live content marker"))
            if let afterOpen {
                try afterOpen()
                try await settle(window)
                #expect(!blockers.isBlocked)
                #expect(!editorTexts(in: controller.view).contains("Live title marker"))
                #expect(!editorTexts(in: controller.view).contains("Live content marker"))
            }
        } else {
            #expect(!texts.contains("Deleted title marker"))
            #expect(!texts.contains("Deleted content marker"))
        }
    }

    private func settle(_ window: UIWindow) async throws {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
    }

    private func editorTexts(in view: UIView) -> [String] {
        var values: [String] = []
        if let field = view as? UITextField, let text = field.text { values.append(text) }
        if let field = view as? UITextView, let text = field.text { values.append(text) }
        return values + view.subviews.flatMap { editorTexts(in: $0) }
    }
}

@MainActor
@Observable
private final class JournalRouteProbe {
    var isPresented = false
}
