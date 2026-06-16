import SwiftUI
import SwiftData

/// The primary navigation shell using `NavigationSplitView`.
///
/// On iPad: sidebar + detail split view.
/// On iPhone: collapses to navigation stack with sidebar as root list.
struct MainShellView: View {

    @State private var selection: SidebarSelection? = .smart(.today)
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
        } detail: {
            DetailColumn(selection: selection)
        }
    }
}

// MARK: - Detail Column

private struct DetailColumn: View {
    let selection: SidebarSelection?

    var body: some View {
        if let selection {
            switch selection {
            case .journals:
                JournalListView()
            case .tag, .smart, .taskList, .savedFilter:
                TaskListView(selection: selection)
            }
        } else {
            ContentUnavailableView(
                "Select a List",
                systemImage: "sidebar.left",
                description: Text("Choose a list from the sidebar to see your tasks.")
            )
        }
    }
}
