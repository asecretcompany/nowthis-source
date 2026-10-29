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
                WatchProNudgeSection()
                AccountsSection(accounts: accounts)
                SyncSection(syncScheduler: syncScheduler, modelContext: modelContext)
                ProUpsellView()
                QAToolsSection()
                CalendarSection(accounts: accounts, modelContext: modelContext)
                NotificationsSection()
                TaskBehaviorSection()
                TaskPhotoSettingsSection()
                SiriShortcutsSection()
                TabBarLayoutSection()
                SidebarLayoutSection()
                AppearanceSection()
                AboutSection()
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Watch Supporter Nudge Section

/// Dismissible contextual nudge shown only when the user has a paired Apple
/// Watch with the NowThis watch app installed but hasn't unlocked Supporter yet.
/// The actual purchase controls live in `ProUpsellView` just below — this row
/// only surfaces the offer and deep-links nowhere else (no cross-surface
/// navigation plumbing; see Task 12 notes for the deferred sidebar variant).
private struct WatchProNudgeSection: View {
    @Environment(ProEntitlement.self) private var entitlement
    @EnvironmentObject private var watchBridge: WatchBridge
    @AppStorage("proUpsellDismissed") private var dismissed = false

    var body: some View {
        if !entitlement.isUnlocked && watchBridge.isWatchPairedAndInstalled && !dismissed {
            Section {
                HStack {
                    Label("You have an Apple Watch — unlock editing with NowThis Supporter", systemImage: "applewatch")
                        .accessibilityLabel("You have an Apple Watch. Unlock NowThis Supporter to check off and add tasks from your wrist.")

                    Spacer()

                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                    .accessibilityHint(String(
                        localized: "settings.watchNudge.a11y.dismissHint",
                        defaultValue: "Dismisses the NowThis Supporter offer for Apple Watch",
                        comment: "VoiceOver hint on the button that dismisses the NowThis Supporter suggestion shown to Apple Watch owners. Spoken, not shown. 'NowThis Supporter' is the product name and is never translated; there is no product called 'Apple Watch Supporter'."))
                }
            }
        }
    }
}

// MARK: - QA Tools Section

/// A tester-only section for exercising the real purchase flow. Non-production
/// builds auto-unlock Supporter (so testers get the watch app free), which hides the
/// purchase button — this toggle forces the paywall so QA can run the sandbox
/// purchase. Shown only when `isTesterBuild` is true, so it never appears for
/// App Store customers; and the underlying override can only remove the tester
/// unlock, never grant access (see `ProEntitlement.forcePaywallOverride`).
private struct QAToolsSection: View {
    @Environment(ProEntitlement.self) private var entitlement
    @EnvironmentObject private var watchBridge: WatchBridge
    @AppStorage(ProEntitlement.forcePaywallKey) private var forcePaywall = false

    var body: some View {
        if entitlement.isTesterBuild {
            // Verbatim throughout: this section is compiled into every build but shown
            // only to testers (`isTesterBuild`), so its copy is deliberately English-only
            // QA text and never enters the localization catalog. `Text(verbatim:)` keeps
            // it out of the spoken-copy and view-copy guards for exactly that reason.
            Section {
                Toggle(isOn: $forcePaywall) {
                    Label {
                        Text(verbatim: "Force paywall (test purchase)")
                    } icon: {
                        Image(systemName: "creditcard")
                    }
                }
                .accessibilityHint(Text(verbatim: String(localized: "support.qa.forcePaywall.hint",
                    defaultValue: "Hides the automatic tester unlock so you can run the real NowThis Supporter purchase. Testing only.",
                    comment: "Spoken tester-only hint. This hides automatic tester access, not verified ownership.")))
                .onChange(of: forcePaywall) { _, _ in
                    Task {
                        await entitlement.refresh()
                        watchBridge.pushSnapshot()
                    }
                }
            } header: {
                Text(verbatim: "QA / Testing")
            } footer: {
                Text(verbatim: String(localized: "support.qa.forcePaywall.body",
                    defaultValue: "Only visible in TestFlight and development builds. Turn on to reach the NowThis Supporter purchase button; turn off to return to free tester access.",
                    comment: "Tester-only explanation. Verified purchases remain honored when automatic tester access is hidden."))
            }
        }
    }
}

