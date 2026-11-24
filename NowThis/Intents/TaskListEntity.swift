import AppIntents
import Foundation
import SwiftData

/// The list identity and display metadata used by Shortcuts and Siri.
struct TaskListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = TaskListEntityQuery()

    var id: String

    @Property(title: LocalizedStringResource("intent.entity.listName", defaultValue: "List Name",
                                             comment: "Shortcuts property for the user-entered list name."))
    var name: String

    @Property(title: LocalizedStringResource("intent.entity.accountName", defaultValue: "Account Name",
                                             comment: "Shortcuts property for the account's display name."))
    var accountName: String?

    init(id: String, name: String) {
        self.id = id
        self.name = name
        accountName = nil
    }

    @MainActor
    init(list: TaskList) {
        id = list.id
        name = list.name
        accountName = list.account?.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        // User-authored names are already display text. Avoid extracting a shared "%@" key.
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: name),
            subtitle: accountName.map { LocalizedStringResource(stringLiteral: $0) }
        )
    }
}

/// Resolves saved lists and offers live name matches for intent parameters.
struct TaskListEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskListEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try entities(for: identifiers, in: ModelContext(container))
    }

    @MainActor
    func entities(for identifiers: [String], in context: ModelContext) throws -> [TaskListEntity] {
        try EntityQueryLookup.lists(for: identifiers, in: context)
            .map { TaskListEntity(list: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskListEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try entities(matching: string, in: ModelContext(container))
    }

    @MainActor
    func entities(matching string: String, in context: ModelContext) throws -> [TaskListEntity] {
        let name = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let descriptor = FetchDescriptor<TaskList>(
            predicate: #Predicate { $0.name.localizedStandardContains(name) },
            sortBy: [SortDescriptor(\TaskList.name), SortDescriptor(\TaskList.id)]
        )
        return try context.fetch(descriptor).map { TaskListEntity(list: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskListEntity] {
        let container = try SharedModelContainer.createReadOnly()
        return try suggestedEntities(in: ModelContext(container))
    }

    @MainActor
    func suggestedEntities(in context: ModelContext) throws -> [TaskListEntity] {
        try context.fetch(EntityQueryLookup.listSuggestionsDescriptor())
            .map { TaskListEntity(list: $0) }
    }
}
