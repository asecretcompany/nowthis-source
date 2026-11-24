import SwiftUI
import SwiftData

/// Full-featured task editor with all VTODO fields.
///
/// Decomposed into focused sub-views per section so that each `body` stays
/// under 50 lines and the type-checker keeps up with the nesting.
struct TaskDetailView: View {

    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @AppStorage(TaskDetailSection.storageKey) private var storedSectionOrder = ""
    @State private var textDraft: TaskTextDraft
    @State private var showingTagPicker = false
    @State private var showingAddSubtask = false
    @State private var selectedPhoto: TaskPhotoSelection?
    @StateObject private var photoEditor = TaskPhotoEditorState()

    init(task: TaskItem) {
        self.task = task
        // Keep the existing deleted-model guard ahead of all property reads, including init.
        _textDraft = State(initialValue: task.modelContext == nil ? TaskTextDraft() : TaskTextDraft(task))
    }

    var body: some View {
        // An open detail view outlives the task it edits: deleting an account
        // cascades ServerAccount → TaskList → TaskItem on the main context, and
        // the next body evaluation would read an invalidated model and trap in
        // SwiftData (`BackingData.swift:249`). Unlike a row, this view can't
        // render solely from a value snapshot because its sections read the task
        // for their live controls, so it checks liveness and leaves instead.
        if task.modelContext == nil {
            Color.clear
                .onAppear { dismiss() }
        } else {
            editor
        }
    }

