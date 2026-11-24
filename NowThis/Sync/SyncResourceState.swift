import Foundation
import SwiftData
import CryptoKit

/// Resource evidence is independent of a task's opaque fields and photo ownership.
/// A receipt permits pull progress; only exact, current single-task proof permits writes.
struct SyncResourceState: Codable, Sendable, Equatable {
    static let prefix = "resource-shape-v1:"
    static let movePrefix = "resource-move-v1:"
    static let cleanupPrefix = "resource-cleanup-v1:"
    enum CaptureKind: Sendable { case moveSource, currentResource }
    static func captureKey(taskID: String, kind: CaptureKind) -> String {
        (kind == .moveSource ? movePrefix : cleanupPrefix) + taskID
    }
    var version = 1
    let scope: TaskPhotoOwnership.Scope
    let href: String
    let etag: String
    let shape: Shape
    let originalBody: String?
    /// Only an empty-ETag acknowledgement needs this recovery constraint.
    var expectedBodyDigest: String? = nil
    var uid: String? = nil
    struct Baseline: Codable, Sendable, Equatable {
        let taskID: String
        let uid: String
        let etag: String
    }
    /// One proof per active local baseline, carried only while that row still owes it.
    var baselines: [Baseline]? = nil
    static func fingerprint(_ body: String) -> String {
        SHA256.hash(data: unfoldedUTF8(body)).map { String(format: "%02x", $0) }.joined()
    }

