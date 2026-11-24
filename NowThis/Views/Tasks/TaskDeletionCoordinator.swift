import Foundation
import SwiftData

/// Shared by every row delete action; the row owns persistence and reminder effects.
struct TaskDeletionCoordinator {
    enum ConfirmationResult {
        case deleted, cancelled, invalidTask, subtasksChanged
    }

    private(set) var subtaskCount: Int?
    private var pendingTask: TaskItem?
    private var pendingScope: TaskWriteEligibility.DeletionScope?

    /// Production row deletion captures the exact admitted subtree before presenting its dialog.
    @MainActor
    mutating func request(_ task: TaskItem, in context: ModelContext, errorState: ErrorState? = nil,
                          delete: (TaskItem, TaskWriteEligibility.DeletionScope) -> Void) {
        cancel()
        guard task.modelContext === context, !task.isDeletedLocally else { return }
        let admission: TaskWriteEligibility.DeletionAdmission
        do {
            admission = try TaskDeletionPersistence.admit(task, in: context)
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return
        }
        let count = activeDescendantCount(in: admission.rows)
        guard count > 0 else {
            delete(task, admission.scope)
            return
        }
        pendingTask = task
        pendingScope = admission.scope
        subtaskCount = count
    }

    mutating func cancel() {
        pendingTask = nil
        pendingScope = nil
        subtaskCount = nil
    }

    /// Re-reads committed closure and permissions after confirmation before dispatching deletion.
    @MainActor
    @discardableResult
    mutating func confirm(in context: ModelContext, errorState: ErrorState? = nil,
                          delete: (TaskItem, TaskWriteEligibility.DeletionScope) -> Void) -> ConfirmationResult {
        guard let task = pendingTask, let confirmedScope = pendingScope else { return .cancelled }
        let displayedCount = subtaskCount
        cancel()
        guard task.modelContext === context, !task.isDeletedLocally else { return .invalidTask }
        let admission: TaskWriteEligibility.DeletionAdmission
        do {
            admission = try TaskDeletionPersistence.admit(task, in: context, confirmed: confirmedScope)
        } catch let refusal as TaskWriteEligibility.Refusal where refusal == .targetChanged {
            return .subtasksChanged
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return .invalidTask
        }
        guard activeDescendantCount(in: admission.rows) == displayedCount else { return .subtasksChanged }
        delete(task, confirmedScope)
        return .deleted
    }

    private func activeDescendantCount(in rows: [TaskItem]) -> Int {
        rows.dropFirst().filter { !$0.isDeletedLocally }.count
    }
}
