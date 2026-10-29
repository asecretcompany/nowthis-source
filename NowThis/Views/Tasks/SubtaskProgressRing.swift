import SwiftUI

/// Circular progress ring showing aggregated subtask completion.
///
/// Displays `completed / total` as a filled ring with a center label. The counts
/// are aggregated across all descendants (not just direct children) by
/// `TaskRowData`, which snapshots them while the task is still valid — the ring
/// never touches a live `PersistentModel`, so an account-delete cascade can't
/// invalidate what it is rendering.
///
/// The ring uses a green fill for completed proportion and a gray track
/// for remaining. When all subtasks are complete, a checkmark replaces
/// the fraction label.
struct SubtaskProgressRing: View {

    let completed: Int
    let total: Int

    /// Ring stroke width.
    private let lineWidth: CGFloat = 3

    /// Ring diameter.
    private let size: CGFloat = 28

    var body: some View {
        let stats = Progress(completed: completed, total: total)

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
                Text(stats.completed, format: .number)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "subtasks.a11y.progress",
            defaultValue: "\(stats.completed) of \(stats.total) subtasks completed",
            comment: "VoiceOver label for the subtask progress ring. First placeholder is how many subtasks are done, second is the total. The second one drives the plural."))
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

}
