import Testing
@testable import NowThis

@Suite("AppTab / token codec")
struct AppTabTokenTests {

    @Test("Every case round-trips through its token")
    func everyCaseRoundTrips() {
        var cases: [AppTab] = [.tasks, .board, .calendar, .matrix, .settings]
        cases.append(contentsOf: SmartList.allCases.map { AppTab.smart($0) })
        for tab in cases {
            #expect(AppTab.decode(from: tab.token) == tab, "\(tab) did not round-trip")
        }
    }

    @Test("Tokens are stable, because they are persisted")
    func tokensAreStable() {
        #expect(AppTab.tasks.token == "tasks")
        #expect(AppTab.board.token == "board")
        #expect(AppTab.calendar.token == "calendar")
        #expect(AppTab.matrix.token == "matrix")
        #expect(AppTab.settings.token == "settings")
        #expect(AppTab.smart(.today).token == "smart:Today")
        #expect(AppTab.smart(.all).token == "smart:All Tasks")
    }

    @Test("An unknown token decodes to nil rather than a wrong tab")
    func unknownTokenDecodesToNil() {
        #expect(AppTab.decode(from: "retired") == nil)
        #expect(AppTab.decode(from: "smart:Nonexistent") == nil)
        #expect(AppTab.decode(from: "") == nil)
        #expect(AppTab.decode(from: "smart:") == nil)
    }

    /// Both ends of the bar are pinned. `.settings` always was; `.tasks` became
    /// pinned because it is the only host for user Lists, Tags, Saved Filters and
    /// Journals, and hiding it stranded all four — a `NavigationSplitView` inside
    /// a sheet's `NavigationStack` renders its sidebar and never pushes.
    @Test("Neither pinned tab is customizable")
    func pinnedTabsAreNotCustomizable() {
        #expect(AppTab.pinned == [.tasks, .settings])
        #expect(!AppTab.customizable.contains(.tasks))
        #expect(!AppTab.customizable.contains(.settings))
        #expect(AppTab.tasks.isPinned)
        #expect(AppTab.settings.isPinned)
        #expect(!AppTab.board.isPinned)
        #expect(!AppTab.smart(.today).isPinned)
    }

    @Test("Every smart list is offerable as a tab")
    func everySmartListIsOfferable() {
        for smart in SmartList.allCases {
            #expect(AppTab.customizable.contains(.smart(smart)))
        }
    }

    /// The Calendar tab and `SmartList.upcoming` both use the SF Symbol
    /// "calendar" (`SidebarView.swift:99`). Two tabs with an identical icon are
    /// indistinguishable on iPhone, so `AppTab` overrides it. Checked across the
    /// whole bar, pinned tabs included — they sit in it alongside the rest.
    @Test("No two tabs share an icon")
    func iconsAreUnique() {
        let icons = (AppTab.pinned + AppTab.customizable).map(\.icon)
        #expect(Set(icons).count == icons.count, "duplicate icons in \(icons)")
    }
}

@Suite("AppTab / visible order")
struct AppTabVisibleOrderTests {

    @Test("Round-trips a reordered array")
    func roundTripsReorderedArray() {
        let reordered: [AppTab] = [.matrix, .smart(.today), .board]
        let json = AppTab.encodeVisible(reordered)
        #expect(AppTab.decodeVisible(from: json) == reordered)
    }

    @Test("Falls back to default on empty input")
    func emptyInputFallsBackToDefault() {
        #expect(AppTab.decodeVisible(from: "") == AppTab.defaultVisible)
    }

    @Test("Falls back to default on malformed JSON")
    func garbageFallsBackToDefault() {
        #expect(AppTab.decodeVisible(from: "not json") == AppTab.defaultVisible)
    }

