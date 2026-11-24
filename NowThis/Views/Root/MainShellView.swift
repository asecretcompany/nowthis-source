import SwiftUI
import SwiftData

struct SavedFilterLoadState {
    private var snapshots: [SavedFilterSnapshot] = []
    private(set) var loadFailed = false

    var verifiedFilters: [SavedFilterSnapshot] { loadFailed ? [] : snapshots }

    mutating func reload(_ read: () throws -> [SavedFilterSnapshot]) {
        do {
            snapshots = try read()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    func verifiedFilter(id: String) -> SavedFilterSnapshot? {
        verifiedFilters.first { $0.id == id }
    }

    func lastKnownName(id: String) -> String? { snapshots.first { $0.id == id }?.name }
}

/// Whether "Open App To" has already had its say in this launch.
///
/// `MainShellView`'s own `@State` flag is not enough on its own. The Tasks tab's
/// content is created lazily and a `TabView` may tear it down again, which
/// resets that flag — and the title menu can write a sidebar selection *before*
/// the shell has ever appeared. Either way the first-appear override would then
/// land on top of a selection the user deliberately chose after launch.
///
/// Process-scoped rather than `@SceneStorage`, which survives a relaunch and
/// would disable the setting permanently after its first use.
@MainActor
enum SidebarStartupOverride {
    private(set) static var isConsumed = false

    /// Records that the launch's one startup override has been spent — either by
    /// being applied, or by the user choosing a selection instead.
    static func consume() { isConsumed = true }
}

/// The primary navigation shell using `NavigationSplitView`.
///
/// On iPad: sidebar + detail split view.
/// On iPhone: collapses to navigation stack with sidebar as root list.
struct MainShellView: View {

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.modelContext) private var modelContext
    @SceneStorage("sidebarSelection") private var selectionKey = "smart:Today"
    @AppStorage("startupScreen") private var startupScreen = "last"
    @State private var selection: SidebarSelection? = .smart(.today)
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var hasAppliedStartup = false
    @State private var startedInRegularSizeClasses = false
    @State private var savedFilters = SavedFilterLoadState()
    @Binding private var deepLinkTaskID: String?
    let allowsDeepLinkPresentation: Bool

    init(deepLinkTaskID: Binding<String?> = .constant(nil), allowsDeepLinkPresentation: Bool = true) {
        self._deepLinkTaskID = deepLinkTaskID
        self.allowsDeepLinkPresentation = allowsDeepLinkPresentation
    }

    private func preparePendingTaskLink() {
        guard deepLinkTaskID != nil else { return }
        let next = Self.selectionForDeepLink(current: selection, allowsPresentation: allowsDeepLinkPresentation)
        if next != selection { selection = next }
    }

    /// Which `SidebarSelection` key to restore on appear.
    ///
    /// Only the pre-existing `smart:` form is honoured here — it names a smart
    /// list shown *inside* the Tasks tab, a meaning this view still owns. The
    /// newer `tab:<token>` form (Task 6) names a *tab*, which `MainTabView`
    /// resolves before this view ever appears; decoding it here would fail
    /// `SidebarSelection.decode`, which returns `.smart(.today)` for any
    /// unrecognised prefix, silently resetting the user's last sidebar
    /// selection to Today. Anything other than `smart:` falls back to the
    /// restored `selectionKey` instead.
    ///
    /// `startupWasConsumed` is the second guard: "Open App To" names where a
    /// *launch* lands, so once this launch's override has been spent — see
    /// ``SidebarStartupOverride`` — the restored selection wins outright.
    static func resolveStartupKey(startupScreen: String, selectionKey: String, startupWasConsumed: Bool = false) -> String {
        guard !startupWasConsumed else { return selectionKey }
        return startupScreen.hasPrefix("smart:") ? startupScreen : selectionKey
    }

    static func selectionForDeepLink(current: SidebarSelection?, allowsPresentation: Bool = true) -> SidebarSelection? {
        guard allowsPresentation else { return current }
        switch current {
        case nil, .journals: return .smart(.today)
        default: return current
        }
    }

    static func selectionAfterSizeClassChange(
        current: SidebarSelection?, storedKey: String, newClass: UserInterfaceSizeClass?
    ) -> SidebarSelection? {
        guard current == nil, newClass == .regular else { return current }
        return SidebarSelection.decode(from: storedKey)
    }

    static func restoreSelectionAfterSizeClassChange(
        _ selection: Binding<SidebarSelection?>, storedKey: String, newClass: UserInterfaceSizeClass?
    ) {
        let current = selection.wrappedValue
        let restored = selectionAfterSizeClassChange(
            current: current, storedKey: storedKey, newClass: newClass)
        // Equal-value writes during adaptation can reset compact back navigation.
        guard restored != current else { return }
        selection.wrappedValue = restored
    }

    private var needsCompactSidebarButton: Bool {
        if #available(iOS 27.1, *) {
            return startedInRegularSizeClasses && horizontalSizeClass == .compact && selection != nil
        }
        return false
    }

