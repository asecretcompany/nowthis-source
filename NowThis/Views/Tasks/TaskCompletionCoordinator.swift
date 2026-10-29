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

    /// The delay (in seconds) between starting the animation and changing the task status.
    let animationDelay: TimeInterval

    /// Called after a task status change to reload widget timelines.
    /// Defaults to `WidgetCenter.shared.reloadAllTimelines()`.
    private let onWidgetReload: () -> Void

    private var delayedTask: Task<Void, Never>?

    init(
        animationDelay: TimeInterval = 0.8,
        onWidgetReload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.animationDelay = animationDelay
        self.onWidgetReload = onWidgetReload
    }

    /// Toggles the task's completion status with animation sequencing.
    ///
    /// - Completing: sets `isAnimating = true`, then after `animationDelay`
    ///   sets the task's status to `.completed`.
    /// - Un-completing: immediately reverts the task's status. No delay.
    ///
    /// - Parameter task: The task to toggle.
    /// - Parameter onStatusChanged: Called after the status has actually changed,
    ///   for saving context and triggering sync.
    func toggle(_ task: TaskItem, onStatusChanged: @escaping () -> Void) {
        delayedTask?.cancel()

        if task.status == .completed {
            // Un-complete: immediate, no animation
            TaskCompletionLogic.markUncompleted(task)
            isAnimating = false
            onWidgetReload()
            onStatusChanged()
        } else {
            // Complete: animate first, then change status after delay
            isAnimating = true

            delayedTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.animationDelay ?? 0.8))
                guard !Task.isCancelled else { return }

                // The animation delay is a real window: an account delete lands on
                // the main context and cascades this task away, and completing —
                // or reading the title of — an invalidated model traps in
                // SwiftData. Drop the pending completion and stop the animation.
                guard task.modelContext != nil else {
                    self?.isAnimating = false
                    return
                }

                TaskCompletionLogic.markCompleted(task)
                self?.isAnimating = false
                IntentDonationManager.donateCompleteTask(title: task.title)
                self?.onWidgetReload()
                onStatusChanged()
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
