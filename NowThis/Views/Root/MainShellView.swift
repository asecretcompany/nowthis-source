import SwiftUI
import SwiftData

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

    @SceneStorage("sidebarSelection") private var selectionKey = "smart:Today"
    @AppStorage("startupScreen") private var startupScreen = "last"
    @State private var selection: SidebarSelection? = .smart(.today)
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var hasAppliedStartup = false

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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
        } detail: {
            DetailColumn(selection: selection)
        }
        .onAppear {
            if !hasAppliedStartup {
                hasAppliedStartup = true
                let key = Self.resolveStartupKey(
                    startupScreen: startupScreen,
                    selectionKey: selectionKey,
                    startupWasConsumed: SidebarStartupOverride.isConsumed)
                SidebarStartupOverride.consume()
                selection = SidebarSelection.decode(from: key)
            }
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
