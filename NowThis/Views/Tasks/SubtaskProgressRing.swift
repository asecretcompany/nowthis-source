import SwiftUI

/// Circular progress ring showing aggregated subtask completion.
///
/// Recursively counts all descendant subtasks (not just direct children)
/// and displays `completed / total` as a filled ring with a center label.
///
/// The ring uses a green fill for completed proportion and a gray track
/// for remaining. When all subtasks are complete, a checkmark replaces
/// the fraction label.
struct SubtaskProgressRing: View {

    let task: TaskItem

    /// Ring stroke width.
    private let lineWidth: CGFloat = 3

    /// Ring diameter.
    private let size: CGFloat = 28

    var body: some View {
        let stats = aggregatedProgress(for: task)

        ZStack {
            // Background track
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
                .frame(width: size, height: size)

            // Progress arc
            Circle()
                .trim(from: 0, to: stats.fraction)
                .stroke(
                    stats.isComplete ? .green : .accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .animation(.easeInOut(duration: 0.3), value: stats.fraction)

            // Center label
            if stats.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                Text("\(stats.completed)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(stats.completed) of \(stats.total) subtask\(stats.total == 1 ? "" : "s") completed"
        )
    }

    // MARK: - Progress Calculation

    /// Aggregated progress across all descendants.
    private struct Progress {
        let completed: Int
        let total: Int

        var fraction: CGFloat {
            guard total > 0 else { return 0 }
            return CGFloat(completed) / CGFloat(total)
        }

        var isComplete: Bool {
            total > 0 && completed == total
        }
    }

    /// Recursively counts completed and total subtasks across the full hierarchy.
    ///
    /// Only counts non-deleted subtasks. A subtask with its own subtasks
    /// contributes its own status AND its children's counts.
    private func aggregatedProgress(for task: TaskItem) -> Progress {
        let activeSubtasks = task.subtasks.filter { !$0.isDeletedLocally }
        guard !activeSubtasks.isEmpty else {
            return Progress(completed: 0, total: 0)
        }

        var completed = 0
        var total = 0

        for subtask in activeSubtasks {
            total += 1
            if subtask.status == .completed {
                completed += 1
            }

            // Recurse into children
            let childProgress = aggregatedProgress(for: subtask)
            completed += childProgress.completed
            total += childProgress.total
        }

        return Progress(completed: completed, total: total)
    }
}
