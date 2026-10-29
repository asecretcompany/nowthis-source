import SwiftUI

struct WatchTaskRow: View {
    let task: WatchTask
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(task.title).strikethrough(task.isCompleted).lineLimit(2)
                    if let due = task.dueDate {
                        Text(DueDateFormatter.format(due, isDateOnly: task.isDueDateOnly))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(task.isCompleted ? "Double-tap to mark as not completed."
                                            : "Double-tap to complete this task.")
        .sensoryFeedback(.success, trigger: task.isCompleted)
    }

    private var accessibilityText: String {
        var parts = [task.title]
        if let due = task.dueDate {
            parts.append(String(localized: "watch.row.a11y.due",
                                 defaultValue: "Due \(DueDateFormatter.accessibilityLabel(due, isDateOnly: task.isDueDateOnly))",
                                 comment: "Fragment appended into a task row's longer VoiceOver label on Apple Watch; the interpolated value is an already-localized formatted due date/time."))
        }
        if task.isCompleted {
            parts.append(String(localized: "watch.row.a11y.completed",
                                 defaultValue: "Completed",
                                 comment: "Fragment appended into a task row's longer VoiceOver label on Apple Watch, indicating the task is marked done."))
        }
        return parts.joined(separator: ", ")
    }
}
