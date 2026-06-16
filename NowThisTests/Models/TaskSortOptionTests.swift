import Testing
import Foundation

@testable import NowThis

// MARK: - TaskSortOption Tests

@Suite("TaskSortOption")
struct TaskSortOptionTests {

    // MARK: - Due Date Sort

    @Test("Sort by due date ascending puts earlier dates first")
    func sortDueDateAscending() {
        let task1 = TaskItem(title: "Early")
        task1.dueDate = Date(timeIntervalSinceNow: -3600) // 1 hour ago

        let task2 = TaskItem(title: "Later")
        task2.dueDate = Date(timeIntervalSinceNow: 3600) // 1 hour ahead

        let task3 = TaskItem(title: "No due date")

        let sorted = [task3, task2, task1].sorted(
            by: TaskSortOption.dueDate.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Early")
        #expect(sorted[1].title == "Later")
        #expect(sorted[2].title == "No due date")
    }

    @Test("Sort by due date descending puts later dates first")
    func sortDueDateDescending() {
        let task1 = TaskItem(title: "Early")
        task1.dueDate = Date(timeIntervalSinceNow: -3600)

        let task2 = TaskItem(title: "Later")
        task2.dueDate = Date(timeIntervalSinceNow: 3600)

        let sorted = [task1, task2].sorted(
            by: TaskSortOption.dueDate.comparator(ascending: false)
        )

        #expect(sorted[0].title == "Later")
        #expect(sorted[1].title == "Early")
    }

    // MARK: - Priority Sort

    @Test("Sort by priority ascending puts highest priority first")
    func sortPriorityAscending() {
        let high = TaskItem(title: "Urgent", priority: .high)
        let low = TaskItem(title: "Chill", priority: .low)
        let medium = TaskItem(title: "Normal", priority: .medium)

        let sorted = [low, high, medium].sorted(
            by: TaskSortOption.priority.comparator(ascending: true)
        )

        // .high rawValue=1, .medium=5, .low=9
        #expect(sorted[0].title == "Urgent")
        #expect(sorted[1].title == "Normal")
        #expect(sorted[2].title == "Chill")
    }

    // MARK: - Title Sort

    @Test("Sort by title ascending is alphabetical")
    func sortTitleAscending() {
        let apple = TaskItem(title: "Apple")
        let banana = TaskItem(title: "Banana")
        let cherry = TaskItem(title: "Cherry")

        let sorted = [cherry, apple, banana].sorted(
            by: TaskSortOption.title.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Apple")
        #expect(sorted[1].title == "Banana")
        #expect(sorted[2].title == "Cherry")
    }

    @Test("Sort by title is case-insensitive")
    func sortTitleCaseInsensitive() {
        let lower = TaskItem(title: "apple")
        let upper = TaskItem(title: "BANANA")

        let sorted = [upper, lower].sorted(
            by: TaskSortOption.title.comparator(ascending: true)
        )

        #expect(sorted[0].title == "apple")
        #expect(sorted[1].title == "BANANA")
    }

    // MARK: - Created Date Sort

    @Test("Sort by created date ascending puts oldest first")
    func sortCreatedAscending() {
        let old = TaskItem(title: "Old")
        old.createdDate = Date(timeIntervalSinceNow: -86400)

        let recent = TaskItem(title: "Recent")
        recent.createdDate = Date()

        let sorted = [recent, old].sorted(
            by: TaskSortOption.createdDate.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Old")
        #expect(sorted[1].title == "Recent")
    }

    // MARK: - Modified Date Sort

    @Test("Sort by modified date descending puts most recent first")
    func sortModifiedDescending() {
        let old = TaskItem(title: "Stale")
        old.lastModifiedDate = Date(timeIntervalSinceNow: -86400)

        let fresh = TaskItem(title: "Fresh")
        fresh.lastModifiedDate = Date()

        let sorted = [old, fresh].sorted(
            by: TaskSortOption.modifiedDate.comparator(ascending: false)
        )

        #expect(sorted[0].title == "Fresh")
        #expect(sorted[1].title == "Stale")
    }

    @Test("Modified date falls back to created date when nil")
    func sortModifiedFallback() {
        let noMod = TaskItem(title: "No mod date")
        noMod.lastModifiedDate = nil
        noMod.createdDate = Date(timeIntervalSinceNow: -86400)

        let hasMod = TaskItem(title: "Has mod date")
        hasMod.lastModifiedDate = Date()

        let sorted = [noMod, hasMod].sorted(
            by: TaskSortOption.modifiedDate.comparator(ascending: false)
        )

        #expect(sorted[0].title == "Has mod date")
        #expect(sorted[1].title == "No mod date")
    }

    // MARK: - All Cases

    @Test("All sort options have icons")
    func allOptionsHaveIcons() {
        for option in TaskSortOption.allCases {
            #expect(!option.icon.isEmpty)
        }
    }

    @Test("All sort options have display names")
    func allOptionsHaveNames() {
        for option in TaskSortOption.allCases {
            #expect(!option.rawValue.isEmpty)
        }
    }

    // MARK: - Start Date Sort

    @Test("Sort by start date ascending puts earlier starts first")
    func sortStartDateAscending() {
        let early = TaskItem(title: "Early start")
        early.startDate = Date(timeIntervalSinceNow: -3600)

        let late = TaskItem(title: "Late start")
        late.startDate = Date(timeIntervalSinceNow: 3600)

        let noStart = TaskItem(title: "No start date")

        let sorted = [noStart, late, early].sorted(
            by: TaskSortOption.startDate.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Early start")
        #expect(sorted[1].title == "Late start")
        #expect(sorted[2].title == "No start date")
    }

    @Test("Sort by start date descending puts later starts first")
    func sortStartDateDescending() {
        let early = TaskItem(title: "Early start")
        early.startDate = Date(timeIntervalSinceNow: -3600)

        let late = TaskItem(title: "Late start")
        late.startDate = Date(timeIntervalSinceNow: 3600)

        let sorted = [early, late].sorted(
            by: TaskSortOption.startDate.comparator(ascending: false)
        )

        #expect(sorted[0].title == "Late start")
        #expect(sorted[1].title == "Early start")
    }

    // MARK: - Completed Date Sort

    @Test("Sort by completed date ascending puts earlier completions first")
    func sortCompletedDateAscending() {
        let first = TaskItem(title: "Done early")
        first.completedDate = Date(timeIntervalSinceNow: -7200)

        let second = TaskItem(title: "Done later")
        second.completedDate = Date(timeIntervalSinceNow: -3600)

        let notDone = TaskItem(title: "Not done")

        let sorted = [notDone, second, first].sorted(
            by: TaskSortOption.completedDate.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Done early")
        #expect(sorted[1].title == "Done later")
        #expect(sorted[2].title == "Not done")
    }

    // MARK: - Tags Sort

    @Test("Sort by tags ascending puts alphabetically earlier tag first")
    func sortTagsAscending() {
        let alpha = TaskItem(title: "Alpha tagged")
        alpha.tags = [Tag(name: "Alpha")]

        let beta = TaskItem(title: "Beta tagged")
        beta.tags = [Tag(name: "Beta")]

        let noTag = TaskItem(title: "No tags")

        let sorted = [noTag, beta, alpha].sorted(
            by: TaskSortOption.tags.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Alpha tagged")
        #expect(sorted[1].title == "Beta tagged")
        #expect(sorted[2].title == "No tags")
    }

    // MARK: - Relevance Sort

    @Test("Sort by relevance puts high-priority due-soon tasks first")
    func sortRelevanceAscending() {
        let urgentSoon = TaskItem(title: "Urgent soon", priority: .high)
        urgentSoon.dueDate = Date(timeIntervalSinceNow: 3600) // 1 hour

        let lowFar = TaskItem(title: "Low far", priority: .low)
        lowFar.dueDate = Date(timeIntervalSinceNow: 86400 * 7) // 7 days

        let mediumNoDue = TaskItem(title: "Medium no due", priority: .medium)

        let sorted = [lowFar, mediumNoDue, urgentSoon].sorted(
            by: TaskSortOption.relevance.comparator(ascending: true)
        )

        #expect(sorted[0].title == "Urgent soon")
        #expect(sorted[2].title == "Medium no due")
    }

    // MARK: - Manual Sort

    @Test("Sort manually uses manualSortOrder ascending")
    func sortManuallyAscending() {
        let first = TaskItem(title: "First")
        first.manualSortOrder = 0

        let second = TaskItem(title: "Second")
        second.manualSortOrder = 1

        let third = TaskItem(title: "Third")
        third.manualSortOrder = 2

        let sorted = [third, first, second].sorted(
            by: TaskSortOption.manually.comparator(ascending: true)
        )

        #expect(sorted[0].title == "First")
        #expect(sorted[1].title == "Second")
        #expect(sorted[2].title == "Third")
    }
}

// MARK: - SortDirection Tests

@Suite("SortDirection")
struct SortDirectionTests {

    @Test("Toggle changes direction")
    func toggle() {
        var dir = SortDirection.ascending
        dir.toggle()
        #expect(dir == .descending)
        dir.toggle()
        #expect(dir == .ascending)
    }

    @Test("isAscending reflects state")
    func isAscending() {
        #expect(SortDirection.ascending.isAscending == true)
        #expect(SortDirection.descending.isAscending == false)
    }
}
