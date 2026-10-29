import Foundation
import Testing
@testable import NowThis

@Suite("WatchSnapshotStore")
struct WatchSnapshotStoreTests {
    private func sampleSnapshot() -> WatchSnapshot {
        WatchSnapshot(
            schemaVersion: WatchSnapshot.currentSchemaVersion,
            isProUnlocked: true,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lists: [WatchListMeta(id: "L1", name: "Work", colorHex: "#FF0000", activeTaskCount: 3)],
            tasks: [WatchTask(id: "T1", uid: "uid-1", title: "Buy milk",
                              dueDate: Date(timeIntervalSince1970: 1_800_000_500),
                              isDueDateOnly: true, priorityRaw: 0, isCompleted: false,
                              listID: "L1", parentUID: nil)],
            truncated: false,
            defaultListID: "L1")
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func snapshotRoundTripsToDisk() throws {
        let dir = try makeTempDir()
        let store = WatchSnapshotStore(containerURL: dir)
        let sample = sampleSnapshot()

        try store.save(sample)
        let loaded = store.load()

        #expect(loaded == sample)
    }

    @Test func loadReturnsNilWhenMissingOrCorrupt() throws {
        let dir = try makeTempDir()
        let store = WatchSnapshotStore(containerURL: dir)

        #expect(store.load() == nil)

        let corruptURL = dir.appendingPathComponent("watch-snapshot.json")
        try Data([0xFF, 0x00, 0xDE, 0xAD]).write(to: corruptURL)

        #expect(store.load() == nil)
    }

    @Test func overlayRoundTripsToDisk() throws {
        let dir = try makeTempDir()
        let store = WatchSnapshotStore(containerURL: dir)
        var overlay = WatchOverlayState()
        overlay.noteComplete(uid: "uid-1")
        overlay.noteUncomplete(uid: "uid-2")
        overlay.noteAdd(WatchPendingAdd(id: UUID(), rawText: "Buy eggs",
                                        createdAt: Date(timeIntervalSince1970: 1_800_000_000)))

        try store.save(overlay: overlay)
        let loaded = store.loadOverlay()

        #expect(loaded == overlay)
    }

    @Test func loadOverlayReturnsDefaultWhenMissingOrCorrupt() throws {
        let dir = try makeTempDir()
        let store = WatchSnapshotStore(containerURL: dir)

        // Missing file → default (empty) overlay, never nil (unlike load()).
        #expect(store.loadOverlay() == WatchOverlayState())

        let corruptURL = dir.appendingPathComponent("watch-overlay.json")
        try Data([0xFF, 0x00, 0xDE, 0xAD]).write(to: corruptURL)

        #expect(store.loadOverlay() == WatchOverlayState())
    }
}
