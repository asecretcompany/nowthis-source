import Foundation

/// Value types shared between the iOS app, the watch app, and the watch widget.
/// Foundation-only: these files compile for iOS and watchOS.
struct WatchListMeta: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let colorHex: String
    let activeTaskCount: Int
}

struct WatchTask: Codable, Identifiable, Equatable {
    let id: String
    let uid: String
    let title: String
    let dueDate: Date?
    let isDueDateOnly: Bool
    let priorityRaw: Int
    let isCompleted: Bool
    let listID: String
    let parentUID: String?
}

struct WatchSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1
    private static let contextKey = "snapshot"

    var schemaVersion: Int
    let isProUnlocked: Bool
    let generatedAt: Date
    let lists: [WatchListMeta]
    let tasks: [WatchTask]
    let truncated: Bool
    let defaultListID: String?
    var proAccessValidUntil: Date? = nil
    var testerProOverride: Bool? = nil
    var receipts: [WatchOperationReceipt]? = nil

    func canEditTasks(at now: Date) -> Bool {
        testerProOverride == true || (isProUnlocked && (proAccessValidUntil.map { now < $0 } ?? true))
    }

    /// Wraps the JSON-encoded snapshot for `WCSession.updateApplicationContext`.
    func contextDictionary() throws -> [String: Any] {
        [Self.contextKey: try JSONEncoder().encode(self)]
    }
}

extension WatchSnapshot {
    // Declared in an extension (not the primary struct body) so the compiler-synthesized
    // memberwise initializer is preserved alongside this failable one.

    /// Fails (nil) on missing key, corrupt data, or a schema major newer than this build understands.
    init?(contextDictionary: [String: Any]) {
        guard let data = contextDictionary[Self.contextKey] as? Data,
              let decoded = try? JSONDecoder().decode(WatchSnapshot.self, from: data),
              decoded.schemaVersion <= Self.currentSchemaVersion else { return nil }
        self = decoded
    }
}

enum WatchEdit: Codable, Equatable {
    case complete(uid: String)
    case uncomplete(uid: String)
    /// `dueDate` and `priorityRaw` come from the watch's add screen and are both
    /// optional — that is what keeps the two builds compatible in each direction.
    /// Swift synthesises `decodeIfPresent` for optional associated values, so an
    /// older watch's payload decodes here with nils, and a newer watch's extra keys
    /// are ignored by a phone that predates them. `WatchPayloadCodecTests` pins both.
    ///
    /// The date is resolved on the watch rather than sent as a preset: an edit can sit
    /// queued in `transferUserInfo` for hours, and "Tomorrow" has to keep meaning the
    /// day the user tapped it, not the day the phone got round to applying it.
    case add(rawText: String, listID: String?, dueDate: Date?, priorityRaw: Int?)

    private static let userInfoKey = "edit"
    static let operationIDKey = "operationID"
    static let receiptQueryKey = "receiptQuery"
    static let receiptReplyKey = "receipts"

    var hasValidRawText: Bool {
        guard case .add(let rawText, _, _, _) = self else { return true }
        return rawText.utf8.count <= 16_000 && rawText.count <= 2_000
    }

    enum ValidationError: Error { case rawTextTooLong }


    func userInfoDictionary(operationID: UUID? = nil) throws -> [String: Any] {
        guard hasValidRawText else { throw ValidationError.rawTextTooLong }
        var payload: [String: Any] = [Self.userInfoKey: try JSONEncoder().encode(self)]
        if let operationID { payload[Self.operationIDKey] = operationID.uuidString }
        return payload
    }

    init?(userInfoDictionary: [String: Any]) {
        guard let data = userInfoDictionary[Self.userInfoKey] as? Data,
              let decoded = try? JSONDecoder().decode(WatchEdit.self, from: data) else { return nil }
        self = decoded
    }
}

/// Reply vocabulary for `sendMessage` acknowledgements (phone → watch).
enum WatchEditReply {
    static let key = "result"
    static let applied = "applied"
    static let locked = "locked"
    static let unknownTask = "unknownTask"
    static let invalid = "invalid"
    static let refusalReasonKey = "refusalReason"
    static let unconfirmed = "unconfirmed"
    static let unsupportedRecurrence = "unsupportedRecurrence"
    // Optional application-context fields also report rejected queued edits to older transports.
    static let completionFailureIDKey = "completionFailureID"
    static let completionFailureUIDKey = "completionFailureUID"
}

/// Optional additive protocol fields: older peers ignore IDs/receipts and keep legacy reconciliation.
struct WatchOperationReceipt: Codable, Equatable, Sendable {
    let id: UUID
    let result: String
    let refusalReason: String?

    init(id: UUID, result: String, refusalReason: String? = nil) {
        self.id = id
        self.result = result
        self.refusalReason = refusalReason
    }
}

enum WatchEditRefusalReason: String, Sendable {
    case readOnlyList
}

struct WatchPendingOperation: Codable, Equatable, Identifiable {
    let id: UUID
    let edit: WatchEdit
    let createdAt: Date
}
