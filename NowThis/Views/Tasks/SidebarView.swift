import SwiftUI
import SwiftData

/// Smart list filter presets for the sidebar.
enum SmartList: String, CaseIterable, Identifiable {
    case today = "Today"
    case upcoming = "Upcoming"
    case overdue = "Overdue"
    case all = "All Tasks"
    case completed = "Completed"

    var id: String { rawValue }

    /// User-facing label.
    ///
    /// Separate from `rawValue` on purpose: the rawValue is persisted in `@AppStorage`
    /// (`SidebarView`, `SettingsView`) and rebuilt into a `SidebarSelection` on launch.
    /// Localizing it would silently lose the user's sidebar selection on a language change.
    var displayName: String {
        switch self {
        case .today:
            return String(localized: "smartlist.today", defaultValue: "Today",
                          comment: "Sidebar Smart List: tasks due today. Noun phrase naming a screen, not the adverb.")
        case .upcoming:
            return String(localized: "smartlist.upcoming", defaultValue: "Upcoming",
                          comment: "Sidebar Smart List: tasks due in the next few days.")
        case .overdue:
            return String(localized: "smartlist.overdue", defaultValue: "Overdue",
                          comment: "Sidebar Smart List: tasks past their due date and not completed.")
        case .all:
            return String(localized: "smartlist.all", defaultValue: "All Tasks",
                          comment: "Sidebar Smart List: every task in every list.")
        case .completed:
            return String(localized: "smartlist.completed", defaultValue: "Completed",
                          comment: "Sidebar Smart List: finished tasks. Same word as the task status.")
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .upcoming: return "calendar"
        case .overdue: return "exclamationmark.circle.fill"
        case .all: return "tray.full.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .today: return .orange
        case .upcoming: return .blue
        case .overdue: return .red
        case .all: return .indigo
        case .completed: return .green
        }
    }
}

/// The active selection in the sidebar — either a smart list, a user task list,
/// a saved custom filter, or the journals section.
enum SidebarSelection: Hashable {
    case smart(SmartList)
    case taskList(String) // TaskList ID
    case savedFilter(String) // SavedFilter ID
    case journals
    case tag(String) // Tag ID

    /// Encodes the selection as a string for persistence (e.g. @SceneStorage).
    var encoded: String {
        switch self {
        case .smart(let list): return "smart:\(list.rawValue)"
        case .taskList(let id): return "list:\(id)"
        case .savedFilter(let id): return "filter:\(id)"
        case .journals: return "journals"
        case .tag(let id): return "tag:\(id)"
        }
    }

    /// Decodes a selection from a persisted string. Returns `.smart(.today)` on invalid input.
    static func decode(from string: String) -> SidebarSelection {
        if string == "journals" { return .journals }
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return .smart(.today) }
        let prefix = String(parts[0])
        let value = String(parts[1])
        switch prefix {
        case "smart":
            return .smart(SmartList(rawValue: value) ?? .today)
        case "list":
            return .taskList(value)
        case "filter":
            return .savedFilter(value)
        case "tag":
            return .tag(value)
        default:
            return .smart(.today)
        }
    }
}

