import SwiftUI
import WidgetKit

@available(iOS 27.0, *)
struct PortraitTaskWidgetView: View {
    let entry: TaskWidgetEntry

    @ScaledMetric(relativeTo: .headline) private var headerHeight = 56.0
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight = 80.0
    @ScaledMetric(relativeTo: .caption) private var rowSpacing = 4.0

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let visibleCount = WidgetDisplayPolicy.portraitVisibleCount(
                availableHeight: height, headerHeight: headerHeight, rowHeight: rowHeight,
                spacing: rowSpacing, candidateCount: entry.tasks.count
            )

            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 3) {
                        listTitle
                        Text(LocalizedStringResource(
                            "widget.portrait.tasksShown",
                            defaultValue: "\(visibleCount) tasks shown",
                            comment: "Number of task rows currently visible in the extra-large portrait widget. This count may be smaller than the number of tasks due."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    listTitle
                    Color.clear
                }
                .frame(height: min(headerHeight, height), alignment: .topLeading)

                if entry.tasks.isEmpty {
                    ViewThatFits {
                        Text("Nothing due today")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: rowSpacing) {
                        ForEach(entry.tasks.prefix(visibleCount)) { task in
                            PortraitTaskWidgetRow(task: task, showsListName: entry.showsListNames)
                                .frame(height: rowHeight)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var listTitle: some View {
        Label {
            Text(entry.listName)
                .lineLimit(1)
        } icon: {
            Image(systemName: "checklist")
                .foregroundStyle(.tint)
                .widgetAccentable()
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }
}

@available(iOS 27.0, *)
private struct PortraitTaskWidgetRow: View {
    let task: WidgetTaskItem
    let showsListName: Bool

    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Button(intent: CompleteTaskIntent(task: TaskEntity(
            id: task.id,
            title: task.title,
            isCompleted: task.isCompleted,
            listName: task.listName
        ))) {
            HStack(spacing: 10) {
                VStack(spacing: 3) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(task.isCompleted ? .green : task.priority.color)
                        .widgetAccentable()

                    if task.priority != .none {
                        Text(task.priority.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(task.priority.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(minWidth: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .strikethrough(task.isCompleted)
                        .lineLimit(2)

                    if let due = task.dueDate {
                        Text(DueDateFormatter.format(due, isDateOnly: task.isDueDateOnly, timeZone: timeZone))
                            .foregroundStyle(DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly)
                                             ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }

                    if showsListName {
                        Text(task.listName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(taskRowAccessibilityLabel(
            title: task.title, isCompleted: task.isCompleted,
            priorityName: task.priority == .none ? nil : task.priority.displayName
        ))
        .accessibilityValue(spokenContext)
        .accessibilityHint(task.isCompleted ? "Double tap to mark as incomplete" : "Double tap to complete")
    }

    private var spokenContext: String {
        [
            task.dueDate.map {
                DueDateFormatter.accessibilityLabel($0, isDateOnly: task.isDueDateOnly, timeZone: timeZone)
            },
            showsListName ? task.listName : nil
        ]
        .compactMap { $0 }
        .formatted(.list(type: .and))
    }
}
