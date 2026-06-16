import AppIntents

/// Registers NowThis shortcuts with the system for Siri and Spotlight suggestions.
///
/// This provider enables voice commands like:
/// - "Hey Siri, add a task to NowThis"
/// - "Hey Siri, what's due today in NowThis"
/// - "Hey Siri, how many tasks do I have in NowThis"
///
/// The system surfaces these phrases in Siri Suggestions and the Shortcuts app.
/// Maximum 10 AppShortcut entries allowed — using 7 of 10 slots.
struct NowThisShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "Create a task in \(.applicationName)",
                "New task in \(.applicationName)"
            ],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )

        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: [
                "Complete a task in \(.applicationName)",
                "Mark task as done in \(.applicationName)",
                "Finish task in \(.applicationName)"
            ],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle"
        )

        AppShortcut(
            intent: ShowTasksIntent(),
            phrases: [
                "Show my tasks in \(.applicationName)",
                "What tasks do I have in \(.applicationName)",
                "List tasks in \(.applicationName)"
            ],
            shortTitle: "Show Tasks",
            systemImageName: "list.bullet"
        )

        AppShortcut(
            intent: TasksDueTodayIntent(),
            phrases: [
                "What's due today in \(.applicationName)",
                "Tasks due today in \(.applicationName)",
                "Today's tasks in \(.applicationName)"
            ],
            shortTitle: "Due Today",
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: TaskCountIntent(),
            phrases: [
                "How many tasks do I have in \(.applicationName)",
                "Count my tasks in \(.applicationName)"
            ],
            shortTitle: "Task Count",
            systemImageName: "number"
        )

        AppShortcut(
            intent: SearchTasksIntent(),
            phrases: [
                "Search tasks in \(.applicationName)",
                "Find a task in \(.applicationName)"
            ],
            shortTitle: "Search Tasks",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: DeleteTaskIntent(),
            phrases: [
                "Delete a task in \(.applicationName)",
                "Remove a task from \(.applicationName)"
            ],
            shortTitle: "Delete Task",
            systemImageName: "trash"
        )
    }
}
