import Foundation
import Testing
@testable import NowThis

@Suite("WatchOverlayState")
struct WatchOverlayStateTests {
    private func makeTask(uid: String, title: String = "Buy milk", isCompleted: Bool = false) -> WatchTask {
        WatchTask(id: "T-\(uid)", uid: uid, title: title, dueDate: nil,
                  isDueDateOnly: false, priorityRaw: 0, isCompleted: isCompleted,
                  listID: "L1", parentUID: nil)
    }

    private func makeSnapshot(tasks: [WatchTask], generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> WatchSnapshot {
        WatchSnapshot(schemaVersion: WatchSnapshot.currentSchemaVersion,
                      isProUnlocked: true,
                      generatedAt: generatedAt,
                      lists: [],
                      tasks: tasks,
                      truncated: false,
                      defaultListID: "L1")
    }

    @Test func pendingCompleteFlipsDisplayState() {
        var overlay = WatchOverlayState()
        overlay.noteComplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [makeTask(uid: "uid-1", isCompleted: false)])

        let displayed = overlay.displayTasks(from: snapshot)

        #expect(displayed.count == 1)
        #expect(displayed[0].isCompleted == true)
        #expect(displayed[0].uid == "uid-1")
    }

    @Test func reconcileClearsCompleteOnceSnapshotAgrees() {
        var overlay = WatchOverlayState()
        overlay.noteComplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [makeTask(uid: "uid-1", isCompleted: true)])

        overlay.reconcile(with: snapshot)

        #expect(overlay.pendingCompletes.isEmpty)
    }

    @Test func reconcileClearsCompleteWhenTaskDisappears() {
        var overlay = WatchOverlayState()
        overlay.noteComplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [])

        overlay.reconcile(with: snapshot)

        #expect(overlay.pendingCompletes.isEmpty)
    }

    @Test func pendingAddShowsAsSyntheticTask() {
        var overlay = WatchOverlayState()
        let add = WatchPendingAdd(id: UUID(), rawText: "Buy eggs tomorrow", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        overlay.noteAdd(add)
        let snapshot = makeSnapshot(tasks: [])

        let displayed = overlay.displayTasks(from: snapshot)

        #expect(displayed.count == 1)
        #expect(displayed[0].uid == "pending-\(add.id)")
        #expect(displayed[0].id == "pending-\(add.id)")
        #expect(displayed[0].title == "Buy eggs tomorrow")
        #expect(displayed[0].listID == "")
        #expect(displayed[0].isCompleted == false)
    }

    @Test func reconcileClearsStaleAdds() {
        var overlay = WatchOverlayState()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let add = WatchPendingAdd(id: UUID(), rawText: "Buy eggs tomorrow", createdAt: createdAt)
        overlay.noteAdd(add)
        // Snapshot generated well after createdAt + 5s grace, and with no matching title.
        let staleSnapshot = makeSnapshot(tasks: [], generatedAt: createdAt.addingTimeInterval(10))

        overlay.reconcile(with: staleSnapshot)

        #expect(overlay.pendingAdds.isEmpty)
    }

    @Test func confirmAddClearsExactlyThePendingAddById() {
        var overlay = WatchOverlayState()
        // Two pending adds sharing identical dictated text. The phone stores the
        // natural-language-parsed title ("buy milk tomorrow at 5pm" → "Buy milk"),
        // so a text match would never fire AND would collapse both — only the
        // WatchPendingAdd.id distinguishes them.
        let first = WatchPendingAdd(id: UUID(), rawText: "buy milk tomorrow at 5pm", createdAt: Date())
        let second = WatchPendingAdd(id: UUID(), rawText: "buy milk tomorrow at 5pm", createdAt: Date())
        overlay.noteAdd(first)
        overlay.noteAdd(second)

        overlay.confirmAdd(id: first.id)

        // Only the acknowledged add is cleared; its same-text sibling is preserved.
        #expect(overlay.pendingAdds.map(\.id) == [second.id])
    }

    @Test func pendingUncompleteFlipsDisplayState() {
        var overlay = WatchOverlayState()
        overlay.noteUncomplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [makeTask(uid: "uid-1", isCompleted: true)])

        let displayed = overlay.displayTasks(from: snapshot)

        #expect(displayed.count == 1)
        #expect(displayed[0].isCompleted == false)
        #expect(displayed[0].uid == "uid-1")
    }

    @Test func noteCompleteAndUncompleteClearEachOther() {
        var overlay = WatchOverlayState()

        overlay.noteComplete(uid: "uid-1")
        #expect(overlay.pendingCompletes == ["uid-1"])
        #expect(overlay.pendingUncompletes.isEmpty)

        // noteUncomplete must drop the uid out of pendingCompletes…
        overlay.noteUncomplete(uid: "uid-1")
        #expect(overlay.pendingUncompletes == ["uid-1"])
        #expect(overlay.pendingCompletes.isEmpty)

        // …and noteComplete must drop it back out of pendingUncompletes.
        overlay.noteComplete(uid: "uid-1")
        #expect(overlay.pendingCompletes == ["uid-1"])
        #expect(overlay.pendingUncompletes.isEmpty)
    }

    @Test func reconcileClearsUncompleteOnceSnapshotAgrees() {
        var overlay = WatchOverlayState()
        overlay.noteUncomplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [makeTask(uid: "uid-1", isCompleted: false)])

        overlay.reconcile(with: snapshot)

        #expect(overlay.pendingUncompletes.isEmpty)
    }

    @Test func reconcileClearsUncompleteWhenTaskDisappears() {
        var overlay = WatchOverlayState()
        overlay.noteUncomplete(uid: "uid-1")
        let snapshot = makeSnapshot(tasks: [])

        overlay.reconcile(with: snapshot)

        #expect(overlay.pendingUncompletes.isEmpty)
    }
}
