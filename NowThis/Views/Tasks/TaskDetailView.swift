import SwiftUI
import SwiftData

/// Full-featured task editor with all VTODO fields.
///
/// Decomposed into focused sub-views per section to keep each body
/// under 50 lines as required by GEMINI.md.
struct TaskDetailView: View {

    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var showingAddSubtask = false

    var body: some View {
        Form {
            TitleSection(task: task)
            StatusSection(task: task)
            DatesSection(task: task)
            DetailsSection(task: task)
            TagsSection(task: task)
            NotesSection(task: task)
            SubtasksSection(
                task: task,
                onAddSubtask: { showingAddSubtask = true }
            )
            LinkedJournalsSection(task: task)
        }
        .navigationTitle("Task Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndDismiss() }
                    .fontWeight(.semibold)
            }
            ToolbarItem(placement: .secondaryAction) {
                AddToCalendarButton(task: task)
            }
        }
        .onChange(of: task.title) { _, _ in markDirty() }
        .onChange(of: task.status) { _, _ in markDirty() }
        .sheet(isPresented: $showingAddSubtask) {
            AddSubtaskSheet(parentTask: task)
        }
    }

    private func markDirty() {
        task.lastModifiedDate = Date()
        task.isDirty = true
    }

    private func saveAndDismiss() {
        markDirty()
        try? modelContext.save()
        syncScheduler.syncAfterChange(modelContext: modelContext)

        // Auto-sync to calendar if enabled
        let accounts = (try? modelContext.fetch(FetchDescriptor<ServerAccount>())) ?? []
        Task {
            await CalendarAutoSync.syncTaskIfEnabled(task, accounts: accounts)
        }

        dismiss()
    }
}

// MARK: - Title Section

private struct TitleSection: View {
    @Bindable var task: TaskItem

    var body: some View {
        Section {
            TextField("Task name", text: $task.title, axis: .vertical)
                .font(.headline)
                .lineLimit(1...4)
        }
    }
}

// MARK: - Status Section

private struct StatusSection: View {
    @Bindable var task: TaskItem

