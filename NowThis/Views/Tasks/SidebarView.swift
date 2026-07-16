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
        case .filters: return "Filters"
        case .journals: return "Journals"
        case .tags: return "Tags"
        case .lists: return "Lists"
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

    @Query private var taskLists: [TaskList]
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
    private var visibleTaskLists: [TaskList] {
        taskLists.filter { FocusFilterState.shared.isVisible($0) }
    }

    private func deleteList(at offsets: IndexSet) {
        let visible = visibleTaskLists
        for index in offsets {
            let list = visible[index]
            modelContext.delete(list)
        }
        try? modelContext.save()
    }

    private func deleteFilter(at offsets: IndexSet) {
        for index in offsets {
            let filter = savedFilters[index]
            modelContext.delete(filter)
        }
        try? modelContext.save()
    }
}

// MARK: - Smart Lists Section

private struct SmartListsSection: View {
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
    @Query(filter: Self.activeTasksPredicate) private var allTasks: [TaskItem]


    /// All 5 smart list counts computed in a single pass over the task array.
    private var smartListCounts: [SmartList: Int] {
        let now = Date()
        let endOfWeek = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now

        var todayCount = 0
        var upcomingCount = 0
        var overdueCount = 0
        var allCount = 0
        var completedCount = 0

        for task in allTasks {
            guard task.parentTask == nil else { continue }

            if task.status == .completed {
                completedCount += 1
                continue
            }

            allCount += 1

            guard let due = task.dueDate else { continue }

            if TaskListFilter.shouldIncludeInToday(
                dueDate: due,
                isDueDateOnly: task.isDueDateOnly,
                isCompleted: false,
                now: now
            ) {
                todayCount += 1
            }
            if due >= now && due <= endOfWeek {
                upcomingCount += 1
            }
            if DueDateHelper.isOverdue(dueDate: due, isDateOnly: task.isDueDateOnly) {
                overdueCount += 1
            }
        }

        return [
            .today: todayCount,
            .upcoming: upcomingCount,
            .overdue: overdueCount,
            .all: allCount,
            .completed: completedCount
        ]
    }

    var body: some View {
        let counts = smartListCounts
        Section("Smart Lists") {
            ForEach(SmartList.allCases) { smartList in
                let count = counts[smartList] ?? 0
                NavigationLink(value: SidebarSelection.smart(smartList)) {
                    HStack {
                        Label(smartList.rawValue, systemImage: smartList.icon)
                            .foregroundStyle(smartList.tintColor)
                        Spacer()
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityLabel("\(smartList.rawValue), \(count) task\(count == 1 ? "" : "s")")
            }
        }
    }
}

// MARK: - Saved Filters Section

private struct SavedFiltersSection: View {
    let filters: [SavedFilter]
    let onDelete: (IndexSet) -> Void
    let onAddNew: () -> Void

    var body: some View {
        if !filters.isEmpty || true {
            Section("Filters") {
                ForEach(filters) { filter in
                    NavigationLink(value: SidebarSelection.savedFilter(filter.id)) {
                        HStack {
                            Label(filter.name, systemImage: filter.icon)
                                .foregroundStyle(Color(hex: filter.colorHex) ?? .gray)
                            Spacer()
                            Text(filter.logic.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityLabel("\(filter.name), custom filter")
                }
                .onDelete(perform: onDelete)

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

    @Query(
        filter: Self.activeJournalsPredicate,
        sort: \JournalEntry.createdDate, order: .reverse
    ) private var journals: [JournalEntry]

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
            .accessibilityLabel("Journals, \(journals.count) entries")
        }
    }
}

// MARK: - Tags Sidebar Section

private struct TagsSidebarSection: View {
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Environment(\.modelContext) private var modelContext
    @State private var showingNewTagSheet = false

    var body: some View {
        Section("Tags") {
            ForEach(tags) { tag in
                NavigationLink(value: SidebarSelection.tag(tag.id)) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(tagColor(tag))
                            .frame(width: 10, height: 10)
                        Text(tag.name)
                        Spacer()
                        Text("\(tag.tasks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(tag.name), \(tag.tasks.count) task\(tag.tasks.count == 1 ? "" : "s")")
            }
            .onDelete(perform: deleteTag)

            Button(action: { showingNewTagSheet = true }) {
                Label("New Tag", systemImage: "plus.circle.fill")
                    .foregroundStyle(.purple)
            }
        }
        .sheet(isPresented: $showingNewTagSheet) {
            NewTagSheet()
        }
    }

    private func tagColor(_ tag: Tag) -> Color {
        if let hex = tag.color {
            return Color(hex: hex) ?? .purple
        }
        return .purple
    }

    private func deleteTag(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tags[index])
        }
        try? modelContext.save()
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
                    TextField("Tag Name", text: $tagName)
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
        try? modelContext.save()
        HapticManager.success()
        dismiss()
    }
}

// MARK: - User Lists Section

private struct UserListsSection: View {
    let taskLists: [TaskList]
    let onDelete: (IndexSet) -> Void
    let onAddNew: () -> Void
    @State private var editingList: TaskList?

    var body: some View {
        Section("Lists") {
            ForEach(taskLists) { list in
                NavigationLink(value: SidebarSelection.taskList(list.id)) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(hex: list.colorHex) ?? .blue)
                            .frame(width: 10, height: 10)
                        Text(list.name)
                        Spacer()
                        Text("\(list.tasks.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(list.name), \(list.tasks.count) task\(list.tasks.count == 1 ? "" : "s")")
                .contextMenu {
                    Button {
                        editingList = list
                    } label: {
                        Label("Edit List", systemImage: "pencil")
                    }
                }
            }
            .onDelete(perform: onDelete)

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
        try? modelContext.save()
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
        list.name = trimmed
        list.colorHex = selectedColor
        list.defaultDueDateRuleRaw = dueDateRuleRaw.isEmpty ? nil : dueDateRuleRaw
        list.defaultReminderModeRaw = reminderModeRaw.isEmpty ? nil : reminderModeRaw
        try? modelContext.save()
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
