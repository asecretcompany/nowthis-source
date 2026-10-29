import SwiftUI
import WidgetKit

/// A single snapshot of "today" for the complication timeline.
struct TaskComplicationEntry: TimelineEntry {
    let date: Date
    let remainingToday: Int
    let nextTitle: String?
    let nextDueText: String?
}

/// Reads the App Group snapshot written by the phone (via `PhoneBridge`) and
/// reduces it to today's remaining-task count + the soonest task, for the
/// `accessoryCircular`/`accessoryRectangular`/`accessoryInline` complications.
///
/// Reads the raw persisted snapshot, not `overlay.displayTasks(from:)` — a task
/// completed optimistically on the watch won't drop from the count until the
/// next inbound phone snapshot. Complications are an at-a-glance surface that
/// refreshes on snapshot sync, not a live view.
struct TaskComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskComplicationEntry {
        TaskComplicationEntry(date: .now, remainingToday: 3, nextTitle: "Buy milk", nextDueText: "5:00 PM")
    }
    func getSnapshot(in context: Context, completion: @escaping (TaskComplicationEntry) -> Void) {
        completion(makeEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskComplicationEntry>) -> Void) {
        // Refresh at the top of the next hour; PhoneBridge also reloads timelines on every snapshot.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
        completion(Timeline(entries: [makeEntry()], policy: .after(next)))
    }

    private func makeEntry() -> TaskComplicationEntry {
        let snapshot = WatchSnapshotStore().load()
        // WatchSmartList.today matches the watch's Today view (effectiveDeadline basis for
        // date-only tasks) so the complication count never disagrees with the Today screen.
        let today = WatchSmartList.today
            .filter(snapshot?.tasks ?? [])
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        let next = today.first
        return TaskComplicationEntry(
            date: .now,
            remainingToday: today.count,
            nextTitle: next?.title,
            nextDueText: next.flatMap { t in t.dueDate.map { DueDateFormatter.format($0, isDateOnly: t.isDueDateOnly) } })
    }
}
