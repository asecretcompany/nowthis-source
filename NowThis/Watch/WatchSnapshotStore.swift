import Foundation

/// Persists the last WatchSnapshot + overlay as JSON in the watchOS App Group
/// container so the watch app and the complication widget share one source.
struct WatchSnapshotStore {
    private let snapshotURL: URL?
    private let overlayURL: URL?

    init(containerURL: URL? = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)) {
        snapshotURL = containerURL?.appendingPathComponent("watch-snapshot.json")
        overlayURL = containerURL?.appendingPathComponent("watch-overlay.json")
    }

    func save(_ snapshot: WatchSnapshot) throws {
        guard let url = snapshotURL else { return }
        var purchased = snapshot
        purchased.testerProOverride = nil
        try JSONEncoder().encode(purchased).write(to: url, options: .atomic)
    }
    func load() -> WatchSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
    func save(overlay: WatchOverlayState) throws {
        guard let url = overlayURL else { return }
        try JSONEncoder().encode(overlay).write(to: url, options: .atomic)
    }
    func loadOverlay() -> WatchOverlayState {
        guard let url = overlayURL, let data = try? Data(contentsOf: url),
              let overlay = try? JSONDecoder().decode(WatchOverlayState.self, from: data)
        else { return WatchOverlayState() }
        return overlay
    }
}
