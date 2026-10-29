import SwiftUI
import SwiftData
import os

/// Full-featured task editor with all VTODO fields.
///
/// Decomposed into focused sub-views per section so that each `body` stays
/// under 50 lines and the type-checker keeps up with the nesting.
struct TaskDetailView: View {
    private static let logger = Logger(subsystem: "com.nowthis", category: "task-detail")

    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var showingAddSubtask = false
    @State private var selectedPhoto: TaskPhotoSelection?
    @StateObject private var photoEditor = TaskPhotoEditorState()

    var body: some View {
        // An open detail view outlives the task it edits: deleting an account
        // cascades ServerAccount → TaskList → TaskItem on the main context, and
        // the next body evaluation would read an invalidated model and trap in
        // SwiftData (`BackingData.swift:249`). Unlike a row, this view can't
        // render from a value snapshot — its sections hold two-way `$task`
        // bindings — so it checks liveness and leaves instead.
        if task.modelContext == nil {
            Color.clear
                .onAppear { dismiss() }
        } else {
            editor
        }
    }

    private var editor: some View {
        Form {
            TitleSection(task: task)
            StatusSection(task: task)
            DatesSection(task: task)
            DetailsSection(task: task)
            TagsSection(task: task)
            NotesSection(task: task)
            TaskPhotosSection(task: task, onSelectPhoto: { photoID in
                selectedPhoto = TaskPhotoSelection(id: photoID)
            }, editor: photoEditor)
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
        .onChange(of: task.title) { _, _ in reminderEditDidChange() }
        .onChange(of: task.status) { _, _ in reminderEditDidChange() }
        // Present outside the Form: recycled section cells must not own the viewer.
        .sheet(item: $selectedPhoto) { selection in
            TaskPhotoViewer(task: task, photoID: selection.id)
        }
        .sheet(isPresented: $photoEditor.showingCamera, onDismiss: { photoEditor.cancelCamera() }) {
            TaskPhotoCamera(onCapture: photoEditor.captured,
                onCancel: photoEditor.cancelCamera, onFailure: photoEditor.cameraFailed)
                .ignoresSafeArea()
        }
        .alert("Photo Error", isPresented: Binding(
            get: { photoEditor.photoError != nil },
            set: { if !$0 { photoEditor.photoError = nil } }), presenting: photoEditor.photoError) { _ in
                Button("OK", role: .cancel) { photoEditor.photoError = nil }
        } message: { error in
            Text(error.message(locale: locale))
        }
        .onAppear { photoEditor.isActive = true }
        .onDisappear { photoEditor.cancelImport() }
        .sheet(isPresented: $showingAddSubtask) {
            AddSubtaskSheet(parentTask: task)
        }
    }

    private func reminderEditDidChange() {
        do {
            try Self.saveReminderEdit(task, in: modelContext)
        } catch {
            Self.logger.error("Failed to save detail reminder edit: \(error.localizedDescription)")
        }
    }

    @MainActor
    static func saveReminderEdit(
        _ task: TaskItem,
        in context: ModelContext,
        requestReconcile: @MainActor (ModelContext) -> Void = ReminderScheduler.requestReconcile
    ) throws {
        guard task.modelContext != nil else { return }
        try BackgroundRunBudget.protectingCurrent {
            task.lastModifiedDate = Date()
            task.isDirty = true
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }
        requestReconcile(context)
    }

    private func saveAndDismiss() {
        do {
            try Self.saveReminderEdit(task, in: modelContext)
        } catch {
            Self.logger.error("Failed to save task details: \(error.localizedDescription)")
            return
        }
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
                // An empty label literal extracted as the `""` key. The visible label is the
                // `Label` beside it; VoiceOver gets it explicitly rather than by proximity.
                Picker(selection: $task.status) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Status")
            }

            HStack {
                Label("Priority", systemImage: "flag")
                Spacer()
                Picker(selection: $task.priority) {
                    ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { pri in
                        Label(pri.displayName, systemImage: pri.icon).tag(pri)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Priority")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Progress", systemImage: "chart.bar")
                    Spacer()
                    // `.percent` places the sign where the language puts it — French and the
                    // Nordic languages use a space before it, and some scripts put it first.
                    Text(Double(task.percentComplete) / 100, format: .percent.precision(.fractionLength(0)))
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
    /// Every control in this section changes what the scheduler should have pending, so it
    /// needs a context of its own to ask for a re-plan with.
    @Environment(\.modelContext) private var modelContext
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
                    task.reminderOffset = nil
                    task.recurrenceRule = nil
                }
                ReminderScheduler.requestReconcile(modelContext: modelContext)
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
                    // Not gated on `reminderOffset`: moving a bare due date has to move its
                    // overdue-badge notification too, or the badge fires at the old deadline.
                    ReminderScheduler.requestReconcile(modelContext: modelContext)
                }

                Picker(selection: Binding(
                    get: { task.reminderOffset },
                    set: { newValue in
                        task.reminderOffset = newValue
                        if newValue != nil {
                            ReminderScheduler.requestPermissionIfNeeded()
                        }
                        // Either way the plan changes: clearing a reminder on a still-dated task
                        // turns it into an overdue-badge notification rather than nothing.
                        ReminderScheduler.requestReconcile(modelContext: modelContext)
                    }
                )) {
                    // Already localized at the literal inside String(localized:), so the
                    // verbatim initializer is the correct one here.
                    Text(verbatim: String(
                        localized: "reminder.none", defaultValue: "None",
                        comment: "Reminder picker value meaning the task has no reminder. Answers 'Reminder: ?', so the word agrees with the target language's word for reminder — masculine in Spanish, French and Italian. Do not share this key with the priority, location or empty-quadrant 'None'."))
                        .tag(nil as Int?)
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
                            ReminderScheduler.requestReconcile(modelContext: modelContext)
                        }
                    )) {
                        Label(String(
                            localized: "reminder.nag.toggle",
                            defaultValue: "Repeat Hourly Until Completed",
                            comment: "Toggle in the Reminder section that makes a reminder fire every hour until the task is completed. 'Completed' here is the task STATE — the same word as the Completed status, not the sheet-dismiss Done button. The recurrence control sits directly below this row, so the verb must not be the one used for a repeating task."),
                              systemImage: "bell.and.waves.left.and.right")
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
            return String(localized: "taskDetail.recurrence.never", defaultValue: "Never", comment: "Value shown next to the Repeat row in Task Detail when the task has no recurrence rule set")
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
        ReminderScheduler.requestReconcile(modelContext: modelContext)
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

        var displayName: String {
            switch self {
            case .never:
                return String(localized: "recurrence.preset.never", defaultValue: "Never",
                              comment: "Recurrence preset: the task does not repeat. Answers 'Repeats: ?'.")
            case .daily:
                return String(localized: "recurrence.preset.daily", defaultValue: "Daily",
                              comment: "Recurrence preset: repeats every day.")
            case .weekly:
                return String(localized: "recurrence.preset.weekly", defaultValue: "Weekly",
                              comment: "Recurrence preset: repeats every week.")
            case .monthly:
                return String(localized: "recurrence.preset.monthly", defaultValue: "Monthly",
                              comment: "Recurrence preset: repeats every month.")
            case .yearly:
                return String(localized: "recurrence.preset.yearly", defaultValue: "Yearly",
                              comment: "Recurrence preset: repeats every year.")
            case .custom:
                return String(localized: "recurrence.preset.custom", defaultValue: "Custom",
                              comment: "Recurrence preset: the user defines their own interval and weekdays.")
            }
        }
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
                                Text(preset.displayName)
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

                        Stepper(value: $customInterval, in: 1...99) {
                            Text(verbatim: intervalLabel)
                        }
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
                                        Text(verbatim: day.shortName())
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

    /// The stepper's whole label, not a unit spliced into a shared template.
    ///
    /// `"Every %lld %@"` cannot be translated. German inflects the phrase with the numeral —
    /// *jeden Tag* for one, *alle 2 Tage* for more — so the noun and the number are not
    /// separable, and a translator handed the bare unit `"day"` has no sentence to put it in.
    /// Four complete templates, each plural-varied in the catalog.
    private var intervalLabel: String {
        switch customFrequency {
        case .daily:
            return String(localized: "recurrence.custom.interval.daily",
                          defaultValue: "Every \(customInterval) days",
                          comment: "Label on the stepper that sets how often a task repeats, for a daily rule. The placeholder is the interval in days.")
        case .weekly:
            return String(localized: "recurrence.custom.interval.weekly",
                          defaultValue: "Every \(customInterval) weeks",
                          comment: "Label on the stepper that sets how often a task repeats, for a weekly rule. The placeholder is the interval in weeks.")
        case .monthly:
            return String(localized: "recurrence.custom.interval.monthly",
                          defaultValue: "Every \(customInterval) months",
                          comment: "Label on the stepper that sets how often a task repeats, for a monthly rule. The placeholder is the interval in months.")
        case .yearly:
            return String(localized: "recurrence.custom.interval.yearly",
                          defaultValue: "Every \(customInterval) years",
                          comment: "Label on the stepper that sets how often a task repeats, for a yearly rule. The placeholder is the interval in years.")
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
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var showingLocationPicker = false
    @State private var moveRequest: MoveToListRequest?

    /// Spoken stand-in when the task has no location. Deliberately the same key the
    /// visible label uses, so VoiceOver and the screen say the same word.
    private static let noLocationSpoken = String(
        localized: "location.none", defaultValue: "None",
        comment: "Shown in place of a location when the task has none, and spoken as the second half of the row's VoiceOver label. Answers 'Location: ?', so the word agrees with the target language's word for location. Do not share this key with the priority, reminder or empty-quadrant 'None'.")

    var body: some View {
        Section("Details") {
            listRow

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
                                Text(verbatim: String(
                                    localized: "location.geofence.radiusValue",
                                    defaultValue: "\(Measurement(value: radius, unit: UnitLength.meters).formatted(.measurement(width: .narrow))) radius",
                                    comment: "Caption under the geofence slider showing how large the trigger area is. The placeholder is an already-formatted distance with its unit, e.g. \"50 m\"."))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: String(
                            localized: "location.none", defaultValue: "None",
                            comment: "Shown in place of a location when the task has none. Answers 'Location: ?', so the word agrees with the target language's word for location. Do not share this key with the priority, reminder or empty-quadrant 'None'."))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .foregroundStyle(.primary)
            // The `%@` is spoken, so its fallback has to be localized too. A bare "not set"
            // here made VoiceOver say "Ort, not set" beside a screen correctly reading
            // "Keiner" — the outer key translates, the argument filling it did not.
            .accessibilityLabel("Location, \(task.locationName ?? Self.noLocationSpoken)")
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

extension DetailsSection {
    /// Shows which list the task is in, and moves it to another.
    private var listRow: some View {
        Button {
            moveRequest = MoveToListRequest(task: task)
        } label: {
            HStack {
                Label("List", systemImage: "list.bullet")
                Spacer()
                if let list = task.taskList {
                    Circle()
                        .fill(Color(hex: list.colorHex) ?? .blue)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(verbatim: list.name)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(!MoveDestinations.canMove(task))
        // Reads "List, Work"; the button trait says it can be changed.
        .accessibilityElement(children: .combine)
        .sheet(item: $moveRequest) { request in
            MoveToListSheet(request: request) { listID in
                guard MoveDestinations.perform(task, toListID: listID, in: modelContext) else { return }
                syncScheduler.syncAfterChange(modelContext: modelContext)
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
                    // Two numbers and a solidus — no words, so no catalog entry. `verbatim`
                    // keeps it out of the catalog while `formatted()` still applies the locale's
                    // digits and grouping.
                    Text(verbatim: "\(completedCount.formatted())/\(activeSubtasks.count.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeSubtasks: [TaskItem] {
        // The traversal itself has to be safe: the section reads its children
        // before anything checks the parent's own liveness, and reading
        // `subtasks` on a task an account delete has cascaded away traps in
        // SwiftData rather than returning nothing. Same guard as
        // `TaskListHelpers.orderedSubtasksIfLive`, without imposing its sort.
        guard task.modelContext != nil else { return [] }
        return task.subtasks.filter { $0.modelContext != nil && !$0.isDeletedLocally }
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
            // Same two literals the row's checkbox uses, so the two checkboxes
            // read as one control. An all-literal ternary binds the
            // LocalizedStringKey overload; a mixed one would ship verbatim.
            .accessibilityLabel(subtask.status == .completed ? "Completed" : "Not completed")
            .accessibilityAddTraits(.isButton)

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
        do { try ReminderSchedulingJournal.saveTaskChanges(in: modelContext) }
        catch { return }
        if subtask.status == .completed { ReminderScheduler.cancelReminder(for: subtask.id) }
        ReminderScheduler.requestReconcile(modelContext: modelContext)
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
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        HapticManager.success()
        dismiss()
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
                                TaskListHelpers.markTagsChanged(on: task)
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
            // Named, not just "Remove": a task with five tags gives VoiceOver
            // five identical buttons otherwise. Localized at the literal via
            // `String(localized:)` because the tag name is user data — handing
            // the composed String to `.accessibilityLabel` would bind the
            // disfavored StringProtocol overload and never reach the catalog.
            .accessibilityLabel(String(
                localized: "taskDetail.tag.a11y.remove",
                defaultValue: "Remove tag \(tag.name)",
                comment: "VoiceOver label for the small x button on a tag pill in Task Detail, which takes that tag off the task. The placeholder is the user's own tag name."))
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
                    TextField(String(localized: "tag.field.name",
                                     defaultValue: "Tag name",
                                     comment: "Placeholder in the text field where a new tag's name is typed. One key for both places a tag can be created — the task detail sheet and the sidebar."),
                              text: $newTagName)
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
        // Or the change neither reaches the server nor survives the next pull.
        TaskListHelpers.markTagsChanged(on: task)
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
        TaskListHelpers.markTagsChanged(on: task)
        newTagName = ""
        HapticManager.success()
    }
}
