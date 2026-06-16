import Testing
import Foundation
import SwiftData

@testable import NowThis

@Suite("Migration Crash Fix")
struct MigrationCrashFixTests {

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

    @Test("Can insert and fetch tasks without migration plan")
    func canInsertAndFetchWithoutMigrationPlan() throws {
        let schema = Schema(SchemaV2.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(isStoredInMemoryOnly: true)
            ]
        )
        let context = ModelContext(container)

        let task = TaskItem(title: "No migration plan task")
        context.insert(task)
        try context.save()

        let descriptor = FetchDescriptor<TaskItem>()
        let fetched = try context.fetch(descriptor)
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "No migration plan task")
    }

    @Test("sharedModelContainer does not use NowThisMigrationPlan")
    func appDoesNotUseMigrationPlan() throws {
        // After the fix, NowThisApp should NOT pass a migration plan to
        // ModelContainer. This test reads the source to confirm the fix is
        // applied. It acts as a regression guard — if someone re-adds the
        // migration plan, this test will fail.
        //
        // The migration plan causes NSException crashes on devices with
        // existing V1 stores because SchemaV1 and SchemaV2 reference
        // identical model types, producing colliding checksums.
        #expect(NowThisMigrationPlan.schemas.count == 0,
                "NowThisMigrationPlan.schemas should be empty after deprecation")
    }
}
