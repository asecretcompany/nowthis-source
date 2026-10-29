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

    /// The selected tab's ``AppTab/token``.
    ///
    /// A **new key**: the previous `"selectedTab"` held an `Int` *position*,
    /// which stops identifying anything once tabs reorder, and `@SceneStorage`
    /// cannot change a key's type in place. Everyone lands on Tasks once after
    /// updating, which is the correct trade — the old value is meaningless.
    @SceneStorage("selectedTabToken") private var selectedTabToken = AppTab.tasks.token

    /// The user's chosen tabs, in order. Settings is pinned and never stored.
    @AppStorage("tabBarVisible") private var visibleTabsJSON = ""

    /// Which screen "Open App To" names. See ``resolveStartupTab(_:visible:)``.
    @AppStorage("startupScreen") private var startupScreen = "last"
    @State private var hasAppliedStartupTab = false

    @Binding var deepLinkTaskID: String?

    @EnvironmentObject private var syncScheduler: SyncScheduler
    @ScaledMetric(relativeTo: .subheadline) private var syncProgressHeight: CGFloat = 28

    /// Languages whose machine-translation disclosure the user has already dismissed. A set, not
    /// a boolean: switching German → Italian must disclose again, because the sheet that was
    /// acknowledged was written in German. See ``TranslationDisclosure``.
    @AppStorage(TranslationDisclosure.storageKey) private var acknowledgedLanguagesRaw = ""
    @State private var showingTranslationDisclosure = false

    /// The sync failure the user has dismissed. The banner stays hidden for
    /// this exact failure until it clears (a sync succeeds) or a different
    /// failure occurs.
    @State private var dismissedFailure: SyncFailure?

    /// Hrefs of trashed lists the user has already been shown. A set, not a boolean: a list the
    /// user trashes *later* has to produce its own notice, and one already acknowledged must
    /// never come back. See ``TrashedListsNotice``.
    @AppStorage(TrashedListReporter.defaultsKey) private var reportedTrashedHrefsRaw = ""
    @State private var pendingTrashedLists: [TrashedList] = []

    var body: some View {
        VStack(spacing: 0) {
            // Keep this space even while idle: changing the tab viewport's
            // height can move a task away from a tap already in progress.
            Color.clear
                .frame(height: syncProgressHeight)
                .overlay {
                    SyncProgressView()
                        .lineLimit(1)
                }
                .allowsHitTesting(false)

            if SyncFailureBanner.isVisible(
                failure: syncScheduler.lastSyncFailure,
                dismissed: dismissedFailure
            ), let failure = syncScheduler.lastSyncFailure {
                SyncFailureBanner(
                    failure: failure,
                    onTap: failure.isUserActionable ? {
                        withAnimation {
                            selectedTabToken = AppTab.settings.token
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
                // Attached here rather than beside the translation-disclosure sheet below:
                // two `.sheet` modifiers on the same view contend, and only one presents.
                .task { refreshPendingTrashedLists() }
                .onChange(of: syncScheduler.trashedListsFound) { _, _ in
                    refreshPendingTrashedLists()
                }
                .sheet(isPresented: Binding(
                    get: { !pendingTrashedLists.isEmpty },
                    set: { if !$0 { acknowledgeTrashedLists() } }
                )) {
                    TrashedListsNotice(lists: pendingTrashedLists,
                                       onDismiss: acknowledgeTrashedLists)
                }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9),
                   value: syncScheduler.lastSyncFailure)
        .onChange(of: syncScheduler.lastSyncFailure) { _, newValue in
            // Once a sync succeeds (failure clears), forget the dismissal so a
            // later, genuinely new failure can surface again.
            if newValue == nil { dismissedFailure = nil }
        }
        // Reaching MainTabView *is* the onboarding gate: ContentView only shows it once an
        // account exists, so there is no separate flag to consult.
        .task {
            showingTranslationDisclosure = TranslationDisclosure.shouldPresent(
                language: TranslationDisclosure.currentLanguage,
                acknowledged: TranslationDisclosure.decode(acknowledgedLanguagesRaw),
                hasCompletedOnboarding: true)
        }
        .sheet(isPresented: $showingTranslationDisclosure) {
            TranslationDisclosureSheet {
                // Recorded here, on dismiss — a sheet the user never read must not consume
                // the one time this language gets disclosed.
                acknowledgedLanguagesRaw = TranslationDisclosure.encode(
                    TranslationDisclosure.acknowledging(
                        TranslationDisclosure.currentLanguage,
                        in: TranslationDisclosure.decode(acknowledgedLanguagesRaw)))
            }
        }
    }

    private func refreshPendingTrashedLists() {
        let pending = TrashedListReporter.unreported(
            syncScheduler.trashedListsFound,
            reported: TrashedListReporter.decode(reportedTrashedHrefsRaw))
        if !pending.isEmpty { pendingTrashedLists = pending }
    }

    /// Records the shown lists and closes the sheet. Called from the Done button *and* from a
    /// swipe-down dismissal — otherwise a swiped-away notice would return after every sync.
    ///
    /// Hrefs are never forgotten, deliberately. Pruning the set to whatever the last sync found
    /// would mean a sync that failed for one account, or that ran before any account was
    /// reachable, silently re-announcing lists the user has already dismissed. The cost is that
    /// restoring a list on the server and trashing it again does not produce a second notice;
    /// the set is bounded by how many distinct lists a person ever trashes, which is small.
    private func acknowledgeTrashedLists() {
        guard !pendingTrashedLists.isEmpty else { return }
        reportedTrashedHrefsRaw = TrashedListReporter.encode(
            TrashedListReporter.decode(reportedTrashedHrefsRaw)
                .union(pendingTrashedLists.map(\.href)))
        pendingTrashedLists = []
    }

    private var visibleTabs: [AppTab] { AppTab.decodeVisible(from: visibleTabsJSON) }

    /// Resolves a persisted token against the tabs that currently exist.
    ///
    /// Static and pure so the clamping rules are testable without a view.
    /// Anything unrecognised or no longer in the bar clamps to `.tasks`, which
    /// is pinned first and therefore always both present and the bar's leftmost
    /// tab — where iOS itself would land.
    static func resolveSelection(_ stored: String, visible: [AppTab]) -> AppTab {
        guard let tab = AppTab.decode(from: stored) else { return .tasks }
        if tab.isPinned { return tab }
        return visible.contains(tab) ? tab : .tasks
    }

    /// Which tab to open on launch, or `nil` to keep the restored one.
    ///
    /// Three stored forms: `last`, the pre-existing `smart:<rawValue>` (a smart
    /// list shown *inside* the Tasks tab, still applied by `MainShellView`),
    /// and the new `tab:<token>`.
    static func resolveStartupTab(_ stored: String, visible: [AppTab]) -> AppTab? {
        if stored == "last" { return nil }
        // Tasks is pinned, so the legacy form always has a tab to land on.
        if stored.hasPrefix("smart:") {
            return SmartList(rawValue: String(stored.dropFirst("smart:".count))) == nil ? nil : .tasks
        }
        guard stored.hasPrefix("tab:") else { return nil }
        let token = String(stored.dropFirst("tab:".count))
        guard let tab = AppTab.decode(from: token) else { return nil }
        if tab.isPinned { return tab }
        return visible.contains(tab) ? tab : nil
    }

    /// The tabs "Open App To" can name, in bar order — the pinned pair around
    /// whatever the user chose. The picker's rows and ``startupChoiceRow(for:visible:)``
    /// are both built from this, so they cannot drift apart.
    static func startupTabChoices(visible: [AppTab]) -> [AppTab] {
        [.tasks] + visible + [.settings]
    }

    /// The "Open App To" row a stored value selects.
    ///
    /// The picker used to tag rows for the currently-visible tabs only, so a
    /// stored value matching no tag selected nothing: the row rendered with no
    /// value at all and VoiceOver read none either. Every upgrading user holding
    /// a legacy `smart:` value saw that, as did anyone who hid the tab they had
    /// chosen or reset the bar.
    ///
    /// Anything still matching no row falls back to `last`, and that is not a
    /// cosmetic patch: ``resolveStartupTab(_:visible:)`` ignores exactly the same
    /// values, so "Last Place" is what the app genuinely does with them.
    static func startupChoiceRow(for stored: String, visible: [AppTab]) -> String {
        if stored == "last" { return stored }
        if stored.hasPrefix("smart:"),
           SmartList(rawValue: String(stored.dropFirst("smart:".count))) != nil {
            return stored
        }
        if stored.hasPrefix("tab:"),
           let tab = AppTab.decode(from: String(stored.dropFirst("tab:".count))),
           startupTabChoices(visible: visible).contains(tab) {
            return stored
        }
        return "last"
    }

    private var selection: Binding<String> {
        Binding(
            get: { Self.resolveSelection(selectedTabToken, visible: visibleTabs).token },
            set: { selectedTabToken = $0 }
        )
    }

    private var tabView: some View {
        TabView(selection: selection) {
            // Pinned: always first, never hidden, never reordered. It is the only
            // host for user Lists, Tags, Saved Filters and Journals — see
            // ``AppTab`` for what hiding it did to all four.
            tabItem(for: .tasks)

            ForEach(visibleTabs) { tab in
                tabItem(for: tab)
            }

            // Pinned: always last, never hidden, never reordered. This is also
            // what makes the sync-failure banner's jump to Settings safe.
            tabItem(for: .settings)
        }
        .onChange(of: deepLinkTaskID) { _, newValue in
            guard newValue != nil else { return }
            // A deep link opens a task, and the pinned Tasks tab is where the
            // shell that shows one lives.
            selectedTabToken = AppTab.tasks.token
        }
        .onAppear {
            guard !hasAppliedStartupTab else { return }
            hasAppliedStartupTab = true
            if let tab = Self.resolveStartupTab(startupScreen, visible: visibleTabs) {
                selectedTabToken = tab.token
            }
        }
    }

    /// One tab of the bar. Pinned and chosen tabs go through the same builder so
    /// there is a single construction site per screen — `MainShellView` in
    /// particular, since a second instance of it carries its own startup state.
    private func tabItem(for tab: AppTab) -> some View {
        destination(for: tab)
            .tabItem { Label(tab.displayName, systemImage: tab.icon) }
            .tag(tab.token)
    }

    @ViewBuilder
    private func destination(for tab: AppTab) -> some View {
        switch tab {
        case .tasks:
            MainShellView()
        case .board:
            KanbanBoardView().refreshOnInboundSync()
        case .calendar:
            CalendarContainerView().refreshOnInboundSync()
        case .matrix:
            EisenhowerMatrixView().refreshOnInboundSync()
        case .smart(let list):
            // `TaskListView` supplies no navigation container of its own — in
            // the Tasks tab, `MainShellView`'s split view provides it. Without
            // this stack the tab renders with no navigation bar, no title, and
            // a dead `.searchable`.
            NavigationStack {
                TaskListView(selection: .smart(list))
                    .refreshOnInboundSync()
            }
        case .settings:
            SettingsView()
        }
    }
}

#Preview("Onboarding") {
    ContentView(deepLinkTaskID: .constant(nil))
        .modelContainer(for: ServerAccount.self, inMemory: true)
}

