import SwiftUI
import SwiftData
import UIKit
import Testing
@testable import NowThis

@Suite("Sync progress layout", .serialized)
@MainActor
struct SyncProgressLayoutTests {
    @Test("Sync progress never moves the task viewport or its tap targets",
          arguments: [DynamicTypeSize.large, .accessibility3])
    func progressKeepsTaskViewportInPlace(typeSize: DynamicTypeSize) async throws {
        let container = try DAVSyncScenario.container()
        let account = ServerAccount(vaultDisplayName: "Layout Vault")
        let list = TaskList(id: "layout-list", serverURL: "nowthis://layout", name: "Layout", colorHex: "#007AFF")
        list.account = account
        container.mainContext.insert(account)
        container.mainContext.insert(list)
        for index in 0..<8 {
            let task = TaskItem(id: "layout-task-\(index)", title: "Layout task \(index)")
            task.taskList = list
            task.dueDate = Date()
            container.mainContext.insert(task)
        }
        try container.mainContext.save()

        let defaultsName = "NowThis.SyncProgressLayout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in })
        let progress = scheduler.progressState
        let entitlement = ProEntitlement(client: ProStoreTestClient(), cache: ProEntitlementCache(defaults: nil))
        let bridge = WatchBridge(session: nil, entitlement: entitlement,
                                 syncScheduler: scheduler, modelContainer: container)
        let root = MainTabView(deepLinkTaskID: .constant(nil))
            .modelContainer(container)
            .environmentObject(scheduler)
            .environment(progress)
            .environmentObject(bridge)
            .environment(entitlement)
            .environment(AppIconController())
            .environment(\.dynamicTypeSize, typeSize)
            .defaultAppStorage(defaults)
        let controller = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        try await settleLayout(window)
        let tabController = try #require(descendantController(UITabBarController.self, in: controller))
        let viewport = tabController.view!
        let idleFrame = viewport.convert(viewport.bounds, to: window)
        let collection = try #require(descendantView(UICollectionView.self, in: viewport))
        let cell = try #require(collection.visibleCells.sorted {
            $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
        }.first)
        let idleCellFrame = cell.convert(cell.bounds, to: window)
        let tapPoint = CGPoint(x: idleCellFrame.midX, y: idleCellFrame.minY + 8)
        let idleTarget = cellContaining(window.hitTest(tapPoint, with: nil))
        try #require(idleTarget != nil, "The probe must land on a real task-list cell")
        try capture(window, name: "\(typeSize)-idle")

        for stage in [SyncProgress.Stage.discovering, .downloading, .finishing] {
            progress.apply(.init(accountID: account.id, listID: list.id, stage: stage,
                                 completed: 12, total: 100))
            try await settleLayout(window)
            #expect(viewport.convert(viewport.bounds, to: window) == idleFrame,
                    "Starting or updating sync must not resize or move the task viewport")
            #expect(cell.convert(cell.bounds, to: window) == idleCellFrame,
                    "The task under the user's finger must stay in place")
            #expect(cellContaining(window.hitTest(tapPoint, with: nil)) === idleTarget,
                    "The same screen coordinate must keep targeting the same task")
            if stage == .downloading {
                try capture(window, name: "\(typeSize)-syncing")
            }
        }

        progress.clear()
        try await settleLayout(window)
        #expect(viewport.convert(viewport.bounds, to: window) == idleFrame)
        #expect(cell.convert(cell.bounds, to: window) == idleCellFrame)
        #expect(cellContaining(window.hitTest(tapPoint, with: nil)) === idleTarget)
    }

    @Test("Large-text landscape leaves enough unobscured space for a complete task row")
    func accessibilityLandscapeFitsTaskRow() async throws {
        let container = try DAVSyncScenario.container()
        let account = ServerAccount(vaultDisplayName: "Landscape Vault")
        let list = TaskList(id: "landscape-list", serverURL: "nowthis://layout", name: "Landscape", colorHex: "#007AFF")
        list.account = account
        container.mainContext.insert(account)
        container.mainContext.insert(list)
        for index in 0..<3 {
            let task = TaskItem(id: "landscape-task-\(index)", title: "Duo fixture smoke 26.10.1")
            task.taskList = list
            task.dueDate = Date()
            container.mainContext.insert(task)
        }
        try container.mainContext.save()
        let defaultsName = "NowThis.LandscapeLayout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in })
        // 438 pt is the landscape container after the shell's reserved 28 pt sync strip.
        // Host this component directly: the test phone's TabView has different chrome from Duo.
        let root = NavigationStack { TaskListView(selection: .smart(.today)) }
            .modelContainer(container)
            .environmentObject(scheduler)
            .environment(scheduler.progressState)
            .environment(\.dynamicTypeSize, .accessibility3)
            .environment(\.verticalSizeClass, .compact)
            .defaultAppStorage(defaults)
            .frame(width: 678, height: 438)
        let controller = UIHostingController(rootView: root)
        // The bounded landscape probe must not inherit the physical test phone's portrait insets.
        controller.safeAreaRegions = []
        controller.traitOverrides.verticalSizeClass = .compact
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await settleLayout(window)
        let collection = try #require(descendantView(UICollectionView.self, in: controller.view))
        let row = try #require(collection.visibleCells.filter { $0.bounds.height > 50 }.first)
        let unobscuredHeight = collection.bounds.height - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom
        print("LANDSCAPE_ROW: visible=\(unobscuredHeight) row=\(row.bounds.height)")
        try capture(window, name: "accessibility3-landscape-row")
        #expect(unobscuredHeight >= row.bounds.height,
                "A task must fit above the idle composer without shrinking accessibility text")
    }

    @Test("Short large-text windows retain the inline composer whenever a draft or focus exists")
    func shortWindowKeepsActiveComposer() {
        for typeSize in [DynamicTypeSize.large, .accessibility1, .accessibility3] {
            for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
                #expect(TaskListView.showsInlineComposer(verticalSizeClass: sizeClass,
                    dynamicTypeSize: typeSize, isFocused: true, title: ""))
                #expect(TaskListView.showsInlineComposer(verticalSizeClass: sizeClass,
                    dynamicTypeSize: typeSize, isFocused: false, title: "Pending draft"))
            }
        }
        #expect(!TaskListView.showsInlineComposer(verticalSizeClass: .compact,
            dynamicTypeSize: .accessibility3, isFocused: false, title: ""))
        #expect(TaskListView.showsInlineComposer(verticalSizeClass: .regular,
            dynamicTypeSize: .accessibility3, isFocused: false, title: ""))
        #expect(TaskListView.showsInlineComposer(verticalSizeClass: .compact,
            dynamicTypeSize: .large, isFocused: false, title: ""))
    }

    @Test("A cold task link opens its actual editor and later links wait for that editor", arguments: [false, true])
    func coldLinkPresentsTaskEditor(queueAnother: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let account = ServerAccount(vaultDisplayName: "Link Vault")
        let list = TaskList(id: "link-list", serverURL: "nowthis://link", name: "Links", colorHex: "#007AFF")
        list.account = account
        let task = TaskItem(title: "Cold linked task outside Today")
        task.taskList = list
        container.mainContext.insert(account)
        container.mainContext.insert(list)
        container.mainContext.insert(task)
        let next = TaskItem(title: "Queued target")
        next.taskList = list
        container.mainContext.insert(next)
        try container.mainContext.save()
        let defaultsName = "NowThis.DeepLinkHost.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set("tab:settings", forKey: "startupScreen")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let probe = TaskLinkHostProbe(request: task.id)
        let scheduler = SyncScheduler(onWidgetReload: {}, onNotificationFlush: { _ in })
        let entitlement = ProEntitlement(client: ProStoreTestClient(), cache: ProEntitlementCache(defaults: nil))
        let bridge = WatchBridge(session: nil, entitlement: entitlement,
                                 syncScheduler: scheduler, modelContainer: container)
        let root = MainTabView(deepLinkTaskID: Binding(get: { probe.request }, set: { probe.request = $0 }))
            .modelContainer(container)
            .environmentObject(scheduler)
            .environment(scheduler.progressState)
            .environmentObject(bridge)
            .environment(entitlement)
            .environment(AppIconController())
            .defaultAppStorage(defaults)
        let controller = UIHostingController(rootView: root)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            probe.request = nil
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
            if let presented = presentedController(in: controller),
               editorTexts(in: presented.view).contains(task.title) { break }
        }
        #expect(probe.request == nil, "The real view wiring must consume the presented request")
        let presented = try #require(presentedController(in: controller), "The linked task editor must be presented")
        #expect(editorTexts(in: presented.view).contains(task.title), "The editor must show the exact linked task")
        if queueAnother {
            probe.request = next.id
            try await settleLayout(window)
            #expect(probe.request == next.id, "An active editor must keep the next link pending")
            #expect(presentedController(in: controller) === presented)
            #expect(editorTexts(in: presented.view).contains(task.title))
        }
    }

    @Test("New and pushed journal editors block task links until they leave", arguments: [false, true])
    func journalEditorsBlockTaskLinks(editing: Bool) async throws {
        let container = try DAVSyncScenario.container()
        let entry = JournalEntry(title: "Journal draft target", content: "Original writing")
        container.mainContext.insert(entry)
        try container.mainContext.save()
        let blockers = TaskLinkPresentationState()
        let root = NavigationStack { JournalEditorView(mode: editing ? .edit(entry) : .create) }
            .modelContainer(container)
            .environment(\.taskLinkPresentations, blockers)
        let controller = UIHostingController(rootView: AnyView(root))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        try await settleLayout(window)
        #expect(blockers.isBlocked, "Both journal entry paths must retain ownership while visible")
        controller.rootView = AnyView(Color.clear)
        try await settleLayout(window)
        #expect(!blockers.isBlocked, "Leaving the editor must release a pending link")
        #expect(try ModelContext(container).fetch(FetchDescriptor<JournalEntry>()).map(\.content) == ["Original writing"])
    }

    private func editorTexts(in view: UIView) -> [String] {
        var values: [String] = []
        if let field = view as? UITextField, let text = field.text { values.append(text) }
        if let field = view as? UITextView, let text = field.text { values.append(text) }
        return values + view.subviews.flatMap { editorTexts(in: $0) }
    }

    private func presentedController(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController { return presented }
        for child in controller.children {
            if let presented = presentedController(in: child) { return presented }
        }
        return nil
    }

    private func settleLayout(_ window: UIWindow) async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
    }

    private func descendantController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        for child in controller.children {
            if let match = descendantController(type, in: child) { return match }
        }
        return nil
    }

    private func descendantView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendantView(type, in: child) { return match }
        }
        return nil
    }

    private func cellContaining(_ view: UIView?) -> UICollectionViewCell? {
        guard let view else { return nil }
        if let cell = view as? UICollectionViewCell { return cell }
        return cellContaining(view.superview)
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let directory = URL.documentsDirectory.appending(path: "SyncProgressLayout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appending(path: "\(name).png"))
        print("SYNC_LAYOUT_SCREENSHOT: \(directory.appending(path: "\(name).png").path)")
    }
}

@MainActor
@Observable
private final class TaskLinkHostProbe {
    var request: String?
    init(request: String?) { self.request = request }
}