    /// "Never configured" and "configured to none" are different states, and the
    /// stored blob distinguishes them: the `@AppStorage` default is `""`, which
    /// is not JSON and falls back above; `"[]"` is what the editor writes when
    /// the user has chosen no tabs at all. Collapsing the two is what forced
    /// `canHide` to protect the last tab — see `AppTabEditorTests.canHideLastTab`.
    @Test("An explicitly empty stored array is honoured, not replaced by the default")
    func emptyStoredListIsHonoured() {
        #expect(AppTab.decodeVisible(from: "[]") == [])
    }

    /// The bar the user asked for: pinned Tasks and pinned Settings, nothing
    /// between them. It has to survive a save/load round trip, because the
    /// editor writes on every change and re-reads on every appearance.
    @Test("Choosing no tabs round-trips")
    func noChosenTabsRoundTrips() {
        #expect(AppTab.decodeVisible(from: AppTab.encodeVisible([])) == [])
    }

    /// A blob whose every entry is stripped means the same thing as `"[]"`: the
    /// user has no chosen tabs. It is reachable from the pre-pinning dev builds,
    /// where `.tasks` was storable, and restoring three tabs to someone who had
    /// hidden all three was never what they asked for.
    @Test("A blob that strips to nothing is an empty bar, not a reset")
    func blobStrippingToNothingIsEmpty() {
        #expect(AppTab.decodeVisible(from: #"["tasks"]"#) == [])
        #expect(AppTab.decodeVisible(from: #"["tasks","settings"]"#) == [])
    }

    /// The opposite of `SidebarSectionOrderTests.unknownRawValueDiscardsEverything`.
    @Test("An unknown token is dropped without discarding the rest")
    func unknownTokenIsDroppedNotFatal() {
        let json = #"["matrix","retired","board"]"#
        #expect(AppTab.decodeVisible(from: json) == [.matrix, .board])
    }

    @Test("Duplicates are collapsed, keeping first position")
    func duplicatesAreCollapsed() {
        let json = #"["board","calendar","board"]"#
        #expect(AppTab.decodeVisible(from: json) == [.board, .calendar])
    }

    /// iOS collapses a 6-item bar to 4 + "More", silently demoting the 5th. Both
    /// pinned tabs occupy a slot, so at most 3 chosen tabs may show.
    @Test("More than maxVisible entries are clamped")
    func excessEntriesAreClamped() {
        let json = AppTab.encodeVisible(
            [.board, .calendar, .matrix, .smart(.today), .smart(.overdue)])
        let decoded = AppTab.decodeVisible(from: json)
        #expect(decoded.count == AppTab.maxVisible)
        #expect(decoded == [.board, .calendar, .matrix])
    }

    /// Pinned Tasks + 3 chosen + pinned Settings is the 5 iOS renders without a
    /// "More" list.
    @Test("maxVisible leaves room for both pinned tabs")
    func maxVisibleLeavesRoomForBothPinnedTabs() {
        #expect(AppTab.maxVisible == 3)
        #expect(AppTab.maxVisible + AppTab.pinned.count == 5)
    }