// MARK: - Accounts Section

/// An immutable snapshot of the fields an account row renders.
///
/// The row that launches the delete is the row that has to survive it: tapping
/// an account pushes `AccountEditView`, whose "Delete Account" calls
/// `AccountManager.removeAccount` on the **main** context. Settings is a
/// permanent tab, so this row is still realized underneath and re-renders as the
/// editor pops — reading `account.mode` on the by-then invalidated model trips
/// SwiftData's `BackingData` assertion.
struct AccountRowData: Equatable, Identifiable {
    let id: String
    let displayName: String
    let serverBaseURL: String
    let isVault: Bool

    /// Builds a snapshot from a live account, or `nil` once its backing row is gone.
    init?(account: ServerAccount) {
        guard account.modelContext != nil else { return nil }
        self.id = account.id
        self.displayName = account.displayName
        self.serverBaseURL = account.serverBaseURL
        self.isVault = account.mode == .vault
    }
}

/// A snapshot paired with the live account, which the pushed editor still needs.
private struct AccountEntry: Identifiable {
    let data: AccountRowData
    let account: ServerAccount

    var id: String { data.id }

    init?(account: ServerAccount) {
        guard let data = AccountRowData(account: account) else { return nil }
        self.data = data
        self.account = account
    }
}

private struct AccountsSection: View {
    let accounts: [ServerAccount]

