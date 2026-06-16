import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("Migration Plan")
struct MigrationPlanTests {

    @Test("ModelContainer initializes without migration plan")
    func containerInitializesWithoutMigrationPlan() throws {
        let schema = Schema(SchemaV2.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ]
        )
        #expect(container.schema.entities.count > 0)
    }

    @Test("Current schema includes all 7 model types")
    func schemaIncludesAllModels() {
        let modelTypes = SchemaV2.models
        #expect(modelTypes.count == 7)

        let names = modelTypes.map { String(describing: $0) }
        #expect(names.contains("TaskItem"))
        #expect(names.contains("TaskList"))
        #expect(names.contains("JournalEntry"))
        #expect(names.contains("Tag"))
        #expect(names.contains("ServerAccount"))
        #expect(names.contains("SyncMetadata"))
        #expect(names.contains("SavedFilter"))
    }

    @Test("Deprecated migration plan has no schemas")
    func migrationPlanSchemaOrder() {
        let schemas = NowThisMigrationPlan.schemas
        #expect(schemas.count == 0)
    }

    @Test("Deprecated migration plan has no stages")
    func migrationPlanHasNoStages() {
        #expect(NowThisMigrationPlan.stages.count == 0)
    }

    @Test("Can insert and fetch a task without migration plan")
    func canInsertAndFetchTask() throws {
        let schema = Schema(SchemaV2.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ]
        )
        let context = ModelContext(container)

        let task = TaskItem(title: "Migration test task")
        context.insert(task)
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Migration test task")
    }
}
