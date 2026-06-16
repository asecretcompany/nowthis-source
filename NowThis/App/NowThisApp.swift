import SwiftUI
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

    /// The shared model container for all SwiftData models.
    /// Uses the App Group container for cross-target data sharing.
    /// Falls back to the default container if the App Group is unavailable
    /// (e.g., in test hosts or CI environments).
    var sharedModelContainer: ModelContainer = {
        let schema = Schema(SchemaV2.models)

        // Pre-create the Application Support directory inside the App Group container.
        // SwiftData/CoreData expects this directory to exist but iOS does not
        // auto-create it for App Group containers, causing noisy error logs on first launch.
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupID
        ) {
            let supportDir = groupURL.appendingPathComponent("Library/Application Support")
            if !FileManager.default.fileExists(atPath: supportDir.path) {
                try? FileManager.default.createDirectory(
                    at: supportDir,
                    withIntermediateDirectories: true
                )
            }
        }

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(AppConstants.appGroupID)
        )

        // Primary: App Group container
        do {
            return try ModelContainer(
                for: schema,
                configurations: [config]
            )
        } catch {
            logger.error("ModelContainer init failed: \(error.localizedDescription)")
            backupStoreFiles()
        }

        // Retry after backing up the old store
        do {
            return try ModelContainer(
                for: schema,
                configurations: [config]
            )
        } catch {
            logger.error("Retry failed: \(error.localizedDescription)")
        }

        // Last resort: default container (no App Group)
        do {
            return try ModelContainer(for: schema)
        } catch {
            fatalError(
                "Could not create ModelContainer: \(error.localizedDescription)"
            )
        }
    }()

    /// Backs up SQLite store files to a `.backup` directory so user data is
    /// preserved for potential manual recovery after a migration failure.
    private static func backupStoreFiles() {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupID
        ) else { return }

        let supportDir = groupURL.appendingPathComponent("Library/Application Support")
        let fm = FileManager.default
        let extensions = ["sqlite", "sqlite-wal", "sqlite-shm"]

        // Create timestamped backup directory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backupDir = supportDir.appendingPathComponent(
            "backup-\(formatter.string(from: Date()))"
        )
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        do {
            let files = try fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)
            for file in files {
                let ext = file.pathExtension
                if extensions.contains(ext) || file.lastPathComponent.hasSuffix(".store") {
                    let dest = backupDir.appendingPathComponent(file.lastPathComponent)
                    try fm.moveItem(at: file, to: dest)
                    logger.info("Backed up \(file.lastPathComponent) to \(backupDir.lastPathComponent)")
                }
            }
        } catch {
            logger.error("Backup failed: \(error.localizedDescription)")
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

    init() {
        _syncScheduler = StateObject(wrappedValue: SyncScheduler(syncEngine: Self.sharedSyncEngine))
        UNUserNotificationCenter.current().delegate = notificationDelegate
        backgroundSyncManager.registerBackgroundTask(
            modelContainer: sharedModelContainer,
            syncEngine: Self.sharedSyncEngine
        )
    }

    /// Shared sync scheduler for change-triggered and foreground syncs.
    @StateObject private var syncScheduler: SyncScheduler

    /// The task ID to navigate to from a deep link or Spotlight result.
    @State private var deepLinkTaskID: String?

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
                        modelContext: sharedModelContainer.mainContext
                    )
                    // Sync first — it will refresh reminders on completion
                    syncScheduler.syncOnForeground(
                        modelContext: sharedModelContainer.mainContext
                    )
                    // Defer Spotlight reindex (non-blocking)
                    Task {
                        await spotlightIndexer.reindexAll(
                            modelContext: sharedModelContainer.mainContext
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
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        syncScheduler.syncOnForeground(
                            modelContext: sharedModelContainer.mainContext
                        )
                        Task {
                            await ReminderScheduler.updateBadgeCount(
                                modelContext: sharedModelContainer.mainContext
                            )
                        }
                    } else if newPhase == .background {
                        syncScheduler.cancelInflightSync()
                        backgroundSyncManager.scheduleBackgroundSync()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
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
