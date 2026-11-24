import Foundation

enum TaskDetailSection: String, CaseIterable, Identifiable {
    case title, status, dates, details, tags, notes, photos, subtasks, linkedJournals

    static let storageKey = "taskDetailSectionOrder"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .title: "Title"
        case .status: "Status"
        case .dates: "Dates"
        case .details: "Details"
        case .tags: "Tags"
        case .notes: "Notes"
        case .photos: "Photos"
        case .subtasks: "Subtasks"
        case .linkedJournals: "Linked Journals"
        }
    }

    static func decodeOrder(from stored: String) -> [Self] {
        guard let tokens = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)) else {
            return allCases
        }
        var seen = Set<Self>()
        let ordered = tokens.compactMap(Self.init(rawValue:)).filter { seen.insert($0).inserted }
        return ordered + allCases.filter { !seen.contains($0) }
    }

    static func encodeOrder(_ order: [Self]) -> String {
        guard let data = try? JSONEncoder().encode(order.map(\.rawValue)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