    private var editor: some View {
        Form {
            ForEach(TaskDetailSection.decodeOrder(from: storedSectionOrder)) { section in
                detailSection(section)
            }
        }
        .environment(\.saveErrorState, errorState)
        .errorBanner(errorState)
        .navigationTitle("Task Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndDismiss() }
                    .fontWeight(.semibold)
            }
            ToolbarItem(placement: .secondaryAction) {
                AddToCalendarButton(task: task, errorState: errorState)
            }
            if textDraft.hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard Text Changes") {
                        textDraft.discard()
                        textDraft.refresh(from: task)
                    }
                }
            }
        }
        .interactiveDismissDisabled(textDraft.hasChanges)
        .navigationBarBackButtonHidden(textDraft.hasChanges)
        .onChange(of: task.title) { _, _ in textDraft.refresh(from: task) }
        .onChange(of: task.descriptionText) { _, _ in textDraft.refresh(from: task) }
        // Keep sheets on the editor so they survive changes to the Form's rows.
        .sheet(isPresented: $showingTagPicker) {
            TagPickerSheet(task: task)
        }
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
        .blocksTaskLinks()
    }

    @ViewBuilder
    private func detailSection(_ section: TaskDetailSection) -> some View {
        switch section {
        case .title:
            TitleSection(title: $textDraft.title)
        case .status:
            StatusSection(task: task)
        case .dates:
            DatesSection(task: task)
        case .details:
            DetailsSection(task: task)
        case .tags:
            TagsSection(task: task, onAddTag: { showingTagPicker = true })
        case .notes:
            NotesSection(notes: $textDraft.notes)
        case .photos:
            TaskPhotosSection(task: task, onSelectPhoto: { photoID in
                selectedPhoto = TaskPhotoSelection(id: photoID)
            }, editor: photoEditor)
        case .subtasks:
            SubtasksSection(task: task, onAddSubtask: { showingAddSubtask = true })
        case .linkedJournals:
            LinkedJournalsSection(task: task)
        }
    }

    @MainActor
    static func saveReminderEdit(
        _ task: TaskItem,
        in context: ModelContext,
        requestReconcile: @MainActor (ModelContext) throws -> Void = ReminderScheduler.requestReconcileOrThrow
    ) throws {
        guard task.modelContext != nil else { return }
        try BackgroundRunBudget.protectingCurrent {
            task.lastModifiedDate = Date()
            task.isDirty = true
            try ReminderSchedulingJournal.saveTaskChanges(in: context)
        }
        try requestReconcile(context)
    }

    @MainActor
    fileprivate static func admitEdit(to task: TaskItem, in context: ModelContext,
                                      errorState: ErrorState?) -> Bool {
        do {
            _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
            return true
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
    }

    /// Reads values that can change while an editor remains open without returning a model from the reader.
    @MainActor
    fileprivate static func readCommitted<Value>(_ task: TaskItem, in context: ModelContext,
                                                 value: (TaskItem) -> Value) throws -> Value {
        let id = task.persistentModelID
        guard task.modelContext === context, !context.deletedModelsArray.contains(where: { $0.persistentModelID == id }) else {
            throw TaskWriteEligibility.Refusal.taskUnavailable
        }
        let reader = ModelContext(context.container)
        reader.autosaveEnabled = false
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.includePendingChanges = false
        descriptor.fetchLimit = 1
        guard let stored = try reader.fetch(descriptor).first, stored.persistentModelID == id,
              !stored.isDeletedLocally, !task.isDeletedLocally else {
            throw TaskWriteEligibility.Refusal.taskUnavailable
        }
        return value(stored)
    }

    @MainActor
    @discardableResult
    static func applyDueDateToggle(
        _ enabled: Bool, to task: TaskItem, in context: ModelContext,
        errorState: ErrorState?,
        requestReconcile: @MainActor (ModelContext, (Error) -> Void) -> Bool =
            ReminderScheduler.requestReconcile(modelContext:onSaveFailure:)
    ) -> Bool {
        guard admitEdit(to: task, in: context, errorState: errorState) else { return false }
        if enabled {
            // Newly enabled due dates are timed at the default due time so
            // the row shows a clock time; users can flip to All Day below.
            if task.dueDate == nil {
                task.dueDate = DueDateHelper.timedValue(
                    for: Date(),
                    minutesSinceMidnight: TaskDefaultsPreferences.dueTimeMinutes
                )
            }
            task.isDueDateOnly = false
        } else {
            task.dueDate = nil
            task.isDueDateOnly = false
            task.reminderOffset = nil
            if task.recurrenceRule != nil {
                task.recurrenceRule = nil
                task.lastModifiedDate = Date()
                task.isDirty = true
            }
        }
        return requestReconcile(context) { ViewPersistence.report($0, to: errorState) }
    }

    @MainActor
    @discardableResult
    static func applyReminderOffset(
        _ offset: Int?, to task: TaskItem, in context: ModelContext,
        errorState: ErrorState?,
        requestPermission: @MainActor () -> Void = ReminderScheduler.requestPermissionIfNeeded,
        requestReconcile: @MainActor (ModelContext, (Error) -> Void) -> Bool =
            ReminderScheduler.requestReconcile(modelContext:onSaveFailure:)
    ) -> Bool {
        guard admitEdit(to: task, in: context, errorState: errorState) else { return false }
        task.reminderOffset = offset
        if offset != nil { requestPermission() }
        // Clearing the offset on a dated task changes its reminder into an overdue badge.
        return requestReconcile(context) { ViewPersistence.report($0, to: errorState) }
    }

    @MainActor
    @discardableResult
    static func applyHourlyNag(
        _ enabled: Bool, to task: TaskItem, in context: ModelContext,
        errorState: ErrorState?,
        requestReconcile: @MainActor (ModelContext, (Error) -> Void) -> Bool =
            ReminderScheduler.requestReconcile(modelContext:onSaveFailure:)
    ) -> Bool {
        do { try readCommitted(task, in: context) { _ in } }
        catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
        // Hourly nag is a device preference and uses the existing reminder recovery save.
        task.isNaggingReminder = enabled
        return requestReconcile(context) { ViewPersistence.report($0, to: errorState) }
    }

    @MainActor
    static func applyRecurrenceRule(
        _ rule: String?, replacing original: String?, committedAtOpen: String?,
        to task: TaskItem, in context: ModelContext, errorState: ErrorState?,
        requestReconcile: @MainActor (ModelContext, (Error) -> Void) -> Bool =
            ReminderScheduler.requestReconcile(modelContext:onSaveFailure:)
    ) -> Bool {
        guard rule != original else { return true }
        do {
            _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
            let stored = try readCommitted(task, in: context) { (rule: $0.recurrenceRule, hasDueDate: $0.dueDate != nil) }
            guard (stored.rule == committedAtOpen || stored.rule == original),
                  RecurrenceRule.isPickerRepresentable(stored.rule) else {
                throw TaskWriteEligibility.Refusal.targetChanged
            }
            guard task.recurrenceRule == original else { throw TaskWriteEligibility.Refusal.targetChanged }
            let needsDueDate = rule != nil && !stored.hasDueDate && task.dueDate == nil
            let priorDateOnly = task.isDueDateOnly
            let priorModified = task.lastModifiedDate
            let priorDirty = task.isDirty
            task.recurrenceRule = rule
            task.lastModifiedDate = Date()
            task.isDirty = true
            guard needsDueDate else { return true }
            task.dueDate = Date()
            task.isDueDateOnly = false
            guard requestReconcile(context, { ViewPersistence.report($0, to: errorState) }) else {
                task.recurrenceRule = original
                task.dueDate = nil
                task.isDueDateOnly = priorDateOnly
                task.lastModifiedDate = priorModified
                task.isDirty = priorDirty
                return false
            }
            return true
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
    }

    /// Shared by the status menu and subtask checkbox. Validation precedes every save
    /// and reminder effect, including when recurrence advances without changing status.
    @MainActor
    static func applyStatusChange(
        _ status: TaskStatus, to task: TaskItem, in context: ModelContext,
        save: (() throws -> Void)? = nil,
        errorState: ErrorState? = nil,
        requestReconcile: @escaping @MainActor (ModelContext) throws -> Void = ReminderScheduler.requestReconcileOrThrow,
        cancelReminder: @MainActor (String) -> Void = ReminderScheduler.cancelReminder
    ) throws {
        _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
        let snapshot = TaskStatusSnapshot(task)
        let completed = try TaskCompletionLogic.apply(status, to: task)
        do { try ReminderSchedulingJournal.saveTaskChanges(in: context, save: save) }
        catch {
            snapshot.restore()
            throw error
        }
        if completed { cancelReminder(task.id) }
        ViewPersistence.recoverRemindersAfterCommit(errorState: errorState) {
            try requestReconcile(context)
        }
    }

    @MainActor
    static func applyDone(to task: TaskItem, textDraft: TaskTextDraft, in modelContext: ModelContext,
                          errorState: ErrorState, afterCommit: () -> Void, dismiss: () -> Void) {
        do { _ = try TaskWriteEligibility(writingIn: modelContext).task(.retained(task)) }
        catch TaskWriteEligibility.Refusal.readOnly where !textDraft.hasChanges {
            dismiss()
            return
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return
        }
        do {
            try textDraft.commit(to: task) {
                try BackgroundRunBudget.protectingCurrent {
                    task.lastModifiedDate = Date()
                    task.isDirty = true
                    try ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
                }
            }
        } catch let error as TaskTextValidation.Failure {
            errorState.show(error)
            return
        } catch {
            ViewPersistence.report(error, to: errorState)
            return
        }
        afterCommit()
        dismiss()
    }

    private func saveAndDismiss() {
        Self.applyDone(to: task, textDraft: textDraft, in: modelContext, errorState: errorState, afterCommit: {
            ViewPersistence.recoverRemindersAfterCommit {
                try ReminderScheduler.requestReconcileOrThrow(modelContext: modelContext)
            }
            syncScheduler.syncAfterChange(modelContext: modelContext)

            // Auto-sync to calendar if enabled
            let accounts = (try? modelContext.fetch(FetchDescriptor<ServerAccount>())) ?? []
            CalendarAutoSync.syncTaskIfEnabled(task, accounts: accounts, onCommit: {
                syncScheduler.publishLocalTaskCommit()
            })
        }, dismiss: { dismiss() })
    }
}

// MARK: - Title Section

private struct TitleSection: View {
    @Binding var title: String

    var body: some View {
        Section {
            TextField("Task name", text: $title, axis: .vertical)
                .font(.headline)
                .lineLimit(1...4)
        }
    }
}

// MARK: - Status Section

private struct StatusSection: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState
    @State private var completionError: TaskCompletionLogic.CompletionError?

    var body: some View {
        Section {
            HStack {
                Label("Status", systemImage: "circle.dashed")
                Spacer()
                // An empty label literal extracted as the `""` key. The visible label is the
                // `Label` beside it; VoiceOver gets it explicitly rather than by proximity.
                Picker(selection: Binding(get: { task.status }, set: { status in
                    do { try TaskDetailView.applyStatusChange(status, to: task, in: modelContext, errorState: errorState) }
                    catch let error as TaskCompletionLogic.CompletionError { completionError = error }
                    catch { ViewPersistence.reportTaskWriteRefusal(error, to: errorState); return }
                })) {
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
                Picker(selection: Binding(get: { task.priority }, set: { priority in
                    guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                    task.priority = priority
                })) {
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
                        set: { progress in
                            guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                            task.percentComplete = Int(progress)
                        }
                    ),
                    in: 0...100,
                    step: 5
                )
            }
        }
        .alert("Repeat", isPresented: Binding(
            get: { completionError != nil }, set: { if !$0 { completionError = nil } }
        )) {
            Button("OK", role: .cancel) { completionError = nil }
        } message: {
            if let completionError { Text(completionError.localizedStringResource) }
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState
    @Bindable var task: TaskItem
    @State private var recurrenceEdit: RecurrenceEdit?

    private struct RecurrenceEdit: Identifiable {
        let id = UUID()
        let rule: String?
        let committedRule: String?
    }

    private var isAllDay: Bool { task.isDueDateOnly }

    var body: some View {
        Section("Dates") {
            Toggle(isOn: Binding(get: { task.startDate != nil }, set: { enabled in
                guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                task.startDate = enabled ? (task.startDate ?? Date()) : nil
            })) {
                Label("Start Date", systemImage: "play.circle")
            }

            if task.startDate != nil {
                DatePicker(
                    "Start",
                    selection: Binding(
                        get: { task.startDate ?? Date() },
                        set: { date in
                            guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                            task.startDate = date
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
            }

            Toggle(isOn: Binding(get: { task.dueDate != nil }, set: { enabled in
                TaskDetailView.applyDueDateToggle(enabled, to: task, in: modelContext, errorState: errorState)
            })) {
                Label("Due Date", systemImage: "calendar.badge.clock")
            }

            if task.dueDate != nil {
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
                            guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                            task.dueDate = isAllDay
                                ? DueDateHelper.dateOnlyValue(for: newValue)
                                : newValue
                            // Only user date edits need this save. Completion already handles
                            // recurrence recovery; observing its due-date change would replay it.
                            guard ReminderScheduler.requestReconcile(modelContext: modelContext, onSaveFailure: {
                                ViewPersistence.report($0, to: errorState)
                            }) else { return }
                        }
                    ),
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)

                Picker(selection: Binding(
                    get: { task.reminderOffset },
                    set: { newValue in
                        TaskDetailView.applyReminderOffset(newValue, to: task, in: modelContext, errorState: errorState)
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
                            TaskDetailView.applyHourlyNag(newValue, to: task, in: modelContext, errorState: errorState)
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

            // Present the picker without changing the task. Its Done action applies the rule.
            Button {
                do {
                    let committed = try TaskDetailView.readCommitted(task, in: modelContext) { $0.recurrenceRule }
                    let rule = RecurrenceRule.isPickerRepresentable(committed) ? task.recurrenceRule : committed
                    recurrenceEdit = RecurrenceEdit(rule: rule, committedRule: committed)
                } catch { ViewPersistence.reportTaskWriteRefusal(error, to: errorState) }
            } label: {
                HStack {
                    Label("Repeat", systemImage: "repeat")
                    Spacer()
                    Text(recurrenceDisplayText)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $recurrenceEdit) { edit in
                RecurrencePickerSheet(recurrenceRule: .constant(edit.rule)) { rule, errors in
                    TaskDetailView.applyRecurrenceRule(rule, replacing: edit.rule, committedAtOpen: edit.committedRule, to: task,
                        in: modelContext, errorState: errors)
                }
            }
        }
    }

    private var recurrenceDisplayText: String {
        guard let rrule = task.recurrenceRule, !rrule.isEmpty else {
            return String(localized: "taskDetail.recurrence.never", defaultValue: "Never", comment: "Value shown next to the Repeat row in Task Detail when the task has no recurrence rule set")
        }
        return RecurrenceRule.parse(rrule)?.displayText ?? RecurrenceRule.customDisplayText
    }

    /// Switches the due date between all-day (date-only) and timed, converting the
    /// stored value so the calendar day is preserved. Timed values gain the default
    /// due time; all-day values drop the time and round-trip to `DUE;VALUE=DATE`.
    private func setAllDay(_ allDay: Bool) {
        guard allDay != isAllDay else { return }
        guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
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
        guard ReminderScheduler.requestReconcile(modelContext: modelContext, onSaveFailure: {
            ViewPersistence.report($0, to: errorState)
        }) else { return }
    }
}

// MARK: - Recurrence Picker Sheet

struct RecurrencePickerSheet: View {
    @Binding var recurrenceRule: String?
    @Environment(\.dismiss) private var dismiss
    @State private var errorState = ErrorState()
    @State private var selectedPreset: RecurrencePreset
    @State private var didEdit = false
    private let isReadOnly: Bool
    private let commit: ((String?, ErrorState) -> Bool)?
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

    init(recurrenceRule: Binding<String?>, commit: ((String?, ErrorState) -> Bool)? = nil) {
        self._recurrenceRule = recurrenceRule
        self.commit = commit
        self.isReadOnly = !RecurrenceRule.isPickerRepresentable(recurrenceRule.wrappedValue)
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
            self._customByDay = State(initialValue: Set(rule.plainWeekdays))
        } else {
            self._selectedPreset = State(initialValue: .never)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isReadOnly {
                    Section {
                        Text(RecurrenceRule.customDisplayText)
                        Text("This custom repeat rule is preserved. Use a calendar app that supports it to change it.",
                             comment: "Explanation in the read-only repeat picker for an imported rule the picker cannot represent.")
                        if let raw = recurrenceRule { Text(verbatim: raw).font(.caption).textSelection(.enabled) }
                    }
                } else {
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
            }
            .onChange(of: selectedPreset) { _, _ in didEdit = true }
            .onChange(of: customFrequency) { _, _ in didEdit = true }
            .onChange(of: customInterval) { _, _ in didEdit = true }
            .onChange(of: customByDay) { _, _ in didEdit = true }
            .errorBanner(errorState)
            .navigationTitle("Repeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if applyRule() { dismiss() }
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

    private func applyRule() -> Bool {
        guard !isReadOnly, didEdit else { return true }
        let rule = selectedRule()
        if let commit { return commit(rule, errorState) }
        recurrenceRule = rule
        return true
    }

    private func selectedRule() -> String? {
        let frequency: RecurrenceRule.Frequency
        switch selectedPreset {
        case .never: return nil
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        case .custom: frequency = customFrequency
        }
        let interval = selectedPreset == .custom ? customInterval : 1
        let days = selectedPreset == .custom && frequency == .weekly
            ? customByDay.sorted { $0.calendarWeekday < $1.calendarWeekday }.map { RecurrenceRule.ByDay(weekday: $0) }
            : []
        return RecurrenceRule(frequency: frequency, interval: interval, byDay: days, count: nil, until: nil)
            .toRRULEString()
    }
}

// MARK: - Details Section

private struct DetailsSection: View {
    @Bindable var task: TaskItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var locationSheet: LocationSheet?
    @State private var savedLocation: LocationDraft.Fields?
    @State private var locationTaskID: String?
    @ObservedObject private var geofences = GeofenceManager.shared
    @State private var moveRequest: MoveToListRequest?

    private struct LocationSheet: Identifiable {
        let id = UUID()
        let draft: LocationDraft
    }

    private var location: LocationDraft.Fields { savedLocation ?? LocationDraft.Fields(task) }

    /// Spoken stand-in when the task has no location. Deliberately the same key the
    /// visible label uses, so VoiceOver and the screen say the same word.
    private static let noLocationSpoken = String(
        localized: "location.none", defaultValue: "None",
        comment: "Shown in place of a location when the task has none, and spoken as the second half of the row's VoiceOver label. Answers 'Location: ?', so the word agrees with the target language's word for location. Do not share this key with the priority, reminder or empty-quadrant 'None'.")

    var body: some View {
        Section("Details") {
            listRow

            Button {
                if let draft = LocationDraft.open(task: task, in: modelContext, errorState: errorState) {
                    locationTaskID = task.id
                    savedLocation = draft.savedFields
                    locationSheet = LocationSheet(draft: draft)
                }
            } label: {
                HStack {
                    Label("Location", systemImage: "mappin")
                    Spacer()
                    if let name = location.name {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(name)
                                .font(.subheadline)
                            if let radius = location.radius, radius.isFinite, radius > 0 {
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
            .accessibilityLabel("Location, \(location.name ?? Self.noLocationSpoken)")
            .sheet(item: $locationSheet) { sheet in
                LocationPickerView(task: task, draft: sheet.draft) { fields in
                    savedLocation = fields
                    syncScheduler.publishLocalTaskCommit()
                }
            }
            .onChange(of: syncScheduler.latestCommittedChange?.revision) { _, _ in
                guard let locationTaskID, let change = syncScheduler.latestCommittedChange,
                      change.changedIDs.contains(locationTaskID) else { return }
                if let fields = try? LocationDraft.committedFields(for: task, in: modelContext) {
                    savedLocation = fields
                }
            }
            if location.coordinate != nil, let issue = geofences.permissionIssue {
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("URL", systemImage: "link")
                Spacer()
                TextField("https://...", text: Binding(
                    get: { task.url ?? "" },
                    set: { url in
                        guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
                        task.url = url.isEmpty ? nil : url
                    }
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
            MoveToListSheet(request: request) { destination, errors in
                guard MoveDestinations.perform(request, to: destination, in: modelContext, errorState: errors,
                    revalidate: { syncScheduler.syncAfterChange(modelContext: modelContext) }) else { return false }
                syncScheduler.publishLocalTaskCommit()
                syncScheduler.syncAfterChange(modelContext: modelContext)
                return true
            }
        }
    }
}

// MARK: - Notes Section

private struct NotesSection: View {
    @Binding var notes: String
    @State private var isExpanded = false
    @ScaledMetric(relativeTo: .body) private var compactHeight = 170.0
    @ScaledMetric(relativeTo: .body) private var expandedHeight = 320.0

    var body: some View {
        Section {
            TextEditor(text: $notes)
                .font(.body)
                .frame(height: isExpanded ? expandedHeight : compactHeight)
                .accessibilityLabel("Notes")
        } header: {
            HStack {
                Text("Notes")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    isExpanded.toggle()
                } label: {
                    if isExpanded {
                        Text("Collapse Notes", comment: "Button that returns the task notes editor to its default height.")
                    } else {
                        Text("Expand Notes", comment: "Button that makes the task notes editor taller.")
                    }
                }
                .buttonStyle(.borderless)
                .textCase(nil)
            }
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
    @State private var completionError: TaskCompletionLogic.CompletionError?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState

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
        .alert("Repeat", isPresented: Binding(
            get: { completionError != nil }, set: { if !$0 { completionError = nil } }
        )) {
            Button("OK", role: .cancel) { completionError = nil }
        } message: {
            if let completionError { Text(completionError.localizedStringResource) }
        }
    }

    private func toggleSubtask() {
        do {
            try withAnimation(.easeInOut(duration: 0.2)) {
                try TaskDetailView.applyStatusChange(
                    subtask.status == .completed ? .needsAction : .completed,
                    to: subtask, in: modelContext, errorState: errorState)
            }
        } catch let error as TaskCompletionLogic.CompletionError {
            completionError = error
            return
        } catch { ViewPersistence.reportTaskWriteRefusal(error, to: errorState); return }
        HapticManager.checkbox()
    }
}

// MARK: - Add Subtask Sheet

private struct AddSubtaskSheet: View {
    let parentTask: TaskItem
    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @Environment(\.dismiss) private var dismiss
    @State private var creationDraft = TaskCreationDraft()
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
            .environment(\.saveErrorState, errorState)
            .errorBanner(errorState)
            .navigationTitle("Add Subtask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        creationDraft.discardOwnedChanges()
                        dismiss()
                    }
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
        .onDisappear { creationDraft.discardOwnedChanges() }
    }

    private func createSubtask() {
        guard parentTask.modelContext != nil else { return }
        let trimmed = subtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        do {
            guard try creationDraft.subtask(title: trimmed, parent: parentTask,
                in: modelContext.container) != nil else { return }
        } catch let refusal as TaskWriteEligibility.Refusal {
            ViewPersistence.reportTaskWriteRefusal(refusal, to: errorState, creating: true)
            return
        } catch { errorState.show(error); return }
        guard creationDraft.saveOwnedChanges(errorState: errorState) else { return }
        syncScheduler.publishLocalTaskCommit()
        HapticManager.success()
        dismiss()
    }
}

// MARK: - Linked Journals Section

/// Shows journal entries linked to this task (P12-4).
private struct LinkedJournalsSection: View {
    @Environment(\.modelContext) private var modelContext
    let task: TaskItem

    var body: some View {
        let journals = JournalVisibility.live(task.associatedJournals, in: modelContext)
        if !journals.isEmpty {
            Section("Linked Journals") {
                ForEach(journals) { journal in
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
    let onAddTag: () -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.saveErrorState) private var errorState

    var body: some View {
        Section("Tags") {
            if !task.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(task.tags) { tag in
                        TagPill(tag: tag) {
                            guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState),
                                  tag.modelContext === modelContext, !tag.isDeleted else { return }
                            withAnimation {
                                task.tags.removeAll { $0.id == tag.id }
                                TaskListHelpers.markTagsChanged(on: task)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Button(action: onAddTag) {
                Label("Add Tag", systemImage: "tag")
                    .foregroundStyle(.purple)
            }
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
    @State private var errorState = ErrorState()
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
                        let isSelected = task.tags.contains { $0.id == tag.id }
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
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            .errorBanner(errorState)
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
        guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState),
              tag.modelContext === modelContext, !tag.isDeleted else { return }
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
        guard TaskDetailView.admitEdit(to: task, in: modelContext, errorState: errorState) else { return }
        let tag = Tag(name: trimmed, color: newTagColor)
        modelContext.insert(tag)
        task.tags.append(tag)
        TaskListHelpers.markTagsChanged(on: task)
        newTagName = ""
        HapticManager.success()
    }
}

/// Only the fields TaskCompletionLogic changes, captured immediately before a synchronous attempt.
struct TaskStatusSnapshot {
    let task: TaskItem
    let status: TaskStatus
    let completedDate: Date?
    let dueDate: Date?
    let startDate: Date?
    let percentComplete: Int
    let lastModifiedDate: Date?
    let isDirty: Bool

    init(_ task: TaskItem) {
        self.task = task
        status = task.status
        completedDate = task.completedDate
        dueDate = task.dueDate
        startDate = task.startDate
        percentComplete = task.percentComplete
        lastModifiedDate = task.lastModifiedDate
        isDirty = task.isDirty
    }

    func restore() {
        guard task.modelContext != nil else { return }
        task.status = status
        task.completedDate = completedDate
        task.dueDate = dueDate
        task.startDate = startDate
        task.percentComplete = percentComplete
        task.lastModifiedDate = lastModifiedDate
        task.isDirty = isDirty
    }
}
