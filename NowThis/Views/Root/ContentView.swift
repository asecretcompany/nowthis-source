import SwiftUI
import SwiftData

/// Root view that gates on account existence.
///
/// If no `ServerAccount` is found (neither Vault nor Nextcloud),
/// the welcome/onboarding flow is presented. Otherwise, the main
/// tab bar with tasks and settings is shown.
struct ContentView: View {

    @Query private var accounts: [ServerAccount]
    @Binding var deepLinkTaskID: String?

    /// Persisted appearance preference; `.system` follows the device setting.
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Group {
            if accounts.isEmpty {
                WelcomeView()
            } else {
                MainTabView(deepLinkTaskID: $deepLinkTaskID)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: accounts.isEmpty)
        .errorBanner()
        .preferredColorScheme(appearance.colorScheme)
    }
}

// MARK: - Main Tab View

/// The primary tab bar housing Tasks (NavigationSplitView) and Settings.
struct MainTabView: View {

    @State private var selectedTab = 0
    @Binding var deepLinkTaskID: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            MainShellView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(0)

            KanbanBoardView()
                .tabItem {
                    Label("Board", systemImage: "rectangle.split.3x1")
                }
                .tag(1)

            CalendarContainerView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(2)

            EisenhowerMatrixView()
                .tabItem {
                    Label("Matrix", systemImage: "square.grid.2x2")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(4)
        }
        .onChange(of: deepLinkTaskID) { _, newValue in
            if newValue != nil {
                selectedTab = 0 // Switch to Tasks tab on deep link
            }
        }
    }
}

#Preview("Onboarding") {
    ContentView(deepLinkTaskID: .constant(nil))
        .modelContainer(for: ServerAccount.self, inMemory: true)
}

