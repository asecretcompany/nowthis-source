import Foundation
import SwiftData
@testable import NowThis

/// Deterministic, in-memory SwiftData workloads for sync and display profiling.
/// Keep the returned fixture alive for the entire measurement so its container and context stay open.
@MainActor
struct PerformanceFixture {
    static let nestedTaskCount = 1_650
    static let distributedTaskCount = 10_000
    static let distributedListCount = 100
    static let distributedTasksPerList = distributedTaskCount / distributedListCount
    static let stressTaskCount = 50_000
    static let calendarWeekTaskCount = 1_000
    static let timeZone = TimeZone(secondsFromGMT: 0)!

    let container: ModelContainer
    let context: ModelContext

    static var calendarWeekStart: Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
    }

    static func taskID(index: Int) -> String {
        String(format: "performance-task-%08d", index)
    }

    static func seedNestedTasks() throws -> PerformanceFixture {
        let fixture = try makeEmpty()
        let list = makeList(index: 0)
        fixture.context.insert(list)

        var tasks: [TaskItem] = []
        tasks.reserveCapacity(nestedTaskCount)
        for index in 0..<nestedTaskCount {
            let task = makeTask(index: index, list: list)
            if index > 0 {
                task.parentTask = tasks[(index - 1) / 2]
            }
            fixture.context.insert(task)
            tasks.append(task)
        }

        try fixture.context.save()
        return fixture
    }

    static func seedDistributedTasks() throws -> PerformanceFixture {
        try seedFlatTasks(
            taskCount: distributedTaskCount,
            listCount: distributedListCount,
            profile: "distributed"
        )
    }

    static func seedSingleListTasks() throws -> PerformanceFixture {
        try seedFlatTasks(
            taskCount: distributedTaskCount,
            listCount: 1,
            profile: "single-list"
        )
    }

    static func seedStressTasks() throws -> PerformanceFixture {
        try seedFlatTasks(
            taskCount: stressTaskCount,
            listCount: distributedListCount,
            profile: "stress"
        )
    }

    static func seedCalendarWeekTasks() throws -> PerformanceFixture {
        let fixture = try makeEmpty()
        let list = makeList(index: 0, profile: "calendar-week")
        fixture.context.insert(list)

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        for index in 0..<calendarWeekTaskCount {
            let day = index % 7
            let dueDate = calendar.date(byAdding: .day, value: day, to: calendarWeekStart)!
            let task = makeTask(index: index, list: list, profile: "calendar-week")
            task.dueDate = dueDate.addingTimeInterval(TimeInterval((index / 7) * 60))
            fixture.context.insert(task)
        }

        try fixture.context.save()
        return fixture
    }

    /// Builds a stable VTODO containing a base64 attachment with exactly `binaryByteCount` bytes.
    static func largeAttachmentICS(binaryByteCount: Int = 16 * 1024) -> String {
        precondition(binaryByteCount >= 0)
        let attachment = Data(repeating: 0x41, count: binaryByteCount).base64EncodedString()
        return [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//NowThis//Performance Fixture//EN",
            "BEGIN:VTODO",
            "UID:performance-attachment-fixture",
            "DTSTAMP:20261005T120000Z",
            "SUMMARY:Attachment performance fixture",
            "ATTACH;ENCODING=BASE64;VALUE=BINARY:\(attachment)",
            "END:VTODO",
            "END:VCALENDAR",
            ""
        ].joined(separator: "\r\n")
    }

    private static func seedFlatTasks(
        taskCount: Int,
        listCount: Int,
        profile: String
    ) throws -> PerformanceFixture {
        precondition(taskCount >= 0 && listCount > 0)
        let fixture = try makeEmpty()
        var lists: [TaskList] = []
        lists.reserveCapacity(listCount)
        for index in 0..<listCount {
            let list = makeList(index: index, profile: profile)
            fixture.context.insert(list)
            lists.append(list)
        }

        for index in 0..<taskCount {
            let list = lists[index % listCount]
            fixture.context.insert(makeTask(index: index, list: list, profile: profile))
        }

        try fixture.context.save()
        return fixture
    }

    private static func makeEmpty() throws -> PerformanceFixture {
        let container = try ModelContainer(
            for: TaskItem.self,
                TaskList.self,
                JournalEntry.self,
                Tag.self,
                ServerAccount.self,
                SyncMetadata.self,
                SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return PerformanceFixture(container: container, context: ModelContext(container))
    }

    private static func makeList(index: Int, profile: String = "nested") -> TaskList {
        TaskList(
            id: "performance-\(profile)-list-\(index)",
            serverURL: "https://performance.invalid/\(profile)",
            name: "Performance \(profile) \(index)",
            colorHex: "#007AFF"
        )
    }

    private static func makeTask(
        index: Int,
        list: TaskList,
        profile: String = "nested"
    ) -> TaskItem {
        let task = TaskItem(
            id: taskID(index: index),
            uid: "\(profile)-uid-\(index)",
            title: "\(profile) task \(index)"
        )
        task.taskList = list
        task.createdDate = calendarWeekStart
        task.lastModifiedDate = calendarWeekStart
        task.status = TaskStatus.allCases[index % TaskStatus.allCases.count]
        task.priority = TaskPriority.allCases[index % TaskPriority.allCases.count]
        task.descriptionText = index.isMultiple(of: 3) ? "Deterministic performance fixture notes." : nil
        task.dueDate = index.isMultiple(of: 4)
            ? calendarWeekStart.addingTimeInterval(TimeInterval(index % 86_400))
            : nil
        if task.status == .completed {
            task.completedDate = calendarWeekStart.addingTimeInterval(TimeInterval(index % 86_400))
            task.percentComplete = 100
        }
        return task
    }
}
