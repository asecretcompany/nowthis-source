import Foundation
import SwiftData
@testable import NowThis

/// Existing move/photo/race fixtures describe already imported single-task resources.
/// Seed the independent import evidence explicitly; an opaque sidecar is not evidence.
enum SyncResourceFixture {
    static func prove(_ task: TaskItem, in context: ModelContext) throws {
        if let href = task.remoteHref, !href.isEmpty, let etag = task.etag, !etag.isEmpty,
           let scope = TaskPhotoOwnership.Scope(list: task.taskList) {
            try SyncResourceState(scope: scope, href: SyncResourceState.canonical(href, scope: scope),
                etag: etag, shape: .singleTask, originalBody: nil, uid: task.uid).store(in: context)
        }
    }
    static func proveSource(_ task: TaskItem, etag: String = "source-etag", in context: ModelContext) throws {
        guard let href = task.pendingMoveFromHref, let id = task.pendingMoveFromListID,
              let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == id })).first,
              let scope = TaskPhotoOwnership.Scope(list: list) else { return }
        let state = try SyncResourceState(scope: scope, href: SyncResourceState.canonical(href, scope: scope),
            etag: etag, shape: .singleTask, originalBody: nil, uid: task.uid)
        try state.store(in: context)
        try state.store(in: context, key: SyncResourceState.movePrefix + task.id)
    }
}