    var body: some View {
        Section("Accounts") {
            // Snapshot at the array boundary, not inside the row: `ForEach` reads
            // each element's `id` to diff identity before any row body runs, so a
            // guard in `AccountRow` would come one model read too late.
            ForEach(accounts.compactMap(AccountEntry.init(account:))) { entry in
                if entry.data.isVault {
                    VaultAccountRow(data: entry.data)
                } else {
                    NavigationLink {
                        AccountEditView(account: entry.account)
                    } label: {
                        AccountRow(data: entry.data)
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
    let data: AccountRowData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: data.displayName)
                    .font(.body)
                Text(verbatim: data.serverBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.displayName), Nextcloud server \(data.serverBaseURL)")
    }
}

private struct VaultAccountRow: View {
    let data: AccountRowData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.purple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: data.displayName)
                    .font(.body)
                Text("Local Only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.displayName), Local only vault mode")
    }
}

// MARK: - Sync Section

private struct SyncSection: View {
    @ObservedObject var syncScheduler: SyncScheduler
    let modelContext: ModelContext
    @AppStorage(SyncPreferences.windowMonthsKey) private var syncWindowMonths = SyncPreferences.defaultWindowMonths

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
            .accessibilityLabel(syncScheduler.isSyncing
                                ? String(localized: "settings.a11y.syncing",
                                         defaultValue: "Syncing in progress",
                                         comment: "VoiceOver label while a task sync is running.")
                                : String(localized: "settings.a11y.syncNow",
                                         defaultValue: "Sync now",
                                         comment: "VoiceOver label for the button that syncs tasks with the server. Spoken, not shown — sentence case, unlike the visible 'Sync Now' button."))
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
                if let statusCode = syncScheduler.lastSyncFailure?.httpStatusCode {
                    LabeledContent {
                        Text(verbatim: "HTTP \(statusCode)")
                            .monospaced()
                            .textSelection(.enabled)
                    } label: {
                        Text(verbatim: String(localized: "settings.sync.errorDetails",
                            defaultValue: "Error details",
                            comment: "Label beside the HTTP response code for the last failed sync. Lets users report the specific error without sharing account or task data."))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            if syncWindowMonths > 0 {
                Text(verbatim: String(
                    localized: "settings.sync.window.footer",
                    defaultValue: "Only completed tasks from the last \(syncWindowMonths) months will be synced. Active tasks are always synced.",
                    comment: "Footer under the sync settings explaining that the sync window limits how far back completed tasks are fetched. The placeholder is a whole number of months."))
            }
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    /// The disclosure is shown once per language, so it needs a permanent home afterwards —
    /// a disclosure the user can never find again is a formality. Hidden in English, which is
    /// the source language and was not translated.
    @State private var showingTranslationDisclosure = false

    var body: some View {
        Section("About") {
            if TranslationDisclosure.currentLanguage != "en" {
                Button {
                    showingTranslationDisclosure = true
                } label: {
                    Label(String(
                        localized: "disclosure.translation.title",
                        defaultValue: "About this translation",
                        comment: "Title of the sheet explaining that this translation is machine-made, and the label of the Settings row that reopens it. A heading, not a sentence: 'this translation' means the text the reader is currently looking at."),
                          systemImage: "character.bubble")
                }
                .sheet(isPresented: $showingTranslationDisclosure) {
                    // Reachable on demand, so there is no acknowledgement to record: the user
                    // opened it deliberately and it was already owed or already given.
                    TranslationDisclosureSheet(onAcknowledge: {})
                }
            }

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
                ReminderScheduler.requestReconcile(modelContext: modelContext)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Controls how NowThis alerts you. Banners appear at the top of the screen. Badges show a count on the app icon.")
        }
    }
}

// MARK: - Task Behavior Section

/// A list's identity and name, lifted out of the `@Model` so the picker's `ForEach`
/// never touches a model that a sync may have deleted mid-render.
private struct ListChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

private struct TaskBehaviorSection: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TaskDefaultsPreferences.defaultListIDKey) private var defaultNewTaskListID: String = ""
    @AppStorage("showCompletedTasks") private var showCompleted = false
    @AppStorage("startupScreen") private var startupScreen = "last"
    @AppStorage("tabBarVisible") private var visibleTabsJSON = ""
    @AppStorage(TaskDefaultsPreferences.dueDateRuleKey) private var defaultDueDateRule: DefaultDueDateRule = .none
    @AppStorage(TaskDefaultsPreferences.reminderEnabledKey) private var defaultReminderEnabled = false
    @AppStorage(TaskDefaultsPreferences.allDayReminderMinutesKey) private var allDayReminderMinutes = TaskDefaultsPreferences.defaultAllDayReminderMinutes
    @AppStorage(TaskDefaultsPreferences.dueTimeMinutesKey) private var dueTimeMinutes = TaskDefaultsPreferences.defaultDueTimeMinutes
    @Query(sort: \TaskList.name) private var taskLists: [TaskList]

