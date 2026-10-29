import Foundation
import Testing
@testable import NowThis

@Suite("Watch Pro deadlines")
struct WatchProAccessTests {
    private let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(unlocked: Bool = true, tester: Bool? = nil) -> WatchSnapshot {
        WatchSnapshot(schemaVersion: 1, isProUnlocked: unlocked, generatedAt: expiry,
                      lists: [WatchListMeta(id: "list", name: "Inbox", colorHex: "#000000", activeTaskCount: 1)],
                      tasks: [WatchTask(id: "task", uid: "uid", title: "Still visible", dueDate: expiry,
                                        isDueDateOnly: false, priorityRaw: 0, isCompleted: false,
                                        listID: "list", parentUID: nil)], truncated: false, defaultListID: "list",
                      proAccessValidUntil: expiry, testerProOverride: tester)
    }

    @Test func deadlineRoundTripsAndExpiryPreservesReading() throws {
        let snapshot = sample()
        let decoded = try #require(WatchSnapshot(contextDictionary: snapshot.contextDictionary()))
        #expect(decoded.proAccessValidUntil == expiry)
        #expect(decoded.canEditTasks(at: expiry.addingTimeInterval(-1)))
        #expect(!decoded.canEditTasks(at: expiry))
        #expect(decoded.tasks == snapshot.tasks)
        #expect(decoded.lists == snapshot.lists)
        #expect(!sample(unlocked: false).canEditTasks(at: expiry.addingTimeInterval(-1)))
        #expect(WatchSmartList.today.filter(decoded.tasks, now: expiry).count == 1)
    }

    @Test func legacyPayloadKeepsLifetimeSemantics() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample())) as? [String: Any])
        object.removeValue(forKey: "proAccessValidUntil")
        object.removeValue(forKey: "testerProOverride")
        let legacy = try #require(WatchSnapshot(contextDictionary: ["snapshot": JSONSerialization.data(withJSONObject: object)]))
        #expect(legacy.canEditTasks(at: expiry.addingTimeInterval(100)))
        #expect(legacy.tasks == sample().tasks)
    }

    @Test func testerAccessIsEphemeralOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WatchSnapshotStore(containerURL: url)
        let snapshot = sample(unlocked: false, tester: true)
        #expect(snapshot.canEditTasks(at: expiry))
        try store.save(snapshot)
        let loaded = try #require(store.load())
        #expect(loaded.testerProOverride == nil)
        #expect(!loaded.canEditTasks(at: expiry))
        #expect(loaded.tasks == snapshot.tasks)
    }
}
