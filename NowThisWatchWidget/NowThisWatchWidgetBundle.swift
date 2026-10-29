import SwiftUI
import WidgetKit

/// The NowThis watch widget bundle: a single complication surfacing today's
/// remaining task count / next task across the circular, rectangular, and
/// inline accessory families.
@main
struct NowThisWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaskComplicationWidget()
    }
}

/// Complications render regardless of `isProUnlocked` — they're a view-only,
/// free-taste surface (no Pro gate here).
struct TaskComplicationWidget: Widget {
    let kind = "com.asecretcompany.nowthis.watch.tasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TaskComplicationProvider()) { entry in
            TaskComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("NowThis Tasks")
        .description("See how many tasks are due today.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - View

private struct TaskComplicationView: View {
    let entry: TaskComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        case .accessoryInline:
            InlineComplicationView(entry: entry)
        default:
            InlineComplicationView(entry: entry)
        }
    }
}

// MARK: - accessoryCircular

private struct CircularComplicationView: View {
    let entry: TaskComplicationEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if entry.remainingToday == 0 {
                Image(systemName: "checkmark")
                    .font(.title3)
            } else {
                Text(entry.remainingToday, format: .number)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityLabel(remainingTodayLabel(entry.remainingToday))
    }
}

// MARK: - accessoryRectangular

private struct RectangularComplicationView: View {
    let entry: TaskComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(remainingTodayText(entry.remainingToday))
                .font(.headline)
                .lineLimit(1)

            if let title = entry.nextTitle {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                if let due = entry.nextDueText {
                    Text(due)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("All clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rectangularAccessibilityLabel)
    }

    private var rectangularAccessibilityLabel: String {
        guard let title = entry.nextTitle else {
            return String(localized: "watchwidget.rectangular.a11y.empty",
                           defaultValue: "No tasks today. All clear.",
                           comment: "Complete VoiceOver sentence for the rectangular watch complication when there is nothing due today.")
        }
        let base = remainingTodayLabel(entry.remainingToday)
        if let due = entry.nextDueText {
            return String(localized: "watchwidget.rectangular.a11y.nextWithDue",
                           defaultValue: "\(base). Next: \(title), \(due)",
                           comment: "VoiceOver label for the rectangular watch complication when a next task with a due date exists; base is the already-localized remaining-tasks-today phrase from remainingTodayLabel, title is the user-entered task title, due is a formatted date; the sentence structure - localized clause, then Next, then user data - is fixed by the composition.")
        }
        return String(localized: "watchwidget.rectangular.a11y.next",
                       defaultValue: "\(base). Next: \(title)",
                       comment: "VoiceOver label for the rectangular watch complication when a next task without a due date exists; base is the already-localized remaining-tasks-today phrase from remainingTodayLabel, title is the user-entered task title; the sentence structure - localized clause, then Next, then user data - is fixed by the composition.")
    }
}

// MARK: - accessoryInline

private struct InlineComplicationView: View {
    let entry: TaskComplicationEntry

    var body: some View {
        Text(remainingTodayText(entry.remainingToday))
            .accessibilityLabel(remainingTodayLabel(entry.remainingToday))
    }
}

// MARK: - Shared copy

/// Visible label, e.g. "3 tasks today" / "No tasks today".
private func remainingTodayText(_ count: Int) -> String {
    switch count {
    case 0:
        return String(localized: "watchwidget.remaining.text.none",
                       defaultValue: "No tasks today",
                       comment: "Visible text on the watch complication (rectangular/inline) when zero tasks are due today; extremely tight width budget, must stay short.")
    default:
        return String(localized: "watchwidget.remaining.text",
                       defaultValue: "\(count) tasks today",
                       comment: "Visible text on the watch complication (rectangular/inline) stating how many tasks are due today; extremely tight width budget, must stay short. Zero has its own key because it reads as words, not a count.")
    }
}

/// VoiceOver label, e.g. "3 tasks remaining today" / "No tasks remaining today".
private func remainingTodayLabel(_ count: Int) -> String {
    switch count {
    case 0:
        return String(localized: "watchwidget.remaining.a11y.none",
                       defaultValue: "No tasks remaining today",
                       comment: "VoiceOver label for the watch complication (circular/rectangular/inline) when zero tasks are due today; can be longer and more explicit than the visible text.")
    default:
        return String(localized: "watchwidget.remaining.a11y",
                       defaultValue: "\(count) tasks remaining today",
                       comment: "VoiceOver label for the watch complication (circular/rectangular/inline) stating how many tasks are due today; can be longer and more explicit than the visible text. Zero has its own key because it reads as words, not a count.")
    }
}