    var body: some View {
        Section {
            Picker(selection: startupSelection) {
                Text("Last Place").tag("last")

                Section {
                    ForEach(MainTabView.startupTabChoices(visible: visibleTabs)) { tab in
                        Text(verbatim: tab.displayName).tag("tab:\(tab.token)")
                    }
                } header: {
                    Text("Tabs")
                }

                // The pre-existing form, still offered and still distinct: this
                // opens the Tasks tab *showing* that list, where the row above
                // opens a tab of its own. All five, always — every one of them
                // is reachable inside Tasks whatever the bar holds.
                Section {
                    ForEach(SmartList.allCases) { smart in
                        Text(verbatim: smart.displayName).tag("smart:\(smart.rawValue)")
                    }
                } header: {
                    Text("Smart Lists")
                }
            } label: {
                Label("Open App To", systemImage: "arrow.right.circle")
            }
            .accessibilityHint("Choose which screen appears when you open NowThis")

            Toggle(isOn: $showCompleted) {
                Label("Show Completed Tasks", systemImage: "checkmark.circle")
            }
            .accessibilityHint("When off, completed tasks are hidden from your lists and from the calendar view. The board's Completed column always shows them.")

        } header: {
            Text("Task Behavior")
        } footer: {
            Text("Completed tasks can also be toggled from the filter bar on any list.")
        }

        Section {
            // Hidden rather than disabled when there is nothing to pick: a picker
            // offering no lists is worse than no picker.
            if !listChoices.isEmpty {
                Picker(selection: defaultListSelection) {
                    ForEach(listChoices) { choice in
                        Text(verbatim: choice.name).tag(choice.id)
                    }
                } label: {
                    Label("Default List for New Tasks", systemImage: "list.bullet")
                }
                .accessibilityHint("Choose which list new tasks go to when you're not already viewing a list. Siri and the watch use it too.")
            }

            Picker(selection: $defaultDueDateRule) {
                ForEach(DefaultDueDateRule.allCases) { rule in
                    Text(rule.displayName).tag(rule)
                }
            } label: {
                Label("Default Due Date", systemImage: "calendar")
            }
            .accessibilityHint("The due date applied to new tasks. Individual lists can override this, and you can change it per task.")

            Toggle(isOn: $defaultReminderEnabled) {
                Label("Remind Me About New Tasks", systemImage: "bell")
            }
            .accessibilityHint("When on, new tasks that have a due date get a reminder automatically")

            DatePicker(
                selection: dueTimeBinding,
                displayedComponents: .hourAndMinute
            ) {
                Label("Default Due Time", systemImage: "clock.badge.checkmark")
            }
            .accessibilityHint("The time of day given to new tasks when you pick a quick due date like Today or Tomorrow. You can still change the time, or mark a task All Day, per task.")

            DatePicker(
                selection: allDayReminderTimeBinding,
                displayedComponents: .hourAndMinute
            ) {
                Label("All-Day Reminder Time", systemImage: "clock")
            }
            .accessibilityHint("The time of day reminders fire for tasks that are due on a day without a specific time")
        } header: {
            Text("New Task Defaults")
        } footer: {
            Text("New tasks pick up these defaults so they stay visible in the list you add them to. Tasks you add while viewing a list go to that list; everywhere else they go to your default list. You can override the date on each task, and give any list its own defaults from the list's settings.")
        }
        .onAppear(perform: adoptDefaultListIfNeeded)
    }

    private var visibleTabs: [AppTab] { AppTab.decodeVisible(from: visibleTabsJSON) }

    /// "Open App To"'s selection, resolved rather than read raw — the same
    /// treatment ``defaultListSelection`` below needs, for the same reason.
    ///
    /// The picker tagged rows for the visible tabs only, so every value outside
    /// that set — an upgrading user's legacy `smart:`, a `tab:` whose tab has
    /// since been hidden or reset away — matched no tag and drew an empty row,
    /// with nothing for VoiceOver to read either. The legacy values are rows of
    /// their own now, and anything still matching nothing reads as "Last Place",
    /// which is exactly what `MainTabView.resolveStartupTab` does with it.
    private var startupSelection: Binding<String> {
        Binding(
            get: { MainTabView.startupChoiceRow(for: startupScreen, visible: visibleTabs) },
            set: { startupScreen = $0 }
        )
    }

