import Foundation
import Testing
@testable import NowThis

@Suite("WatchPayload codec")
struct WatchPayloadCodecTests {
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

    @Test func snapshotRoundTripsThroughContextDictionary() throws {
        let original = sampleSnapshot()
        let dict = try original.contextDictionary()
        let decoded = WatchSnapshot(contextDictionary: dict)
        #expect(decoded == original)
    }

    @Test func snapshotRejectsNewerSchemaVersion() throws {
        var future = sampleSnapshot()
        future.schemaVersion = WatchSnapshot.currentSchemaVersion + 1
        let dict = try future.contextDictionary()
        #expect(WatchSnapshot(contextDictionary: dict) == nil)
    }

    @Test func snapshotReturnsNilForGarbage() {
        #expect(WatchSnapshot(contextDictionary: [:]) == nil)
        #expect(WatchSnapshot(contextDictionary: ["snapshot": Data([0xFF])]) == nil)
    }

    @Test func editRoundTripsAllCases() throws {
        let edits: [WatchEdit] = [.complete(uid: "u"), .uncomplete(uid: "u"),
                                  .add(rawText: "milk tomorrow 5pm", listID: nil,
                                       dueDate: nil, priorityRaw: nil),
                                  .add(rawText: "x", listID: "L1",
                                       dueDate: nil, priorityRaw: nil)]
        for edit in edits {
            let dict = try edit.userInfoDictionary()
            #expect(WatchEdit(userInfoDictionary: dict) == edit)
        }
    }

    @Test func dateOnlyFlagSurvivesRoundTrip() throws {
        let dict = try sampleSnapshot().contextDictionary()
        let decoded = try #require(WatchSnapshot(contextDictionary: dict))
        #expect(decoded.tasks[0].isDueDateOnly)
    }

    // MARK: - Explicit due date and priority (watch add screen)

    @Test func addCarriesDueDateAndPriority() throws {
        let due = Date(timeIntervalSince1970: 1_800_086_399)
        let edit = WatchEdit.add(rawText: "Buy milk", listID: "L1",
                                 dueDate: due, priorityRaw: TaskPriority.high.rawValue)
        let dict = try edit.userInfoDictionary()
        #expect(WatchEdit(userInfoDictionary: dict) == edit)
    }

    /// An older watch build sends `.add` with only `rawText` and `listID`. A phone
    /// carrying the new fields must still decode it, leaving them nil — otherwise
    /// updating the phone first silently breaks adds from a not-yet-updated watch.
    @Test func addFromAnOlderWatchDecodesWithTheNewFieldsNil() throws {
        let legacyJSON = Data(#"{"add":{"rawText":"Buy milk","listID":"L1"}}"#.utf8)
        let decoded = try #require(WatchEdit(userInfoDictionary: ["edit": legacyJSON]))
        guard case let .add(rawText, listID, dueDate, priorityRaw) = decoded else {
            Issue.record("expected .add, got \(decoded)"); return
        }
        #expect(rawText == "Buy milk")
        #expect(listID == "L1")
        #expect(dueDate == nil)
        #expect(priorityRaw == nil)
    }

    /// The mirror direction: a new watch talking to a phone that predates these
    /// fields. That decoder reads only `rawText` and `listID`, so both must still be
    /// present under those exact names — an old phone ignores what it does not know,
    /// but it cannot survive a key that moved or was renamed.
    @Test func addFromANewerWatchStillCarriesTheOriginalKeys() throws {
        let edit = WatchEdit.add(rawText: "Buy milk", listID: "L1",
                                 dueDate: Date(timeIntervalSince1970: 1_800_086_399),
                                 priorityRaw: TaskPriority.low.rawValue)
        let dict = try edit.userInfoDictionary()
        let data = try #require(dict["edit"] as? Data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let add = try #require(json?["add"] as? [String: Any])
        #expect(add["rawText"] as? String == "Buy milk")
        #expect(add["listID"] as? String == "L1")
    }

}
