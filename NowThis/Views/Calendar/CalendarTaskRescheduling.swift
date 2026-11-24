import Foundation
import SwiftData

@MainActor
enum CalendarTaskRescheduling {
    static func drop(taskIDs: [String], to date: Date, among tasks: [TaskItem],
                     in context: ModelContext, errorState: ErrorState?) -> Bool {
        guard reschedule(taskIDs: taskIDs, to: date, among: tasks, in: context, errorState: errorState)
        else { return false }

        HapticManager.softImpact()
        // A reminder pinned to the previous deadline needs to be reconciled after the save.
        ReminderScheduler.requestReconcile(modelContext: context, onSaveFailure: {
            ViewPersistence.report($0, to: errorState)
        })
        return true
    }

    static func reschedule(taskIDs: [String], to date: Date, among tasks: [TaskItem],
                           in context: ModelContext, errorState: ErrorState? = nil,
                           calendar: Calendar = .current) -> Bool {
        guard !taskIDs.isEmpty else { return false }

        // Only IDs can be read safely from the scoped rows retained by the drag.
        // Fetch them again because a separate sync context may have removed a row.
        let liveIDs: Set<PersistentIdentifier>
        do {
            liveIDs = Set(try context.fetchIdentifiers(EntityQueryLookup.taskDescriptor(for: taskIDs)))
        } catch {
            ViewPersistence.report(error, to: errorState)
            return false
        }
        let liveTasks = tasks.filter {
            $0.modelContext === context && liveIDs.contains($0.persistentModelID) && !$0.isDeleted
        }
        guard !liveTasks.isEmpty else { return false }
        do {
            try TaskWriteEligibility(writingIn: context).tasks(liveTasks)
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }

        let now = Date()
        for task in liveTasks {
            if task.isDueDateOnly {
                task.dueDate = DueDateHelper.dateOnlyValue(for: date, calendar: calendar)
            } else if let oldDue = task.dueDate {
                let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: oldDue)
                var newComponents = calendar.dateComponents([.year, .month, .day], from: date)
                newComponents.hour = timeComponents.hour
                newComponents.minute = timeComponents.minute
                newComponents.second = timeComponents.second
                task.dueDate = calendar.date(from: newComponents) ?? date
            } else {
                task.dueDate = date
            }
            task.isDirty = true
            task.lastModifiedDate = now
        }
        return ViewPersistence.saveOrReport(in: context, errorState: errorState)
    }
}