    /// No stored blob may produce a sixth tab, whatever it holds — that is the
    /// difference between a capped bar and one iOS silently collapses into a
    /// "More" list.
    @Test("Decoding never exceeds the cap, whatever is stored")
    func decodedCountNeverExceedsCap() {
        let blobs = [
            "",
            "[]",
            "not json",
            #"["tasks","board","calendar","matrix"]"#,
            #"["tasks","settings"]"#,
            #"["board","board","calendar","matrix","smart:Today"]"#,
            AppTab.encodeVisible(AppTab.pinned + AppTab.customizable),
            AppTab.encodeVisible(AppTab.customizable),
        ]
        var checked = 0
        for blob in blobs {
            checked += 1
            let decoded = AppTab.decodeVisible(from: blob)
            #expect(decoded.count <= AppTab.maxVisible,
                    "\(blob) decoded to \(decoded.count) tabs, over the cap of \(AppTab.maxVisible)")
        }
        #expect(checked == blobs.count)
    }

    @Test("Settings is stripped if it somehow appears in the stored list")
    func settingsIsStrippedFromStoredList() {
        let json = #"["board","settings","calendar"]"#
        #expect(AppTab.decodeVisible(from: json) == [.board, .calendar])
    }

    /// Development builds of the pre-pinning branch stored `"tasks"` as the
    /// first entry — the design never shipped, so nobody upgrading from a
    /// released build holds one of these. Stripping `.tasks` must still leave
    /// the rest in place: the bar they see is the bar they had — Tasks, Board,
    /// Calendar, Matrix, Settings.
    @Test("Tasks is stripped from a stored list, leaving an upgrading bar unchanged")
    func tasksIsStrippedFromStoredList() {
        #expect(AppTab.decodeVisible(from: #"["tasks","board","calendar","matrix"]"#)
                == [.board, .calendar, .matrix])
        #expect(AppTab.decodeVisible(from: #"["board","tasks","calendar"]"#)
                == [.board, .calendar])
    }

    @Test("A smart list is a first-class tab")
    func smartListIsAFirstClassTab() {
        let json = AppTab.encodeVisible([.board, .smart(.today), .matrix])
        #expect(AppTab.decodeVisible(from: json) == [.board, .smart(.today), .matrix])
    }

    @Test("Hidden is everything customizable that is not visible")
    func hiddenIsTheComplement() {
        let visible: [AppTab] = [.board, .smart(.today)]
        let hidden = AppTab.hidden(given: visible)
        #expect(!hidden.contains(.board))
        #expect(!hidden.contains(.smart(.today)))
        #expect(hidden.contains(.calendar))
        #expect(hidden.contains(.smart(.overdue)))
        // Pinned tabs are never "hidden" — they are never absent.
        #expect(!hidden.contains(.tasks))
        #expect(!hidden.contains(.settings))
        #expect(hidden.count == AppTab.customizable.count - visible.count)
    }

    /// Tasks is pinned in front of these three, so the rendered bar is still
    /// Tasks, Board, Calendar, Matrix, Settings.
    @Test("The default order is today's shipping tab bar")
    func defaultOrderMatchesShippedBar() {
        #expect(AppTab.defaultVisible == [.board, .calendar, .matrix])
        #expect(AppTab.defaultVisible.count == AppTab.maxVisible)
    }
}

@Suite("AppTab / selection resolution")
@MainActor
struct AppTabSelectionTests {

    @Test("A stored selection that is still visible is honoured")
    func visibleSelectionIsHonoured() {
        let visible: [AppTab] = [.board, .matrix]
        #expect(MainTabView.resolveSelection("board", visible: visible) == .board)
    }

    @Test("Both pinned tabs are selectable even though neither is in the visible list")
    func pinnedTabsAreAlwaysSelectable() {
        let visible: [AppTab] = [.board]
        #expect(MainTabView.resolveSelection("settings", visible: visible) == .settings)
        #expect(MainTabView.resolveSelection("tasks", visible: visible) == .tasks)
        #expect(MainTabView.resolveSelection("tasks", visible: []) == .tasks)
    }

    /// Scene restoration can hand back a tab the user has since hidden, and the
    /// pre-existing `@SceneStorage("selectedTab")` held an Int *position* that
    /// stops identifying anything once tabs reorder. Tasks is pinned first, so
    /// it is the bar's first tab and the only correct place to land.
    @Test("A selection that is no longer visible clamps to the pinned Tasks tab")
    func hiddenSelectionClampsToPinnedTasks() {
        let visible: [AppTab] = [.board, .calendar, .smart(.today)]
        #expect(MainTabView.resolveSelection("matrix", visible: visible) == .tasks)
    }

    @Test("A stale Int from the old storage key clamps to the pinned Tasks tab")
    func staleIntClampsToPinnedTasks() {
        let visible: [AppTab] = [.smart(.today), .board]
        #expect(MainTabView.resolveSelection("3", visible: visible) == .tasks)
    }