    var body: some View {
        let retry: (() -> Void)? = savedFilters.loadFailed ? { refreshSavedFilters() } : nil
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(savedFilters: savedFilters.verifiedFilters, retrySavedFilters: retry, selection: $selection)
        } detail: {
            DetailColumn(selection: selection, savedFilter: selectedFilter, lastKnownFilterName: selectedFilterName,
                retrySavedFilters: retry, deepLinkTaskID: $deepLinkTaskID,
                allowsDeepLinkPresentation: allowsDeepLinkPresentation && hasAppliedStartup,
                showsSidebarButton: needsCompactSidebarButton)
        }
        .onAppear {
            refreshSavedFilters()
            if !hasAppliedStartup {
                hasAppliedStartup = true
                startedInRegularSizeClasses = horizontalSizeClass == .regular && verticalSizeClass == .regular
                let key = Self.resolveStartupKey(
                    startupScreen: startupScreen,
                    selectionKey: selectionKey,
                    startupWasConsumed: SidebarStartupOverride.isConsumed)
                SidebarStartupOverride.consume()
                let restored = SidebarSelection.decode(from: key)
                selection = deepLinkTaskID == nil ? restored : Self.selectionForDeepLink(current: restored, allowsPresentation: allowsDeepLinkPresentation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SavedFilterStore.didCommit)) { notification in
            guard notification.object as? String == CalendarMirrorState.storeKey(modelContext.container) else { return }
            refreshSavedFilters()
        }
        .onChange(of: deepLinkTaskID, initial: true) { _, _ in preparePendingTaskLink() }
        .onChange(of: allowsDeepLinkPresentation) { _, allowed in
            if allowed { preparePendingTaskLink() }
        }
        .onChange(of: horizontalSizeClass) { _, newClass in
            Self.restoreSelectionAfterSizeClassChange(
                $selection, storedKey: selectionKey, newClass: newClass)
        }
        .onChange(of: selection) { _, newValue in
            if let newValue {
                selectionKey = newValue.encoded
            }
        }
        // Verified by hand: the title menu's `jump(to:)` writes `selectionKey`
        // directly (it has no `Binding` to `selection`), but `selection` is only
        // ever read from `@SceneStorage` inside `.onAppear`, gated by
        // `hasAppliedStartup` — so an already-appeared shell ignored the write
        // and the visible list never changed. The equality guard matters: the
        // `.onChange(of: selection)` above already writes `selectionKey` on every
        // sidebar-driven selection change, and without the guard that write would
        // immediately re-trigger this one right back.
        .onChange(of: selectionKey) { _, newValue in
            let decoded = SidebarSelection.decode(from: newValue)
            if decoded != selection {
                selection = decoded
            }
        }
    }

    private var selectedFilter: SavedFilterSnapshot? {
        guard case .savedFilter(let id) = selection else { return nil }
        return savedFilters.verifiedFilter(id: id)
    }

    private var selectedFilterName: String? {
        guard case .savedFilter(let id) = selection else { return nil }
        return savedFilters.lastKnownName(id: id)
    }

    private func refreshSavedFilters() {
        savedFilters.reload { try SavedFilterStore.snapshots(in: modelContext.container) }
    }
}

// MARK: - Detail Column

private struct DetailColumn: View {
    let selection: SidebarSelection?
    let savedFilter: SavedFilterSnapshot?
    let lastKnownFilterName: String?
    let retrySavedFilters: (() -> Void)?
    @Binding var deepLinkTaskID: String?
    let allowsDeepLinkPresentation: Bool
    let showsSidebarButton: Bool

    var body: some View {
        if let selection {
            switch selection {
            case .journals:
                JournalListView(showsSidebarButton: showsSidebarButton)
            case .tag, .smart, .taskList, .savedFilter:
                TaskListView(selection: selection, savedFilter: savedFilter, lastKnownFilterName: lastKnownFilterName,
                    retrySavedFilters: retrySavedFilters, deepLinkTaskID: $deepLinkTaskID,
                    allowsDeepLinkPresentation: allowsDeepLinkPresentation, showsSidebarButton: showsSidebarButton)
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

/// Reaches the existing sidebar when a Duo collapse drops its navigation toolbar control.
struct CompactSidebarButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Label(String(localized: "sidebar.action.show",
                defaultValue: "Show Sidebar",
                comment: "Label for the button that returns from the Tasks detail to the sidebar."),
                systemImage: "sidebar.leading")
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("tasks.showSidebar")
    }
}
