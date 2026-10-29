import Foundation

struct WatchPendingAdd: Codable, Equatable, Identifiable {
    let id: UUID
    let rawText: String
    let createdAt: Date
}

/// Optimistic UI overlays applied on top of the last received WatchSnapshot.
/// Pure value type — fully unit-tested; the watch UI renders
/// `overlay.displayTasks(from: snapshot)` and never mutates the snapshot.
struct WatchOverlayState: Codable, Equatable {
    var pendingCompletes: Set<String> = []
    var pendingUncompletes: Set<String> = []
    var pendingAdds: [WatchPendingAdd] = []
    private static let addGrace: TimeInterval = 5

    mutating func noteComplete(uid: String) { pendingUncompletes.remove(uid); pendingCompletes.insert(uid) }
    mutating func noteUncomplete(uid: String) { pendingCompletes.remove(uid); pendingUncompletes.insert(uid) }
    mutating func noteAdd(_ add: WatchPendingAdd) { pendingAdds.append(add) }

    /// Clears the optimistic pending add the phone has acknowledged as `.applied`.
    /// Matched by `WatchPendingAdd.id` — never by `rawText`, because the phone
    /// stores the natural-language-parsed title ("buy milk tomorrow at 5pm" becomes
    /// "Buy milk"), so a text match would never fire for a dictated add and would
    /// collapse two distinct adds that happen to share the same text. Without this,
    /// `reconcile`'s title-equality path can't clear a voice add and the synthetic
    /// row lingers until the 5s grace (unbounded until the next inbound snapshot).
    mutating func confirmAdd(id: UUID) { pendingAdds.removeAll { $0.id == id } }

    mutating func reconcile(with snapshot: WatchSnapshot) {
        let byUID = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.uid, $0) })
        pendingCompletes = pendingCompletes.filter { uid in
            guard let task = byUID[uid] else { return false }
            return !task.isCompleted
        }
        pendingUncompletes = pendingUncompletes.filter { uid in
            guard let task = byUID[uid] else { return false }
            return task.isCompleted
        }
        let titles = Set(snapshot.tasks.map(\.title))
        pendingAdds.removeAll { add in
            snapshot.generatedAt > add.createdAt.addingTimeInterval(Self.addGrace) || titles.contains(add.rawText)
        }
    }

    func displayTasks(from snapshot: WatchSnapshot) -> [WatchTask] {
        var tasks = snapshot.tasks.map { task -> WatchTask in
            if pendingCompletes.contains(task.uid) {
                return WatchTask(id: task.id, uid: task.uid, title: task.title, dueDate: task.dueDate,
                                 isDueDateOnly: task.isDueDateOnly, priorityRaw: task.priorityRaw,
                                 isCompleted: true, listID: task.listID, parentUID: task.parentUID)
            }
            if pendingUncompletes.contains(task.uid) {
                return WatchTask(id: task.id, uid: task.uid, title: task.title, dueDate: task.dueDate,
                                 isDueDateOnly: task.isDueDateOnly, priorityRaw: task.priorityRaw,
                                 isCompleted: false, listID: task.listID, parentUID: task.parentUID)
            }
            return task
        }
        tasks.append(contentsOf: pendingAdds.map { add in
            WatchTask(id: "pending-\(add.id)", uid: "pending-\(add.id)", title: add.rawText,
                      dueDate: nil, isDueDateOnly: false, priorityRaw: 0,
                      isCompleted: false, listID: "", parentUID: nil)
        })
        return tasks
    }
}