    @Test("An empty visible list still resolves, because Tasks is pinned")
    func emptyVisibleListResolvesToTasks() {
        #expect(MainTabView.resolveSelection("board", visible: []) == .tasks)
    }
}

@Suite("AppTab / editor rules")
struct AppTabEditorTests {

    @Test("A tab can be added while there is room")
    func canAddWhileThereIsRoom() {
        #expect(AppTab.canAdd(to: [.board, .calendar]))
    }

    @Test("No tab can be added once the bar is full")
    func cannotAddWhenFull() {
        #expect(!AppTab.canAdd(to: [.board, .calendar, .matrix]))
    }

    @Test("Any chosen tab can be hidden while another remains")
    func canHideWhileAnotherRemains() {
        #expect(AppTab.canHide(.board, from: [.board, .calendar]))
        #expect(AppTab.canHide(.smart(.today), from: [.smart(.today), .board]))
        #expect(AppTab.canHide(.board, from: [.board, .calendar, .matrix]))
    }

    /// Reported by a user: *"Won't let me hide all of them so that all I see is
    /// Tasks and Settings."* Both of those are pinned, so hiding every chosen tab
    /// leaves a two-tab bar with nothing stranded — the Tasks title menu still
    /// offers Board, Calendar and Matrix. The floor was never for the user's
    /// benefit; it existed because `decodeVisible` used to read an empty stored
    /// list as "never configured" and hand back the default three.
    @Test("The last remaining tab can be hidden, leaving the two pinned tabs")
    func canHideLastTab() {
        #expect(AppTab.canHide(.board, from: [.board]))
        #expect(AppTab.canHide(.smart(.today), from: [.smart(.today)]))
    }

    /// The two halves of the fix have to agree. Hiding the last tab is only
    /// honest if what the editor then stores survives the loader — otherwise the
    /// row disappears and three tabs reappear on the next appearance.
    @Test("Hiding the last tab stores a bar that loads back empty")
    func hidingTheLastTabPersists() {
        var visible: [AppTab] = [.board]
        #expect(AppTab.canHide(.board, from: visible))
        visible.removeAll { $0 == .board }
        #expect(AppTab.decodeVisible(from: AppTab.encodeVisible(visible)) == [])
    }

    /// `canHide` means "this tab is in the bar", so it has a false branch worth
    /// asserting — without one, `return true` passes the whole suite. A tab the
    /// user already hid cannot be hidden again, and an empty bar has nothing to
    /// hide at all.
    @Test("A tab that is not in the bar cannot be hidden")
    func cannotHideATabThatIsNotInTheBar() {
        #expect(!AppTab.canHide(.calendar, from: [.board, .matrix]))
        #expect(!AppTab.canHide(.smart(.today), from: [.board]))
        #expect(!AppTab.canHide(.board, from: []))
    }

    /// Settings is what the user asked to keep. Two independent things put it
    /// out of reach, and this asserts both: the editor never offers it, because
    /// `hidden(given:)` is drawn from `customizable`; and `canHide` refuses it
    /// even if something asked directly, because a pinned tab is never in
    /// `visible`. Checked with an empty bar among the configurations, since that
    /// is the state this change newly allows.
    @Test("Neither pinned tab is reachable by the editor, whatever the bar holds")
    func pinnedTabsAreUnreachableByTheEditor() {
        let configurations: [[AppTab]] = [[], [.board], [.board, .calendar, .matrix]]
        var checked = 0
        for visible in configurations {
            for pinned in AppTab.pinned {
                checked += 1
                #expect(!AppTab.hidden(given: visible).contains(pinned),
                        "\(pinned) was offered as addable with \(visible) in the bar")
                #expect(!AppTab.canHide(pinned, from: visible),
                        "\(pinned) was hidable with \(visible) in the bar")
            }
        }
        #expect(checked == configurations.count * AppTab.pinned.count)
    }
}

@Suite("AppTab / title menu contents")
struct AppTabTitleMenuTests {

