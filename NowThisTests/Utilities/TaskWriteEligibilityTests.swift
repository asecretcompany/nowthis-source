import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct TaskWriteEligibilityTests {
    private typealias Refusal = TaskWriteEligibility.Refusal

    @Test("Committed privilege changes take effect without losing either pending edit")
    func freshPrivilege() throws {
        try withStore { container in
            let owner = container.mainContext
            let account = ServerAccount(displayName: "Shared", serverBaseURL: "https://permissions.invalid",
                username: "fixture", mode: .nextcloud)
            let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
            let task = TaskItem(title: "Persisted title")
            let peer = TaskItem(title: "Persisted peer")
            owner.insert(account)
            owner.insert(list)
            owner.insert(task)
            owner.insert(peer)
            list.account = account
            task.taskList = list
            task.isDirty = true
            try owner.save()
            let listID = list.id
            let taskID = task.id
            let listPID = list.persistentModelID
            let policy = TaskWriteEligibility(writingIn: owner)
            #expect(try policy.task(.retained(task)) === task)
            #expect(try policy.destination(.list(id: listID, expectedPersistentID: listPID)) === list)
            try #require(!list.isReadOnly)

            task.title = "Pending task title"
            peer.title = "Pending peer title"
            let other = ModelContext(container)
            let otherList = try #require(try other.fetch(FetchDescriptor<TaskList>(predicate: #Predicate {
                $0.id == listID
            })).first)
            otherList.isReadOnly = true
            try other.save()

            #expect(throws: Refusal.readOnly) { _ = try policy.task(.retained(task)) }
            #expect(throws: Refusal.readOnly) { _ = try policy.task(.id(taskID)) }
            #expect(throws: Refusal.readOnly) {
                _ = try policy.destination(.list(id: listID, expectedPersistentID: listPID))
            }
            #expect(task.title == "Pending task title" && task.isDirty)
            #expect(peer.title == "Pending peer title")
            let stored = ModelContext(container)
            let storedTasks = try stored.fetch(FetchDescriptor<TaskItem>())
            #expect(Set(storedTasks.map(\.title)) == ["Persisted title", "Persisted peer"])

            otherList.isReadOnly = false
            try other.save()
            #expect(try policy.task(.id(taskID)) === task)
            #expect(try policy.destination(.list(id: listID, expectedPersistentID: listPID)) === list)
            #expect(task.title == "Pending task title" && task.isDirty)
        }
    }

    @Test("Pending rebind, deletion, insertion and wrong-context references fail by exact identity")
    func pendingIdentity() throws {
        let container = try DAVSyncScenario.container()
        let owner = container.mainContext
        owner.autosaveEnabled = false
        let source = TaskList(serverURL: "", name: "Local source", colorHex: "#007AFF")
        let other = TaskList(serverURL: "", name: "Local destination", colorHex: "#007AFF")
        let task = TaskItem(title: "Bound task")
        let unbound = TaskItem(title: "Unbound")
        owner.insert(source)
        owner.insert(other)
        owner.insert(task)
        owner.insert(unbound)
        task.taskList = source
        try owner.save()
        let policy = TaskWriteEligibility(writingIn: owner)
        let taskID = task.id
        let unboundID = unbound.id
        let listID = source.id
        let listPID = source.persistentModelID

        #expect(try policy.task(.retained(unbound)) === unbound)
        #expect(try policy.destination(.unbound) == nil)
        task.taskList = nil
        #expect(throws: Refusal.targetChanged) { _ = try policy.task(.retained(task)) }
        #expect(throws: Refusal.targetChanged) { _ = try policy.task(.id(taskID)) }
        task.taskList = other
        #expect(throws: Refusal.targetChanged) { _ = try policy.task(.retained(task)) }
        task.taskList = source

        source.isReadOnly = true
        owner.processPendingChanges()
        #expect(throws: Refusal.readOnly) { _ = try policy.task(.retained(task)) }
        #expect(throws: Refusal.readOnly) {
            _ = try policy.destination(.list(id: listID, expectedPersistentID: listPID))
        }
        source.isReadOnly = false
        task.isDeletedLocally = true
        #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(task)) }
        task.isDeletedLocally = false
        owner.delete(unbound)
        #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(unbound)) }
        #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.id(unboundID)) }

        let inserted = TaskItem(title: "Unsaved draft")
        let pendingList = TaskList(serverURL: "", name: "Unsaved list", colorHex: "#007AFF")
        owner.insert(inserted)
        owner.insert(pendingList)
        let pendingListID = pendingList.id
        #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(inserted)) }
        #expect(throws: Refusal.listUnavailable) {
            _ = try policy.destination(.list(id: pendingListID, expectedPersistentID: nil))
        }

        let outsider = ModelContext(container)
        let otherRow = try #require(try outsider.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.id == taskID
        })).first)
        #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(otherRow)) }
        #expect(task.taskList === source)
    }

    @Test("An account cascade and recreated app IDs do not reattach a retained target")
    func cascadeAndRecreation() throws {
        try withStore { container in
            let owner = container.mainContext
            let account = ServerAccount(displayName: "Removed", serverBaseURL: "https://permissions.invalid",
                username: "fixture", mode: .nextcloud)
            let list = TaskList(serverURL: "/shared/", name: "Removed", colorHex: "#007AFF")
            let task = TaskItem(title: "Removed task")
            owner.insert(account)
            owner.insert(list)
            owner.insert(task)
            list.account = account
            task.taskList = list
            try owner.save()
            let accountID = account.id
            let listID = list.id
            let oldListPID = list.persistentModelID
            let taskID = task.id
            let oldTaskPID = task.persistentModelID
            let policy = TaskWriteEligibility(writingIn: owner)

            let other = ModelContext(container)
            let removedAccount = try #require(try other.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate {
                $0.id == accountID
            })).first)
            let otherTask = try #require(try other.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
                $0.id == taskID
            })).first)
            let pendingDeletion = TaskWriteEligibility(writingIn: other)
            other.delete(removedAccount)
            #expect(throws: Refusal.self) { _ = try pendingDeletion.task(.retained(otherTask)) }
            #expect(throws: Refusal.self) { _ = try pendingDeletion.task(.id(taskID)) }
            #expect(throws: Refusal.listUnavailable) {
                _ = try pendingDeletion.destination(.list(id: listID, expectedPersistentID: oldListPID))
            }
            try other.save()
            #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(task)) }
            #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.id(taskID)) }
            #expect(throws: Refusal.listUnavailable) {
                _ = try policy.destination(.list(id: listID, expectedPersistentID: oldListPID))
            }

            let replacementList = TaskList(id: listID, serverURL: "", name: "New Vault list", colorHex: "#007AFF")
            let replacementTask = TaskItem(id: taskID, title: "New task")
            let vault = ServerAccount(displayName: "Vault", serverBaseURL: "", username: "", mode: .vault)
            other.insert(vault)
            other.insert(replacementList)
            other.insert(replacementTask)
            replacementList.account = vault
            replacementTask.taskList = replacementList
            try other.save()
            try #require(replacementTask.persistentModelID != oldTaskPID)
            try #require(replacementList.persistentModelID != oldListPID)

            #expect(throws: Refusal.taskUnavailable) { _ = try policy.task(.retained(task)) }
            #expect(throws: Refusal.targetChanged) {
                _ = try policy.destination(.list(id: listID, expectedPersistentID: oldListPID))
            }
            let resolved = try policy.task(.id(taskID))
            #expect(resolved.modelContext === owner)
            #expect(resolved.persistentModelID == replacementTask.persistentModelID)
            let destination = try policy.destination(.list(id: listID, expectedPersistentID: nil))
            #expect(destination?.modelContext === owner)
            #expect(destination?.persistentModelID == replacementList.persistentModelID)
            #expect(!owner.hasChanges)
        }
    }

    @Test("A batch spanning the fetch bound denies before changing any row")
    func batchedWriters() throws {
        let container = try DAVSyncScenario.container()
        let owner = container.mainContext
        owner.autosaveEnabled = false
        let list = TaskList(serverURL: "/shared/", name: "Shared", colorHex: "#007AFF")
        owner.insert(list)
        let rows = (0..<129).map { TaskItem(title: "Task \($0)") }
        for row in rows {
            owner.insert(row)
            row.taskList = list
        }
        try owner.save()
        let policy = TaskWriteEligibility(writingIn: owner)
        try policy.tasks(rows)
        let deniedList = TaskList(serverURL: "/denied/", name: "Read-only", colorHex: "#007AFF")
        deniedList.isReadOnly = true
        owner.insert(deniedList)
        rows.last?.taskList = deniedList
        try owner.save()
        #expect(throws: Refusal.readOnly) { try policy.tasks(rows) }
        #expect(!owner.hasChanges)
        #expect(rows.allSatisfy { !$0.isDirty })
    }

    @Test("The app and iOS widget include the shared task writer policy")
    func targetMembership() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let spec = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let paths = YAMLLite.flatten(spec).filter { $0.key.contains(".sources.") && $0.key.hasSuffix(".path") }
        let file = "NowThis/Utilities/TaskWriteEligibility.swift"
        #expect(paths.contains { $0.key.hasPrefix("targets.NowThis.sources.") && $0.value == "NowThis" })
        let explicitTargets = Set(paths.filter { $0.value == file }.keys.compactMap {
            $0.split(separator: ".").dropFirst().first.map(String.init)
        })
        #expect(explicitTargets == ["NowThisWidget"])
    }

    private func withStore(_ check: (ModelContainer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try checkDiskStore(at: directory.appendingPathComponent("local.store"), check: check)
    }

    private func checkDiskStore(at url: URL, check: (ModelContainer) throws -> Void) throws {
        let schema = Schema(SchemaV2.models)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        container.mainContext.autosaveEnabled = false
        try check(container)
    }
}
