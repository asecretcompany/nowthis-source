import SwiftUI
import SwiftData

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
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""
    @State private var showPreview = false
    @State private var showingTaskPicker = false

    /// The entry being edited (nil in create mode until saved).
    private var existingEntry: JournalEntry? {
        if case .edit(let entry) = mode { return entry }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                contentSection
                if let entry = existingEntry {
                    LinkedTasksSection(entry: entry, onLinkTask: { showingTaskPicker = true })
                }
            }
            .navigationTitle(existingEntry == nil ? "New Entry" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear { loadExisting() }
            .sheet(isPresented: $showingTaskPicker) {
                if let entry = existingEntry {
                    TaskPickerSheet(entry: entry)
                }
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
                    Text(LocalizedStringKey(content))
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

        if let entry = existingEntry {
            entry.title = trimmed
            entry.content = content
            entry.lastModifiedDate = Date()
            entry.isDirty = true
        } else {
            let entry = JournalEntry(title: trimmed, content: content)
            modelContext.insert(entry)
        }

        try? modelContext.save()
        dismiss()
    }

    private func loadExisting() {
        guard let entry = existingEntry else { return }
        title = entry.title
        content = entry.content
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
                .accessibilityLabel("\(task.title), \(task.status.displayName)")
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(allTasks) { task in
                    TaskPickerRow(
                        task: task,
                        isLinked: isLinked(task),
                        onToggle: { toggleLink(task: task, isLinked: isLinked(task)) }
                    )
                }
            }
            .navigationTitle("Link Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func isLinked(_ task: TaskItem) -> Bool {
        entry.associatedTasks.contains { $0.id == task.id }
    }

    private func toggleLink(task: TaskItem, isLinked: Bool) {
        if isLinked {
            entry.associatedTasks.removeAll { $0.id == task.id }
        } else {
            entry.associatedTasks.append(task)
        }
        entry.isDirty = true
        entry.lastModifiedDate = Date()
        try? modelContext.save()
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
