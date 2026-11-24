import SwiftUI
import SwiftData
import Combine

/// Full-featured journal editor with Markdown preview toggle.
///
/// Supports create and edit modes. In edit mode, the body is rendered
/// as Markdown when preview is active. Linked tasks are shown with
/// an "Add Task Link" option.
struct JournalEditorView: View {

    enum Mode {
        case create
        case edit(JournalEntry)
    }

    let mode: Mode

    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @Environment(\.dismiss) private var dismiss

    @State private var pendingEntry: JournalEntry?
    @State private var title = ""
    @State private var content = ""
    @State private var showPreview = false
    @State private var showingTaskPicker = false

    @State private var removedFromStore = false

    var body: some View {
        Group {
            switch mode {
            case .create:
                editor(entry: nil)
            case .edit(let retained):
                if !removedFromStore, let entry = JournalVisibility.resolve(retained, in: modelContext) {
                    editor(entry: entry)
                } else {
                    Color.clear
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { dismiss() }
                            }
                        }
                        .task { dismiss() }
                }
            }
        }
        .onReceive(journalChanges) { id in
            guard case .edit(let entry) = mode, entry.persistentModelID == id else { return }
            removedFromStore = JournalVisibility.resolve(entry, in: modelContext) == nil
        }
    }

    private var journalChanges: some Publisher<PersistentIdentifier, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .flatMap { notification in
                // Deliver value IDs only. Never retain the posting ModelContext past its save.
                let updated = notification.userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
                let deleted = notification.userInfo?[ModelContext.NotificationKey.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
                return (updated + deleted).publisher
            }
            .receive(on: RunLoop.main)
    }

    // No `NavigationStack` here. Two of this editor's three hosts push it — the journal list and a
    // task's Linked Journals — onto a stack that already supplies one, and on iOS 18 the second
    // container put a second navigation bar in the window, the state `-[UINavigationBar
    // layoutSubviews]` aborts on. The one host that presents it, the journal list's new-entry
    // sheet, supplies the container instead. Guarded by `NavigationContainerGuardTests`.
    private func editor(entry: JournalEntry?) -> some View {
        Form {
            titleSection
            contentSection
            if let entry {
                LinkedTasksSection(entry: entry, onLinkTask: { showingTaskPicker = true })
            }
        }
        .environment(\.saveErrorState, errorState)
        .errorBanner(errorState)
        .navigationTitle(entry == nil ? "New Entry" : "Edit Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            guard let entry = entry.flatMap({ JournalVisibility.resolve($0, in: modelContext) }) else { return }
            title = entry.title
            content = entry.content
        }
        .blocksTaskLinks()
        .sheet(isPresented: $showingTaskPicker) {
            if let entry = entry.flatMap({ JournalVisibility.resolve($0, in: modelContext) }) {
                TaskPickerSheet(entry: entry)
            }
        }
    }

    // MARK: - Title

    private var titleSection: some View {
        Section {
            TextField("Title", text: $title, axis: .vertical)
                .font(.headline)
                .lineLimit(1...3)
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        Section {
            HStack {
                Text("Content")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { showPreview.toggle() }
                } label: {
                    Image(systemName: showPreview ? "eye.fill" : "eye.slash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPreview ? "Hide preview" : "Show preview")
            }

            if showPreview {
                // Markdown rendered view
                ScrollView {
                    Text(JournalMarkdown.render(content))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .frame(minHeight: 200)
            } else {
                // Raw editor
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .frame(minHeight: 200)
                    .accessibilityLabel("Journal content editor")
            }
        } footer: {
            JournalStorageNotice()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .fontWeight(.semibold)
        }
    }

    // MARK: - Actions

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let entry: JournalEntry
        let isExisting: Bool
        switch mode {
        case .edit(let retained):
            guard let current = JournalVisibility.resolve(retained, in: modelContext) else { dismiss(); return }
            entry = current
            isExisting = true
        case .create:
            if let pendingEntry, pendingEntry.modelContext === modelContext {
                entry = pendingEntry
                isExisting = true
            } else {
                entry = JournalEntry(title: trimmed, content: content)
                modelContext.insert(entry)
                pendingEntry = entry
                isExisting = false
            }
        }
        entry.title = trimmed
        entry.content = content
        if isExisting {
            entry.lastModifiedDate = Date()
            entry.isDirty = true
        }
        guard ViewPersistence.saveOrReport(in: modelContext, errorState: errorState) else { return }
        dismiss()
    }

}

// MARK: - Linked Tasks Section

private struct LinkedTasksSection: View {
    let entry: JournalEntry
    let onLinkTask: () -> Void

    var body: some View {
        Section("Linked Tasks") {
            ForEach(entry.associatedTasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: task.status.systemImageName)
                        .foregroundStyle(task.status == .completed ? .green : .accentColor)
                    Text(task.title)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(
                    localized: "journal.linkedTask.a11y",
                    defaultValue: "\(task.title), \(task.status.displayName)",
                    comment: "VoiceOver label for a task linked to a journal entry. First placeholder is the user-entered title, second is the already-localized status name. Both are data — what is translatable here is the separator and the order."))
            }

            Button(action: onLinkTask) {
                Label("Link Task", systemImage: "link.badge.plus")
            }
        }
    }
}

