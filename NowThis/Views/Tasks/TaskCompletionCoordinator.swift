import Foundation
import SwiftUI
import WidgetKit

/// Coordinates the visual completion animation sequence for a task row.
///
/// When a task is completed, the coordinator enters an "animating" state
/// to show visual feedback (strikethrough, fade) before the actual status
/// change triggers the row's removal from the list.
///
/// Un-completing a task is always immediate — no animation delay.
@MainActor
final class TaskCompletionCoordinator: ObservableObject {

    /// True while the completion animation is playing, before the status change.
    @Published var isAnimating = false
    @Published var completionError: TaskCompletionLogic.CompletionError?

    /// The delay (in seconds) between starting the animation and changing the task status.
    let animationDelay: TimeInterval

    /// Called after a task status change to reload widget timelines.
    /// Defaults to `WidgetCenter.shared.reloadAllTimelines()`.
    private let onWidgetReload: () -> Void

    private let onCompletionDonation: (TaskEntity) -> Void

    private var delayedTask: Task<Void, Never>?

    init(
        animationDelay: TimeInterval = 0.8,
        onWidgetReload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        onCompletionDonation: @escaping (TaskEntity) -> Void = { IntentDonationManager.donateCompleteTask(task: $0) }
    ) {
        self.animationDelay = animationDelay
        self.onWidgetReload = onWidgetReload
        self.onCompletionDonation = onCompletionDonation
    }

    /// Toggles the task's completion status with animation sequencing.
    ///
    /// - Completing: sets `isAnimating = true`, then after `animationDelay`
    ///   sets the task's status to `.completed`.
    /// - Un-completing: immediately reverts the task's status. No delay.
    ///
    /// - Parameter task: The task to toggle.
    /// - Parameter onStatusChanged: Publishes the committed task change exactly once.
    /// - Parameter requestReconcile: Reminder recovery, independently retryable after commit.
    func toggle(_ task: TaskItem, save: @escaping () throws -> Void = {},
                errorState: ErrorState? = nil, requestReconcile: (@MainActor () throws -> Void)? = nil,
                onStatusChanged: @escaping () -> Void) {
        delayedTask?.cancel()
        guard let context = task.modelContext else { return }
        do {
            _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
        } catch {
            isAnimating = false
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return
        }

        if task.status == .completed {
            let snapshot = TaskStatusSnapshot(task)
            TaskCompletionLogic.markUncompleted(task)
            isAnimating = false
            do { try save() }
            catch {
                snapshot.restore()
                ViewPersistence.report(error, to: errorState)
                return
            }
            onWidgetReload()
            onStatusChanged()
            if let requestReconcile {
                ViewPersistence.recoverRemindersAfterCommit(errorState: errorState, requestReconcile: requestReconcile)
            }
        } else {
            isAnimating = true
            delayedTask = Task { @MainActor [weak self, onCompletionDonation] in
                try? await Task.sleep(for: .seconds(self?.animationDelay ?? 0.8))
                guard !Task.isCancelled else { return }
                guard let context = task.modelContext else {
                    self?.isAnimating = false
                    return
                }
                do {
                    _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
                } catch {
                    self?.isAnimating = false
                    ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
                    return
                }
                let snapshot = TaskStatusSnapshot(task)
                do { try TaskCompletionLogic.markCompleted(task) }
                catch {
                    self?.isAnimating = false
                    self?.completionError = .unsupportedRecurrence
                    return
                }
                self?.isAnimating = false
                // Capture values before save and callbacks can invalidate the live model.
                let donationTask = TaskEntity(task: task)
                do { try save() }
                catch {
                    snapshot.restore()
                    ViewPersistence.report(error, to: errorState)
                    return
                }
                onCompletionDonation(donationTask)
                self?.onWidgetReload()
                onStatusChanged()
                if let requestReconcile {
                    ViewPersistence.recoverRemindersAfterCommit(errorState: errorState, requestReconcile: requestReconcile)
                }
            }
        }
    }

    /// Cancels any pending delayed completion.
    func cancel() {
        delayedTask?.cancel()
        delayedTask = nil
        isAnimating = false
    }
}
