import SwiftUI
import SwiftData

/// The primary navigation shell using `NavigationSplitView`.
///
/// On iPad: sidebar + detail split view.
/// On iPhone: collapses to navigation stack with sidebar as root list.
struct MainShellView: View {

    @SceneStorage("sidebarSelection") private var selectionKey = "smart:Today"
    @AppStorage("startupScreen") private var startupScreen = "last"
    @State private var selection: SidebarSelection? = .smart(.today)
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var hasAppliedStartup = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
        } detail: {
            DetailColumn(selection: selection)
        }
        .onAppear {
            if !hasAppliedStartup {
                hasAppliedStartup = true
                let key = startupScreen == "last" ? selectionKey : startupScreen
                selection = SidebarSelection.decode(from: key)
            }
        }
        .onChange(of: selection) { _, newValue in
            if let newValue {
                selectionKey = newValue.encoded
            }
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
                    .refreshOnInboundSync()
            case .tag, .smart, .taskList, .savedFilter:
                TaskListView(selection: selection)
                    .refreshOnInboundSync()
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
