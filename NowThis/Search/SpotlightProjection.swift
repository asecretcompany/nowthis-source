import Foundation
import CryptoKit

/// Immutable input captured from a context owner before Spotlight work suspends.
struct SpotlightTaskInput: Sendable {
    let id: String
    let title: String
    let contentDescription: String?
    let containerTitle: String?
    let keywords: [String]
    let priorityDescription: String?
    let dueDate: Date?
    let completionDate: Date?
    let isDeleted: Bool

    init(
        id: String,
        title: String,
        contentDescription: String? = nil,
        containerTitle: String? = nil,
        keywords: [String] = [],
        priorityDescription: String? = nil,
        dueDate: Date? = nil,
        completionDate: Date? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.contentDescription = contentDescription
        self.containerTitle = containerTitle
        self.keywords = keywords
        self.priorityDescription = priorityDescription
        self.dueDate = dueDate
        self.completionDate = completionDate
        self.isDeleted = isDeleted
    }
}

struct SpotlightTaskSnapshot: Sendable, Equatable, Identifiable, Codable {
    let id: String
    let title: String
    let contentDescription: String?
    let containerTitle: String?
    let keywords: [String]
    let priorityDescription: String?
    let dueDate: Date?
    let completionDate: Date?

    init(
        id: String,
        title: String,
        contentDescription: String? = nil,
        containerTitle: String? = nil,
        keywords: [String] = [],
        priorityDescription: String? = nil,
        dueDate: Date? = nil,
        completionDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.contentDescription = contentDescription
        self.containerTitle = containerTitle
        self.keywords = keywords
        self.priorityDescription = priorityDescription
        self.dueDate = dueDate
        self.completionDate = completionDate
    }
}

struct SpotlightIndexDelta: Sendable, Equatable {
    let changed: [SpotlightTaskSnapshot]
    let removedIDs: [String]
}

enum SpotlightProjection {
    static func fingerprint(_ snapshot: SpotlightTaskSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(snapshot))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func snapshot(from input: SpotlightTaskInput) -> SpotlightTaskSnapshot? {
        guard !input.isDeleted else { return nil }
        return SpotlightTaskSnapshot(
            id: input.id,
            title: input.title,
            contentDescription: input.contentDescription,
            containerTitle: input.containerTitle,
            keywords: input.keywords,
            priorityDescription: input.priorityDescription,
            dueDate: input.dueDate,
            completionDate: input.completionDate
        )
    }

    static func delta(
        current: [SpotlightTaskSnapshot],
        previous: [SpotlightTaskSnapshot]
    ) -> SpotlightIndexDelta {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let currentIDs = Set(current.map(\.id))
        let changed = current.filter { previousByID[$0.id] != $0 }
        let removedIDs = previousByID.keys.filter { !currentIDs.contains($0) }.sorted()
        return SpotlightIndexDelta(changed: changed, removedIDs: removedIDs)
    }

    static func batches<Element>(_ values: [Element], maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: values.count, by: maximumCount).map { start in
            Array(values[start..<min(start + maximumCount, values.count)])
        }
    }
}

struct SpotlightGenerationCoalescer<Value: Sendable>: Sendable {
    private(set) var latestGeneration = 0
    private var pending: (generation: Int, value: Value)?

    mutating func enqueue(_ value: Value) -> Int {
        latestGeneration += 1
        pending = (latestGeneration, value)
        return latestGeneration
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == latestGeneration
    }

    mutating func takePending() -> (generation: Int, value: Value)? {
        defer { pending = nil }
        return pending
    }
}
