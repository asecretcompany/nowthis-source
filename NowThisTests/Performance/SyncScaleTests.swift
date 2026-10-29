import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct SyncScaleTests {
    @Test("nested performance fixture stores exactly 1,650 tasks and their hierarchy")
    func nestedFixtureHasExactCountAndRelationships() throws {
        let fixture = try PerformanceFixture.seedNestedTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())
        let roots = tasks.filter { $0.parentTask == nil }

        #expect(tasks.count == PerformanceFixture.nestedTaskCount)
        #expect(lists.count == 1)
        #expect(roots.count == 1)
        #expect(tasks.filter { $0.parentTask != nil }.count == tasks.count - 1)
        #expect(roots[0].subtasks.count == 2)
        #expect(tasks.allSatisfy { $0.taskList?.id == lists[0].id })

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for index in 1..<tasks.count {
            let expectedParentID = PerformanceFixture.taskID(index: (index - 1) / 2)
            #expect(tasksByID[PerformanceFixture.taskID(index: index)]?.parentTask?.id == expectedParentID)
        }
        withExtendedLifetime(fixture) {}
    }

    @Test("distributed performance fixture stores exactly 10,000 tasks across 100 lists")
    func distributedFixtureHasExactCountsAndRelationships() throws {
        let fixture = try PerformanceFixture.seedDistributedTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())
        let countsByList = Dictionary(grouping: tasks, by: { $0.taskList?.id }).mapValues(\.count)

        #expect(tasks.count == PerformanceFixture.distributedTaskCount)
        #expect(lists.count == PerformanceFixture.distributedListCount)
        #expect(countsByList.count == PerformanceFixture.distributedListCount)
        #expect(countsByList.values.allSatisfy { $0 == PerformanceFixture.distributedTasksPerList })
        #expect(tasks.allSatisfy { $0.parentTask == nil })
        withExtendedLifetime(fixture) {}
    }

    @Test("single-list performance fixture stores exactly 10,000 tasks in one list")
    func singleListFixtureHasExactCountAndRelationships() throws {
        let fixture = try PerformanceFixture.seedSingleListTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())

        #expect(tasks.count == PerformanceFixture.distributedTaskCount)
        #expect(lists.count == 1)
        #expect(tasks.allSatisfy { $0.taskList?.id == lists[0].id })
        withExtendedLifetime(fixture) {}
    }

    @Test("calendar week fixture stores 1,000 tasks with dates in each ISO week day")
    func calendarWeekFixtureHasExactDatedTasks() throws {
        let fixture = try PerformanceFixture.seedCalendarWeekTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let dates = try #require(tasks.compactMap(\.dueDate).sorted().first)
        let weekStart = PerformanceFixture.calendarWeekStart
        let weekEnd = try #require(Calendar(identifier: .iso8601).date(byAdding: .day, value: 7, to: weekStart))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = PerformanceFixture.timeZone
        let dayCounts = Dictionary(grouping: tasks.compactMap(\.dueDate), by: { calendar.startOfDay(for: $0) })

        #expect(tasks.count == PerformanceFixture.calendarWeekTaskCount)
        #expect(dates >= weekStart)
        #expect(tasks.allSatisfy { task in
            guard let dueDate = task.dueDate else { return false }
            return dueDate >= weekStart && dueDate < weekEnd
        })
        #expect(dayCounts.count == 7)
        #expect(dayCounts.values.map(\.count).sorted() == [142, 143, 143, 143, 143, 143, 143])
        withExtendedLifetime(fixture) {}
    }

    @Test("attachment fixture emits deterministic ICS with the requested binary payload size")
    func attachmentPayloadHasRequestedSize() {
        let payload = PerformanceFixture.largeAttachmentICS(binaryByteCount: 16 * 1024)
        let expectedAttachment = Data(repeating: 0x41, count: 16 * 1024).base64EncodedString()

        #expect(payload.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//NowThis//Performance Fixture//EN\r\nBEGIN:VTODO\r\n"))
        #expect(payload.contains("ATTACH;ENCODING=BASE64;VALUE=BINARY:\(expectedAttachment)\r\n"))
        #expect(payload.hasSuffix("END:VTODO\r\nEND:VCALENDAR\r\n"))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NOWTHIS_PERFORMANCE_STRESS"] == "1",
        "Set NOWTHIS_PERFORMANCE_STRESS=1 to run the optional 50,000-task stress case"
    ))
    func optionalStressFixtureStoresExactly50000Tasks() throws {
        let fixture = try PerformanceFixture.seedStressTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())

        #expect(tasks.count == PerformanceFixture.stressTaskCount)
        withExtendedLifetime(fixture) {}
    }
}
