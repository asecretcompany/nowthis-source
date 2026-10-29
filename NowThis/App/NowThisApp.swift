import SwiftUI
import UIKit
import SwiftData
import CoreSpotlight
import os

/// The main entry point for the NowThis app.
///
/// Configures the shared `ModelContainer` using the App Group container
/// so that data is accessible from the main app, widget extension,
/// and watchOS companion.
@main
struct NowThisApp: App {

    private static let logger = Logger(
        subsystem: "com.asecretcompany.nowthis",
        category: "ModelContainer"
    )

    @UIApplicationDelegateAdaptor(StoreLaunchDelegate.self) private var storeLaunchDelegate

    private static func makeStoreOpenCoordinator() -> StoreOpenCoordinator<ModelContainer, StoreOpenFailure> {
        StoreOpenCoordinator(protect: { open in
            StoreOpenBackgroundTask().perform(open: open)
        }) {
            do {
                if let fixture = try PerformanceLaunchFixture.openIfRequested() { return .success(fixture) }
            } catch { return .failure(StoreOpenFailure(message: error.localizedDescription)) }
            let schema = Schema(SchemaV2.models)

            // SwiftData/CoreData expects the App Group support directory to exist.
            if let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppConstants.appGroupID
            ) {
                let supportDirectory = groupURL.appendingPathComponent("Library/Application Support")
                if !FileManager.default.fileExists(atPath: supportDirectory.path) {
                    try? FileManager.default.createDirectory(
                        at: supportDirectory,
                        withIntermediateDirectories: true
                    )
                }
            }

            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(AppConstants.appGroupID)
            )

