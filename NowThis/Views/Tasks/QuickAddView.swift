import SwiftUI
import SwiftData

/// Quick task creation sheet with natural language parsing.
///
/// Supports token syntax as the user types:
/// - `!high`, `!medium`, `!low` → priority
/// - `#ListName` → assign to task list
/// - `@tagname` → assign tag
/// - "today", "tomorrow", "next monday", "in 3 days" → due date
///
/// Matched tokens appear as preview chips below the text field.
struct QuickAddView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var taskTitle = ""
    @State private var selectedPriority: TaskPriority = .none
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var recurrenceRule: String?
    @State private var parseResult = NaturalLanguageParser.ParseResult()
    @FocusState private var isFocused: Bool
    let defaultList: TaskList?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TaskTitleField(title: $taskTitle, isFocused: $isFocused)
                    .onChange(of: taskTitle) { _, newValue in
                        parseResult = NaturalLanguageParser.parse(newValue)
                    }

                if hasTokens {
                    ParsePreviewChips(result: parseResult)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                QuickOptionsBar(
                    priority: $selectedPriority,
                    hasDueDate: $hasDueDate,
                    dueDate: $dueDate,
                    recurrenceRule: $recurrenceRule
                )
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { createTask() }
                        .fontWeight(.semibold)
                        .disabled(effectiveTitle.isEmpty)
                }
            }
            .onAppear { isFocused = true }
            .animation(.easeInOut(duration: 0.2), value: hasTokens)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(!taskTitle.isEmpty)
    }

    /// True if the parser found any tokens.
    private var hasTokens: Bool {
        parseResult.priority != nil
            || parseResult.listName != nil
            || !parseResult.tagNames.isEmpty
            || parseResult.dueDate != nil
    }

    /// The title to use — cleaned by the parser if tokens exist.
    private var effectiveTitle: String {
        let title = hasTokens ? parseResult.cleanTitle : taskTitle
        return title.trimmingCharacters(in: .whitespaces)
    }

    private func createTask() {
        let trimmed = effectiveTitle
        guard !trimmed.isEmpty else { return }

        // Resolve priority: parsed token overrides manual picker
        let priority = parseResult.priority ?? selectedPriority

        let task = TaskItem(title: trimmed, priority: priority)

        // Due date: parsed token overrides manual picker
        if let parsedDate = parseResult.dueDate {
            task.dueDate = parsedDate
        } else {
            task.dueDate = hasDueDate ? (dueDate ?? Date()) : nil
        }

        task.recurrenceRule = recurrenceRule

        // Resolve list: parsed #list name or the default
        if let listName = parseResult.listName {
            task.taskList = resolveTaskList(named: listName) ?? defaultList
        } else {
            task.taskList = defaultList
        }

        // Resolve tags: create-or-find for each @tag
        for tagName in parseResult.tagNames {
            let tag = resolveOrCreateTag(named: tagName)
            task.tags.append(tag)
        }

        task.isDirty = true
        modelContext.insert(task)
        try? modelContext.save()
        syncScheduler.syncAfterChange(modelContext: modelContext)

        // Auto-sync to calendar if enabled
        let accounts = (try? modelContext.fetch(FetchDescriptor<ServerAccount>())) ?? []
        Task {
            await CalendarAutoSync.syncTaskIfEnabled(task, accounts: accounts)
        }

        HapticManager.success()
        IntentDonationManager.donateCreateTask(title: trimmed, listName: task.taskList?.name)
        dismiss()

    }

    /// Finds a TaskList by name (case-insensitive).
    private func resolveTaskList(named name: String) -> TaskList? {
        let allLists = (try? modelContext.fetch(FetchDescriptor<TaskList>())) ?? []
        return allLists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    /// Finds an existing Tag by name or creates a new one.
    private func resolveOrCreateTag(named name: String) -> Tag {
        let allTags = (try? modelContext.fetch(FetchDescriptor<Tag>())) ?? []
        if let existing = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let tag = Tag(name: name)
        modelContext.insert(tag)
        return tag
    }
}

