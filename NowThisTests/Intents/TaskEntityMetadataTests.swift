import AppIntents
import Foundation
import SwiftData
import Testing

@testable import NowThis

@Suite("Task and list entity metadata")
@MainActor
struct TaskEntityMetadataTests {
    @Test("The shipped initializers retain their saved IDs and display values")
    func legacyInitializersKeepTheirIdentity() {
        let task = TaskEntity(id: "saved-task", title: "File receipts", isCompleted: true, listName: "Work")
        let list = TaskListEntity(id: "saved-list", name: "Work")

        #expect(task.id == "saved-task")
        #expect(task.id.entityIdentifierString == "saved-task")
        #expect(task.title == "File receipts")
        #expect(task.isCompleted)
        #expect(task.listName == "Work")
        #expect(task.displayRepresentation.subtitle.map { String(localized: $0) } == "Work")
        #expect(list.id == "saved-list")
        #expect(list.id.entityIdentifierString == "saved-list")
        #expect(list.name == "Work")
        #expect(list.displayRepresentation.subtitle == nil)
    }

    @Test("Saved IDs and suggestions resolve current task metadata")
    func resolvedTasksProjectModelValues() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let list = makeList(id: "work", name: "Work", accountName: "Studio", in: context)
        let task = TaskItem(
            id: "saved-task", uid: "remote-vtodo-uid", title: "File receipts",
            descriptionText: "Private note", priority: .high, status: .inProcess
        )
        task.taskList = list
        task.dueDate = Date(timeIntervalSince1970: 1_797_552_000)
        task.isDueDateOnly = true
        task.startDate = Date(timeIntervalSince1970: 1_797_384_600)
        task.tags = [Tag(name: "Finance"), Tag(name: "Admin")]
        task.recurrenceRule = "FREQ=WEEKLY"
        context.insert(task)
        try context.save()

