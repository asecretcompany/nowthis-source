import AppIntents
import Foundation
import Testing
@testable import NowThis

struct SpotlightEntityLinkTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func searchableItemLinksTheOriginalOpaqueTaskID() {
        let task = SpotlightTaskSnapshot(id: "legacy-opaque-task-id", title: "Meeting prep")

        let item = CoreSpotlightSink.searchableItem(for: task, expiresAt: now)

        #expect(item.uniqueIdentifier == "legacy-opaque-task-id")
        #expect(item.domainIdentifier == "com.asecretcompany.nowthis.task")
        #expect(item.attributeSet.url?.absoluteString == "nowthis://task/legacy-opaque-task-id")
        #expect(item.expirationDate == now)
        if #available(iOS 27.0, *) {
            #expect(item.attributeSet.relatedAppEntityIdentifier ==
                EntityIdentifier(for: TaskEntity.self, identifier: "legacy-opaque-task-id"))
        } else {
            #expect(item.attributeSet.relatedUniqueIdentifier == "legacy-opaque-task-id")
        }
    }

    @Test func freshPreLinkFingerprintGetsOneSameIDUpsert() async throws {
        let task = SpotlightTaskSnapshot(id: "old-task-id", title: "Unchanged task")
        // SHA-256 of the sorted JSON written before entity linkage:
        // {"id":"old-task-id","keywords":[],"title":"Unchanged task"}
        let oldRecord = SpotlightIndexRecord(
            fingerprint: "f7c14a381bf8494c2a02d60ab99deaf197d71830f62e2ca46135b0049f7d554a",
            expiresAt: now.addingTimeInterval(10 * 86_400)
        )
        let store = SpotlightTestStore([task.id: oldRecord])
        let sink = SuspendedSpotlightSink()
        let clock = now
        let worker = SpotlightIndexWorker(sink: sink, store: store, now: { clock })

        await worker.submit(.refresh([task]))
        await worker.flush()

        if #available(iOS 27.0, *) {
            #expect(await sink.indexCount == 1)
            let refreshed = try #require(await sink.values()["old-task-id"])
            let item = CoreSpotlightSink.searchableItem(for: refreshed, expiresAt: oldRecord.expiresAt)
            #expect(item.uniqueIdentifier == "old-task-id")
            #expect(item.attributeSet.relatedAppEntityIdentifier ==
                EntityIdentifier(for: TaskEntity.self, identifier: "old-task-id"))
            #expect(await store.load()["old-task-id"]?.fingerprint != oldRecord.fingerprint)

            let restarted = SpotlightIndexWorker(sink: sink, store: store, now: { clock })
            await restarted.submit(.refresh([task]))
            await restarted.flush()
            #expect(await sink.indexCount == 1)
        } else {
            #expect(await sink.indexCount == 0)
            #expect(await store.load()["old-task-id"] == oldRecord)
        }
    }

    @Test func optOutReplacesTheLinkedItemAndDeletionRemovesIt() async throws {
        let suite = "SpotlightEntityLinkTests." + UUID().uuidString
        let preferences = SpotlightPreferences(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        preferences.setIncludesNotes(true)
        let task = SpotlightTaskSnapshot(id: "private-task", title: "Task", contentDescription: "Private note")
        let sink = SuspendedSpotlightSink()
        let store = SpotlightTestStore()
        let worker = SpotlightIndexWorker(sink: sink, store: store, preferences: preferences)

        await worker.submit(.refresh([task]))
        await worker.flush()
        let before = try #require(await sink.values()["private-task"])
        let original = CoreSpotlightSink.searchableItem(for: before, expiresAt: now)
        #expect(original.attributeSet.contentDescription == "Private note")

        preferences.setIncludesNotes(false)
        await worker.submit(.refresh([task]))
        await worker.flush()
        let after = try #require(await sink.values()["private-task"])
        let replacement = CoreSpotlightSink.searchableItem(for: after, expiresAt: now)
        #expect(await sink.indexCount == 2)
        #expect(replacement.uniqueIdentifier == original.uniqueIdentifier)
        #expect(replacement.attributeSet.url == original.attributeSet.url)
        #expect(replacement.attributeSet.contentDescription == nil)
        if #available(iOS 27.0, *) {
            let expected = EntityIdentifier(for: TaskEntity.self, identifier: "private-task")
            #expect(original.attributeSet.relatedAppEntityIdentifier == expected)
            #expect(replacement.attributeSet.relatedAppEntityIdentifier == expected)
        }

        await worker.submit(.remove("private-task"))
        await worker.flush()
        #expect(await sink.values().isEmpty)
        #expect(await store.load().isEmpty)
    }
}