// MARK: - Parse Preview Chips

private struct ParsePreviewChips: View {
    let result: NaturalLanguageParser.ParseResult

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let priority = result.priority {
                    TokenChip(
                        label: priority.displayName,
                        icon: "flag.fill",
                        tint: priority.color
                    )
                }

                if let listName = result.listName {
                    TokenChip(label: listName, icon: "list.bullet", tint: .blue)
                }

                ForEach(result.tagNames, id: \.self) { tag in
                    TokenChip(label: tag, icon: "tag.fill", tint: .purple)
                }

                if let date = result.dueDate {
                    TokenChip(
                        label: date.formatted(.dateTime.month(.abbreviated).day()),
                        icon: "calendar",
                        tint: .orange
                    )
                }
            }
        }
        .accessibilityLabel("Detected tokens")
    }
}

private struct TokenChip: View {
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Title Field

private struct TaskTitleField: View {
    @Binding var title: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField("What do you need to do?", text: $title, axis: .vertical)
            .font(.title3)
            .focused(isFocused)
            .lineLimit(1...3)
            .padding(16)
            .glassBackground(in: RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Task title")
            .accessibilityHint("Type a task name. Use !high for priority, #list for list, @tag for tags, or date words like tomorrow")
    }
}

// MARK: - Quick Options

private struct QuickOptionsBar: View {
    @Binding var priority: TaskPriority
    @Binding var hasDueDate: Bool
    @Binding var dueDate: Date?
    @Binding var recurrenceRule: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                PriorityPicker(priority: $priority)
                DueDateToggle(hasDueDate: $hasDueDate, dueDate: $dueDate)
                RepeatToggle(recurrenceRule: $recurrenceRule)
                Spacer()
            }

            if hasDueDate {
                DatePicker(
                    "Due Date",
                    selection: Binding(
                        get: { dueDate ?? Date() },
                        set: { dueDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: hasDueDate)
    }
}

private struct PriorityPicker: View {
    @Binding var priority: TaskPriority

    var body: some View {
        Menu {
            ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { pri in
                Button {
                    priority = pri
                } label: {
                    Label(pri.displayName, systemImage: pri.icon)
                }
            }
        } label: {
            Label("Priority", systemImage: priorityIcon)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
        }
        .accessibilityLabel("Priority")
        .accessibilityValue(priority.displayName)
    }

    private var priorityIcon: String {
        priority == .none ? "flag" : "flag.fill"
    }
}

private struct DueDateToggle: View {
    @Binding var hasDueDate: Bool
    @Binding var dueDate: Date?

    var body: some View {
        Button {
            hasDueDate.toggle()
            if hasDueDate && dueDate == nil {
                dueDate = Date()
            }
        } label: {
            Label("Due Date", systemImage: hasDueDate ? "calendar.badge.checkmark" : "calendar")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
        }
        .accessibilityLabel("Due date")
        .accessibilityValue(hasDueDate ? "Set" : "Not set")
        .accessibilityHint(hasDueDate ? "Double tap to remove due date" : "Double tap to set a due date")
    }
}

private struct RepeatToggle: View {
    @Binding var recurrenceRule: String?
    @State private var showingRecurrenceSheet = false

    private var hasRecurrence: Bool { recurrenceRule != nil }

    private var displayText: String {
        guard let rrule = recurrenceRule,
              let rule = RecurrenceRule.parse(rrule) else {
            return "Repeat"
        }
        return rule.displayText
    }

    var body: some View {
        Button {
            showingRecurrenceSheet = true
        } label: {
            Label(displayText, systemImage: "repeat")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
        }
        .sheet(isPresented: $showingRecurrenceSheet) {
            RecurrencePickerSheet(recurrenceRule: $recurrenceRule)
        }
        .accessibilityLabel("Repeat")
        .accessibilityValue(hasRecurrence ? displayText : "Never")
        .accessibilityHint("Double tap to set a recurrence schedule")
    }
}
