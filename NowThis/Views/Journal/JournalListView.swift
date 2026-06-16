import SwiftUI
import SwiftData

/// List of journal entries with create and delete functionality.
///
/// Appears when the user selects "Journals" in the sidebar.
/// Entries are sorted by creation date (newest first).
struct JournalListView: View {

    @Query(sort: \JournalEntry.createdDate, order: .reverse)
    private var journals: [JournalEntry]

    @Environment(\.modelContext) private var modelContext
    @State private var showingNewEntry = false

    var body: some View {
        NavigationStack {
            Group {
                if journals.isEmpty {
                    emptyState
                } else {
                    journalList
                }
            }
            .navigationTitle("Journals")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewEntry = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New journal entry")
                }
            }
            .sheet(isPresented: $showingNewEntry) {
                JournalEditorView(mode: .create)
            }
        }
    }

    // MARK: - List

    private var journalList: some View {
        List {
            ForEach(journals.filter { !$0.isDeletedLocally }) { entry in
                NavigationLink {
                    JournalEditorView(mode: .edit(entry))
                } label: {
                    JournalRow(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Journals", systemImage: "book.closed")
        } description: {
            Text("Tap + to create your first journal entry.")
        }
    }

    // MARK: - Actions

    private func deleteEntries(at offsets: IndexSet) {
        let visible = journals.filter { !$0.isDeletedLocally }
        for index in offsets {
            let entry = visible[index]
            entry.isDeletedLocally = true
            entry.isDirty = true
        }
        try? modelContext.save()
    }
}

// MARK: - Journal Row

private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title)
                .font(.headline)
                .lineLimit(1)

            if !entry.content.isEmpty {
                Text(entry.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(entry.createdDate, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !entry.associatedTasks.isEmpty {
                    Label("\(entry.associatedTasks.count)", systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title), \(entry.createdDate, format: .dateTime.month(.wide).day())")
    }
}
