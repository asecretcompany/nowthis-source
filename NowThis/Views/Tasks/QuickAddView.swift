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
    struct Destination: Equatable {
        let id: String
        let name: String
        let persistentID: PersistentIdentifier

        init(_ list: TaskList) {
            id = list.id
            name = list.name
            persistentID = list.persistentModelID
        }

        var target: TaskWriteEligibility.CreationDestination {
            .list(id: id, expectedPersistentID: persistentID)
        }
    }

    struct CalendarSelection: Identifiable {
        let id = UUID()
        let date: Date
        let destination: Destination?
    }

    struct CalendarDestination {
        let display: Destination
        let reminderEnabled: Bool
    }

    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var creationDraft = TaskCreationDraft()
    @State private var taskTitle = ""
    @State private var selectedPriority: TaskPriority = .none
    @State private var dueDate: Date?
    @State private var hasDueDate = false
    @State private var recurrenceRule: String?
    @State private var parseResult = NaturalLanguageParser.ParseResult()
    @State private var displayedDestination: Destination?
    @FocusState private var isFocused: Bool
    enum DefaultDestination {
        case explicit(Destination)
        case explicitID(String)
        case preview(Destination)
        case unresolved
    }

    private let defaultDestination: DefaultDestination
    var defaultSmartList: SmartList?
    let calendarSelection: CalendarSelection?

    init(defaultList: TaskList?, defaultSmartList: SmartList? = nil, calendarSelection: CalendarSelection? = nil,
         explicitListID: String? = nil) {
        if let explicitListID {
            if let defaultList, defaultList.id == explicitListID {
                defaultDestination = .explicit(Destination(defaultList))
            } else {
                defaultDestination = .explicitID(explicitListID)
            }
        } else if let defaultList {
            defaultDestination = .preview(Destination(defaultList))
        } else {
            defaultDestination = .unresolved
        }
        self.defaultSmartList = defaultSmartList
        self.calendarSelection = calendarSelection
        self._displayedDestination = State(initialValue: calendarSelection?.destination)
        // Pre-fill the due date from the resolved contextual/per-list/global
        // default so Quick Add matches the inline add bar. The resolver already
        // bakes the default due time onto the date, so surface it directly in the
        // picker as a timed value.
        if let due = calendarSelection?.date ?? NewTaskDefaults.resolve(smartList: defaultSmartList, list: defaultList).dueDate {
            self._hasDueDate = State(initialValue: true)
            self._dueDate = State(initialValue: due)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TaskTitleField(title: $taskTitle, isFocused: $isFocused)
                        .onChange(of: taskTitle) { _, newValue in
                            parseResult = (try? TaskTextValidation.quickAdd(newValue)) ?? NaturalLanguageParser.ParseResult()
                        }

                    if hasTokens {
                        ParsePreviewChips(result: parseResult)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if calendarSelection != nil {
                        HStack {
                            Label("List", systemImage: "list.bullet")
                            Spacer()
                            if let destination = displayedDestination {
                                Text(verbatim: destination.name)
                            } else {
                                Text("No Lists")
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    QuickOptionsBar(
                        priority: $selectedPriority,
                        hasDueDate: $hasDueDate,
                        dueDate: $dueDate,
                        recurrenceRule: $recurrenceRule
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .environment(\.saveErrorState, errorState)
            .errorBanner(errorState)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Drawn as a principal item rather than `.navigationTitle` so it can
                // scale. Inline titles truncate instead of shrinking, and German put
                // "Neue Aufgabe" between "Abbrechen" and "Hinzufügen" — it rendered
                // "Neue Aufg…".
                ToolbarItem(placement: .principal) {
                    Text("New Task")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        creationDraft.discardOwnedChanges()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { createTask() }
                        .fontWeight(.semibold)
                        .disabled(effectiveTitle.isEmpty || (calendarSelection != nil && displayedDestination == nil))
                }
            }
            .onAppear { isFocused = true }
            .onChange(of: parseResult.listName, initial: true) { refreshCalendarDestination() }
            .onChange(of: syncScheduler.dataRefreshToken) {
                // A list can arrive after an empty draft opens. A listed destination
                // still goes through the review check on Add if it later changes.
                if displayedDestination == nil { refreshCalendarDestination() }
            }
            .animation(.easeInOut(duration: 0.2), value: hasTokens)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(!taskTitle.isEmpty)
        .onDisappear { creationDraft.discardOwnedChanges() }
        .blocksTaskLinks()
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
        do { parseResult = try TaskTextValidation.quickAdd(taskTitle) }
        catch { errorState.show(error); return }
        let trimmed = effectiveTitle
        guard !trimmed.isEmpty else { return }

        Self.commitCreation(title: trimmed, parseResult: parseResult, selectedPriority: selectedPriority,
            pickerDate: hasDueDate ? (dueDate ?? Date()) : nil, recurrenceRule: recurrenceRule,
            defaultList: nil, capturedDefault: defaultDestination, calendarSelection: calendarSelection,
            displayedDestination: displayedDestination,
            creationDraft: creationDraft, modelContext: modelContext, errorState: errorState,
            reportCalendarDestinationChange: reportCalendarDestinationChange
        ) { task, draftContext, donationList in
            finishCreation(task, in: draftContext, title: trimmed, donationList: donationList)
        }
    }

    @MainActor
    static func commitCreation(title trimmed: String, parseResult: NaturalLanguageParser.ParseResult,
                               selectedPriority: TaskPriority, pickerDate: Date?, recurrenceRule: String?,
                               defaultList: TaskList?, capturedDefault: DefaultDestination? = nil,
                               calendarSelection: CalendarSelection?,
                               displayedDestination: Destination?, creationDraft: TaskCreationDraft,
                               modelContext: ModelContext, errorState: ErrorState,
                               save: (() throws -> Void)? = nil,
                               reportCalendarDestinationChange: (Destination?) -> Void,
                               didCommit: (TaskItem, ModelContext, TaskListEntity?) -> Void) {
        let defaultDestination = capturedDefault ?? defaultList.map { .explicit(Destination($0)) } ?? .unresolved
        let calendarDestination: CalendarDestination?
        if let calendarSelection {
            // A draft retry can still hold its original models. Read the committed list
            // in a fresh context before comparing it with the user's displayed choice.
            let current = Self.committedCalendarDestination(selection: calendarSelection, listName: parseResult.listName,
                                                            in: modelContext.container)
            guard let current, current.display == displayedDestination else {
                reportCalendarDestinationChange(current?.display)
                return
            }
            calendarDestination = current
        } else {
            calendarDestination = nil
        }

        let draftContext = creationDraft.context(in: modelContext.container)
        let list: TaskList?
        let preferenceChange: NewTaskDefaults.PreferenceChange?
        do {
            let destination: TaskWriteEligibility.CreationDestination
            if let calendarDestination {
                destination = calendarDestination.display.target
                preferenceChange = nil
            } else {
                (destination, preferenceChange) = try ordinaryDestination(defaultDestination,
                    token: parseResult.listName, in: ModelContext(modelContext.container))
            }
            list = try TaskWriteEligibility(writingIn: draftContext).destination(destination)
        } catch let refusal as TaskWriteEligibility.Refusal where refusal != .readOnly && calendarSelection != nil {
            if let calendarSelection {
                reportCalendarDestinationChange(Self.committedCalendarDestination(selection: calendarSelection,
                    listName: parseResult.listName, in: modelContext.container)?.display)
            }
            return
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState, creating: true)
            return
        }

        // Resolve priority: parsed token overrides manual picker
        let priority = parseResult.priority ?? selectedPriority

        let task: TaskItem
        do {
            task = try Self.taskForCreation(title: trimmed, priority: priority, tagNames: parseResult.tagNames,
                                            draft: creationDraft, in: draftContext)
        } catch let error as TaskTextValidation.Failure {
            errorState.show(error)
            return
        } catch {
            ViewPersistence.report(error, to: errorState)
            return
        }

        Self.applyDueDate(parseResult, pickerDate: pickerDate, to: task)

        task.recurrenceRule = recurrenceRule

        task.taskList = list

        Self.applyDefaultReminder(to: task, calendarReminderEnabled: calendarDestination?.reminderEnabled)

        task.isDirty = true
        draftContext.insert(task)
        // Snapshot stable list identity before persistence and subsequent side effects.
        let donationList = task.taskList.map { TaskListEntity(list: $0) }
        guard creationDraft.saveOwnedChanges(errorState: errorState, save: save) else { return }
        preferenceChange?.commit()
        didCommit(task, draftContext, donationList)
    }

    private static func ordinaryDestination(_ capturedDefault: DefaultDestination, token: String?,
                                            in reader: ModelContext) throws ->
        (TaskWriteEligibility.CreationDestination, NewTaskDefaults.PreferenceChange?) {
        if let token, let tokenList = try matchingTaskLists(named: token, in: reader).first {
            return (Destination(tokenList).target, nil)
        }
        switch capturedDefault {
        case .explicit(let captured):
            return (captured.target, nil)
        case .explicitID(let id):
            return (.list(id: id, expectedPersistentID: nil), nil)
        case .preview(let captured) where try list(withID: captured.id, in: reader) != nil:
            let preference = TaskDefaultsPreferences.ListPreference()
            let migration = preference.legacyID == captured.id && preference.currentID == nil
                ? NewTaskDefaults.PreferenceChange(listID: captured.id, observed: preference) : nil
            return (captured.target, migration)
        case .preview, .unresolved:
            let choice = try NewTaskDefaults.creationList(explicit: nil, in: reader)
            return (choice.list.map { Destination($0).target } ?? .unbound, choice.preferenceChange)
        }
    }

    private func finishCreation(_ task: TaskItem, in draftContext: ModelContext, title: String,
                                donationList: TaskListEntity?) {
        if task.reminderOffset != nil {
            ReminderScheduler.requestPermissionIfNeeded()
        }
        // Unconditional: a task with a due date and no reminder still needs its "now overdue"
        // notification, and that notification is the only thing that moves the app icon badge
        // while the app is closed.
        ViewPersistence.recoverRemindersAfterCommit {
            try ReminderScheduler.requestReconcileOrThrow(modelContext: draftContext)
        }
        syncScheduler.publishLocalTaskCommit()
        syncScheduler.syncAfterChange(modelContext: modelContext)

        // Keep automatic mirror creation scoped to the existing Quick Add entry point.
        if calendarSelection == nil {
            let accounts = (try? modelContext.fetch(FetchDescriptor<ServerAccount>())) ?? []
            CalendarAutoSync.syncTaskIfEnabled(task, accounts: accounts, onCommit: {
                syncScheduler.publishLocalTaskCommit()
            })
        }

        HapticManager.success()
        IntentDonationManager.donateCreateTask(title: title, list: donationList)
        dismiss()
    }

    private func refreshCalendarDestination() {
        guard let calendarSelection else { return }
        let context = ModelContext(modelContext.container)
        // Token edits can deliberately change the displayed list. A removed scoped list
        // is handled on Add, so the fallback is never committed without a fresh review.
        displayedDestination = Self.calendarDestination(selection: calendarSelection, listName: parseResult.listName,
                                                        in: context, useFallbackForMissingScope: displayedDestination == nil)
            .map(Destination.init) ?? displayedDestination
    }

    private func reportCalendarDestinationChange(_ destination: Destination?) {
        displayedDestination = destination
        errorState.show(String(localized: "quickAdd.calendar.destinationChanged",
            defaultValue: "The destination list changed. Review the list before adding the task.",
            comment: "Alert when the list shown in the calendar's new-task sheet no longer matches the live destination at save time."))
    }

    static func calendarDestination(selection: CalendarSelection, listName: String?, in context: ModelContext,
                                    useFallbackForMissingScope: Bool = true) -> TaskList? {
        try? resolveCalendarDestination(selection: selection, listName: listName, in: context,
            useFallbackForMissingScope: useFallbackForMissingScope)
    }

    private static func resolveCalendarDestination(selection: CalendarSelection, listName: String?, in context: ModelContext,
                                                   useFallbackForMissingScope: Bool) throws -> TaskList? {
        // A name shared by several accounts cannot identify a destination. Keep the
        // scoped list or the displayed default unless the token resolves uniquely.
        if let listName {
            let matches = try matchingTaskLists(named: listName, in: context)
            if matches.count == 1 { return matches.first }
        }
        if let listID = selection.destination?.id {
            if let scopedList = try Self.list(withID: listID, in: context),
               scopedList.persistentModelID == selection.destination?.persistentID { return scopedList }
            guard useFallbackForMissingScope else { return nil }
        }
        return try NewTaskDefaults.creationList(explicit: nil, in: context).list
    }

    static func committedCalendarDestination(selection: CalendarSelection, listName: String?,
                                             in container: ModelContainer) -> CalendarDestination? {
        let context = ModelContext(container)
        guard let list = calendarDestination(selection: selection, listName: listName, in: context) else { return nil }
        return CalendarDestination(display: Destination(list), reminderEnabled: NewTaskDefaults.effectiveReminderEnabled(for: list))
    }

    private static func list(withID id: String, in context: ModelContext) throws -> TaskList? {
        var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func applyDueDate(_ result: NaturalLanguageParser.ParseResult, pickerDate: Date?, to task: TaskItem) {
        // Parsed dates win. A picker or default date has a time, including on a draft retry.
        task.dueDate = result.dueDate ?? pickerDate
        task.isDueDateOnly = result.dueDate != nil && !result.dueHasTime
    }

    static func applyDefaultReminder(to task: TaskItem, calendarReminderEnabled: Bool?) {
        // Offset 0 fires at the due time.
        if let calendarReminderEnabled {
            // The editor does not offer a manual reminder. On retry the pending
            // task may still carry an offset set by a previous date or destination.
            task.reminderOffset = task.dueDate != nil && calendarReminderEnabled ? 0 : nil
        } else if task.dueDate != nil,
                  task.reminderOffset == nil,
                  NewTaskDefaults.effectiveReminderEnabled(for: task.taskList) {
            task.reminderOffset = 0
        }
    }

    private static func matchingTaskLists(named name: String, in context: ModelContext) throws -> [TaskList] {
        let allLists = try context.fetch(FetchDescriptor<TaskList>())
        return allLists.filter { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    static func taskForCreation(title: String, priority: TaskPriority = .none, tagNames: [String],
                                draft: TaskCreationDraft, in context: ModelContext,
                                fetchTags: (ModelContext) throws -> [Tag] = Tag.fetchAll(in:)) throws -> TaskItem {
        let title = try TaskTextValidation.title(title)
        let tags = try Tag.resolve(tagNames, in: context, fetch: fetchTags)
        let task = try draft.task(title: title, priority: priority)
        let removedIDs = Set(task.tags.map(\.id)).subtracting(tags.map(\.id))
        task.tags = tags
        // An owned draft can reuse staged tags after a failed save. Discard only
        // removed tags inserted in this context, so the retry cannot leave orphans.
        for case let tag as Tag in context.insertedModelsArray where removedIDs.contains(tag.id) {
            context.delete(tag)
        }
        return task
    }
}

// MARK: - Parse Preview Chips

struct ParsePreviewChips: View {
    let result: NaturalLanguageParser.ParseResult
    let tagNames: [String]

    init(result: NaturalLanguageParser.ParseResult) {
        self.result = result
        tagNames = Tag.uniqueNames(result.tagNames)
    }

    static func dueDateLabels(for result: NaturalLanguageParser.ParseResult,
                              timeZone: TimeZone = .current) -> (visible: String, spoken: String)? {
        guard let date = result.dueDate else { return nil }
        let isDateOnly = !result.dueHasTime
        return (
            DueDateFormatter.format(date, isDateOnly: isDateOnly, timeZone: timeZone),
            DueDateFormatter.accessibilityLabel(date, isDateOnly: isDateOnly, timeZone: timeZone)
        )
    }

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

                ForEach(tagNames, id: \.self) { tag in
                    TokenChip(label: tag, icon: "tag.fill", tint: .purple)
                }

                if let dueDateLabels = Self.dueDateLabels(for: result) {
                    TokenChip(
                        label: dueDateLabels.visible,
                        icon: "calendar",
                        tint: .orange
                    )
                    .accessibilityLabel(dueDateLabels.spoken)
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
            // Scrolls horizontally rather than compressing. The three chips fit side by
            // side in English; in German "Fälligkeitsdatum" and "Wiederholen" do not, and
            // a plain HStack squeezed each capsule until SwiftUI hyphen-broke the labels
            // across two and three lines ("Wie-der-holen") at three different heights.
            // Same pattern the filter row on the task list already uses.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    PriorityPicker(priority: $priority)
                    DueDateToggle(hasDueDate: $hasDueDate, dueDate: $dueDate)
                    RepeatToggle(recurrenceRule: $recurrenceRule)
                }
                .padding(.horizontal, 1)   // keeps the capsule glass edges from clipping
            }
            .scrollBounceBehavior(.basedOnSize)

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
                .lineLimit(1)
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
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
        }
        .accessibilityLabel(String(localized: "quickAdd.a11y.dueDate",
                                   defaultValue: "Due date",
                                   comment: "VoiceOver label for the due-date chip in Quick Add. Spoken, not shown — sentence case, unlike the visible 'Due Date' sort option and intent parameter."))
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
            return String(localized: "quickadd.recurrence.repeat", defaultValue: "Repeat", comment: "Label on the Quick Add recurrence chip before a repeat rule has been set; tapping it opens the recurrence picker")
        }
        return rule.displayText
    }

    var body: some View {
        Button {
            showingRecurrenceSheet = true
        } label: {
            Label(displayText, systemImage: "repeat")
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(in: Capsule())
        }
        .sheet(isPresented: $showingRecurrenceSheet) {
            RecurrencePickerSheet(recurrenceRule: $recurrenceRule)
        }
        .accessibilityLabel("Repeat")
        .accessibilityValue(hasRecurrence ? displayText : String(localized: "quickadd.recurrence.never", defaultValue: "Never", comment: "VoiceOver value for the Quick Add recurrence chip when no repeat rule is set; the other branch, displayText, is an already-localized description of the active repeat rule"))
        .accessibilityHint("Double tap to set a recurrence schedule")
    }
}