    var body: some View {
        Section {
            HStack {
                Label("Status", systemImage: "circle.dashed")
                Spacer()
                Picker("", selection: $task.status) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Text(status.displayLabel).tag(status)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Label("Priority", systemImage: "flag")
                Spacer()
                Picker("", selection: $task.priority) {
                    ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { pri in
                        Label(pri.displayName, systemImage: pri.icon).tag(pri)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Progress", systemImage: "chart.bar")
                    Spacer()
                    Text("\(task.percentComplete)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: Double(task.percentComplete), total: 100)
                    .tint(progressColor)

                Slider(
                    value: Binding(
                        get: { Double(task.percentComplete) },
                        set: { task.percentComplete = Int($0) }
                    ),
                    in: 0...100,
                    step: 5
                )
            }
        }
    }

    private var progressColor: Color {
        if task.percentComplete >= 100 { return .green }
        if task.percentComplete >= 50 { return .blue }
        return .orange
    }
}

// MARK: - Dates Section

private struct DatesSection: View {
    @Bindable var task: TaskItem
    @State private var hasStartDate: Bool
    @State private var hasDueDate: Bool
    @State private var isAllDay: Bool
    @State private var showingRecurrenceSheet = false

    init(task: TaskItem) {
        self.task = task
        self._hasStartDate = State(initialValue: task.startDate != nil)
        self._hasDueDate = State(initialValue: task.dueDate != nil)
        self._isAllDay = State(initialValue: task.isDueDateOnly)
    }

    var body: some View {
        Section("Dates") {
            Toggle(isOn: $hasStartDate) {
                Label("Start Date", systemImage: "play.circle")
            }
            .onChange(of: hasStartDate) { _, newValue in
                task.startDate = newValue ? (task.startDate ?? Date()) : nil
            }

            if hasStartDate {
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { task.startDate ?? Date() },
                        set: { task.startDate = $0 }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
            }

            Toggle(isOn: $hasDueDate) {
                Label("Due Date", systemImage: "calendar.badge.clock")
            }
            .onChange(of: hasDueDate) { _, newValue in
                if newValue {
                    // Newly enabled due dates are timed at the default due time so
                    // the row shows a clock time; users can flip to All Day below.
                    if task.dueDate == nil {
                        task.dueDate = DueDateHelper.timedValue(
                            for: Date(),
                            minutesSinceMidnight: TaskDefaultsPreferences.dueTimeMinutes
                        )
                    }
                    task.isDueDateOnly = false
                    isAllDay = false
                } else {
                    task.dueDate = nil
                    task.isDueDateOnly = false
                    isAllDay = false
                    if task.reminderOffset != nil {
                        ReminderScheduler.cancelReminder(for: task.id)
                    }
                    task.reminderOffset = nil
                    task.recurrenceRule = nil
                }
            }

            if hasDueDate {
                Toggle(isOn: Binding(
                    get: { isAllDay },
                    set: { setAllDay($0) }
                )) {
                    Label("All Day", systemImage: "clock")
                }
                .accessibilityHint("When on, the task is due on the whole day with no specific time and its row shows \"All day\"")

                DatePicker(
                    "Due",
                    selection: Binding(
                        get: {
                            guard let due = task.dueDate else { return Date() }
                            return isAllDay
                                ? DueDateHelper.localStartOfDay(for: due, isDateOnly: true)
                                : due
                        },
                        set: { newValue in
                            task.dueDate = isAllDay
                                ? DueDateHelper.dateOnlyValue(for: newValue)
                                : newValue
                        }
                    ),
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .onChange(of: task.dueDate) { _, _ in
                    if task.reminderOffset != nil {
                        ReminderScheduler.scheduleReminder(for: task)
                    }
                }

                Picker(selection: Binding(
                    get: { task.reminderOffset },
                    set: { newValue in
                        task.reminderOffset = newValue
                        if newValue != nil {
                            ReminderScheduler.requestPermissionIfNeeded()
                            ReminderScheduler.scheduleReminder(for: task)
                        } else {
                            ReminderScheduler.cancelReminder(for: task.id)
                        }
                    }
                )) {
                    Text("None").tag(nil as Int?)
                    Text("At due time").tag(0 as Int?)
                    Text("5 minutes before").tag(300 as Int?)
                    Text("15 minutes before").tag(900 as Int?)
                    Text("30 minutes before").tag(1800 as Int?)
                    Text("1 hour before").tag(3600 as Int?)
                    Text("1 day before").tag(86400 as Int?)
                } label: {
                    Label("Reminder", systemImage: "bell")
                }

                // Hourly nag — visible when a reminder is set
                if task.reminderOffset != nil {
                    Toggle(isOn: Binding(
                        get: { task.isNaggingReminder },
                        set: { newValue in
                            task.isNaggingReminder = newValue
                            ReminderScheduler.scheduleReminder(for: task)
                        }
                    )) {
                        Label("Repeat Hourly Until Done", systemImage: "bell.and.waves.left.and.right")
                    }
                    .tint(.orange)
                }
            }

            // Recurrence — always visible; auto-enables due date if needed
            Button {
                if !hasDueDate {
                    hasDueDate = true
                    task.dueDate = Date()
                }
                showingRecurrenceSheet = true
            } label: {
                HStack {
                    Label("Repeat", systemImage: "repeat")
                    Spacer()
                    Text(recurrenceDisplayText)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showingRecurrenceSheet) {
                RecurrencePickerSheet(recurrenceRule: $task.recurrenceRule)
            }
            .onChange(of: task.recurrenceRule) { _, newValue in
                task.lastModifiedDate = Date()
                task.isDirty = true
                // Auto-enable due date when recurrence is set
                if newValue != nil && !hasDueDate {
                    hasDueDate = true
                    task.dueDate = Date()
                }
            }
        }
    }

    private var recurrenceDisplayText: String {
        guard let rrule = task.recurrenceRule,
              let rule = RecurrenceRule.parse(rrule) else {
            return "Never"
        }
        return rule.displayText
    }

    /// Switches the due date between all-day (date-only) and timed, converting the
    /// stored value so the calendar day is preserved. Timed values gain the default
    /// due time; all-day values drop the time and round-trip to `DUE;VALUE=DATE`.
    private func setAllDay(_ allDay: Bool) {
        guard allDay != isAllDay else { return }
        isAllDay = allDay
        task.isDueDateOnly = allDay
        let current = task.dueDate ?? Date()
        if allDay {
            task.dueDate = DueDateHelper.dateOnlyValue(for: current)
        } else {
            let localDay = DueDateHelper.localStartOfDay(for: current, isDateOnly: true)
            task.dueDate = DueDateHelper.timedValue(
                for: localDay,
                minutesSinceMidnight: TaskDefaultsPreferences.dueTimeMinutes
            )
        }
        if task.reminderOffset != nil {
            ReminderScheduler.scheduleReminder(for: task)
        }
    }
}

// MARK: - Recurrence Picker Sheet

struct RecurrencePickerSheet: View {
    @Binding var recurrenceRule: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPreset: RecurrencePreset
    @State private var customFrequency: RecurrenceRule.Frequency = .weekly
    @State private var customInterval: Int = 1
    @State private var customByDay: Set<RecurrenceRule.Weekday> = []

    enum RecurrencePreset: String, CaseIterable, Identifiable {
        case never = "Never"
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        case yearly = "Yearly"
        case custom = "Custom"

        var id: String { rawValue }
    }

    init(recurrenceRule: Binding<String?>) {
        self._recurrenceRule = recurrenceRule
        // Determine initial preset from existing rule
        if let rrule = recurrenceRule.wrappedValue, let rule = RecurrenceRule.parse(rrule) {
            if rule.interval == 1 && rule.byDay.isEmpty {
                switch rule.frequency {
                case .daily: self._selectedPreset = State(initialValue: .daily)
                case .weekly: self._selectedPreset = State(initialValue: .weekly)
                case .monthly: self._selectedPreset = State(initialValue: .monthly)
                case .yearly: self._selectedPreset = State(initialValue: .yearly)
                }
            } else {
                self._selectedPreset = State(initialValue: .custom)
            }
            self._customFrequency = State(initialValue: rule.frequency)
            self._customInterval = State(initialValue: rule.interval)
            self._customByDay = State(initialValue: Set(rule.byDay))
        } else {
            self._selectedPreset = State(initialValue: .never)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RecurrencePreset.allCases) { preset in
                        Button {
                            selectedPreset = preset
                        } label: {
                            HStack {
                                Text(preset.rawValue)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                if selectedPreset == .custom {
                    Section("Frequency") {
                        Picker("Every", selection: $customFrequency) {
                            ForEach(RecurrenceRule.Frequency.allCases) { freq in
                                Text(freq.displayName).tag(freq)
                            }
                        }

                        Stepper("Every \(customInterval) \(intervalUnit)", value: $customInterval, in: 1...99)
                    }

                    if customFrequency == .weekly {
                        Section("Days of Week") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                                ForEach(RecurrenceRule.Weekday.allCases) { day in
                                    Button {
                                        if customByDay.contains(day) {
                                            customByDay.remove(day)
                                        } else {
                                            customByDay.insert(day)
                                        }
                                    } label: {
                                        Text(day.shortName)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                customByDay.contains(day)
                                                    ? Color.blue : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8)
                                            )
                                            .foregroundStyle(
                                                customByDay.contains(day) ? .white : .primary
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Repeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        applyRule()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var intervalUnit: String {
        switch customFrequency {
        case .daily: return customInterval == 1 ? "day" : "days"
        case .weekly: return customInterval == 1 ? "week" : "weeks"
        case .monthly: return customInterval == 1 ? "month" : "months"
        case .yearly: return customInterval == 1 ? "year" : "years"
        }
    }

    private func applyRule() {
        switch selectedPreset {
        case .never:
            recurrenceRule = nil
        case .daily:
            recurrenceRule = "FREQ=DAILY"
        case .weekly:
            recurrenceRule = "FREQ=WEEKLY"
        case .monthly:
            recurrenceRule = "FREQ=MONTHLY"
        case .yearly:
            recurrenceRule = "FREQ=YEARLY"
        case .custom:
            let rule = RecurrenceRule(
                frequency: customFrequency,
                interval: customInterval,
                byDay: Array(customByDay).sorted(by: { $0.calendarWeekday < $1.calendarWeekday }),
                count: nil,
                until: nil
            )
            recurrenceRule = rule.toRRULEString()
        }
    }
}

// MARK: - Details Section

private struct DetailsSection: View {
    @Bindable var task: TaskItem
    @State private var showingLocationPicker = false

    var body: some View {
        Section("Details") {
            Button {
                showingLocationPicker = true
            } label: {
                HStack {
                    Label("Location", systemImage: "mappin")
                    Spacer()
                    if let name = task.locationName {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(name)
                                .font(.subheadline)
                            if let radius = task.geofenceRadius {
                                Text("\(Int(radius))m radius")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text("None")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("Location, \(task.locationName ?? "not set")")
            .sheet(isPresented: $showingLocationPicker) {
                LocationPickerView(task: task)
            }

            HStack {
                Label("URL", systemImage: "link")
                Spacer()
                TextField("https://...", text: Binding(
                    get: { task.url ?? "" },
                    set: { task.url = $0.isEmpty ? nil : $0 }
                ))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            }
        }
    }
}

// MARK: - Notes Section

private struct NotesSection: View {
    @Bindable var task: TaskItem

    var body: some View {
        Section("Notes") {
            TextEditor(text: Binding(
                get: { task.descriptionText ?? "" },
                set: { task.descriptionText = $0.isEmpty ? nil : $0 }
            ))
            .frame(minHeight: 100)
            .font(.body)
        }
    }
}

// MARK: - Subtasks Section

private struct SubtasksSection: View {
    @Bindable var task: TaskItem
    let onAddSubtask: () -> Void

    var body: some View {
        Section {
            ForEach(activeSubtasks) { subtask in
                SubtaskRow(subtask: subtask)
            }

            Button(action: onAddSubtask) {
                Label("Add Subtask", systemImage: "plus.circle")
                    .foregroundStyle(.blue)
            }
        } header: {
            HStack {
                Text("Subtasks")
                Spacer()
                if !activeSubtasks.isEmpty {
                    Text("\(completedCount)/\(activeSubtasks.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeSubtasks: [TaskItem] {
        task.subtasks.filter { !$0.isDeletedLocally }
    }

    private var completedCount: Int {
        activeSubtasks.filter { $0.status == .completed }.count
    }
}

private struct SubtaskRow: View {
    @Bindable var subtask: TaskItem
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 10) {
            Button {
                toggleSubtask()
            } label: {
                Image(systemName: subtask.status == .completed
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        subtask.status == .completed ? .green : .secondary
                    )
            }
            .buttonStyle(.plain)

            Text(subtask.title)
                .strikethrough(subtask.status == .completed)
                .foregroundStyle(
                    subtask.status == .completed ? .secondary : .primary
                )

            Spacer()
        }
    }

    private func toggleSubtask() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if subtask.status == .completed {
                subtask.status = .needsAction
                subtask.completedDate = nil
            } else {
                subtask.status = .completed
                subtask.completedDate = Date()
            }
            subtask.lastModifiedDate = Date()
            subtask.isDirty = true
        }
        HapticManager.checkbox()
        try? modelContext.save()
    }
}

// MARK: - Add Subtask Sheet

private struct AddSubtaskSheet: View {
    let parentTask: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var subtaskTitle = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("Subtask name", text: $subtaskTitle)
                    .font(.title3)
                    .focused($isFocused)
                    .padding(16)
                    .glassBackground(in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("Add Subtask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { createSubtask() }
                        .fontWeight(.semibold)
                        .disabled(subtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func createSubtask() {
        let trimmed = subtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let subtask = TaskItem(title: trimmed)
        subtask.parentTask = parentTask
        subtask.taskList = parentTask.taskList
        subtask.parentUID = parentTask.uid
        subtask.isDirty = true

        modelContext.insert(subtask)
        try? modelContext.save()
        HapticManager.success()
        dismiss()
    }
}

// MARK: - TaskStatus Extension

// MARK: - TaskStatus Extension

extension TaskStatus {
    var displayLabel: String {
        switch self {
        case .needsAction: return "To Do"
        case .inProcess: return "In Progress"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Linked Journals Section

/// Shows journal entries linked to this task (P12-4).
private struct LinkedJournalsSection: View {
    let task: TaskItem

    var body: some View {
        if !task.associatedJournals.isEmpty {
            Section("Linked Journals") {
                ForEach(task.associatedJournals) { journal in
                    NavigationLink {
                        JournalEditorView(mode: .edit(journal))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(journal.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(journal.createdDate, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel("\(journal.title), journal entry")
                }
            }
        }
    }
}

// MARK: - Tags Section

private struct TagsSection: View {
    @Bindable var task: TaskItem
    @State private var showingTagPicker = false

    var body: some View {
        Section("Tags") {
            if !task.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(task.tags) { tag in
                        TagPill(tag: tag) {
                            withAnimation {
                                task.tags.removeAll { $0.id == tag.id }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button(action: { showingTagPicker = true }) {
                Label("Add Tag", systemImage: "tag")
                    .foregroundStyle(.purple)
            }
        }
        .sheet(isPresented: $showingTagPicker) {
            TagPickerSheet(task: task)
        }
    }
}

private struct TagPill: View {
    let tag: Tag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(pillColor)
                .frame(width: 8, height: 8)
            Text(tag.name)
                .font(.caption)
                .fontWeight(.medium)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(pillColor.opacity(0.12), in: Capsule())
        .foregroundStyle(pillColor)
    }

    private var pillColor: Color {
        if let hex = tag.color {
            return Color(hex: hex) ?? .purple
        }
        return .purple
    }
}

/// Simple horizontal flow layout for tag pills.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: - Tag Picker Sheet

private struct TagPickerSheet: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTagName = ""
    @State private var newTagColor = "#AF52DE"

    private let colors = [
        "#007AFF", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#5856D6", "#AF52DE", "#FF2D55"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Existing Tags") {
                    ForEach(allTags) { tag in
                        Button {
                            toggleTag(tag)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tagColor(tag))
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if task.tags.contains(where: { $0.id == tag.id }) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }

                Section("Create New Tag") {
                    TextField("Tag name", text: $newTagName)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { hex in
                            Button {
                                newTagColor = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .purple)
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if newTagColor == hex {
                                            Circle()
                                                .strokeBorder(.white, lineWidth: 2)
                                                .frame(width: 16, height: 16)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    Button("Create & Add") {
                        createAndAddTag()
                    }
                    .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleTag(_ tag: Tag) {
        if let index = task.tags.firstIndex(where: { $0.id == tag.id }) {
            task.tags.remove(at: index)
        } else {
            task.tags.append(tag)
        }
    }

    private func tagColor(_ tag: Tag) -> Color {
        if let hex = tag.color {
            return Color(hex: hex) ?? .purple
        }
        return .purple
    }

    private func createAndAddTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, color: newTagColor)
        modelContext.insert(tag)
        task.tags.append(tag)
        newTagName = ""
        HapticManager.success()
    }
}
