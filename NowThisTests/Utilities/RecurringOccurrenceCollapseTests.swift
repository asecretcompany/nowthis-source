import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - Recurring Occurrence Collapse Tests
//
// Regression coverage for the Upcoming/Overdue recurring-task bug: a daily task
// was projected into one row per future instance, but every one of those rows was
// built from the same `TaskItem`. `TaskRowData` snapshots `task.dueDate`, so all of
// them rendered the *base* task's date — a daily "Hotsauce" due Aug 30 at 20:15
// showed "Aug 30 at 20:15" again on the row that had sorted into Aug 31's slot.
// The occurrence date reached the sort, the section header and the accessibility
// label, but never the visible badge.
//
// The same duplication broke the checkbox: every projected row completed the one
// underlying task, so tapping a future instance advanced the series as if the
// nearest one had been done.
//
// Both are resolved by the same rule: a task contributes exactly one occurrence,
// at its own due date. `occurrenceDate == task.dueDate` is therefore the invariant
// that keeps the date on a row and the task behind it in agreement.

@Suite("Recurring Occurrence Collapse")
struct RecurringOccurrenceCollapseTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self,
                 SavedFilter.self,
            configurations: config
        )
    }

    /// Builds an inserted task so `TaskRowData` (which refuses an invalidated
    /// model) can snapshot it exactly as a row would.
    @MainActor
    private func makeTask(
        in context: ModelContext,
        title: String,
        due: Date,
        rrule: String? = nil
    ) -> TaskItem {
        let task = TaskItem(title: title, priority: .high)
        task.dueDate = due
        task.recurrenceRule = rrule
        context.insert(task)
        return task
    }

    // MARK: - The reported bug

    @Test("A daily task contributes one Upcoming occurrence, not one per instance")
    @MainActor
    func dailyTaskAppearsOnceInUpcoming() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let due = now.addingTimeInterval(2 * 3600)
        let task = makeTask(in: context, title: "Hotsauce", due: due, rrule: "FREQ=DAILY")

        let occurrences = TaskListHelpers.occurrences(
            from: [task], smartList: .upcoming, now: now
        )

        #expect(occurrences.count == 1,
                "a daily task must occupy one Upcoming row, not one per day in the 4-week window")
        #expect(occurrences.first?.occurrenceDate == due)
    }

    /// The screenshot symptom, asserted where it actually surfaced: the badge is
    /// rendered from `TaskRowData.dueDate`, so that value — not the occurrence date
    /// the sort used — is what the user reads on the row.
    @Test("Every Upcoming row renders its own occurrence date")
    @MainActor
    func upcomingRowsRenderTheirOwnDate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let tasks = [
            makeTask(in: context, title: "Hotsauce", due: now.addingTimeInterval(2 * 3600), rrule: "FREQ=DAILY"),
            makeTask(in: context, title: "Puppy pill", due: now.addingTimeInterval(26 * 3600), rrule: "FREQ=DAILY"),
            makeTask(in: context, title: "Call Xcel", due: now.addingTimeInterval(20 * 3600))
        ]

        let occurrences = TaskListHelpers.occurrences(
            from: tasks, smartList: .upcoming, now: now
        )

        #expect(occurrences.count == 3, "one row per task, recurring or not")
        for occurrence in occurrences {
            let rendered = try #require(TaskRowData(task: occurrence.task))
            #expect(rendered.dueDate == occurrence.occurrenceDate,
                    "the row for \(rendered.title) displays a date other than the one it sorted under")
        }
    }

    /// The second half of the same defect. A row whose date is its task's date can
    /// only complete the instance it is showing, so the checkbox needs no gate.
    @Test("No occurrence detaches its row from the task the checkbox completes")
    @MainActor
    func occurrenceDateAlwaysMatchesTheTaskBehindIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let upcoming = makeTask(in: context, title: "Hotsauce", due: now.addingTimeInterval(3600), rrule: "FREQ=DAILY")
        let missed = makeTask(in: context, title: "Sage practice", due: now.addingTimeInterval(-3 * 86_400), rrule: "FREQ=DAILY")

        let rows = TaskListHelpers.occurrences(from: [upcoming], smartList: .upcoming, now: now)
            + TaskListHelpers.occurrences(from: [missed], smartList: .overdue, now: now)

        #expect(rows.count == 2, "examined too few rows to prove anything")
        for row in rows {
            #expect(row.occurrenceDate == row.task.dueDate,
                    "\(row.task.title) renders an instance its checkbox does not complete")
        }
    }

    // MARK: - Overdue

    @Test("A missed daily task contributes one Overdue occurrence, not one per miss")
    @MainActor
    func missedDailyTaskAppearsOnceInOverdue() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let due = now.addingTimeInterval(-3 * 86_400)
        let task = makeTask(in: context, title: "Hotsauce", due: due, rrule: "FREQ=DAILY")

        let occurrences = TaskListHelpers.occurrences(
            from: [task], smartList: .overdue, now: now
        )

        #expect(occurrences.count == 1,
                "three missed days must not stack three identical rows")
        #expect(occurrences.first?.occurrenceDate == due)
    }

    // MARK: - Unchanged behaviour

    @Test("Non-recurring tasks keep their existing Upcoming window behaviour")
    @MainActor
    func nonRecurringTasksAreUnaffected() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let soon = makeTask(in: context, title: "Get blood draw", due: now.addingTimeInterval(86_400))
        let past = makeTask(in: context, title: "Respond to Deb", due: now.addingTimeInterval(-86_400))
        let beyondWindow = makeTask(in: context, title: "Far off", due: now.addingTimeInterval(40 * 86_400))

        let occurrences = TaskListHelpers.occurrences(
            from: [soon, past, beyondWindow], smartList: .upcoming, now: now
        )

        #expect(occurrences.map(\.task.title) == ["Get blood draw"],
                "Upcoming still admits only dated tasks inside the 4-week window")
    }

    @Test("Occurrences stay sorted by date across recurring and one-off tasks")
    @MainActor
    func occurrencesRemainSorted() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date()
        let later = makeTask(in: context, title: "Hotsauce", due: now.addingTimeInterval(10 * 3600), rrule: "FREQ=DAILY")
        let sooner = makeTask(in: context, title: "Call Xcel", due: now.addingTimeInterval(3600))

        let occurrences = TaskListHelpers.occurrences(
            from: [later, sooner], smartList: .upcoming, now: now
        )

        #expect(occurrences.map(\.task.title) == ["Call Xcel", "Hotsauce"])
    }
}