    static func unfoldedUTF8(_ body: String) -> Data {
        let input = Array(body.utf8)
        var output: [UInt8] = []; output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 13 || byte == 10 {
                index += 1
                if byte == 13, index < input.count, input[index] == 10 { index += 1 }
                if index < input.count, input[index] == 32 || input[index] == 9 { index += 1 }
                else { output.append(10) }
            } else { output.append(byte); index += 1 }
        }
        return Data(output)
    }
    enum Shape: String, Codable, Sendable { case singleTask, unsupported, nonTask }
    enum Hold: Error, LocalizedError {
        case needsRevalidation, unsupported
        var errorDescription: String? {
            switch self {
            case .needsRevalidation:
                String(localized: "Sync this task before trying again. Its server content needs to be checked.")
            case .unsupported:
                String(localized: "This task contains server content that NowThis cannot safely change. Your changes are kept on this device.")
            }
        }
    }
    static func canonical(_ href: String, scope: TaskPhotoOwnership.Scope) throws -> String {
        try DAVCollectionScope(baseURL: scope.serverBaseURL, calendarPath: scope.collectionPath).href(href)
    }
    static func key(scope: TaskPhotoOwnership.Scope, href: String) throws -> String {
        try key(scope: scope, canonicalHref: canonical(href, scope: scope))
    }
    private static func key(scope: TaskPhotoOwnership.Scope, canonicalHref: String) throws -> String {
        let values = [scope.accountID, scope.listID, scope.serverBaseURL, scope.username,
                      scope.collectionPath, canonicalHref]
        return prefix + SHA256.hash(data: try JSONEncoder().encode(values)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(key: String, in context: ModelContext) throws -> Self? {
        guard let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first else { return nil }
        guard let state = decode(row) else { return nil }
        if key.hasPrefix(prefix), (try? Self.key(scope: state.scope, href: state.href)) != key { return nil }
        return state
    }
    private static func decode(_ row: SyncMetadata) -> Self? {
        guard row.collectionPath.isEmpty, let json = row.syncToken,
              let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == 1, (try? canonical(state.href, scope: state.scope)) == state.href,
              state.shape == .unsupported || state.originalBody == nil else { return nil }
        return state
    }
    static func read(scope: TaskPhotoOwnership.Scope, href: String, in context: ModelContext) throws -> Self? {
        let state = try read(key: key(scope: scope, href: href), in: context)
        return try state?.scope == scope && state?.href == canonical(href, scope: scope) ? state : nil
    }
    func store(in context: ModelContext, key override: String? = nil) throws {
        try prepareStore(in: context, key: override)()
    }
    func prepareStore(in context: ModelContext, key override: String? = nil) throws -> () -> Void {
        let key = try override ?? Self.key(scope: scope, href: href)
        let json = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first
            ?? SyncMetadata(id: key, collectionPath: "")
        return {
            if row.modelContext == nil { context.insert(row) }
            row.syncToken = json
        }
    }
    static func observe(_ resource: ParsedRemoteTask, scope: TaskPhotoOwnership.Scope, in context: ModelContext) throws {
        guard resource.shape != nil else { return }
        try observe([resource], scope: scope, in: context)
    }
    /// Work is bounded by the inbound transaction; no body history is retained.
    static func observe(_ resources: [ParsedRemoteTask], scope: TaskPhotoOwnership.Scope, in context: ModelContext) throws {
        let listID = scope.listID
        let uids = resources.compactMap { $0.todo?.uid }
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.taskList?.id == listID && uids.contains($0.uid)
        }))
        let keys = try resources.map { try key(scope: scope, href: $0.href) }
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { keys.contains($0.id) }))
        var byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for resource in resources {
            guard let shape = resource.shape else { continue }
            let href = try canonical(resource.href, scope: scope)
            let key = try key(scope: scope, href: href)
            let previous = byID[key].flatMap { decode($0) }.flatMap {
                $0.scope == scope && $0.href == href ? $0 : nil
            }
            var state = Self(scope: scope, href: href, etag: resource.etag, shape: shape,
                originalBody: shape == .unsupported ? resource.originalBody : nil, uid: resource.todo?.uid)
            if shape == .singleTask, let previous, previous.shape == .singleTask, previous.uid == state.uid {
                state.baselines = tasks.compactMap { task in
                    guard task.isDirty || task.isDeletedLocally,
                          task.uid == state.uid, let etag = task.etag, !etag.isEmpty,
                          (try? canonical(task.remoteHref ?? "", scope: scope)) == href,
                          previous.etag == etag || previous.baselines?.contains(where: {
                              $0.taskID == task.id && $0.uid == task.uid && $0.etag == etag
                          }) == true else { return nil }
                    return Baseline(taskID: task.id, uid: task.uid, etag: etag)
                }
            }
            let row = byID[key] ?? SyncMetadata(id: key, collectionPath: "")
            if row.modelContext == nil { context.insert(row) }
            row.syncToken = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            byID[key] = row
        }
    }
    func sameObservation(as other: Self) -> Bool {
        var first = self; var second = other
        first.baselines = nil; second.baselines = nil
        return first == second
    }
    func requireSupported(etag expected: String? = nil) throws {
        guard shape == .singleTask else { throw Hold.unsupported }
        guard !etag.isEmpty, expected == nil || expected == etag else { throw Hold.needsRevalidation }
    }
    static func proof(list: TaskList?, href: String, etag: String?, taskID: String, uid: String,
                      allowRetainedRevision: Bool = true, in context: ModelContext) throws -> Self {
        guard let scope = TaskPhotoOwnership.Scope(list: list), let etag, !etag.isEmpty,
              let record = try read(scope: scope, href: href, in: context) else { throw Hold.needsRevalidation }
        try record.requireSupported()
        guard record.uid == uid else { throw Hold.unsupported }
        let known = record.etag == etag || (allowRetainedRevision && record.baselines?.contains(where: {
            $0.taskID == taskID && $0.uid == uid && $0.etag == etag
        }) == true)
        if !known {
            guard allowRetainedRevision,
                  let captured = try capture(taskID: taskID, scope: scope, href: href, kind: .currentResource, in: context),
                  captured.etag == etag, captured.uid == uid, captured.shape == .singleTask else { throw Hold.needsRevalidation }
        }
        return Self(scope: scope, href: record.href, etag: etag, shape: .singleTask, originalBody: nil, uid: uid)
    }
    static func capture(taskID: String, scope: TaskPhotoOwnership.Scope, href: String,
                        kind: CaptureKind = .moveSource, in context: ModelContext) throws -> Self? {
        let key = captureKey(taskID: taskID, kind: kind)
        guard try context.fetchCount(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })) > 0 else { return nil }
        guard let captured = try read(key: key, in: context), captured.scope == scope,
              captured.href == (try canonical(href, scope: scope)) else { throw Hold.needsRevalidation }
        return captured
    }
    static func releaseBaseline(taskID: String, scope: TaskPhotoOwnership.Scope, href: String,
                                in context: ModelContext) throws {
        try prepareReleaseBaseline(taskID: taskID, scope: scope, href: href, in: context)()
    }
    private static func prepareReleaseBaseline(taskID: String, scope: TaskPhotoOwnership.Scope, href: String,
                                                in context: ModelContext) throws -> () -> Void {
        guard var state = try read(scope: scope, href: href, in: context),
              state.baselines?.contains(where: { $0.taskID == taskID }) == true else { return {} }
        state.baselines?.removeAll { $0.taskID == taskID }
        if state.baselines?.isEmpty == true { state.baselines = nil }
        return try state.prepareStore(in: context)
    }
    static func prepareRemoveCapture(taskID: String, kind: CaptureKind = .moveSource,
                                     in context: ModelContext) throws -> () -> Void {
        let key = captureKey(taskID: taskID, kind: kind)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key }))
        let release: () -> Void
        if let row = rows.first, let state = decode(row) {
            release = try prepareReleaseBaseline(taskID: taskID, scope: state.scope, href: state.href, in: context)
        } else { release = {} }
        return { release(); for row in rows { context.delete(row) } }
    }
    static func removeCapture(taskID: String, kind: CaptureKind = .moveSource, in context: ModelContext) throws {
        try prepareRemoveCapture(taskID: taskID, kind: kind, in: context)()
    }
    static func sourceProof(_ task: TaskItem, requireCurrent: Bool = false, in context: ModelContext) throws -> Self? {
        guard let href = task.pendingMoveFromHref, let listID = task.pendingMoveFromListID else { return nil }
        guard let list = try context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
              let scope = TaskPhotoOwnership.Scope(list: list),
              let captured = try capture(taskID: task.id, scope: scope, href: href, in: context),
              let latest = try read(scope: scope, href: href, in: context) else { throw Hold.needsRevalidation }
        try latest.requireSupported()
        guard latest.uid == task.uid, captured.uid == task.uid else { throw Hold.unsupported }
        try captured.requireSupported()
        guard !requireCurrent || latest.etag == captured.etag else { throw Hold.needsRevalidation }
        return captured
    }
    static func requireWritable(_ task: TaskItem, allowRetainedRevision: Bool = true, in context: ModelContext) throws {
        _ = try sourceProof(task, requireCurrent: !allowRetainedRevision, in: context)
        if let href = task.remoteHref, !href.isEmpty {
            _ = try proof(list: task.taskList, href: href, etag: task.etag, taskID: task.id, uid: task.uid, allowRetainedRevision: allowRetainedRevision, in: context)
        }
    }
    static func pendingKeys(_ task: TaskItem, in context: ModelContext) -> Set<String> {
        var keys: Set<String> = [movePrefix + task.id, cleanupPrefix + task.id]
        if let href = task.remoteHref, let scope = TaskPhotoOwnership.Scope(list: task.taskList),
           let key = try? key(scope: scope, href: href) { keys.insert(key) }
        if let href = task.pendingMoveFromHref, let listID = task.pendingMoveFromListID,
           let list = try? context.fetch(FetchDescriptor<TaskList>(predicate: #Predicate { $0.id == listID })).first,
           let scope = TaskPhotoOwnership.Scope(list: list), let key = try? key(scope: scope, href: href) { keys.insert(key) }
        return keys
    }
    static func needsClassification(list: TaskList, in context: ModelContext,
                                    makeReadContext: (ModelContainer) -> ModelContext = { ModelContext($0) }) throws -> Set<String> {
        try scanForClassification(list: list, in: context, makeReadContext: makeReadContext).needsClassification
    }

    struct ClassificationScan {
        var needsClassification: Set<String> = []
        var aliases: [String: Set<String>] = [:]
        var hasLocalTasks = false
    }

    static func scanForClassification(list: TaskList, in context: ModelContext,
                                      makeReadContext: (ModelContainer) -> ModelContext = { ModelContext($0) }) throws -> ClassificationScan {
        let id = list.id
        let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id }))
        PerformanceTrace.record(.shapeTasks, rows: tasks.count)
        var result = ClassificationScan(hasLocalTasks: !tasks.isEmpty)
        guard let scope = TaskPhotoOwnership.Scope(list: list) else { return result }
        let members = try tasks.compactMap { task -> (task: TaskItem, href: String, key: String)? in
            guard let raw = task.remoteHref, !raw.isEmpty else { return nil }
            let href = try canonical(raw, scope: scope)
            if raw != href { result.aliases[href, default: []].insert(raw) }
            return (task, raw, try key(scope: scope, canonicalHref: href))
        }
        let keys = members.map(\.key)
        var records: [String: (shape: Shape, etag: String, uid: String?, baselines: [Baseline])] = [:]
        for start in stride(from: 0, to: keys.count, by: 100) {
            let batch = Array(keys[start..<min(start + 100, keys.count)])
            let batchContext = makeReadContext(context.container)
            let rows = try batchContext.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { batch.contains($0.id) }))
            PerformanceTrace.record(.genericShapeRecords, rows: rows.count, keys: batch.count)
            for row in rows { if let state = decode(row), state.scope == scope, (try? key(scope: scope, href: state.href)) == row.id { records[row.id] = (state.shape, state.etag, state.uid, state.baselines ?? []) } }
        }
        var captureCandidates: [(taskID: String, uid: String, etag: String?, href: String)] = []
        for (task, href, key) in members {
            guard let record = records[key] else { result.needsClassification.insert(href); continue }
            // Exact revisions and already classified unsupported bodies need no
            // operation-capture lookup, however large the offline edit backlog.
            if record.shape == .unsupported || (!record.etag.isEmpty && record.etag == task.etag) { continue }
            if record.shape == .singleTask, !record.etag.isEmpty,
               record.uid == task.uid, task.isDirty || task.isDeletedLocally {
                if record.baselines.contains(where: { $0.taskID == task.id && $0.uid == task.uid && $0.etag == task.etag }) { continue }
                captureCandidates.append((task.id, task.uid, task.etag, href))
            } else { result.needsClassification.insert(href) }
        }
        // Only genuine mismatches can need a retained current-resource capture.
        // Read those keys in bounded batches, without per-task contexts/counts.
        for start in stride(from: 0, to: captureCandidates.count, by: 100) {
            let candidates = Array(captureCandidates[start..<min(start + 100, captureCandidates.count)])
            let keys = candidates.map { captureKey(taskID: $0.taskID, kind: .currentResource) }
            let batchContext = makeReadContext(context.container)
            let rows = try batchContext.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { keys.contains($0.id) }))
            PerformanceTrace.record(.retainedShapeCaptures, rows: rows.count, keys: keys.count)
            let captures = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for candidate in candidates {
                let captured = captures[captureKey(taskID: candidate.taskID, kind: .currentResource)].flatMap { decode($0) }
                // This is scheduling evidence for the existing conditional E1
                // obligation, never authority to move or create a destination.
                let retained = captured.map {
                    $0.scope == scope && $0.href == (try? canonical(candidate.href, scope: scope))
                        && $0.shape == .singleTask && $0.uid == candidate.uid
                        && !$0.etag.isEmpty && $0.etag == candidate.etag
                } ?? false
                if !retained { result.needsClassification.insert(candidate.href) }
            }
        }
        return result
    }
}
