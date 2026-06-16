import SwiftUI
import SwiftData

/// Application settings view.
///
/// Shows account information, sync status, and app info.
struct SettingsView: View {

    @Query private var accounts: [ServerAccount]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler

    var body: some View {
        NavigationStack {
            Form {
                AccountsSection(accounts: accounts)
                SyncSection(syncScheduler: syncScheduler, modelContext: modelContext)
                CalendarSection(accounts: accounts, modelContext: modelContext)
                NotificationsSection()
                TaskBehaviorSection()
                AppearanceSection()
                AboutSection()
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Accounts Section

private struct AccountsSection: View {
    let accounts: [ServerAccount]

    var body: some View {
        Section("Accounts") {
            ForEach(accounts) { account in
                if account.mode == .vault {
                    VaultAccountRow(account: account)
                } else {
                    NavigationLink {
                        AccountEditView(account: account)
                    } label: {
                        AccountRow(account: account)
                    }
                    .accessibilityHint("Double tap to edit account settings")
                }
            }

            NavigationLink {
                AccountSetupView()
            } label: {
                Label("Add Account", systemImage: "plus.circle")
            }
        }
    }
}

private struct AccountRow: View {
    let account: ServerAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                Text(account.serverBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName), Nextcloud server \(account.serverBaseURL)")
    }
}

private struct VaultAccountRow: View {
    let account: ServerAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.purple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.body)
                Text("Local Only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName), Local only vault mode")
    }
}

// MARK: - Sync Section

private struct SyncSection: View {
    @ObservedObject var syncScheduler: SyncScheduler
    let modelContext: ModelContext
    @AppStorage("syncWindowMonths") private var syncWindowMonths = 0

