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
    }

    static let allListsPredicate = #Predicate<TaskList> { _ in true }
    static let activeTasksPredicate = #Predicate<TaskItem> { !$0.isDeletedLocally }

    @Query(
        filter: Self.allListsPredicate,
        sort: \TaskList.name
    ) private var taskLists: [TaskList]

    @Query(
        filter: Self.activeTasksPredicate,
        sort: \TaskItem.dueDate
    ) private var allTasks: [TaskItem]

    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    @State private var viewMode: ViewMode = .month
    @State private var selectedListID: String?
    @State private var showDayDetail = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Calendar view
                Group {
                    switch viewMode {
                    case .month:
                        CalendarMonthView(
                            tasks: filteredTasks,
                            selectedDate: $selectedDate,
                            displayedMonth: $displayedMonth
                        )
                    case .week:
                        CalendarWeekView(
                            tasks: filteredTasks,
                            selectedDate: $selectedDate,
                            displayedMonth: $displayedMonth
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: viewMode)

                Divider()
                    .padding(.top, 8)

                // Day detail inline
                CalendarDayDetailView(
                    date: selectedDate,
                    tasks: filteredTasks
                )
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .refreshable {
                await syncScheduler.syncNow(modelContext: modelContext)
            }
            .navigationDestination(for: TaskItem.self) { task in
                TaskDetailView(task: task)
            }
            .onAppear {
                if selectedListID == nil {
                    selectedListID = taskLists.first?.id
                }
            }
        }
    }

    // MARK: - Data

    private var filteredTasks: [TaskItem] {
        guard let listID = selectedListID ?? taskLists.first?.id else {
            return allTasks
        }
        return allTasks.filter { $0.taskList?.id == listID }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if taskLists.count > 1 {
                Menu {
                    ForEach(taskLists) { list in
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
                        Text(selectedList?.name ?? "Calendar")
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Select task list")
            } else {
                Text(selectedList?.name ?? "Calendar")
                    .font(.headline)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Picker("View", selection: $viewMode) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
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

    private var selectedList: TaskList? {
        taskLists.first { $0.id == selectedListID } ?? taskLists.first
    }
}
