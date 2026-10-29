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

    func userInfoDictionary() throws -> [String: Any] {
        [Self.userInfoKey: try JSONEncoder().encode(self)]
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
}
