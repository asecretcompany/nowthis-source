import SwiftUI
import SwiftData

/// Container view that coordinates month/week calendar views.
///
/// Provides a toolbar toggle between month and week views,
/// a list scope picker, and navigation to day detail and task detail.
struct CalendarContainerView: View {

    enum ViewMode: String, CaseIterable {
        case month = "Month"
        case week = "Week"

        var displayName: String {
            switch self {
            case .month:
                return String(localized: "calendar.viewMode.month", defaultValue: "Month",
                              comment: "Calendar view picker: show a whole month. Segmented control, very short.")
            case .week:
                return String(localized: "calendar.viewMode.week", defaultValue: "Week",
                              comment: "Calendar view picker: show one week. Segmented control, very short.")
            }
        }
    }

    static let allListsPredicate = #Predicate<TaskList> { _ in true }
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }

    static func taskQueryPredicate(listID: String?) -> Predicate<TaskItem> {
        guard let listID else { return activeTasksPredicate }
        return #Predicate<TaskItem> { !$0.isDeletedLocally && $0.taskList?.id == listID }
    }

    @State private var taskLists: [TaskList] = []

    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    @State private var viewMode: ViewMode = .month
    @State private var selectedListID: String?
    @State private var showDayDetail = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncCommands) private var syncCommands

    /// The way out when this screen is the hidden-destination sheet rather than a tab.
    ///
    /// The sheet cannot supply it. This view opens on its own `NavigationStack`, so a `.toolbar`
    /// applied at the presentation site has no bar of this view's to land on — and wrapping it in
    /// a second container to give it one is exactly the nesting `-[UINavigationBar layoutSubviews]`
    /// aborts on. Gated on `isPresented`, so the tab that hosts this same view keeps no Done
    /// button. See `NavigationContainerGuardTests`.
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CalendarScopedTasks(listID: selectedList?.id) { tasks in
                let projection = CalendarTaskProjection(rows: tasks.glanceRows())
                VStack(spacing: 0) {
                    // Calendar view
                    Group {
                        switch viewMode {
                        case .month:
                            CalendarMonthView(
                                tasks: tasks,
                                selectedDate: $selectedDate,
                                displayedMonth: $displayedMonth,
                                projection: projection
                            )
                        case .week:
                            CalendarWeekView(
                                tasks: tasks,
                                selectedDate: $selectedDate,
                                displayedMonth: $displayedMonth,
                                projection: projection
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewMode)

                    Divider()
                        .padding(.top, 8)

                    // Day detail inline
                    CalendarDayDetailView(
                        date: selectedDate,
                        tasks: tasks,
                        projection: projection
                    )
                }
            }
            .background(InboundQueryReader(descriptor: FetchDescriptor<TaskList>(sortBy: [SortDescriptor(\TaskList.name)])) { taskLists = $0 })
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable {
                await syncCommands.syncNow(modelContext)
            }
            .navigationDestination(for: TaskItem.self) { task in
                TaskDetailView(task: task)
            }
            .onAppear {
                if selectedListID == nil {
                    selectedListID = liveLists.first?.id
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isPresented {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }

        ToolbarItem(placement: .principal) {
            if liveLists.count > 1 {
                Menu {
                    ForEach(liveLists) { list in
                        Button {
                            selectedListID = list.id
                        } label: {
                            HStack {
                                Text(list.name)
                                if list.id == selectedListID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedList?.name ?? String(localized: "calendar.title.allLists", defaultValue: "All Lists", comment: "Toolbar title shown where a selected list's name would otherwise appear, used when no specific list is selected (effectively all lists); previously said Calendar in English here, changed to respect the glossary since Calendar is reserved for the separate Apple/EventKit calendar feature in Settings and a CalDAV collection is called a List"))
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Select list")
            } else {
                Text(selectedList?.name ?? String(localized: "calendar.title.allLists", defaultValue: "All Lists", comment: "Toolbar title shown where a selected list's name would otherwise appear, used when no specific list is selected (effectively all lists); previously said Calendar in English here, changed to respect the glossary since Calendar is reserved for the separate Apple/EventKit calendar feature in Settings and a CalDAV collection is called a List"))
                    .font(.headline)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .accessibilityLabel("Calendar view mode")
        }

        ToolbarItem(placement: .topBarLeading) {
            Button {
                withAnimation {
                    selectedDate = Date()
                    displayedMonth = Date()
                }
            } label: {
                Text("Today")
                    .font(.subheadline)
            }
            .accessibilityLabel("Go to today")
        }
    }

    /// The scoped reader guards tasks; the toolbar also guards lists. An account delete cascades
    /// `ServerAccount` -> `TaskList` on the main context while this view is still
    /// on screen. Reading `$0.id` or `list.name` on one of those traps.
    private var liveLists: [TaskList] {
        TaskListHelpers.liveModels(taskLists, in: modelContext)
    }

    private var selectedList: TaskList? {
        liveLists.first { $0.id == selectedListID } ?? liveLists.first
    }
}

/// Selection changes update the query descriptor while the calendar host keeps its state.
private struct CalendarScopedTasks<Content: View>: View {
    let listID: String?
    let content: ([TaskItem]) -> Content
    @State private var tasks: [TaskItem] = []
    @Environment(\.modelContext) private var modelContext

    init(listID: String?, @ViewBuilder content: @escaping ([TaskItem]) -> Content) {
        self.listID = listID
        self.content = content
    }

    var body: some View {
        let descriptor = FetchDescriptor(predicate: CalendarContainerView.taskQueryPredicate(listID: listID))
        content(TaskListHelpers.liveTasks(tasks, in: modelContext, matching: descriptor))
            .background(InboundQueryReader(
                descriptor: FetchDescriptor(predicate: CalendarContainerView.taskQueryPredicate(listID: listID),
                    sortBy: [SortDescriptor(\TaskItem.dueDate)]),
                scope: listID ?? "all", listID: listID) { tasks = $0 })
    }
}