    @Test("Hidden presentations are offered")
    func hiddenPresentationsAreOffered() {
        let visible: [AppTab] = [.smart(.today)]
        let offered = AppTab.titleMenuHiddenPresentations(visible: visible)
        #expect(offered.contains(.board))
        #expect(offered.contains(.calendar))
        #expect(offered.contains(.matrix))
    }

    @Test("Visible presentations are not offered — they are one tap away already")
    func visiblePresentationsAreNotOffered() {
        let visible: [AppTab] = [.board, .calendar, .matrix]
        #expect(AppTab.titleMenuHiddenPresentations(visible: visible).isEmpty)
    }

    @Test("Smart lists never appear in the presentations group")
    func smartListsAreNotPresentations() {
        let visible: [AppTab] = []
        let offered = AppTab.titleMenuHiddenPresentations(visible: visible)
        #expect(!offered.contains { if case .smart = $0 { return true } else { return false } })
    }

    /// The critical regression. When `.tasks` could be hidden it was offered here
    /// as a hidden destination, and the sheet that opened held a
    /// `NavigationSplitView` inside a `NavigationStack`: it rendered the sidebar
    /// and never performed the compact-width push, so tapping a List, Tag, Saved
    /// Filter or Journals row only moved the highlight. Every one of those was
    /// unreachable anywhere in the app. Pinning makes it unofferable.
    @Test("Neither pinned tab is ever offered as a hidden destination")
    func pinnedTabsAreNeverOffered() {
        let configurations: [[AppTab]] = [
            [], [.board], [.smart(.today), .calendar], [.board, .calendar, .matrix],
        ]
        var checked = 0
        for visible in configurations {
            checked += 1
            let offered = AppTab.titleMenuHiddenPresentations(visible: visible)
            #expect(!offered.contains(.tasks), "Tasks was offered as hidden for \(visible)")
            #expect(!offered.contains(.settings), "Settings was offered as hidden for \(visible)")
        }
        #expect(checked == configurations.count)
    }
}

@Suite("TaskListView / title menu jump")
@MainActor
struct TaskListViewJumpTests {

    @Test("A visible tab is selected directly")
    func visibleTabIsSelectedDirectly() {
        let visible: [AppTab] = [.board, .smart(.today)]
        #expect(TaskListView.resolveJump(to: .board, visible: visible) == .selectTab(.board))
        #expect(TaskListView.resolveJump(to: .smart(.today), visible: visible) == .selectTab(.smart(.today)))
    }

    @Test("A pinned tab is selected directly, whatever the bar holds")
    func pinnedTabIsSelectedDirectly() {
        #expect(TaskListView.resolveJump(to: .tasks, visible: [.board]) == .selectTab(.tasks))
        #expect(TaskListView.resolveJump(to: .tasks, visible: []) == .selectTab(.tasks))
    }

    @Test("A smart list without a tab of its own is shown in the pinned Tasks tab")
    func hiddenSmartListShowsInThePinnedTasksTab() {
        let visible: [AppTab] = [.board]
        #expect(TaskListView.resolveJump(to: .smart(.overdue), visible: visible) == .showInTasksTab(.overdue))
    }