    var body: some View {
        Section {
            Button {
                Task {
                    await syncScheduler.syncNow(modelContext: modelContext)
                }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncScheduler.isSyncing {
                        ProgressView()
                    }
                }
            }
            .disabled(syncScheduler.isSyncing)
            .accessibilityLabel(syncScheduler.isSyncing ? "Syncing in progress" : "Sync now")
            .accessibilityHint("Double tap to sync tasks with your server")

            Picker(selection: $syncWindowMonths) {
                Text("All").tag(0)
                Text("12 Months").tag(12)
                Text("6 Months").tag(6)
                Text("3 Months").tag(3)
                Text("1 Month").tag(1)
            } label: {
                Label("Sync History", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityHint("Limits how far back completed tasks are synced from the server")

            if let lastSync = syncScheduler.lastSyncDate {
                HStack {
                    Text("Last Sync")
                    Spacer()
                    Text(lastSync, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let error = syncScheduler.lastError {
                Label {
                    Text(error)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                .accessibilityLabel(Text("Sync error: \(error)"))
            }
        } header: {
            Text("Sync")
        } footer: {
            if syncWindowMonths > 0 {
                Text("Only completed tasks from the last \(syncWindowMonths) month\(syncWindowMonths == 1 ? "" : "s") will be synced. Active tasks are always synced.")
            }
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("Privacy-first. Zero tracking. Your data stays yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.purple)
            }
        }
    }
}

// MARK: - Notifications Section

private struct NotificationsSection: View {
    @AppStorage(NotificationPreferences.bannerEnabledKey) private var bannerEnabled = true
    @AppStorage(NotificationPreferences.badgeEnabledKey) private var badgeEnabled = true
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Section {
            Toggle(isOn: $bannerEnabled) {
                Label("Banners", systemImage: "text.bubble")
            }
            .accessibilityHint("Show notification banners when reminders fire")

            Toggle(isOn: $badgeEnabled) {
                Label("Badges", systemImage: "app.badge")
            }
            .accessibilityHint("Show a count of overdue tasks on the app icon")
            .onChange(of: badgeEnabled) { _, _ in
                Task {
                    await ReminderScheduler.updateBadgeCount(modelContext: modelContext)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Controls how NowThis alerts you. Banners appear at the top of the screen. Badges show a count on the app icon.")
        }
    }
}

// MARK: - Task Behavior Section

private struct TaskBehaviorSection: View {
    @AppStorage("defaultSiriListID") private var defaultSiriListID: String = ""
    @Query(sort: \TaskList.name) private var taskLists: [TaskList]

    var body: some View {
        Section {
            Picker(selection: $defaultSiriListID) {
                Text("First List").tag("")
                ForEach(taskLists) { list in
                    Text(list.name).tag(list.id)
                }
            } label: {
                Label("Default List for Siri", systemImage: "mic.fill")
            }
            .accessibilityHint("Choose which list Siri adds tasks to when you don't specify one")
        } header: {
            Text("Task Behavior")
        }
    }
}

// MARK: - Appearance Section

private struct AppearanceSection: View {
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        Section {
            Picker(selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { appearance in
                    Label(appearance.displayName, systemImage: appearance.systemImageName)
                        .tag(appearance.rawValue)
                }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
            .accessibilityHint("Choose Light, Dark, or follow the system setting")
        } header: {
            Text("Appearance")
        } footer: {
            Text("System follows your device's Light or Dark setting.")
        }
    }
}

// MARK: - Calendar Section

private struct CalendarSection: View {
    let accounts: [ServerAccount]
    let modelContext: ModelContext

    @StateObject private var permissionManager = CalendarPermissionManager()
    @AppStorage("appleCalendarSyncEnabled") private var appleCalendarEnabled = false
    @AppStorage("nextcloudCalendarSyncEnabled") private var nextcloudCalendarEnabled = false
    @State private var isSyncing = false

    var body: some View {
        Section("Calendar Integration") {
            // Apple Calendar toggle
            Toggle(isOn: $appleCalendarEnabled) {
                Label("Sync to Apple Calendar", systemImage: "applelogo")
            }
            .onChange(of: appleCalendarEnabled) { _, enabled in
                if enabled {
                    Task {
                        let granted = await permissionManager.requestAccess()
                        if !granted {
                            appleCalendarEnabled = false
                        }
                    }
                }
            }

            // Permission status
            if appleCalendarEnabled {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(permissionManager.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Nextcloud Calendar toggle (only for Nextcloud accounts)
            if hasNextcloudAccounts {
                Toggle(isOn: $nextcloudCalendarEnabled) {
                    Label("Sync to Nextcloud Calendar", systemImage: "cloud")
                }
            }

            // Sync Now button
            if appleCalendarEnabled || nextcloudCalendarEnabled {
                Button {
                    syncCalendarsNow()
                } label: {
                    HStack {
                        Label("Sync Calendar Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if isSyncing {
                            ProgressView()
                        }
                    }
                }
                .disabled(isSyncing)
                .accessibilityLabel(isSyncing ? "Calendar sync in progress" : "Sync calendar now")
            }

            // Info text
            Label {
                Text("Tasks with due dates will appear as events in your calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
            }
        }
    }

    private var hasNextcloudAccounts: Bool {
        accounts.contains { $0.mode != .vault }
    }

    private func syncCalendarsNow() {
        isSyncing = true
        Task { @MainActor in
            // Apple Calendar sync
            if appleCalendarEnabled {
                let appleSync = AppleCalendarSyncManager(permissionManager: permissionManager)
                await appleSync.syncAll(modelContext: modelContext)
            }

            // Nextcloud Calendar sync
            if nextcloudCalendarEnabled {
                let nextcloudSync = NextcloudCalendarSyncManager()
                for account in accounts where account.mode != .vault {
                    nonisolated(unsafe) let unsafeAccount = account
                    nonisolated(unsafe) let unsafeContext = modelContext
                    try? await nextcloudSync.syncAll(account: unsafeAccount, modelContext: unsafeContext)
                }
            }

            isSyncing = false
        }
    }
}
