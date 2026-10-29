import Foundation
import SwiftData

/// A minimal, immutable snapshot of the fields the *compact* task presentations
/// render — the calendar day list, the week-view blocks, and the Eisenhower
/// matrix quadrants.
///
/// Same reason as `TaskRowData`: deleting an account cascades
/// `ServerAccount` → `TaskList` → `TaskItem` on the **main** context, and any
/// row SwiftUI still has realized will trap on its next read with
///
///     SwiftData/BackingData.swift:249: Fatal error: This backing data was
///     detached from a context without resolving attribute faults
///
/// It stays deliberately smaller than `TaskRowData`: these rows show no tags and
/// no subtask progress, so they skip that type's recursive subtree walk. A
/// matrix quadrant re-snapshots its whole column on every scroll tick, so the
/// difference is not academic.
struct TaskGlanceData: Equatable, Identifiable {
    let id: String
    let title: String
    let status: TaskStatus
    let priority: TaskPriority
    let dueDate: Date?
    let isDueDateOnly: Bool

    /// Builds a snapshot from a live task, or `nil` if its backing row has been
    /// invalidated. Callers treat `nil` as "this task is gone — render nothing".
    init?(task: TaskItem) {
        guard task.modelContext != nil else { return nil }
        self.id = task.id
        self.title = task.title
        self.status = task.status
        self.priority = task.priority
        self.dueDate = task.dueDate
        self.isDueDateOnly = task.isDueDateOnly
    }
}

/// A snapshot paired with the live task it came from.
///
/// The compact presentations still need the model itself — to push a
/// `NavigationLink(value:)` or to hand back to a selection callback — but they
/// must never *read* it during a layout pass. Holding a reference is safe;
/// dereferencing is not. `id` comes from the snapshot, so even `ForEach`'s
/// identity read (which happens before any view body runs) touches no model.
struct TaskGlanceRow: Identifiable {
    let data: TaskGlanceData
    let task: TaskItem

    var id: String { data.id }

    init?(task: TaskItem) {
        guard let data = TaskGlanceData(task: task) else { return nil }
        self.data = data
        self.task = task
    }
}

/// A task selected for presentation in a `.sheet(item:)`, with its identity
/// captured up front.
///
/// `.sheet(item:)` reads the bound value's `id` in the **presenting view's** body,
/// on every pass, for as long as the sheet is up — and the binding is `@State`, so
/// it outlives the model. Binding a bare `TaskItem` means that read lands on an
/// invalidated model if anything deletes the task while the sheet is open, which
/// on iPad is as ordinary as swiping a list away in the sidebar next to it. The
/// presented editor's own dismiss-guard cannot help: it runs after this read.
struct SelectedTask: Identifiable {
    let task: TaskItem
    let id: String

    init(_ task: TaskItem) {
        self.task = task
        self.id = task.id
    }
}

extension Sequence where Element == TaskItem {
    /// Snapshots each task, dropping any whose backing row is already gone.
    ///
    /// The guard belongs here, at the array boundary, rather than inside the row:
    /// `ForEach` reads each element's `id` to diff identity *before* it evaluates
    /// any row body, so a leaf-level guard runs too late to help.
    func glanceRows() -> [TaskGlanceRow] {
        compactMap(TaskGlanceRow.init(task:))
    }
}