    /// Lists offered by the picker, in the same localized order the resolver uses.
    ///
    /// Snapshotted to a value type before `ForEach` rather than iterating live models:
    /// `ForEach` reads each element's `id` to diff identity *before* any row body runs,
    /// so a list deleted by a sync mid-render is dereferenced by the loop itself. The
    /// guard belongs at the array boundary, not in the row.
    private var listChoices: [ListChoice] {
        taskLists
            .filter { $0.modelContext != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { ListChoice(id: $0.id, name: $0.name) }
    }

    /// The picker's selection, resolved rather than read raw.
    ///
    /// `onAppear` persists the adopted list, but it runs *after* the first render — and a
    /// `Picker` whose selection matches no tag draws an empty row. So the getter applies
    /// the same fallback the resolver does, and the row shows a real list name on the
    /// very first frame instead of blank-then-populated.
    private var defaultListSelection: Binding<String> {
        Binding(
            get: {
                let stored = defaultNewTaskListID
                if listChoices.contains(where: { $0.id == stored }) { return stored }
                return listChoices.first?.id ?? ""
            },
            set: { defaultNewTaskListID = $0 }
        )
    }

    /// Materialises the stored default so the picker shows a concrete list name.
    ///
    /// Doubles as the migration point for the old `defaultSiriListID` key — the
    /// resolver reads through ``TaskDefaultsPreferences/defaultListID``, which copies
    /// the legacy value forward, so by the time the picker binds its `@AppStorage` the
    /// new key holds a real ID.
    private func adoptDefaultListIfNeeded() {
        _ = NewTaskDefaults.resolveListAdopting(explicit: nil, in: modelContext)
    }

    /// Bridges the stored minutes-since-midnight to a `Date` for the time picker.
    private var allDayReminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(Double(allDayReminderMinutes) * 60)
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                allDayReminderMinutes = (comps.hour ?? 9) * 60 + (comps.minute ?? 0)
                ReminderScheduler.requestReconcile(modelContext: modelContext)
            }
        )
    }

    /// Bridges the stored default-due-time minutes-since-midnight to a `Date`.
    private var dueTimeBinding: Binding<Date> {
        Binding(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(Double(dueTimeMinutes) * 60)
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                dueTimeMinutes = (comps.hour ?? 9) * 60 + (comps.minute ?? 0)
            }
        )
    }
}

// MARK: - Siri & Shortcuts Section

private struct SiriShortcutsSection: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Try: \"Hey Siri, add a reminder in NowThis\"")
                        .font(.callout)
                    Text("Also works: \"add a task\", \"what's due today\", \"complete a task\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.blue)
            }

            Link(destination: URL(string: "shortcuts://")!) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom Siri Phrases")
                            .font(.callout)
                        Text("Create your own voice commands in the Shortcuts app using NowThis actions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.purple)
                }
            }
        } header: {
            Text("Siri & Shortcuts")
        }
    }
}

// MARK: - Sidebar Layout Section

private struct SidebarLayoutSection: View {
    @AppStorage("sidebarSectionOrder") private var sectionOrderJSON = ""
    @AppStorage("sidebarHiddenSections") private var hiddenSectionsJSON = ""
    @State private var sections: [SidebarSection] = SidebarSection.defaultOrder
    @State private var hiddenSections: Set<SidebarSection> = []

