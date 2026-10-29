import Foundation
import SwiftData
import os

/// Fetches saved Watch state in its own context, merges the main-context overlay, projects,
/// and encodes the payload without returning live SwiftData models across actor isolation.
actor WatchSnapshotWorker {
    private let modelContainer: ModelContainer
    private static let log = Logger(subsystem: "com.asecretcompany.nowthis", category: "WatchSnapshotWorker")

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func makeSnapshot(for request: WatchSnapshotBuildRequest) -> WatchEncodedSnapshot? {
        let interval = PerformanceTrace.begin("WatchSnapshot")
        defer { PerformanceTrace.end("WatchSnapshot", interval) }

        let context = ModelContext(modelContainer)
        // A failed read is not an empty store. Returning nil keeps the last delivered
        // snapshot intact instead of sending a destructive empty or partial replacement.
        guard let savedTasks = try? context.fetch(FetchDescriptor<TaskItem>()),
              let savedLists = try? context.fetch(FetchDescriptor<TaskList>()) else {
            Self.log.error("Snapshot fetch failed; preserving previous Watch state")
            return nil
        }
        let rows = WatchSnapshotProjection.applying(
            request.overlay,
            toTasks: savedTasks.map { WatchTaskInput($0) },
            lists: savedLists.map { WatchListInput($0) }
        )
        let defaultListID = resolveDefaultListID(request.savedDefaultListID, lists: rows.lists)
        let snapshot = WatchSnapshotValueBuilder.build(
            tasks: rows.tasks,
            lists: rows.lists,
            isProUnlocked: request.isProUnlocked,
            defaultListID: defaultListID,
            now: request.now,
            calendar: request.calendar,
            proAccessValidUntil: request.proAccessValidUntil,
            testerProOverride: request.testerProOverride
        )

        do {
            return WatchEncodedSnapshot(contextDictionary: try snapshot.contextDictionary())
        } catch {
            Self.log.error("Snapshot encoding failed: \(error)")
            return nil
        }
    }

    private func resolveDefaultListID(_ savedID: String?, lists: [WatchListInput]) -> String? {
        if let savedID, lists.contains(where: { $0.id == savedID }) {
            return savedID
        }
        return lists.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }?.id
    }
}
