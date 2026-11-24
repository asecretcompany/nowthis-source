import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Import work accounting")
@MainActor
struct SyncImportWorkTests {
    @Test("Inbound chunks bound category values as well as resource count")
    func categoryWorkChunks() {
        let resources = (0..<5).map { index in
            var todo = ICalendarParser.VTODOData()
            todo.uid = "cat-\(index)"
            todo.categories = Array(repeating: "Work", count: 256)
            return ParsedRemoteTask(href: "/one/cat-\(index).ics", etag: "e1", todo: todo)
        }
        let chunks = SyncEngine.inboundApplyChunks(resources)
        #expect(chunks.map(\.count) == [2, 2, 1])
        #expect(chunks.flatMap { $0 }.map(\.href) == resources.map(\.href))
        #expect(chunks.allSatisfy { $0.reduce(0) { $0 + ($1.todo?.categories?.count ?? 0) } <= 512 })
    }

    private func resource(uid: String, etag: String, categories: String? = "Work,work") -> CalDAVClient.RemoteTask {
        var lines = ["BEGIN:VCALENDAR", "BEGIN:VTODO", "UID:" + uid, "SUMMARY:" + uid,
            "DUE;TZID=Europe/Berlin:20261010T090000"]
        if let categories { lines.append("CATEGORIES:" + categories) }
        lines += ["END:VTODO", "END:VCALENDAR"]
        return .init(href: "/one/" + uid + ".ics", etag: etag, icsData: lines.joined(separator: "\r\n"))
    }

    @Test("A tagged batch reads the tag table once and reuses formatter and category identities")
    func batchReusesWork() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list)
        let store = try SyncImportStore(context: context)
        var map: [String: TaskItem] = [:]
        for index in 0..<100 {
            let remote = try store.parse(resource(uid: "row-\(index)", etag: "a"))
            #expect(try store.apply(remote, list: list, uidMap: &map))
        }
        #expect(store.parseCount == 100)
        #expect(store.tagFetchCount == 1)
        #expect(store.formatterCache.namedTimeZoneFormatterCreationCount == 1)
        #expect(map.count == 100)
        #expect(try context.fetchCount(FetchDescriptor<NowThis.Tag>()) == 1)
        #expect(map.values.allSatisfy { $0.tags.count == 1 })
        try context.save()
        withExtendedLifetime(container) {}
    }

    @Test("Unchanged records do not write; absent categories preserve tags and explicit empty clears")
    func absentAndEmptyCategoriesRemainDistinct() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let list = TaskList(serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        context.insert(list)
        let store = try SyncImportStore(context: context)
        var map: [String: TaskItem] = [:]
        let initial = try store.parse(resource(uid: "row", etag: "a"))
        #expect(try store.apply(initial, list: list, uidMap: &map)); try context.save()
        #expect(try !store.apply(initial, list: list, uidMap: &map))
        #expect(!context.hasChanges)
        #expect(try store.apply(try store.parse(resource(uid: "row", etag: "b", categories: nil)), list: list, uidMap: &map))
        #expect(map["row"]?.tags.count == 1)
        #expect(try store.apply(try store.parse(resource(uid: "row", etag: "c", categories: "")), list: list, uidMap: &map))
        #expect(map["row"]?.tags.isEmpty == true)
        withExtendedLifetime(container) {}
    }
}