/// Sidebar navigation showing smart lists and user-created task lists.
/// Reorderable sidebar sections.
///
/// Smart Lists is always first and non-hideable. The remaining sections
/// can be reordered and hidden via Settings → Sidebar Layout.
enum SidebarSection: String, Codable, CaseIterable, Identifiable {
    case filters
    case journals
    case tags
    case lists

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .filters:
            return String(localized: "sidebar.section.filters", defaultValue: "Filters",
                          comment: "Sidebar section header for the user's saved filters.")
        case .journals:
            return String(localized: "sidebar.section.journals", defaultValue: "Journals",
                          comment: "Sidebar section header for dated journal entries (VJOURNAL), which are separate from tasks.")
        case .tags:
            return String(localized: "sidebar.section.tags", defaultValue: "Tags",
                          comment: "Sidebar section header for the user's tags.")
        case .lists:
            return String(localized: "sidebar.section.lists", defaultValue: "Lists",
                          comment: "Sidebar section header for the user's own lists (CalDAV collections).")
        }
    }

    /// Default section order (matches the original hardcoded layout).
    static let defaultOrder: [SidebarSection] = [.filters, .journals, .tags, .lists]

    /// Loads the section order from AppStorage JSON, falling back to default.
    static func loadOrder(from json: String) -> [SidebarSection] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SidebarSection].self, from: data) else {
            return defaultOrder
        }
        return decoded
    }

    /// Encodes a section order array to JSON for AppStorage.
    static func encodeOrder(_ order: [SidebarSection]) -> String {
        guard let data = try? JSONEncoder().encode(order) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

/// Sidebar navigation showing smart lists and user-created task lists.
struct SidebarView: View {

    @State private var taskLists: [TaskList] = []
    @Query(sort: \SavedFilter.sortOrder) private var savedFilters: [SavedFilter]
    @Binding var selection: SidebarSelection?
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewListSheet = false
    @State private var showingFilterBuilder = false
    @AppStorage("sidebarSectionOrder") private var sectionOrderJSON = ""
    @AppStorage("sidebarHiddenSections") private var hiddenSectionsJSON = ""

    private var sectionOrder: [SidebarSection] {
        let order = SidebarSection.loadOrder(from: sectionOrderJSON)
        return order.isEmpty ? SidebarSection.defaultOrder : order
    }

    private var hiddenSections: Set<SidebarSection> {
        guard let data = hiddenSectionsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SidebarSection].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    var body: some View {
        List(selection: $selection) {
            SmartListsSection()
            ForEach(sectionOrder) { section in
                if !hiddenSections.contains(section) {
                    sectionView(for: section)
                }
            }
        }
        .background(InboundQueryReader(descriptor: FetchDescriptor<TaskList>()) { taskLists = $0 })
        .navigationTitle("NowThis")
        .listStyle(.sidebar)
        .sheet(isPresented: $showingNewListSheet) {
            NewListSheet()
        }
        .sheet(isPresented: $showingFilterBuilder) {
            FilterBuilderView()
        }
    }

    @ViewBuilder
    private func sectionView(for section: SidebarSection) -> some View {
        switch section {
        case .filters:
            SavedFiltersSection(
                filters: savedFilters,
                onDelete: deleteFilter,
                onAddNew: { showingFilterBuilder = true }
            )
        case .journals:
            JournalsSidebarSection()
        case .tags:
            TagsSidebarSection()
        case .lists:
            UserListsSection(
                taskLists: visibleTaskLists,
                onDelete: deleteList,
                onAddNew: { showingNewListSheet = true }
            )
        }
    }

    /// Task lists filtered by the active Focus mode.
    ///
    /// The liveness check comes first: `isVisible` reads the list's own
    /// properties, so it would trap on a list an account delete has already
    /// cascaded away before the row ever gets a chance to guard.
    private var visibleTaskLists: [TaskList] {
        TaskListHelpers.liveModels(taskLists, in: modelContext).filter { FocusFilterState.shared.isVisible($0) }
    }

    /// Deletes the models the swiped rows came from. The section resolves the
    /// offsets itself, against the snapshot array it actually rendered — an
    /// index into `visibleTaskLists` can point at a different list once a row
    /// whose model was already invalidated has been dropped.
    private func deleteList(_ doomed: [TaskList]) {
        for list in doomed {
            TaskListHelpers.settlePendingMoves(beforeDeleting: list, in: modelContext)
            if let accountID = list.account?.id {
                do { try SyncImportCheckpoint.removeList(accountID: accountID, listID: list.id, in: modelContext) }
                catch { return }
            }
            modelContext.delete(list)
        }
        do { try ReminderSchedulingJournal.saveTaskChanges(in: modelContext, needsRecovery: true) }
        catch { return }
        ReminderScheduler.requestReconcile(modelContext: modelContext)
    }

    private func deleteFilter(_ doomed: [SavedFilter]) {
        for filter in doomed {
            modelContext.delete(filter)
        }
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
    }
}

// MARK: - Smart Lists Section

private struct SmartListsSection: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var countsModel = SmartListCountsModel()

    var body: some View {
        Section("Smart Lists") {
            ForEach(SmartList.allCases) { smartList in
                let count = countsModel.counts[smartList]
                NavigationLink(value: SidebarSelection.smart(smartList)) {
                    HStack {
                        Label(smartList.displayName, systemImage: smartList.icon)
                            .foregroundStyle(smartList.tintColor)
                        Spacer()
                        if count > 0 {
                            Text(count, format: .number)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel(String(
                    localized: "list.a11y.taskCount",
                    defaultValue: "\(smartList.displayName), \(count) tasks",
                    comment: "VoiceOver label for a row that names a collection and how many tasks are in it. First placeholder is the name (a list, tag, smart list or board quadrant), second is the count."))
            }
        }
        .task {
            countsModel.start(container: modelContext.container)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Picks up a day rollover (e.g. the app left open overnight):
            // a task due "today" moves to Overdue without any save firing.
            if newPhase == .active {
                countsModel.scheduleRefresh()
            }
        }
    }
}

// MARK: - Saved Filters Section

/// An immutable snapshot of the fields a saved-filter row renders.
///
/// Swiping the row deletes the `SavedFilter` on the **main** context; the row is
/// still realized while the delete animation runs, and reading `filter.name` (or
/// `filter.logic`, a computed getter over the stored `logicOperator`) on the
/// invalidated model trips SwiftData's `BackingData` assertion.
struct SavedFilterRowData: Equatable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let colorHex: String
    /// Resolved here, while the model is alive — `logic` reads a stored attribute.
    let logicDisplayName: String

    init?(filter: SavedFilter) {
        guard filter.modelContext != nil else { return nil }
        self.id = filter.id
        self.name = filter.name
        self.icon = filter.icon
        self.colorHex = filter.colorHex
        self.logicDisplayName = filter.logic.displayName
    }
}

/// A snapshot paired with the live filter, which swipe-to-delete still needs.
private struct SavedFilterEntry: Identifiable {
    let data: SavedFilterRowData
    let filter: SavedFilter

    var id: String { data.id }

    init?(filter: SavedFilter) {
        guard let data = SavedFilterRowData(filter: filter) else { return nil }
        self.data = data
        self.filter = filter
    }
}

private struct SavedFiltersSection: View {
    let filters: [SavedFilter]
    let onDelete: ([SavedFilter]) -> Void
    let onAddNew: () -> Void

    var body: some View {
        if !filters.isEmpty || true {
            // Snapshot at the array boundary: `ForEach` reads each element's `id`
            // before any row body runs, so a guard inside the row is too late.
            let entries = filters.compactMap(SavedFilterEntry.init(filter:))
            Section("Filters") {
                ForEach(entries) { entry in
                    NavigationLink(value: SidebarSelection.savedFilter(entry.data.id)) {
                        HStack {
                            Label(entry.data.name, systemImage: entry.data.icon)
                                .foregroundStyle(Color(hex: entry.data.colorHex) ?? .gray)
                            Spacer()
                            Text(verbatim: entry.data.logicDisplayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel("\(entry.data.name), custom filter")
                }
                // Resolve offsets against the same array the rows came from —
                // the compactMap can drop an entry the caller's array still has.
                .onDelete { offsets in onDelete(offsets.map { entries[$0].filter }) }

                Button(action: onAddNew) {
                    Label("New Filter", systemImage: "plus.circle.fill")
                        .foregroundStyle(.purple)
                }
            }
        }
    }
}

// MARK: - Journals Sidebar Section

private struct JournalsSidebarSection: View {
    static let activeJournalsPredicate = #Predicate<JournalEntry> { !$0.isDeletedLocally }

    @State private var journals: [JournalEntry] = []

    var body: some View {
        Section {
            NavigationLink(value: SidebarSelection.journals) {
                Label {
                    Text("Journals")
                } icon: {
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(.purple)
                }
                .badge(journals.count)
            }
            .accessibilityLabel(String(
                localized: "sidebar.journals.a11y.entryCount",
                defaultValue: "Journals, \(journals.count) entries",
                comment: "VoiceOver label for the sidebar's Journals row. The placeholder is how many journal entries exist."))
        }
        .background(InboundQueryReader(descriptor: FetchDescriptor(predicate: Self.activeJournalsPredicate,
            sortBy: [SortDescriptor(\JournalEntry.createdDate, order: .reverse)])) { journals = $0 })
    }
}

// MARK: - Tags Sidebar Section

/// An immutable snapshot of the fields a tag row renders.
///
/// Swiping the row deletes the `Tag` on the **main** context. `tasks.count` is
/// the riskier read of the two: it traverses the relationship into `TaskItem`,
/// which an account delete invalidates independently of the tag itself.
struct TagRowData: Equatable, Identifiable {
    let id: String
    let name: String
    let colorHex: String?
    let taskCount: Int

    init?(tag: Tag) {
        guard tag.modelContext != nil else { return nil }
        self.id = tag.id
        self.name = tag.name
        self.colorHex = tag.color
        self.taskCount = tag.tasks.count
    }

    var color: Color {
        guard let colorHex else { return .purple }
        return Color(hex: colorHex) ?? .purple
    }
}

/// A snapshot paired with the live tag, which swipe-to-delete still needs.
private struct TagEntry: Identifiable {
    let data: TagRowData
    let tag: Tag

    var id: String { data.id }

    init?(tag: Tag) {
        guard let data = TagRowData(tag: tag) else { return nil }
        self.data = data
        self.tag = tag
    }
}

private struct TagsSidebarSection: View {
    @State private var tags: [Tag] = []
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewTagSheet = false

    var body: some View {
        // Snapshot at the array boundary: `ForEach` reads each element's `id`
        // before any row body runs, so a guard inside the row is too late.
        let entries = TaskListHelpers.liveModels(tags, in: modelContext).compactMap(TagEntry.init(tag:))
        Section("Tags") {
            ForEach(entries) { entry in
                NavigationLink(value: SidebarSelection.tag(entry.data.id)) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(entry.data.color)
                            .frame(width: 10, height: 10)
                        Text(verbatim: entry.data.name)
                        Spacer()
                        Text(entry.data.taskCount, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(
                    localized: "list.a11y.taskCount",
                    defaultValue: "\(entry.data.name), \(entry.data.taskCount) tasks",
                    comment: "VoiceOver label for a row that names a collection and how many tasks are in it. First placeholder is the name (a list, tag, smart list or board quadrant), second is the count."))
            }
            // Resolve offsets against the same array the rows came from — the
            // compactMap can drop an entry `tags` still has.
            .onDelete { offsets in delete(offsets.map { entries[$0].tag }) }

            Button(action: { showingNewTagSheet = true }) {
                Label("New Tag", systemImage: "plus.circle.fill")
                    .foregroundStyle(.purple)
            }
        }
        .background(InboundQueryReader(descriptor: FetchDescriptor<Tag>(sortBy: [SortDescriptor(\Tag.name)])) { tags = $0 })
        .sheet(isPresented: $showingNewTagSheet) {
            NewTagSheet()
        }
    }

    private func delete(_ doomed: [Tag]) {
        for tag in doomed {
            modelContext.delete(tag)
        }
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
    }
}

// MARK: - New Tag Sheet

private struct NewTagSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var selectedColor = "#AF52DE"

    private let colors = [
        "#007AFF", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#5856D6", "#AF52DE", "#FF2D55"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "tag.field.name",
                                     defaultValue: "Tag name",
                                     comment: "Placeholder in the text field where a new tag's name is typed. One key for both places a tag can be created — the task detail sheet and the sidebar."),
                              text: $tagName)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { hex in
                            ColorDot(hex: hex, isSelected: selectedColor == hex) {
                                selectedColor = hex
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createTag() }
                        .disabled(tagName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createTag() {
        let trimmed = tagName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let tag = Tag(name: trimmed, color: selectedColor)
        modelContext.insert(tag)
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        HapticManager.success()
        dismiss()
    }
}

// MARK: - User Lists Section

/// An immutable snapshot of the fields a task-list row renders.
///
/// Two main-context deletes reach these rows: swiping one deletes the `TaskList`
/// directly, and `AccountManager.removeAccount` cascades
/// `ServerAccount` → `TaskList` → `TaskItem`. The sidebar is permanently on
/// screen, so its rows are always realized when either happens. `tasks.count` is
/// doubly exposed — it traverses into the very `TaskItem`s the cascade removes.
struct TaskListRowData: Equatable, Identifiable {
    let id: String
    let name: String
    let colorHex: String
    let taskCount: Int

    init?(list: TaskList) {
        guard list.modelContext != nil else { return nil }
        self.id = list.id
        self.name = list.name
        self.colorHex = list.colorHex
        self.taskCount = list.tasks.count
    }

    var color: Color { Color(hex: colorHex) ?? .blue }
}

/// A snapshot paired with the live list, which edit and delete still need.
private struct TaskListEntry: Identifiable {
    let data: TaskListRowData
    let list: TaskList

    var id: String { data.id }

    init?(list: TaskList) {
        guard let data = TaskListRowData(list: list) else { return nil }
        self.data = data
        self.list = list
    }
}

private struct UserListsSection: View {
    let taskLists: [TaskList]
    let onDelete: ([TaskList]) -> Void
    let onAddNew: () -> Void
    @State private var editingList: TaskList?

    var body: some View {
        // Snapshot at the array boundary: `ForEach` reads each element's `id`
        // before any row body runs, so a guard inside the row is too late.
        let entries = taskLists.compactMap(TaskListEntry.init(list:))
        Section("Lists") {
            ForEach(entries) { entry in
                NavigationLink(value: SidebarSelection.taskList(entry.data.id)) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(entry.data.color)
                            .frame(width: 10, height: 10)
                        Text(verbatim: entry.data.name)
                        Spacer()
                        Text(entry.data.taskCount, format: .number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(String(
                    localized: "list.a11y.taskCount",
                    defaultValue: "\(entry.data.name), \(entry.data.taskCount) tasks",
                    comment: "VoiceOver label for a row that names a collection and how many tasks are in it. First placeholder is the name (a list, tag, smart list or board quadrant), second is the count."))
                .contextMenu {
                    Button {
                        editingList = entry.list
                    } label: {
                        Label("Edit List", systemImage: "pencil")
                    }
                }
            }
            // Resolve offsets against the same array the rows came from — the
            // compactMap can drop an entry `taskLists` still has.
            .onDelete { offsets in onDelete(offsets.map { entries[$0].list }) }

            Button(action: onAddNew) {
                Label("New List", systemImage: "plus.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
        .sheet(item: $editingList) { list in
            EditListSheet(list: list)
        }
    }
}

// MARK: - New List Sheet

private struct NewListSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var listName = ""
    @State private var selectedColor = "#007AFF"

    private let colors = [
        "#007AFF", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#5856D6", "#AF52DE", "#FF2D55"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("List Name", text: $listName)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { hex in
                            ColorDot(hex: hex, isSelected: selectedColor == hex) {
                                selectedColor = hex
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("New List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createList() }
                        .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func createList() {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let list = TaskList(serverURL: "", name: trimmed, colorHex: selectedColor)

        // Attach to first account
        let accounts = (try? modelContext.fetch(FetchDescriptor<ServerAccount>())) ?? []
        list.account = accounts.first

        modelContext.insert(list)
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        HapticManager.success()
        dismiss()
    }
}

// MARK: - Edit List Sheet

private struct EditListSheet: View {
    @Bindable var list: TaskList
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var listName: String
    @State private var selectedColor: String
    /// Per-list due-date override rule, or "" to use the global default.
    @State private var dueDateRuleRaw: String
    /// Per-list reminder override ("on"/"off"), or "" to use the global default.
    @State private var reminderModeRaw: String

    private let colors = [
        "#007AFF", "#FF3B30", "#FF9500", "#FFCC00",
        "#34C759", "#5856D6", "#AF52DE", "#FF2D55"
    ]

    init(list: TaskList) {
        self.list = list
        self._listName = State(initialValue: list.name)
        self._selectedColor = State(initialValue: list.colorHex)
        self._dueDateRuleRaw = State(initialValue: list.defaultDueDateRuleRaw ?? "")
        self._reminderModeRaw = State(initialValue: list.defaultReminderModeRaw ?? "")
    }

    var body: some View {
        // The list can be deleted while this sheet is open — swiped away in the
        // sidebar behind it, or cascaded away with its account. Reading an
        // invalidated model traps in SwiftData, and the two-way `$list` binding
        // rules out a value snapshot here, so leave instead. Same treatment as
        // `AccountEditView`, `TaskDetailView` and `JournalEditorView`.
        if list.modelContext == nil {
            Color.clear.onAppear { dismiss() }
        } else {
            editor
        }
    }

    private var editor: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("List Name", text: $listName)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 12) {
                        ForEach(colors, id: \.self) { hex in
                            ColorDot(hex: hex, isSelected: selectedColor == hex) {
                                selectedColor = hex
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                Section {
                    Picker("Default Due Date", selection: $dueDateRuleRaw) {
                        Text("Use Global Default").tag("")
                        ForEach(DefaultDueDateRule.allCases) { rule in
                            Text(rule.displayName).tag(rule.rawValue)
                        }
                    }
                    .accessibilityHint("The due date applied to new tasks added to this list")

                    Picker("Default Reminder", selection: $reminderModeRaw) {
                        Text("Use Global Default").tag("")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    .accessibilityHint("Whether new tasks in this list get a reminder automatically")
                } header: {
                    Text("New Task Defaults")
                } footer: {
                    Text("Overrides the app-wide defaults for tasks added to this list.")
                }
            }
            .navigationTitle("Edit List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveChanges() }
                        .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveChanges() {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Name and colour are CalDAV properties and have to reach the server, or the next
        // sync's discovery pass reads the old ones back over them. The two default-rule
        // columns below are local app configuration and are deliberately not flagged.
        if list.name != trimmed || list.colorHex != selectedColor {
            list.isMetadataDirty = true
        }
        list.name = trimmed
        list.colorHex = selectedColor
        list.defaultDueDateRuleRaw = dueDateRuleRaw.isEmpty ? nil : dueDateRuleRaw
        list.defaultReminderModeRaw = reminderModeRaw.isEmpty ? nil : reminderModeRaw
        try? ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
        HapticManager.success()
        dismiss()
    }
}

private struct ColorDot: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex) ?? .blue)
                .frame(width: 28, height: 28)
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(.white, lineWidth: 2)
                            .frame(width: 20, height: 20)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(hex)")
    }
}
