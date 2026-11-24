import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Widget Configuration Tests

@Suite("WidgetConfiguration")
struct WidgetConfigurationTests {
    @Test("Widget candidate bounds preserve fixed DST and extreme-zone results")
    @MainActor
    func candidateBoundsRespectInjectedCalendar() throws {
        let cases = [("America/Los_Angeles", 3, 8), ("America/Los_Angeles", 11, 1),
                     ("Europe/Berlin", 3, 29), ("Europe/Berlin", 10, 25),
                     ("Australia/Lord_Howe", 4, 5), ("Australia/Lord_Howe", 10, 4),
                     ("Etc/GMT-14", 11, 3), ("Etc/GMT+12", 11, 3)]
        for (zone, month, day) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let now = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
            let start = calendar.startOfDay(for: now)
            let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: start))
            let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: start))
            let container = try makeContainer(); let context = container.mainContext
            let list = TaskList(serverURL: "", name: "Selected", colorHex: "#FF0000")
            let other = TaskList(serverURL: "", name: "Other", colorHex: "#FF0000")
            context.insert(list); context.insert(other)
            func task(_ title: String, _ due: Date, allDay: Bool = false, otherList: Bool = false) -> TaskItem {
                let value = TaskItem(title: title)
                value.taskList = otherList ? other : list; value.dueDate = due
                value.isDueDateOnly = allDay; context.insert(value); return value
            }
            let allDay = task("All day", DueDateHelper.dateOnlyValue(for: now, calendar: calendar), allDay: true)
            let timed = task("Timed today", now)
            let old = task("Yesterday", DueDateHelper.dateOnlyValue(for: yesterday, calendar: calendar), allDay: true)
            _ = task("Tomorrow all day", DueDateHelper.dateOnlyValue(for: tomorrow, calendar: calendar), allDay: true)
            _ = task("Tomorrow midnight", tomorrow)
            let completed = task("Completed", now); completed.status = .completed
            let otherTask = task("Other list today", now.addingTimeInterval(60), otherList: true)
            try context.save()
            for overdue in [false, true] {
                for selectedOnly in [false, true] {
                    var expected = [allDay, timed]
                    if overdue { expected.append(old) }
                    if !selectedOnly { expected.append(otherTask) }
                    expected.sort { $0.dueDate! < $1.dueDate! }
                    let result = try SelectListsIntent.fetchFilteredTasks(listIDs: selectedOnly ? [list.id] : [],
                        maxTasks: 10, showOverdue: overdue, container: container, now: now, calendar: calendar)
                    #expect(result.tasks.map(\.id) == expected.map(\.id), "\(zone), overdue=\(overdue), selected=\(selectedOnly)")
                }
            }
        }
    }

    @Test("Portrait candidates keep the first twenty eligible IDs across the spring DST boundary")
    @MainActor
    func portraitCandidateLimitPreservesOrdering() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-03-08T18:00:00Z"))
        let localMidnight = try #require(formatter.date(from: "2026-03-08T08:00:00Z"))
        let nextLocalMidnight = try #require(formatter.date(from: "2026-03-09T07:00:00Z"))
        let utcMidnight = try #require(formatter.date(from: "2026-03-08T00:00:00Z"))

        let container = try makeContainer()
        let context = container.mainContext
        let selected = TaskList(serverURL: "", name: "Selected", colorHex: "#FF0000")
        let other = TaskList(serverURL: "", name: "Other", colorHex: "#0000FF")
        context.insert(selected)
        context.insert(other)

        func insertTask(_ title: String, due: Date, list: TaskList) -> TaskItem {
            let task = TaskItem(title: title)
            task.dueDate = due
            task.taskList = list
            context.insert(task)
            return task
        }

        let allDay = insertTask("All day today", due: utcMidnight, list: selected)
        allDay.isDueDateOnly = true
        let overdue = insertTask("Timed yesterday", due: localMidnight.addingTimeInterval(-1), list: selected)
        let timed = (1...23).map { minute in
            insertTask("Timed \(minute)", due: localMidnight.addingTimeInterval(Double(minute * 60)), list: selected)
        }
        let lateToday = insertTask("Last second of today", due: nextLocalMidnight.addingTimeInterval(-1), list: selected)
        _ = insertTask("Start of tomorrow", due: nextLocalMidnight, list: selected)
        _ = insertTask("Different list", due: localMidnight, list: other)
        insertTask("Completed today", due: localMidnight, list: selected).status = .completed
        insertTask("Tombstone today", due: localMidnight, list: selected).isDeletedLocally = true
        try context.save()

        for showOverdue in [false, true] {
            let expected = [allDay] + (showOverdue ? [overdue] : []) + timed + [lateToday]
            let bounded = try SelectListsIntent.fetchFilteredTasks(
                listIDs: [selected.id], maxTasks: WidgetDisplayPolicy.portraitCandidateLimit,
                showOverdue: showOverdue, container: container, now: now, calendar: calendar
            )
            #expect(bounded.tasks.count == 20)
            #expect(bounded.tasks.map(\.id) == expected.prefix(20).map(\.id))
            #expect(bounded.tasks.first?.isDueDateOnly == true)
            #expect(bounded.displayName == "Selected")

            let allEligible = try SelectListsIntent.fetchFilteredTasks(
                listIDs: [selected.id], maxTasks: 30,
                showOverdue: showOverdue, container: container, now: now, calendar: calendar
            )
            #expect(allEligible.tasks.map(\.id) == expected.map(\.id))
        }
    }

    @Test("Widget candidate pages exclude unrelated lists and future rows")
    @MainActor
    func scopedCandidateWork() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let selected = TaskList(serverURL: "", name: "Selected", colorHex: "#FF0000")
        let other = TaskList(serverURL: "", name: "Other", colorHex: "#FF0000")
        context.insert(selected); context.insert(other)
        let now = Date()
        let future = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        for index in 0..<1000 {
            let task = TaskItem(title: "Unrelated \(index)")
            task.taskList = index.isMultiple(of: 2) ? other : selected
            task.dueDate = index.isMultiple(of: 2) ? now : future
            context.insert(task)
        }
        let eligible = TaskItem(title: "Eligible")
        eligible.taskList = selected; eligible.dueDate = now
        context.insert(eligible)
        try context.save()
        var pages: [Int] = []
        let result = try SelectListsIntent.fetchFilteredTasks(listIDs: [selected.id], maxTasks: 3,
            container: container, now: now, onCandidatePage: { pages.append($0) })
        #expect(result.tasks.map(\.id) == [eligible.id])
        #expect(pages.reduce(0, +) == 1)
        #expect(pages.allSatisfy { $0 <= 128 })
    }

    @Test("Widget pages continue beyond completed candidates and preserve time ordering")
    @MainActor
    func pagesContinuePastExcludedRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        for index in 0..<260 {
            let task = TaskItem(title: "Completed \(index)", status: .completed)
            task.taskList = list; task.dueDate = start.addingTimeInterval(Double(index))
            context.insert(task)
        }
        let first = TaskItem(title: "First"); first.taskList = list
        first.dueDate = start.addingTimeInterval(1000)
        let second = TaskItem(title: "Second"); second.taskList = list
        second.dueDate = start.addingTimeInterval(2000)
        context.insert(first); context.insert(second); try context.save()
        var pages: [Int] = []
        let result = try SelectListsIntent.fetchFilteredTasks(listIDs: [list.id], maxTasks: 2,
            container: container, now: now, onCandidatePage: { pages.append($0) })
        #expect(result.tasks.map(\.id) == [first.id, second.id])
        #expect(pages.allSatisfy { $0 <= 128 })
        #expect(pages.count >= 3)
    }

    @Test("Selected list header survives empty results and zero candidate limit")
    @MainActor
    func selectedListHeaderSurvivesEmptyResults() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let work = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(work)

        let future = TaskItem(title: "Future task")
        future.taskList = work
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        future.dueDate = now.addingTimeInterval(30 * 24 * 60 * 60)
        context.insert(future)
        try context.save()

        var zeroLimitPages: [Int] = []
        let zeroLimit = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [work.id], maxTasks: 0, container: container, now: now,
            onCandidatePage: { zeroLimitPages.append($0) })
        #expect(zeroLimit.tasks.isEmpty)
        #expect(zeroLimitPages.isEmpty, "A zero result limit should not fetch candidate pages")
        #expect(zeroLimit.displayName == "Work")

        let noQualifyingRows = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [work.id], maxTasks: 10, container: container, now: now)
        #expect(noQualifyingRows.tasks.isEmpty)
        #expect(noQualifyingRows.displayName == "Work")

        let missingID = try SelectListsIntent.fetchFilteredTasks(
            listIDs: ["missing-list-id"], maxTasks: 0, container: container, now: now)
        let fallback = try LocalizationCatalogFixture.rendering(
            ofKey: "widget.header.fallback", inCatalogAt: "NowThis/Localizable.xcstrings")
        #expect(missingID.tasks.isEmpty)
        #expect(missingID.displayName == fallback)
    }

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    // MARK: - All Lists (no filter)

    @Test("Returns all tasks when no lists selected")
    @MainActor
    func allTasksWhenNoFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(list1)
        context.insert(list2)

        let task1 = TaskItem(title: "Work task")
        task1.dueDate = Date()
        task1.taskList = list1
        context.insert(task1)

        let task2 = TaskItem(title: "Home task")
        task2.dueDate = Date()
        task2.taskList = list2
        context.insert(task2)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 2)
        // Resolved through the app bundle, not hardcoded English: this assertion compared
        // runtime output to "All Lists" and failed as "Alle Listen" the first time the
        // suite was run on a German simulator.
        let expected = try LocalizationCatalogFixture.rendering(
            ofKey: "widget.header.allLists", inCatalogAt: "NowThis/Localizable.xcstrings")
        #expect(result.displayName == expected)
    }

    // MARK: - Single list filter

    @Test("Returns only tasks from selected list")
    @MainActor
    func singleListFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let workList = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let homeList = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(workList)
        context.insert(homeList)

        let workTask = TaskItem(title: "Work task")
        workTask.dueDate = Date()
        workTask.taskList = workList
        context.insert(workTask)

        let homeTask = TaskItem(title: "Home task")
        homeTask.dueDate = Date()
        homeTask.taskList = homeList
        context.insert(homeTask)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [workList.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Work task")
        #expect(result.displayName == "Work")
    }

    // MARK: - Multi list filter

    @Test("Returns tasks from multiple selected lists")
    @MainActor
    func multiListFilter() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        let list3 = TaskList(serverURL: "", name: "Shopping", colorHex: "#0000FF")
        context.insert(list1)
        context.insert(list2)
        context.insert(list3)

        let t1 = TaskItem(title: "Work task")
        t1.dueDate = Date()
        t1.taskList = list1
        context.insert(t1)

        let t2 = TaskItem(title: "Home task")
        t2.dueDate = Date()
        t2.taskList = list2
        context.insert(t2)

        let t3 = TaskItem(title: "Shopping task")
        t3.dueDate = Date()
        t3.taskList = list3
        context.insert(t3)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list1.id, list2.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 2)
        let titles = Set(result.tasks.map(\.title))
        #expect(titles.contains("Work task"))
        #expect(titles.contains("Home task"))
        #expect(!titles.contains("Shopping task"))
    }

    // MARK: - Excludes deleted tasks

    @Test("Excludes soft-deleted tasks from results")
    @MainActor
    func excludesDeletedTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let active = TaskItem(title: "Active task")
        active.dueDate = Date()
        active.taskList = list
        context.insert(active)

        let deleted = TaskItem(title: "Deleted task")
        deleted.dueDate = Date()
        deleted.taskList = list
        deleted.isDeletedLocally = true
        context.insert(deleted)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Active task")
    }

    // MARK: - Respects maxTasks limit

    @Test("Respects maxTasks limit")
    @MainActor
    func respectsMaxTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Big", colorHex: "#FF0000")
        context.insert(list)

        for i in 1...10 {
            let task = TaskItem(title: "Task \(i)")
            task.dueDate = Date()
            task.taskList = list
            context.insert(task)
        }

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 3,
            container: container
        )

        #expect(result.tasks.count == 3)
    }

    // MARK: - Display name for multiple lists

    @Test("Display name shows comma-separated list names for multi-select")
    @MainActor
    func displayNameMultiSelect() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list1 = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        let list2 = TaskList(serverURL: "", name: "Home", colorHex: "#00FF00")
        context.insert(list1)
        context.insert(list2)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list1.id, list2.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.displayName.contains("Work"))
        #expect(result.displayName.contains("Home"))
    }

    // MARK: - Due date sorting

    @Test("Overdue tasks sort before today's tasks with showOverdue")
    @MainActor
    func dueDateTasksSortFirst() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let overdue = TaskItem(title: "Overdue task")
        overdue.dueDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        overdue.taskList = list
        context.insert(overdue)

        let todayLater = TaskItem(title: "Today later")
        todayLater.dueDate = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date())
        todayLater.taskList = list
        context.insert(todayLater)

        let todayEarlier = TaskItem(title: "Today earlier")
        todayEarlier.dueDate = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())
        todayEarlier.taskList = list
        context.insert(todayEarlier)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            showOverdue: true,
            container: container
        )

        #expect(result.tasks.count == 3)
        // Sorted by soonest first: overdue, today earlier, today later
        #expect(result.tasks[0].title == "Overdue task")
        #expect(result.tasks[1].title == "Today earlier")
        #expect(result.tasks[2].title == "Today later")
    }

    @Test("Widget respects maxTasks limit with today's tasks")
    @MainActor
    func dueDateTasksFillLimitFirst() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        // Create 5 tasks due today
        for i in 1...5 {
            let task = TaskItem(title: "Today \(i)")
            task.dueDate = Date()
            task.taskList = list
            context.insert(task)
        }

        try context.save()

        // Limit to 3 — should get only 3 of the 5 today tasks
        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 3,
            container: container
        )

        #expect(result.tasks.count == 3)
    }

    // MARK: - Excludes completed tasks

    @Test("Excludes completed tasks from widget results")
    @MainActor
    func excludesCompletedTasks() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "", name: "Work", colorHex: "#FF0000")
        context.insert(list)

        let active = TaskItem(title: "Active task")
        active.dueDate = Date()
        active.taskList = list
        context.insert(active)

        let completed = TaskItem(title: "Completed task", status: .completed)
        completed.dueDate = Date()
        completed.taskList = list
        context.insert(completed)

        try context.save()

        let result = try SelectListsIntent.fetchFilteredTasks(
            listIDs: [list.id],
            maxTasks: 10,
            container: container
        )

        #expect(result.tasks.count == 1)
        #expect(result.tasks.first?.title == "Active task")
    }
}
