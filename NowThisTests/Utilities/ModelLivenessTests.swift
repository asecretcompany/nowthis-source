import SwiftData
import Testing
@testable import NowThis

@Suite("Cross-context collection liveness")
@MainActor
struct ModelLivenessTests {
    @Test("Deleted lists and journals are excluded before their attributes are touched")
    func deletedModelsAreExcluded() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list)
        let journal = JournalEntry(title: "Journal")
        main.insert(journal); try main.save()
        let background = ModelContext(container)
        for model in try background.fetch(FetchDescriptor<TaskList>()) { background.delete(model) }
        for model in try background.fetch(FetchDescriptor<JournalEntry>()) { background.delete(model) }
        try background.save()
        #expect(TaskListHelpers.liveModels([list], in: main).isEmpty)
        #expect(TaskListHelpers.liveModels([journal], in: main).isEmpty)
        let pending = TaskList(serverURL: "/pending/", name: "Pending", colorHex: "#007AFF")
        main.insert(pending)
        #expect(TaskListHelpers.liveModels([pending], in: main).map(\.id) == [pending.id])
        withExtendedLifetime(container) {}
    }
}