    var body: some View {
        Section {
            ForEach($sections) { $section in
                let currentSection = section
                HStack {
                    Label(currentSection.displayName, systemImage: iconFor(currentSection))
                    Spacer()
                    Button {
                        toggleVisibility(currentSection)
                    } label: {
                        Image(systemName: hiddenSections.contains(currentSection) ? "eye.slash" : "eye")
                            .foregroundStyle(hiddenSections.contains(currentSection) ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hiddenSections.contains(currentSection) ? "Show \(currentSection.displayName)" : "Hide \(currentSection.displayName)")
                }
            }
            .onMove(perform: moveSection)

            Button("Reset to Default") {
                sections = SidebarSection.defaultOrder
                hiddenSections = []
                saveOrder()
                saveHidden()
            }
            .foregroundStyle(.red)
        } header: {
            HStack {
                Text("Sidebar Layout")
                Spacer()
                EditButton()
                    .font(.caption)
            }
        } footer: {
            Text("Smart Lists always appears first. Drag to reorder, tap the eye to hide sections.")
        }
        .onAppear { loadState() }
    }

    private func iconFor(_ section: SidebarSection) -> String {
        switch section {
        case .filters: return "line.3.horizontal.decrease.circle"
        case .journals: return "book.closed.fill"
        case .tags: return "tag.fill"
        case .lists: return "list.bullet"
        }
    }

    private func loadState() {
        sections = SidebarSection.loadOrder(from: sectionOrderJSON)
        if sections.isEmpty { sections = SidebarSection.defaultOrder }
        if let data = hiddenSectionsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SidebarSection].self, from: data) {
            hiddenSections = Set(decoded)
        }
    }

    private func moveSection(from source: IndexSet, to destination: Int) {
        sections.move(fromOffsets: source, toOffset: destination)
        saveOrder()
    }

    private func toggleVisibility(_ section: SidebarSection) {
        if hiddenSections.contains(section) {
            hiddenSections.remove(section)
        } else {
            hiddenSections.insert(section)
        }
        saveHidden()
    }

    private func saveOrder() {
        sectionOrderJSON = SidebarSection.encodeOrder(sections)
    }

    private func saveHidden() {
        let array = Array(hiddenSections)
        if let data = try? JSONEncoder().encode(array) {
            hiddenSectionsJSON = String(data: data, encoding: .utf8) ?? ""
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
            NavigationLink("App Icon") { AppIconPickerView() }
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
                .accessibilityLabel(isSyncing
                                    ? String(localized: "settings.a11y.calendarSyncing",
                                             defaultValue: "Calendar sync in progress",
                                             comment: "VoiceOver label while an Apple Calendar sync is running.")
                                    : String(localized: "settings.a11y.syncCalendarNow",
                                             defaultValue: "Sync calendar now",
                                             comment: "VoiceOver label for the button that syncs tasks with Apple Calendar. Spoken, not shown — sentence case, unlike the visible 'Sync Calendar Now' button."))
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
        accounts.contains { $0.modelContext != nil && $0.mode != .vault }
    }

    private func syncCalendarsNow() {
        isSyncing = true
        // Resolve which accounts to sync *before* the awaits below. Reading
        // `account.mode` after them risks touching a model that an account delete
        // invalidated while the Apple leg was still running.
        let calendarAccounts = accounts.filter { $0.modelContext != nil && $0.mode != .vault }
        Task { @MainActor in
            // Apple Calendar sync
            if appleCalendarEnabled {
                let appleSync = AppleCalendarSyncManager(permissionManager: permissionManager)
                await appleSync.syncAll(modelContext: modelContext)
            }

            // Nextcloud Calendar sync
            if nextcloudCalendarEnabled {
                let nextcloudSync = NextcloudCalendarSyncManager()
                // Re-checked each iteration: the previous account's network round
                // trip is another window for the delete to land.
                for account in calendarAccounts where account.modelContext != nil {
                    nonisolated(unsafe) let unsafeAccount = account
                    nonisolated(unsafe) let unsafeContext = modelContext
                    try? await nextcloudSync.syncAll(account: unsafeAccount, modelContext: unsafeContext)
                }
            }

            isSyncing = false
        }
    }
}

#if DEBUG
#Preview("Settings sync controls") {
    let container = try! ModelContainer(for: Schema(SchemaV2.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let _ = try! AccountManager(modelContext: container.mainContext).createVaultAccount()
    let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in })
    let entitlement = ProEntitlement(cache: ProEntitlementCache(defaults: nil),
                                     testerBuild: { false }, forcePaywall: { false })
    let bridge = WatchBridge(session: nil, entitlement: entitlement,
                             syncScheduler: scheduler, modelContainer: container)
    return SettingsView()
        .modelContainer(container)
        .environmentObject(scheduler)
        .environmentObject(bridge)
        .environment(entitlement)
        .environment(AppIconController())
}

#Preview("Sync error details") {
    let container = try! ModelContainer(for: Schema(SchemaV2.models),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in })
    let failure = SyncFailure.from(CalDAVError.serverError(statusCode: 500))
    scheduler.lastSyncFailure = failure
    scheduler.lastError = failure?.message
    return Form {
        SyncSection(syncScheduler: scheduler, modelContext: container.mainContext)
    }
}
#endif