    /// Was `hiddenSmartListPresentsAsSheetWhenTasksIsNotVisible`: with Tasks
    /// hidable, a smart list picked from a bar with no Tasks tab had nowhere to
    /// appear and fell back to a sheet. Tasks is pinned now, so it always has a
    /// host and the sheet route is dead for smart lists — checked exhaustively,
    /// because a single stale `visible.contains(.tasks)` test would resurrect it.
    @Test("A smart list never needs a sheet, because Tasks is pinned")
    func smartListNeverNeedsASheet() {
        let configurations: [[AppTab]] = [
            [], [.board, .matrix], [.smart(.today)], [.board, .calendar, .matrix],
        ]
        var checked = 0
        for visible in configurations {
            for smart in SmartList.allCases {
                checked += 1
                let route = TaskListView.resolveJump(to: .smart(smart), visible: visible)
                #expect(route != .presentSheet(.smart(smart)),
                        "\(smart) fell back to a sheet with \(visible) in the bar")
            }
        }
        #expect(checked == configurations.count * SmartList.allCases.count)
    }

    @Test("A hidden Board/Calendar/Matrix presents as a sheet, unchanged")
    func hiddenPresentationPresentsAsSheet() {
        let visible: [AppTab] = []
        #expect(TaskListView.resolveJump(to: .board, visible: visible) == .presentSheet(.board))
        #expect(TaskListView.resolveJump(to: .calendar, visible: visible) == .presentSheet(.calendar))
        #expect(TaskListView.resolveJump(to: .matrix, visible: visible) == .presentSheet(.matrix))
    }

    /// A jump must land on what was picked, *and* by a route that can actually
    /// show it. The payload check alone was near-tautological — an implementation
    /// that always returned `.selectTab(target)` satisfied it, and that is
    /// precisely the original bug: selecting a tab the `TabView` does not contain
    /// is silently clamped back to the first one, so the jump does nothing. So
    /// each route also asserts the precondition that makes it work: `.selectTab`
    /// only for a tab that is in the bar, and the two detours only for one that
    /// is not.
    @Test("Every jump resolves to itself, by a route that can show it")
    func everyJumpResolvesToItself() {
        let configurations: [[AppTab]] = [
            [.board, .calendar, .matrix],
            [.board, .smart(.today), .matrix],
            [.smart(.today), .smart(.overdue)],
            [],
            [.calendar, .matrix, .smart(.all)],
        ]
        var checked = 0
        for visible in configurations {
            for target in AppTab.pinned + AppTab.customizable {
                checked += 1
                let isInTheBar = target.isPinned || visible.contains(target)
                switch TaskListView.resolveJump(to: target, visible: visible) {
                case .selectTab(let tab):
                    #expect(tab == target, "selectTab resolved to \(tab), not the picked \(target)")
                    #expect(isInTheBar, """
                        selectTab(\(tab)) would select a tab the bar \(visible) does not \
                        contain, which resolveSelection clamps straight back to Tasks
                        """)
                case .showInTasksTab(let list):
                    #expect(AppTab.smart(list) == target,
                            "showInTasksTab resolved to \(list), not the picked \(target)")
                    #expect(!isInTheBar, """
                        showInTasksTab detoured \(target) through Tasks although \(visible) \
                        already shows it
                        """)
                case .presentSheet(let tab):
                    #expect(tab == target, "presentSheet resolved to \(tab), not the picked \(target)")
                    #expect(!isInTheBar, """
                        presentSheet(\(tab)) would open a sheet for something the bar \
                        \(visible) already shows
                        """)
                    #expect(!isSmart(tab),
                            "presentSheet(\(tab)): a smart list has the pinned Tasks tab to host it")
                }
            }
        }
        #expect(checked == configurations.count * (AppTab.pinned.count + AppTab.customizable.count))
    }

    private func isSmart(_ tab: AppTab) -> Bool {
        if case .smart = tab { return true }
        return false
    }

    /// From inside the hidden-destination sheet, picking a tab wrote
    /// `selectedTabToken` and left the sheet up: the tab changed invisibly behind
    /// it and nothing appeared to happen. Only the route that *opens* a sheet may
    /// leave one open.
    @Test("Every route but the sheet route dismisses an open sheet")
    func onlyTheSheetRouteKeepsASheetOpen() {
        #expect(TaskListView.TitleMenuJump.selectTab(.board).dismissesPresentedSheet)
        #expect(TaskListView.TitleMenuJump.selectTab(.tasks).dismissesPresentedSheet)
        #expect(TaskListView.TitleMenuJump.showInTasksTab(.overdue).dismissesPresentedSheet)
        #expect(!TaskListView.TitleMenuJump.presentSheet(.calendar).dismissesPresentedSheet)
    }
}

@Suite("AppTab / startup screen")
@MainActor
struct AppTabStartupTests {

    @Test("\"last\" means do not override the restored tab")
    func lastMeansNoOverride() {
        #expect(MainTabView.resolveStartupTab("last", visible: AppTab.defaultVisible) == nil)
    }

    @Test("A tab token selects that tab")
    func tabTokenSelectsThatTab() {
        #expect(MainTabView.resolveStartupTab("tab:matrix", visible: AppTab.defaultVisible) == .matrix)
    }

    /// The pre-existing form. It names a smart list shown *inside* the Tasks
    /// tab, and `MainShellView` still applies it, so the tab bar must land on
    /// Tasks — which is always there now, whatever else the user chose.
    @Test("A legacy smart: value lands on the pinned Tasks tab")
    func legacySmartValueLandsOnTasks() {
        #expect(MainTabView.resolveStartupTab("smart:Overdue", visible: AppTab.defaultVisible) == .tasks)
        #expect(MainTabView.resolveStartupTab("smart:Overdue", visible: []) == .tasks)
    }

    @Test("A startup tab the user has since hidden is ignored")
    func hiddenStartupTabIsIgnored() {
        #expect(MainTabView.resolveStartupTab("tab:matrix", visible: [.board]) == nil)
    }

    @Test("Both pinned tabs are valid startup tabs, because both are always present")
    func pinnedTabsAreValidStartupTabs() {
        #expect(MainTabView.resolveStartupTab("tab:settings", visible: []) == .settings)
        #expect(MainTabView.resolveStartupTab("tab:tasks", visible: []) == .tasks)
    }
}

@Suite("AppTab / Open App To rows")
@MainActor
struct AppTabStartupChoiceTests {

    @Test("The tab rows are the bar itself: pinned Tasks, the chosen tabs, pinned Settings")
    func tabRowsAreTheBarItself() {
        #expect(MainTabView.startupTabChoices(visible: [.board, .matrix])
                == [.tasks, .board, .matrix, .settings])
        #expect(MainTabView.startupTabChoices(visible: []) == [.tasks, .settings])
    }

    /// The legacy meaning is still meaningful and still offered: "open the Tasks
    /// tab showing Overdue" is a different instruction from "open the Overdue
    /// tab". Every upgrading user who ever set this holds one of these values.
    @Test("A legacy smart: value still names a row")
    func legacySmartValueNamesARow() {
        for smart in SmartList.allCases {
            #expect(MainTabView.startupChoiceRow(for: "smart:\(smart.rawValue)", visible: [])
                    == "smart:\(smart.rawValue)")
        }
    }

    @Test("A pinned tab names a row whatever the bar holds")
    func pinnedTabsNameARow() {
        #expect(MainTabView.startupChoiceRow(for: "tab:tasks", visible: []) == "tab:tasks")
        #expect(MainTabView.startupChoiceRow(for: "tab:settings", visible: []) == "tab:settings")
    }

    @Test("A chosen tab names a row")
    func chosenTabNamesARow() {
        #expect(MainTabView.startupChoiceRow(for: "tab:matrix", visible: [.board, .matrix])
                == "tab:matrix")
        #expect(MainTabView.startupChoiceRow(for: "last", visible: []) == "last")
    }

    /// The defect: the picker enumerated only the currently-visible tabs, so a
    /// stored value matching no row's tag selected nothing and the row rendered
    /// blank — with nothing for VoiceOver to speak either.
    @Test("A value naming no row falls back to Last Place, never to nothing")
    func unmatchedValueFallsBackToLastPlace() {
        #expect(MainTabView.startupChoiceRow(for: "tab:matrix", visible: [.board]) == "last")
        #expect(MainTabView.startupChoiceRow(for: "smart:Nonexistent", visible: []) == "last")
        #expect(MainTabView.startupChoiceRow(for: "", visible: []) == "last")
        #expect(MainTabView.startupChoiceRow(for: "garbage", visible: []) == "last")
        #expect(MainTabView.startupChoiceRow(for: "tab:retired", visible: []) == "last")
    }

    /// The row has to describe what launch will actually do, in both directions:
    /// anything shown as "Last Place" must really be a no-op at launch, and
    /// anything shown as a destination must really go there. Falling back to
    /// "Last Place" is only honest because `resolveStartupTab` ignores exactly
    /// the same values.
    @Test("The row shown and the tab opened agree, for every stored value")
    func theRowNeverLiesAboutLaunch() {
        let stored = ["last", "tab:tasks", "tab:settings", "tab:board", "tab:matrix",
                      "tab:smart:Today", "smart:Overdue", "smart:Nonexistent",
                      "", "garbage"]
        let configurations: [[AppTab]] = [
            [], [.board], [.board, .calendar, .matrix], [.smart(.today), .board],
        ]
        var checked = 0
        for visible in configurations {
            for value in stored {
                checked += 1
                let row = MainTabView.startupChoiceRow(for: value, visible: visible)
                let opened = MainTabView.resolveStartupTab(value, visible: visible)
                if row == "last" {
                    #expect(opened == nil, """
                        "\(value)" reads as Last Place with \(visible) in the bar, \
                        but launch opens \(String(describing: opened))
                        """)
                } else {
                    #expect(opened != nil || value == "last", """
                        "\(value)" reads as \(row) with \(visible) in the bar, \
                        but launch overrides nothing
                        """)
                }
            }
        }
        #expect(checked == configurations.count * stored.count)
    }
}

@Suite("MainShellView / startup key")
@MainActor
struct MainShellViewStartupKeyTests {

    /// The pre-existing form: `MainShellView` still owns it, and applies it
    /// over whatever sidebar selection scene storage restored.
    @Test("A smart: startup screen is honoured")
    func smartStartupScreenIsHonoured() {
        #expect(MainShellView.resolveStartupKey(startupScreen: "smart:Overdue", selectionKey: "smart:Today")
                == "smart:Overdue")
    }

    @Test("\"last\" falls back to the restored selection")
    func lastFallsBackToRestoredSelection() {
        #expect(MainShellView.resolveStartupKey(startupScreen: "last", selectionKey: "smart:Overdue")
                == "smart:Overdue")
    }

    /// The regression the Task 6 ruling exists to prevent. `tab:` names a
    /// *tab* — a meaning `MainTabView.resolveStartupTab` now owns — not a
    /// `SidebarSelection`. Before this fix, `MainShellView` decoded it anyway:
    /// `SidebarSelection.decode` returns `.smart(.today)` for any unrecognised
    /// prefix, silently resetting the Tasks tab's sidebar selection to Today on
    /// every launch instead of restoring the user's last place.
    @Test("A tab: startup screen falls back to the restored selection, not Today")
    func tabStartupScreenFallsBackToRestoredSelection() {
        #expect(MainShellView.resolveStartupKey(startupScreen: "tab:matrix", selectionKey: "smart:Overdue")
                == "smart:Overdue")
    }

    /// "Open App To" is a *launch* instruction, so it applies at most once per
    /// launch. The Tasks tab is created lazily and its `@State` flag resets if
    /// the `TabView` ever tears it down, so without a process-wide record the
    /// override re-applied on a later first-appear and overwrote a selection the
    /// user had deliberately jumped to.
    @Test("A selection chosen after launch is not overwritten by Open App To")
    func aChosenSelectionSurvivesTheStartupOverride() {
        #expect(MainShellView.resolveStartupKey(startupScreen: "smart:Today",
                                                selectionKey: "smart:Overdue",
                                                startupWasConsumed: true)
                == "smart:Overdue")
        // Still honoured on the launch that has not consumed it yet.
        #expect(MainShellView.resolveStartupKey(startupScreen: "smart:Today",
                                                selectionKey: "smart:Overdue",
                                                startupWasConsumed: false)
                == "smart:Today")
    }
}