            do {
                return .success(try ModelContainer(for: schema, configurations: [configuration]))
            } catch {
                logger.error("ModelContainer open failed: \(error.localizedDescription)")
                return .failure(StoreOpenFailure(message: error.localizedDescription))
            }
        }
    }

    /// The Spotlight indexer for system-wide search.
    private let spotlightIndexer = SpotlightIndexer()

    /// Handles notification tap callbacks (NSObject required by UNUserNotificationCenterDelegate).
    private let notificationDelegate = NotificationDelegate()

    /// Manages Background App Refresh for periodic sync while the app is suspended.
    private let backgroundSyncManager = BackgroundSyncManager()

    /// Shared sync engine used by both foreground (`SyncScheduler`) and
    /// background (`BackgroundSyncManager`) paths. The actor-held `isRunning`
    /// flag prevents concurrent syncs from creating duplicate tasks.
    private static let sharedSyncEngine = SyncEngine()

    /// Purchased support ownership and its deadline-aware, idempotent listener.
    private let proEntitlement = ProEntitlement()
    private let appIconController = AppIconController()

    /// iOS side of the phone-mirror to the watch companion app: pushes
    /// `WatchSnapshot`s down and applies `WatchEdit`s back via `WatchEditApplier`.
    private var watchBridge: WatchBridge? { storeLaunchDelegate.watchBridge }

    init() {
        let coordinator = Self.makeStoreOpenCoordinator()
        let scheduler = SyncScheduler(syncEngine: Self.sharedSyncEngine)
        _syncScheduler = StateObject(wrappedValue: scheduler)

        // SwiftUI constructs App before UIKit has finished launching. Prepare only;
        // open under protection in didFinishLaunching, before scene connection.
        storeLaunchDelegate.prepare(coordinator: coordinator, onLaunch: { [backgroundSyncManager] in
            backgroundSyncManager.registerBackgroundTask(syncEngine: Self.sharedSyncEngine)
        }, onOpened: {
            [proEntitlement, appIconController, notificationDelegate, spotlightIndexer, backgroundSyncManager] modelContainer in
            let bridge = WatchBridge(
                entitlement: proEntitlement,
                syncScheduler: scheduler,
                modelContainer: modelContainer
            )
            UNUserNotificationCenter.current().delegate = notificationDelegate
            spotlightIndexer.startObserving(modelContext: modelContainer.mainContext)
            scheduler.configureSpotlight(modelContext: modelContainer.mainContext, indexer: spotlightIndexer)
            backgroundSyncManager.configureStore(modelContainer: modelContainer)
            proEntitlement.start()
            appIconController.start(entitlement: proEntitlement)
            bridge.activate()
            return bridge
        })
    }

    /// Shared sync scheduler for change-triggered and foreground syncs.
    @StateObject private var syncScheduler: SyncScheduler

    /// The task ID to navigate to from a deep link or Spotlight result.
    @State private var deepLinkTaskID: String?

    @Environment(\.scenePhase) private var scenePhase

    private func retryStoreOpen() {
        storeLaunchDelegate.retry()
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer = storeLaunchDelegate.storeOpenState?.container,
               let watchBridge {
            ContentView(deepLinkTaskID: $deepLinkTaskID)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .onContinueUserActivity(
                    CSSearchableItemActionType
                ) { activity in
                    handleSpotlightActivity(activity)
                }
                .task {
                    // Badge count is fast — do it immediately
                    await ReminderScheduler.updateBadgeCount(
                        modelContext: modelContainer.mainContext
                    )
                    // Local recovery must not depend on successful CalDAV execution.
                    await ReminderScheduler.reconcileNow(modelContainer: modelContainer, policy: .background)
                    syncScheduler.syncOnForeground(
                        modelContext: modelContainer.mainContext
                    )
                    // Defer Spotlight reindex (non-blocking)
                    Task {
                        await spotlightIndexer.reindexAll(
                            modelContext: modelContainer.mainContext
                        )
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NotificationDelegate.didTapReminderNotification
                    )
                ) { notification in
                    if let taskID = notification.userInfo?["taskID"] as? String {
                        deepLinkTaskID = taskID
                    }
                }
                .environmentObject(syncScheduler)
                .environment(syncScheduler.progressState)
                .environment(\.syncCommands, syncScheduler.commands)
                .environmentObject(watchBridge)
                .environment(proEntitlement)
                .environment(appIconController)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await proEntitlement.refresh()
                            try? await appIconController.reconcileOwnership(proEntitlement.ownedCollectionIDs)
                        }
                        Task {
                            await ReminderScheduler.reconcileNow(modelContainer: modelContainer, policy: .background)
                            syncScheduler.syncOnForeground(modelContext: modelContainer.mainContext)
                        }
                    } else if newPhase == .background {
                        // Acquire synchronously while the scene callback still owns execution.
                        let assertion = ReminderBackgroundAssertion()
                        assertion.start {
                            await ReminderScheduler.reconcileNow(modelContainer: modelContainer,
                                policy: ReminderReconcilePolicy(allowsPermissionPrompt: false,
                                    deadline: assertion.budget.finalCutoff))
                        }
                        syncScheduler.cancelInflightSync()
                        backgroundSyncManager.scheduleBackgroundSync()
                    }
                }
                .modelContainer(modelContainer)
            } else if let message = storeLaunchDelegate.storeOpenState?.recoveryMessage {
                StoreRecoveryView(errorMessage: message) {
                    retryStoreOpen()
                }
            } else {
                ProgressView()
                    .accessibilityLabel(Text("NowThis"))
            }
        }
    }

    // MARK: - Deep Link Handling

    /// Handles `nowthis://task/{id}` URLs from Spotlight, widgets, and Shortcuts.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "nowthis",
              url.host == "task",
              let taskID = url.pathComponents.dropFirst().first,
              UUID(uuidString: taskID) != nil else {
            return
        }
        deepLinkTaskID = taskID
    }

    /// Handles Spotlight continuation activities.
    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let taskID = activity.userInfo?[
            CSSearchableItemActivityIdentifier
        ] as? String else {
            return
        }
        deepLinkTaskID = taskID
    }
}
