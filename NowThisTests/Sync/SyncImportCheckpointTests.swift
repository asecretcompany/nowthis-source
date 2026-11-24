import Foundation
import SwiftData
import Testing
@testable import NowThis

private struct ReceiptResourceFixture {
    let href: String
    let receiptID: String
    let etag: String
}

private final class ReceiptRowFixture {
    let id: String
    let href: String
    var etag: String

    init(id: String, href: String, etag: String) {
        self.id = id
        self.href = href
        self.etag = etag
    }
}

@Suite("Scoped durable sync checkpoints")
@MainActor
struct SyncImportCheckpointTests {
    @Test("Scopes cannot share a path-only token and identity changes invalidate the baseline")
    func scopeIdentity() throws {
        let baseline = SyncImportCheckpoint.identity(accountID: "a", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 3)
        #expect(baseline != SyncImportCheckpoint.identity(accountID: "b", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 3))
        #expect(baseline != SyncImportCheckpoint.identity(accountID: "a", listID: "l", baseURL: "https://other.invalid", username: "u", months: 3))
        #expect(baseline != SyncImportCheckpoint.identity(accountID: "a", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 0))
        let container = try DAVSyncScenario.container()
        let legacy = SyncMetadata(collectionPath: "/one/"); legacy.syncToken = "legacy"
        container.mainContext.insert(legacy); try container.mainContext.save()
        let scope = SyncCollectionPuller.Scope(accountID: "a", listID: "l", historyScope: "3")
        #expect(try SyncImportCheckpoint.read(id: baseline, scope: scope, in: ModelContext(container)) == nil)
        let complete = SyncCollectionPuller.Checkpoint(scope: scope, token: "durable", ctag: "c1", lastIntegrity: Date(timeIntervalSince1970: 10), hasCompletedBaseline: true)
        try SyncImportCheckpoint.commit(complete, id: baseline, collectionPath: "/one/", container: container)
        #expect(try SyncImportCheckpoint.read(id: baseline, scope: scope, in: ModelContext(container)) == complete)
        #expect(try container.mainContext.fetch(FetchDescriptor<SyncMetadata>()).first { $0.id == legacy.id }?.syncToken == "legacy")
        withExtendedLifetime(container) {}
    }
    @Test("Body accounting survives a restart, including history excluded from the visible window")
    func accountedBodiesAreDurableAndScoped() throws {
        let container = try DAVSyncScenario.container()
        let body = CalDAVClient.RemoteTask(href: "/one/old.ics", etag: "e1", icsData: "BEGIN:VTODO\nUID:old\nSTATUS:COMPLETED\nCOMPLETED:20000101T120000Z\nEND:VTODO")
        try SyncImportCheckpoint.markAccounted([body], id: "scope-a", container: container)
        #expect(try SyncImportCheckpoint.accountedETags(id: "scope-a", container: container) == [body.href: body.etag])
        #expect(try SyncImportCheckpoint.accountedETags(id: "scope-b", container: container).isEmpty)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<TaskItem>()) == 0)
        try SyncImportCheckpoint.removeAccounted([body.href], id: "scope-a", container: container)
        #expect(try SyncImportCheckpoint.accountedETags(id: "scope-a", container: container).isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Replaying a duplicate href updates one durable receipt and keeps its original path")
    func duplicateHrefReplayUpdatesExistingReceipt() throws {
        let container = try DAVSyncScenario.container()
        let first = CalDAVClient.RemoteTask(href: "/one/replayed.ics", etag: "e1", icsData: "first")
        let replay = CalDAVClient.RemoteTask(href: "/one/replayed.ics", etag: "e2", icsData: "replay")
        let finalReplay = CalDAVClient.RemoteTask(href: "/one/replayed.ics", etag: "e3", icsData: "final")

        try SyncImportCheckpoint.markAccounted([first], id: "scope-replay", container: container)
        try SyncImportCheckpoint.markAccounted([replay, finalReplay], id: "scope-replay", container: container)

        let prefix = "scope-replay:resource:"
        let rows = try ModelContext(container).fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id.starts(with: prefix) }))
        #expect(rows.count == 1)
        #expect(rows.first?.collectionPath == "/one/replayed.ics")
        #expect(rows.first?.lastCTag == "e3")
        #expect(try SyncImportCheckpoint.accountedETags(id: "scope-replay", container: container) == ["/one/replayed.ics": "e3"])
        withExtendedLifetime(container) {}
    }

    @Test("A bounded receipt batch prefetches distinct IDs once and reuses collision rows")
    func receiptBatchPrefetchesOnceAndPreservesReceiptIDCollisions() throws {
        let existing = ReceiptRowFixture(id: "receipt-existing", href: "/old.ics", etag: "old")
        let resources = [
            ReceiptResourceFixture(href: "/old.ics", receiptID: "receipt-existing", etag: "updated"),
            ReceiptResourceFixture(href: "/first.ics", receiptID: "receipt-collision", etag: "first"),
            ReceiptResourceFixture(href: "/second.ics", receiptID: "receipt-collision", etag: "last")
        ]
        var fetches: [[String]] = []
        var rows = [existing.id: existing]
        var inserted: [ReceiptRowFixture] = []

        try SyncImportCheckpoint.updateReceiptRows(
            resources,
            receiptID: \.receiptID,
            fetchExisting: { ids in
                fetches.append(ids)
                return rows.filter { ids.contains($0.key) }
            },
            makeRow: { resource, id in
                let row = ReceiptRowFixture(id: id, href: resource.href, etag: "")
                inserted.append(row)
                rows[id] = row
                return row
            },
            updateRow: { row, resource in row.etag = resource.etag }
        )
        try SyncImportCheckpoint.updateReceiptRows(
            [ReceiptResourceFixture](),
            receiptID: \.receiptID,
            fetchExisting: { ids in
                fetches.append(ids)
                return [:]
            },
            makeRow: { resource, id in ReceiptRowFixture(id: id, href: resource.href, etag: resource.etag) },
            updateRow: { row, resource in row.etag = resource.etag }
        )

        #expect(fetches == [["receipt-collision", "receipt-existing"]])
        #expect(existing.etag == "updated")
        #expect(inserted.count == 1)
        #expect(inserted.first?.href == "/first.ics")
        #expect(inserted.first?.etag == "last")
    }

    @Test("Changing history scope prunes old receipts and account removal clears only its metadata")
    func receiptsAreBoundedByActiveScopeAndAccount() throws {
        let container = try DAVSyncScenario.container()
        let three = SyncImportCheckpoint.identity(accountID: "a", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 3)
        let all = SyncImportCheckpoint.identity(accountID: "a", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 0)
        let other = SyncImportCheckpoint.identity(accountID: "b", listID: "l", baseURL: "https://fixture.invalid", username: "u", months: 0)
        let body = CalDAVClient.RemoteTask(href: "/one/old.ics", etag: "e", icsData: "fixture")
        for key in [three, all, other] { try SyncImportCheckpoint.markAccounted([body], id: key, container: container) }
        try SyncImportCheckpoint.pruneOtherScopes(accountID: "a", listID: "l", keeping: all, container: container)
        #expect(try SyncImportCheckpoint.accountedETags(id: three, container: container).isEmpty)
        #expect(try SyncImportCheckpoint.accountedETags(id: all, container: container).count == 1)
        let owner = ModelContext(container)
        try SyncImportCheckpoint.removeAccount("a", in: owner); try owner.save()
        #expect(try SyncImportCheckpoint.accountedETags(id: all, container: container).isEmpty)
        #expect(try SyncImportCheckpoint.accountedETags(id: other, container: container).count == 1)
        withExtendedLifetime(container) {}
    }

    @Test("A new writer repairs a durably pending hierarchy even with an existing baseline")
    func durableParentWorkSurvivesWriterReplacement() async throws {
        let container = try DAVSyncScenario.container(); let main = container.mainContext
        let list = TaskList(id: "list", serverURL: "/one/", name: "Fixture", colorHex: "#007AFF")
        main.insert(list); try main.save()
        let key = "collection-fixture"
        let scope = SyncCollectionPuller.Scope(accountID: "a", listID: list.id, historyScope: "0")
        try SyncImportCheckpoint.commit(.init(scope: scope, token: "old-token", ctag: "c1",
            lastIntegrity: Date(), hasCompletedBaseline: true), id: key, collectionPath: "/one/", container: container)
        let first = SyncInboundBatchWriter(container: container, listID: list.id, checkpointID: key)
        let child = ParsedRemoteTask(href: "/one/child.ics", etag: "c", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:child\nRELATED-TO:parent\nEND:VTODO"))
        let parent = ParsedRemoteTask(href: "/one/parent.ics", etag: "p", todo: try ICalendarParser.parseSingleVTODO(from: "BEGIN:VTODO\nUID:parent\nEND:VTODO"))
        _ = try first.apply([child, parent])
        #expect(try SyncImportCheckpoint.hierarchyPending(id: key, in: ModelContext(container)))
        let resumed = SyncInboundBatchWriter(container: container, listID: list.id, checkpointID: key)
        _ = try await resumed.resolveParents()
        let tasks = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
        #expect(tasks.first { $0.uid == "child" }?.parentTask?.uid == "parent")
        #expect(try !SyncImportCheckpoint.hierarchyPending(id: key, in: ModelContext(container)))
        #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))?.token == "old-token")
        withExtendedLifetime(container) {}
    }

}
