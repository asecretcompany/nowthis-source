import Foundation
import SwiftData

/// Durable raw VTODO data without adding attributes to the shipping model schema.
struct VTODOOpaqueState: Codable, Sendable, Equatable {
    var version = 1
    var opaqueProperties: [String] = []
    var alarmBlocks: [[String]] = []
    var baselineReminderOffset: Int?
    /// An older client landed a stripped destination; retain the source until a
    /// matching recovered payload is accepted. Optional for existing V1 rows.
    var destinationRepairPending: Bool?

    static let empty = VTODOOpaqueState()
    static let prefix = "vtodo-opaque-v1:"
    enum StateError: Error { case malformed, unsupportedVersion, missingRemoteState }

    init() {}
    init(_ data: ICalendarParser.VTODOData) throws {
        opaqueProperties = data.opaqueProperties
        alarmBlocks = data.alarmBlocks
        baselineReminderOffset = data.alarmTriggerSeconds
        try validate()
    }

    /// Only unknown, single content lines may be replayed outside alarm components.
    static func safeProperty(_ line: String) -> Bool {
        guard safeContentLine(line) else { return false }
        let name = ICalendarParser.splitProperty(line).name
        if name == "RELATED-TO" { return !isParentRelationship(line) }
        return !owned.contains(name) && name != "BEGIN" && name != "END"
    }

    static func isParentRelationship(_ line: String) -> Bool {
        // Only parameters before the value count; parameter names and values are case insensitive.
        var quoted = false
        var parameters: [String] = []
        var current = ""
        for character in line {
            if character == "\"" { quoted.toggle() }
            if !quoted && character == ":" { break }
            if !quoted && character == ";" { parameters.append(current); current = "" }
            else { current.append(character) }
        }
        parameters.append(current)
        let relation = parameters.dropFirst().first {
            $0.uppercased().hasPrefix("RELTYPE=")
        }?.dropFirst("RELTYPE=".count)
        return relation == nil || relation?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).uppercased() == "PARENT"
    }

    private static let owned: Set<String> = ["UID", "DTSTAMP", "SUMMARY", "DESCRIPTION", "STATUS",
        "PRIORITY", "PERCENT-COMPLETE", "DUE", "DTSTART", "COMPLETED", "CREATED", "LAST-MODIFIED",
        "CATEGORIES", "LOCATION", "GEO", "URL", "RRULE", "X-APPLE-SORT-ORDER", "ATTACH"]

    private static func safeContentLine(_ line: String) -> Bool {
        guard !line.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) }) else { return false }
        let name = ICalendarParser.splitProperty(line).name
        return !name.isEmpty && name.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    static func safeAlarm(_ block: [String]) -> Bool {
        block.count >= 2 && block.first == "BEGIN:VALARM" && block.last == "END:VALARM"
            && block.dropFirst().dropLast().allSatisfy {
                safeContentLine($0) && !["BEGIN", "END"].contains(ICalendarParser.splitProperty($0).name)
            }
    }

    func validate() throws {
        guard version == 1 else { throw StateError.unsupportedVersion }
        guard opaqueProperties.allSatisfy(Self.safeProperty), alarmBlocks.allSatisfy(Self.safeAlarm) else {
            throw StateError.malformed
        }
    }

    private struct VersionEnvelope: Decodable { let version: Int }

    static func load(taskID: String, in context: ModelContext) throws -> Self? {
        let id = prefix + taskID
        guard let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id })).first else { return nil }
        return try decode(row)
    }

    private static func decode(_ row: SyncMetadata) throws -> Self {
        guard row.collectionPath.isEmpty, let json = row.syncToken, let bytes = json.data(using: .utf8) else { throw StateError.malformed }
        let decoder = JSONDecoder()
        let envelope: VersionEnvelope
        do { envelope = try decoder.decode(VersionEnvelope.self, from: bytes) }
        catch { throw StateError.malformed }
        guard envelope.version == 1 else { throw StateError.unsupportedVersion }
        let state: Self
        do { state = try decoder.decode(Self.self, from: bytes) }
        catch { throw StateError.malformed }
        try state.validate()
        return state
    }
    static func outbound(for task: TaskItem, in context: ModelContext) throws -> Self {
        if let state = try load(taskID: task.id, in: context) { return state }
        guard task.isLocalOnly, task.remoteHref?.isEmpty != false && task.pendingMoveFromHref == nil else { throw StateError.missingRemoteState }
        return .empty
    }

    func store(taskID: String, in context: ModelContext) throws {
        try validate()
        let json = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        let id = Self.prefix + taskID
        let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == id })).first
            ?? SyncMetadata(id: id, collectionPath: "")
        if row.modelContext == nil { context.insert(row) }
        row.syncToken = json
    }

    /// One fresh, non-suspending import transaction. No row or decoded value escapes it.
    final class Batch {
        private let context: ModelContext
        private var rows: [String: SyncMetadata]
        private var decoded: [String: VTODOOpaqueState] = [:]
        let fetchCount: Int

        init(taskIDs: [String], in context: ModelContext) throws {
            self.context = context
            let keys = taskIDs.map { VTODOOpaqueState.prefix + $0 }
            let found = keys.isEmpty ? [] : try context.fetch(FetchDescriptor<SyncMetadata>(
                predicate: #Predicate { keys.contains($0.id) }))
            rows = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            fetchCount = keys.isEmpty ? 0 : 1
        }

        func load(taskID: String) throws -> VTODOOpaqueState? {
            let key = VTODOOpaqueState.prefix + taskID
            if let state = decoded[key] { return state }
            guard let row = rows[key] else { return nil }
            let state = try VTODOOpaqueState.decode(row)
            decoded[key] = state
            return state
        }

        func store(_ state: VTODOOpaqueState, taskID: String) throws {
            try state.validate()
            let key = VTODOOpaqueState.prefix + taskID
            let row = rows[key] ?? SyncMetadata(id: key, collectionPath: "")
            if row.modelContext == nil { context.insert(row) }
            row.syncToken = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            rows[key] = row
            decoded[key] = state
        }
    }

    /// Resolve all rows before deleting any, so a failed read cannot leave partial cleanup.
    static func remove(tasks: [TaskItem], in context: ModelContext) throws {
        var pending = tasks
        var ids = Set<String>()
        while let task = pending.popLast() {
            if ids.insert(prefix + task.id).inserted { pending.append(contentsOf: task.subtasks) }
        }
        let keys = Array(ids)
        let rows = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { keys.contains($0.id) }))
        for row in rows { context.delete(row) }
    }
}
