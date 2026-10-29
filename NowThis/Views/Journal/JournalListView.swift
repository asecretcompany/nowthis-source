import SwiftUI
import SwiftData

/// List of journal entries with create and delete functionality.
///
/// Appears when the user selects "Journals" in the sidebar.
/// Entries are sorted by creation date (newest first).
struct JournalListView: View {

    @State private var journals: [JournalEntry] = []

    @Environment(\.modelContext) private var modelContext
    @State private var showingNewEntry = false

    // No `NavigationStack` here. `MainShellView`'s detail column is this view's only host and
    // already supplies one, and on a compact iPhone that `NavigationSplitView` collapses into a
    // single navigation controller — so a stack of our own put a second navigation bar in the
    // window alongside the collapsed one. That is the state `-[UINavigationBar layoutSubviews]`
    // asserts on ("the top item belongs to a different navigation bar ... possibly from a client
    // attempt to nest wrapped navigation controllers"), and it aborts the app. The title, the
    // toolbar and the `NavigationLink` pushes below all attach to the detail column's bar
    // unchanged. Guarded by `NavigationContainerGuardTests`.
    var body: some View {
        Group {
            if liveJournals.isEmpty {
                emptyState
            } else {
                journalList
            }
        }
        .background(InboundQueryReader(descriptor: FetchDescriptor<JournalEntry>(sortBy: [SortDescriptor(\JournalEntry.createdDate, order: .reverse)])) { journals = $0 })
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
            // The editor brings no container of its own, because the rows below push it. A sheet
            // is a new presentation, so here it needs one for its title and Cancel/Save.
            NavigationStack {
                JournalEditorView(mode: .create)
            }
        }
    }

    private var liveJournals: [JournalEntry] {
        TaskListHelpers.liveModels(journals, in: modelContext).filter { !$0.isDeletedLocally }
    }

    // MARK: - List

    private var journalList: some View {
        List {
            // Liveness before `isDeletedLocally`, and before `ForEach` reads `id`
            // to diff identity — both dereference the entry, so the guard inside
            // the row below would otherwise run two model reads too late.
            ForEach(liveJournals) { entry in
                if let data = JournalRowData(entry: entry) {
                    NavigationLink {
                        JournalEditorView(mode: .edit(entry))
                    } label: {
                        JournalRow(data: data)
                    }
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
        // Must match the array the rows were built from, or the offsets point at
        // the wrong entries.
        let visible = liveJournals
        for index in offsets {
            let entry = visible[index]
            entry.isDeletedLocally = true
            entry.isDirty = true
        }
        try? modelContext.save()
    }
}

// MARK: - Journal Row

/// An immutable snapshot of the fields a `JournalRow` renders.
///
/// The row is handed a value, never a live `JournalEntry`. SwiftUI retains
/// realized rows across updates, so a later layout pass could read `entry.title`
/// on a model whose backing row a sync (or an account delete) had already
/// removed, tripping SwiftData's `BackingData` assertion. Snapshotting at
/// row-build time — while `@Query` still guarantees validity — closes that window.
struct JournalRowData: Equatable {
    let title: String
    let content: String
    let createdDate: Date
    let associatedTaskCount: Int

    /// Builds a snapshot from a live entry, or `nil` if the entry's backing row
    /// has been invalidated. Callers treat `nil` as "row is gone — render nothing".
    init?(entry: JournalEntry) {
        guard entry.modelContext != nil else { return nil }
        self.title = entry.title
        self.content = entry.content
        self.createdDate = entry.createdDate
        self.associatedTaskCount = entry.associatedTasks.count
    }
}

private struct JournalRow: View {
    let data: JournalRowData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: data.title)
                .font(.headline)
                .lineLimit(1)

            if !data.content.isEmpty {
                Text(verbatim: data.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Text(data.createdDate, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if data.associatedTaskCount > 0 {
                    Label { Text(data.associatedTaskCount, format: .number) }
                        icon: { Image(systemName: "link") }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            localized: "journal.entryRow.a11y",
            defaultValue: "\(data.title), \(data.createdDate, format: .dateTime.month(.wide).day())",
            comment: "VoiceOver label for a journal entry row. First placeholder is the user-entered title, second is the entry's date. Both are data — what is translatable here is the separator and the order."))
    }
}
