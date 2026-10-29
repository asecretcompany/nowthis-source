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