// MARK: - Task Picker Sheet

private struct TaskPickerSheet: View {
    let entry: JournalEntry

    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }

    @Query(
        filter: Self.activeTasksPredicate,
        sort: \TaskItem.createdDate, order: .reverse
    ) private var allTasks: [TaskItem]

    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @Environment(\.dismiss) private var dismiss

    /// Liveness at the array boundary. `ForEach` reads each task's `id` to diff
    /// identity before any row body runs, and the picker can be open while a sync
    /// or an account delete cascades tasks away on the main context.
    private var liveTasks: [TaskItem] {
        allTasks.filter { $0.modelContext != nil }
    }

    var body: some View {
        NavigationStack {
            if let linked = JournalTaskLinks(entry: entry, in: modelContext) {
                List {
                    ForEach(liveTasks) { task in
                        TaskPickerRow(
                            task: task,
                            isLinked: linked.taskIDs.contains(task.persistentModelID),
                            onToggle: { toggleLink(task: task) }
                        )
                    }
                }
                .environment(\.saveErrorState, errorState)
                .errorBanner(errorState)
                .navigationTitle("Link Tasks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            guard JournalVisibility.resolve(entry, in: modelContext) != nil else { dismiss(); return }
                            guard ViewPersistence.saveOrReport(in: modelContext, errorState: errorState) else { return }
                            dismiss()
                        }
                    }
                }
            } else {
                Color.clear.task { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleLink(task: TaskItem) {
        guard let entry = JournalVisibility.resolve(entry, in: modelContext) else { dismiss(); return }
        guard task.modelContext === modelContext else { return }
        let id = task.persistentModelID
        if entry.associatedTasks.contains(where: { $0.persistentModelID == id }) {
            entry.associatedTasks.removeAll { $0.persistentModelID == id }
        } else {
            guard canLink(task, id: id) else { return }
            entry.associatedTasks.append(task)
        }
        entry.isDirty = true
        entry.lastModifiedDate = Date()
        guard ViewPersistence.saveOrReport(in: modelContext, errorState: errorState) else { return }
    }

    private func canLink(_ task: TaskItem, id: PersistentIdentifier) -> Bool {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.persistentModelID == id && !$0.isDeletedLocally
        })
        descriptor.includePendingChanges = false
        let reader = ModelContext(modelContext.container)
        return (try? reader.fetchIdentifiers(descriptor).contains(id)) == true
            && !modelContext.deletedModelsArray.contains { $0.persistentModelID == id }
            && !task.isDeletedLocally
    }
}

/// One liveness read and one relationship pass supply membership for every rendered task row.
@MainActor
struct JournalTaskLinks {
    let taskIDs: Set<PersistentIdentifier>

    init?(entry: JournalEntry, in context: ModelContext,
          resolve: @MainActor (JournalEntry, ModelContext) -> JournalEntry? = JournalVisibility.resolve) {
        guard let entry = resolve(entry, context) else { return nil }
        taskIDs = Set(entry.associatedTasks.map(\.persistentModelID))
    }
}

// MARK: - Task Picker Row

private struct TaskPickerRow: View {
    let task: TaskItem
    let isLinked: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(task.title)
                    .foregroundStyle(.primary)
                Spacer()
                if isLinked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .accessibilityAddTraits(isLinked ? .isSelected : [])
    }
}
