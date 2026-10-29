import Foundation
import SwiftData

/// Opens a deterministic, app-local store for Release UI performance journeys.
/// The app calls this before opening its regular store; a `nil` result keeps the
/// existing store path unchanged.
@MainActor
enum PerformanceLaunchFixture {
    private static let taskCountArgument = "-performance-task-count"
    private static let listCountArgument = "-performance-list-count"
    private static let resetArgument = "-performance-fixture-reset"

    static var isEnabled: Bool {
        #if NOWTHIS_PERFORMANCE_FIXTURES
        ProcessInfo.processInfo.arguments.contains(taskCountArgument)
        #else
        false
        #endif
    }

    static func openIfRequested() throws -> ModelContainer? {
        #if NOWTHIS_PERFORMANCE_FIXTURES
        guard isEnabled else { return nil }
        return try openFixtureStore()
        #else
        return nil
        #endif
    }

    #if NOWTHIS_PERFORMANCE_FIXTURES
    private static func openFixtureStore() throws -> ModelContainer {
        let arguments = ProcessInfo.processInfo.arguments
        let taskCount = try integerArgument(taskCountArgument, in: arguments, default: 10_000)
        let listCount = try integerArgument(listCountArgument, in: arguments, default: 100)
        guard (1...50_000).contains(taskCount), (1...100).contains(listCount) else {
            throw FixtureError.invalidCounts(taskCount: taskCount, listCount: listCount)
        }

        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let profileDirectory = documentsURL
            .appendingPathComponent("PerformanceFixture-\(taskCount)-\(listCount)", isDirectory: true)
        let storeURL = profileDirectory.appendingPathComponent("Performance.store")
        let seedMarkerURL = profileDirectory.appendingPathComponent("seed-complete")

        if arguments.contains(resetArgument) {
            try removeItemIfExists(profileDirectory, using: fileManager)
        } else if fileManager.fileExists(atPath: storeURL.path),
                  !fileManager.fileExists(atPath: seedMarkerURL.path) {
            // Recover cleanly from an interrupted first seed.
            try removeItemIfExists(profileDirectory, using: fileManager)
        }
        try fileManager.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )

        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(
            "PerformanceFixture",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])

        if !fileManager.fileExists(atPath: seedMarkerURL.path) {
            try seed(container: container, taskCount: taskCount, listCount: listCount)
            try Data("ready".utf8).write(to: seedMarkerURL, options: .atomic)
        }
        return container
    }

    private static func removeItemIfExists(_ url: URL, using fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func integerArgument(
        _ name: String,
        in arguments: [String],
        default defaultValue: Int
    ) throws -> Int {
        guard let position = arguments.firstIndex(of: name) else { return defaultValue }
        guard arguments.indices.contains(position + 1),
              let value = Int(arguments[position + 1]) else {
            throw FixtureError.invalidArgument(name)
        }
        return value
    }

    private static func seed(
        container: ModelContainer,
        taskCount: Int,
        listCount: Int
    ) throws {
        let context = ModelContext(container)
        let account = ServerAccount(vaultDisplayName: "Performance Vault")
        context.insert(account)

        var lists: [TaskList] = []
        lists.reserveCapacity(listCount)
        for index in 0..<listCount {
            let list = TaskList(
                id: "performance-fixture-list-\(index)",
                serverURL: "nowthis://performance-fixture/\(index)",
                name: String(format: "Fixture list %03d", index),
                colorHex: "#007AFF"
            )
            list.account = account
            context.insert(list)
            lists.append(list)
        }

        let today = Calendar.current.startOfDay(for: Date())
        let statuses: [TaskStatus] = [.needsAction, .inProcess, .completed]
        let priorities: [TaskPriority] = [.high, .medium, .low, .none]
        for index in 0..<taskCount {
            let task = TaskItem(
                id: String(format: "performance-fixture-task-%08d", index),
                uid: "performance-fixture-uid-\(index)",
                title: String(format: "Fixture task %05d", index)
            )
            task.taskList = lists[index % listCount]
            task.createdDate = today
            task.lastModifiedDate = today
            task.status = statuses[index % statuses.count]
            task.priority = priorities[(index / 2) % priorities.count]
            if index.isMultiple(of: 2) {
                task.dueDate = Calendar.current.date(byAdding: .hour, value: 12, to: today)
            } else {
                let daysAhead = 1 + ((index / 2) % 7)
                task.dueDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: today)
            }
            task.isDueDateOnly = true
            if task.status == .completed {
                task.percentComplete = 100
                task.completedDate = today
            }
            context.insert(task)

            if (index + 1).isMultiple(of: 1_000) {
                try context.save()
            }
        }

        let journal = JournalEntry(
            id: "performance-fixture-journal-00000",
            uid: "performance-fixture-journal-uid-00000",
            title: "Fixture journal 00000",
            content: "Deterministic performance fixture journal entry."
        )
        journal.taskList = lists[0]
        context.insert(journal)
        try context.save()
    }

    private enum FixtureError: Error {
        case invalidArgument(String)
        case invalidCounts(taskCount: Int, listCount: Int)
    }

    #endif
}
