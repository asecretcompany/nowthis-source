import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Atomic inbound batches", .serialized)
@MainActor
struct SyncInboundBatchWriterTests {
    @Test("Edits after an earlier cached read stay authoritative", arguments: [true, false])
    func newerLocalEdit(save: Bool) throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(uid: "uid", title: "Before")
        task.taskList = list; task.etag = "e1"; task.isDirty = false
        main.insert(list); main.insert(task); try main.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        let first = ParsedRemoteTask(href: "/one/uid.ics", etag: "e1", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:uid\nSUMMARY:Before\nEND:VTODO"))
        _ = try writer.apply([first]) // Populate the previous batch's registered models.
        task.title = "My newer edit"; task.isDirty = true
        if save { try main.save() }
        let next = ParsedRemoteTask(href: "/one/uid.ics", etag: "e2", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:uid\nSUMMARY:Server old edit\nEND:VTODO"))
        _ = try writer.apply([next])
        #expect(task.title == "My newer edit")
        #expect(task.isDirty)
        if save {
            let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
            #expect(stored.title == "My newer edit")
            #expect(stored.isDirty)
        }
        withExtendedLifetime(container) {}
    }
    @Test("A pending local insert with the arriving UID does not gain a remote duplicate")
    func pendingInsertWins() throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list); try main.save()
        let local = TaskItem(uid: "pending", title: "My pending task")
        local.taskList = list; local.isDirty = true; main.insert(local)
        let resource = ParsedRemoteTask(href: "/one/pending.ics", etag: "e1", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:pending\nSUMMARY:Server task\nEND:VTODO"))
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        _ = try writer.apply([resource])
        #expect(try main.fetch(FetchDescriptor<TaskItem>()).filter { $0.uid == "pending" }.count == 1)
        #expect(local.title == "My pending task")
        withExtendedLifetime(container) {}
    }