        let query = TaskEntityQuery()
        let resolved = try query.entities(for: ["saved-task", "remote-vtodo-uid"], in: context)
        let suggested = try query.suggestedEntities(in: context)
        #expect(resolved.map(\.id) == ["saved-task"])
        #expect(suggested.map(\.id) == ["saved-task"])
        for entity in resolved + suggested {
            #expect(entity.title == "File receipts")
            #expect(entity.statusName == TaskStatus.inProcess.displayName)
            #expect(!entity.isCompleted)
            #expect(entity.listName == "Work")
            #expect(entity.dueDate == Date(timeIntervalSince1970: 1_797_552_000))
            #expect(entity.isDueDateOnly)
            #expect(entity.startDate == Date(timeIntervalSince1970: 1_797_384_600))
            #expect(!entity.isStartDateOnly)
            #expect(entity.priorityName == TaskPriority.high.displayName)
            #expect(Set(entity.tagNames) == ["Finance", "Admin"])
            #expect(entity.isRecurring)
            #expect(entity.accountName == "Studio")
        }
    }

    @Test("Only the task and list metadata allowlists are visible as intent properties")
    func onlyDisplayMetadataIsExposed() {
        let task = TaskEntity(id: "task", title: "Example", isCompleted: false, listName: "Work")
        let list = TaskListEntity(id: "list", name: "Work")

        #expect(exposedProperties(of: task) == [
            "title", "statusName", "listName", "dueDate", "isDueDateOnly",
            "startDate", "isStartDateOnly", "priorityName", "tagNames", "isRecurring", "accountName"
        ])
        #expect(exposedProperties(of: list) == ["name", "accountName"])
    }

    @Test("Task name matching preserves duplicates, honors accents and skips tombstones")
    func taskNameMatchingIncludesListAndAccountContext() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let home = makeList(id: "home", name: "Personal", accountName: "Vault", in: context)
        let work = makeList(id: "work", name: "Work", accountName: "Studio", in: context)
        for (id, list) in [("home-task", home), ("work-task", work), ("deleted-task", work)] {
            let task = TaskItem(id: id, title: "Café receipts")
            task.taskList = list
            task.createdDate = Date(timeIntervalSince1970: 0)
            task.isDeletedLocally = id == "deleted-task"
            context.insert(task)
        }
        for index in 1...21 {
            let task = TaskItem(id: "newer-\(index)", title: "Something else", descriptionText: "Café receipts")
            task.createdDate = Date(timeIntervalSince1970: Double(index))
            context.insert(task)
        }
        try context.save()

        let query = TaskEntityQuery()
        let matches = try query.entities(matching: "  CAFE ", in: context)
        #expect(matches.map(\.id) == ["home-task", "work-task"])
        #expect(matches.map(\.listName) == ["Personal", "Work"])
        #expect(matches.map(\.accountName) == ["Vault", "Studio"])
        #expect(matches.map { $0.displayRepresentation.subtitle.map { String(localized: $0) } }
            == ["Personal · Vault", "Work · Studio"])
        #expect(try query.entities(matching: "   ", in: context).isEmpty)
        #expect(try query.entities(matching: "missing", in: context).isEmpty)
    }

    @Test("Search results distinguish equal task names in the same list by due date")
    func sameListTaskNameMatchesIncludeDueDates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let work = makeList(id: "work", name: "Work", accountName: "Studio", in: context)
        let iso8601 = ISO8601DateFormatter()
        let firstDueDate = try #require(iso8601.date(from: "2026-11-18T00:00:00Z"))
        let secondDueDate = try #require(iso8601.date(from: "2027-11-18T00:00:00Z"))

        for (id, dueDate) in [("first-receipts", firstDueDate), ("second-receipts", secondDueDate)] {
            let task = TaskItem(id: id, title: "File receipts")
            task.taskList = work
            task.createdDate = Date(timeIntervalSince1970: 0)
            task.dueDate = dueDate
            task.isDueDateOnly = true
            context.insert(task)
        }
        try context.save()

        let matches = try TaskEntityQuery().entities(matching: "receipts", in: ModelContext(container))
        #expect(matches.map(\.id) == ["first-receipts", "second-receipts"])
        #expect(matches.map(\.title) == ["File receipts", "File receipts"])

        // UTC midnight stores the task's civil day, including its year.
        var civilDateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)
        civilDateStyle.timeZone = .gmt
        let dueDates = [firstDueDate, secondDueDate].map { $0.formatted(civilDateStyle) }
        #expect(matches.map { $0.displayRepresentation.subtitle.map { String(localized: $0) } }
            == dueDates.map { "Work · Studio · \($0)" })
    }

    @Test("List name matching and lookup identify equal names by account")
    func listNameMatchingIncludesAccountContext() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = makeList(id: "personal-list", name: "Café", accountName: "Vault", in: context)
        _ = makeList(id: "studio-list", name: "Café", accountName: "Studio", in: context)
        _ = makeList(id: "unrelated", name: "Work", accountName: "Café", in: context)
        try context.save()

        let query = TaskListEntityQuery()
        let matches = try query.entities(matching: "cafe", in: context)
        #expect(matches.map(\.id) == ["personal-list", "studio-list"])
        #expect(matches.map(\.accountName) == ["Vault", "Studio"])
        #expect(matches.map { $0.displayRepresentation.subtitle.map { String(localized: $0) } }
            == ["Vault", "Studio"])
        let resolved = try query.entities(for: ["studio-list", "personal-list"], in: context)
        #expect(resolved.map(\.accountName) == ["Studio", "Vault"])
        let suggested = try query.suggestedEntities(in: context)
        #expect(suggested.map(\.accountName) == ["Vault", "Studio", "Café"])
        #expect(try query.entities(matching: "", in: context).isEmpty)
        #expect(try query.entities(matching: "missing", in: context).isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SchemaV2.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeList(id: String, name: String, accountName: String, in context: ModelContext) -> TaskList {
        let account = ServerAccount(
            displayName: accountName, serverBaseURL: "https://private.example", username: "private-user"
        )
        let list = TaskList(id: id, serverURL: "/private/list/path", name: name, colorHex: "#007AFF")
        context.insert(account)
        context.insert(list)
        list.account = account
        return list
    }

    private func exposedProperties(of entity: some AppEntity) -> Set<String> {
        Set(Mirror(reflecting: entity).children.compactMap { child in
            guard child.value is any AnyIntentValue, let label = child.label else { return nil }
            return String(label.drop(while: { $0 == "_" }))
        })
    }
}
