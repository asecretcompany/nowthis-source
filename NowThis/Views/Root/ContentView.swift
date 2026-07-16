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

    @SceneStorage("selectedTab") private var selectedTab = 0
    @Binding var deepLinkTaskID: String?

    @EnvironmentObject private var syncScheduler: SyncScheduler

    /// The sync failure the user has dismissed. The banner stays hidden for
    /// this exact failure until it clears (a sync succeeds) or a different
    /// failure occurs.
    @State private var dismissedFailure: SyncFailure?

    private static let settingsTab = 4

    var body: some View {
        VStack(spacing: 0) {
            if SyncFailureBanner.isVisible(
                failure: syncScheduler.lastSyncFailure,
                dismissed: dismissedFailure
            ), let failure = syncScheduler.lastSyncFailure {
                SyncFailureBanner(
                    failure: failure,
                    onTap: failure.isUserActionable ? {
                        withAnimation {
                            selectedTab = Self.settingsTab
                            dismissedFailure = syncScheduler.lastSyncFailure
                        }
                    } : nil,
                    onDismiss: {
                        withAnimation { dismissedFailure = syncScheduler.lastSyncFailure }
                    }
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            tabView
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9),
                   value: syncScheduler.lastSyncFailure)
        .onChange(of: syncScheduler.lastSyncFailure) { _, newValue in
            // Once a sync succeeds (failure clears), forget the dismissal so a
            // later, genuinely new failure can surface again.
            if newValue == nil { dismissedFailure = nil }
        }
    }

    private var tabView: some View {
        TabView(selection: $selectedTab) {
            MainShellView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(0)

            KanbanBoardView()
                .refreshOnInboundSync()
                .tabItem {
                    Label("Board", systemImage: "rectangle.split.3x1")
                }
                .tag(1)

            CalendarContainerView()
                .refreshOnInboundSync()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
                .tag(2)

            EisenhowerMatrixView()
                .refreshOnInboundSync()
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