    @Test("Explicit deletion preserves a dirty descendant and every ancestor")
    func dirtyDescendantPreventsCascade() async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list)
        let parent = TaskItem(uid: "parent", title: "Parent")
        let child = TaskItem(uid: "child", title: "Newer local child")
        for task in [parent, child] {
            main.insert(task); task.taskList = list; task.isLocalOnly = false
            task.remoteHref = "/one/" + task.uid + ".ics"; task.isDirty = false
        }
        child.parentTask = parent; child.parentUID = parent.uid; child.isDirty = true
        try main.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        _ = try await writer.deleteExplicit([parent.remoteHref!, child.remoteHref!])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 2)
        withExtendedLifetime(container) {}
    }

    @Test("A task imported from the server can be removed by a final delta tombstone")
    func finalImportedTaskCanBeDeleted() async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list); try main.save()
        let resource = ParsedRemoteTask(href: "/one/remote.ics", etag: "e1", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:remote\nSUMMARY:Server task\nEND:VTODO"))
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        _ = try writer.apply([resource])
        #expect(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first?.isLocalOnly == false)
        _ = try await writer.deleteExplicit([resource.href])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
        withExtendedLifetime(container) {}
    }

    @Test("A stale dirty-task queue cannot create a PUT for the former list")
    func uploadScopeMustMatchCurrentDestination() throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let accountID = try DAVSyncScenario.account(in: container)
        let account = try #require(try main.fetch(FetchDescriptor<ServerAccount>()).first)
        let source = TaskList(id: "source", serverURL: "/one/", name: "Source", colorHex: "#007AFF")
        let destination = TaskList(id: "destination", serverURL: "/two/", name: "Destination", colorHex: "#007AFF")
        for list in [source, destination] { list.account = account; main.insert(list) }
        let task = TaskItem(uid: "moving", title: "Moved before its queued PUT")
        task.taskList = destination; task.isDirty = true; main.insert(task); try main.save()
        let snapshot = try SyncPushAcknowledgement.snapshot(taskID: task.id, calendarPath: "/one/", container: container, expectedListID: source.id, expectedAccountID: accountID)
        #expect(snapshot == nil)
        withExtendedLifetime(container) {}
    }

    @Test("Large explicit deletions save in bounded transactions")
    func boundedDeletion() async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list)
        var hrefs: [String] = []
        for index in 0..<250 {
            let task = TaskItem(uid: "remote-\(index)", title: "Remote task")
            task.taskList = list; task.isLocalOnly = false; task.isDirty = false
            task.remoteHref = "/one/\(index).ics"; hrefs.append(task.remoteHref!)
            main.insert(task)
        }
        try main.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        let lastCommit = try await writer.deleteExplicit(hrefs)
        #expect((lastCommit?.change.deletedIDs.count ?? 0) <= 100)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskItem>()) == 0)
        withExtendedLifetime(container) {}
    }

    @Test("Renaming a resource with the same ETag retains its task identity", arguments: [false, true])
    func renameKeepsIdentity(explicit: Bool) async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list); try main.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        func resource(_ uid: String, _ href: String) throws -> ParsedRemoteTask {
            ParsedRemoteTask(href: href, etag: "same", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:\(uid)\nSUMMARY:\(uid)\nEND:VTODO"))
        }
        _ = try writer.apply([resource("renamed", "/one/old.ics"), resource("survivor", "/one/survivor.ics")])
        let original = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first { $0.uid == "renamed" })
        let originalID = original.id
        _ = try writer.apply([resource("renamed", "/one/new.ics")])
        if explicit { _ = try await writer.deleteExplicit(["/one/old.ics"]) }
        else { _ = try await writer.reconcileManifest([.init(href: "/one/new.ics", etag: "same"), .init(href: "/one/survivor.ics", etag: "same")]) }
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.count == 2)
        #expect(tasks.first { $0.uid == "renamed" }?.id == originalID)
        #expect(tasks.first { $0.uid == "renamed" }?.remoteHref == "/one/new.ics")
        withExtendedLifetime(container) {}
    }

    @Test("Shipping category repair preserves saved dirty content and pending tag edits", arguments: [false, true])
    func dirtyCategoryRepair(save: Bool) throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        main.autosaveEnabled = false
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        let task = TaskItem(uid: "uid", title: "Before")
        let home = Tag(name: "Home"); main.insert(home)
        task.taskList = list; task.tags = [home]; task.etag = "e1"; task.isDirty = false
        main.insert(list); main.insert(task); try main.save()
        task.title = "My edit"; task.isDirty = true
        if save { try main.save() }
        let resource = ParsedRemoteTask(href: "/one/uid.ics", etag: "e2", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:uid\nSUMMARY:Old server title\nCATEGORIES:Work\nEND:VTODO"))
        _ = try SyncInboundBatchWriter(container: container, listID: list.id).apply([resource], repairCategories: true)
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).first)
        #expect(Set(stored.tags.map(\.name)) == (save ? ["Home", "Work"] : ["Home"]))
        #expect(stored.title == (save ? "My edit" : "Before"))
        #expect(task.title == "My edit" && task.isDirty)
        withExtendedLifetime(container) {}
    }

    @Test("A saved local reparent between hierarchy batches cannot introduce a cycle")
    func localReparentDuringPlanning() async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list)
        for uid in ["root", "b-parent", "z-target"] + (0..<100).map({ String(format: "child-%03d", $0) }) {
            let task = TaskItem(id: uid, uid: uid, title: uid)
            task.taskList = list; task.isDirty = false; task.isLocalOnly = false; task.etag = "old"
            main.insert(task)
        }
        try main.save()
        let writer = SyncInboundBatchWriter(container: container, listID: list.id)
        let fillers = try (0..<100).map { index in
            let uid = String(format: "child-%03d", index)
            return ParsedRemoteTask(href: "/one/\(uid).ics", etag: "new", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:\(uid)\nRELATED-TO:root\nEND:VTODO"))
        }
        _ = try writer.apply(fillers)
        _ = try writer.apply([.init(href: "/one/z-target.ics", etag: "new", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:z-target\nRELATED-TO:b-parent\nEND:VTODO"))])
        _ = try await writer.resolveParents(onCommit: { _ in
            await MainActor.run {
                do {
                let main = container.mainContext
                let tasks = try main.fetch(FetchDescriptor<TaskItem>())
                let parent = try #require(tasks.first { $0.id == "b-parent" })
                let target = try #require(tasks.first { $0.id == "z-target" })
                if parent.parentTask == nil {
                    parent.parentTask = target; parent.parentUID = target.uid; parent.isDirty = true
                    try main.save()
                }
                } catch { Issue.record(error) }
            }
        })
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        let parent = try #require(tasks.first { $0.id == "b-parent" })
        let target = try #require(tasks.first { $0.id == "z-target" })
        #expect(target.parentTask == nil)
        #expect(parent.parentTask?.id == target.id)
        #expect(parent.isDirty)
        withExtendedLifetime(container) {}
    }

}
