import Foundation
import SwiftData

/// Shared batched lookup for Siri entities and widget list configuration.
enum EntityQueryLookup {
    static func taskDescriptor(for identifiers: [String]) -> FetchDescriptor<TaskItem> {
        FetchDescriptor<TaskItem>(predicate: #Predicate { task in
            identifiers.contains(task.id) && !task.isDeletedLocally
        })
    }

    static func listDescriptor(for identifiers: [String]) -> FetchDescriptor<TaskList> {
        FetchDescriptor<TaskList>(predicate: #Predicate { list in
            identifiers.contains(list.id)
        })
    }

    static func listSuggestionsDescriptor() -> FetchDescriptor<TaskList> {
        var descriptor = FetchDescriptor<TaskList>(sortBy: [
            SortDescriptor(\TaskList.name),
            SortDescriptor(\TaskList.id)
        ])
        descriptor.fetchLimit = 50
        return descriptor
    }

    @MainActor
    static func tasks(for identifiers: [String], in context: ModelContext) throws -> [TaskItem] {
        guard !identifiers.isEmpty else { return [] }
        let tasks = try context.fetch(taskDescriptor(for: identifiers))
        return inRequestedOrder(tasks, identifiers: identifiers, id: \.id)
    }

    @MainActor
    static func lists(for identifiers: [String], in context: ModelContext) throws -> [TaskList] {
        guard !identifiers.isEmpty else { return [] }
        let lists = try context.fetch(listDescriptor(for: identifiers))
        return inRequestedOrder(lists, identifiers: identifiers, id: \.id)
    }

    /// Resolve each identity once, in its first requested position; missing IDs are omitted.
    private static func inRequestedOrder<Model>(
        _ models: [Model], identifiers: [String], id: KeyPath<Model, String>
    ) -> [Model] {
        let byID = Dictionary(models.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else { return nil }
            return byID[identifier]
        }
    }
}
