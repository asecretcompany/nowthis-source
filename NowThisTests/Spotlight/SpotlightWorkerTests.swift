import Foundation
import Testing
#if canImport(NowThis)
@testable import NowThis
#else
@testable import SpotlightHarness
#endif

private enum SpotlightTestError: Error { case failed }

actor SuspendedSpotlightSink: SpotlightIndexSink {
    private var items: [String: SpotlightTaskSnapshot] = [:]
    private var suspendID: String?
    private var failingID: String?
    private var suspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var indexCount = 0

    init(suspendID: String? = nil, failingID: String? = nil) {
        self.suspendID = suspendID
        self.failingID = failingID
    }

    func index(_ snapshots: [SpotlightTaskSnapshot], expiresAt: Date) async throws {
        if let suspendID, snapshots.contains(where: { $0.id == suspendID }) {
            self.suspendID = nil
            suspended = true
            suspensionWaiters.forEach { $0.resume() }
            suspensionWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        if let failingID, snapshots.contains(where: { $0.id == failingID }) {
            throw SpotlightTestError.failed
        }
        indexCount += snapshots.count
        for snapshot in snapshots { items[snapshot.id] = snapshot }
    }

    func remove(_ identifiers: [String]) {
        for id in identifiers { items.removeValue(forKey: id) }
    }

    func removeAll() { items.removeAll() }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func resumeIndex() {
        release?.resume()
        release = nil
    }

    func values() -> [String: SpotlightTaskSnapshot] { items }
}

actor SpotlightTestStore: SpotlightIncrementalIndexStateStore {
    private var records: [String: SpotlightIndexRecord]
    private var failOnSave: Int?
    private var saveCount = 0
    private(set) var encodedRecordCount = 0

    init(_ records: [String: SpotlightIndexRecord] = [:], failOnSave: Int? = nil) {
        self.records = records
        self.failOnSave = failOnSave
    }

    func load() -> [String: SpotlightIndexRecord] { records }

    func save(_ records: [String: SpotlightIndexRecord]) throws {
        encodedRecordCount += records.count
        saveCount += 1
        if saveCount == failOnSave { throw SpotlightTestError.failed }
        self.records = records
    }

    func apply(upserts: [String: SpotlightIndexRecord], removing identifiers: [String]) throws {
        encodedRecordCount += upserts.count + identifiers.count
        saveCount += 1
        if saveCount == failOnSave { throw SpotlightTestError.failed }
        for id in identifiers { records.removeValue(forKey: id) }
        records.merge(upserts, uniquingKeysWith: { _, latest in latest })
    }

    func compact() {}
}

/// Hides the incremental conformance to exercise the legacy load/save API.
private struct SpotlightLegacyTestStore: SpotlightIndexStateStore {
    let store: SpotlightTestStore

    func load() async -> [String: SpotlightIndexRecord] { await store.load() }
    func save(_ records: [String: SpotlightIndexRecord]) async throws { try await store.save(records) }
}

/// Records the size of actual serialized journal transactions, including
/// attempted writes, rather than inferring volume from the number of batches.
private actor SpotlightRecordingJournal: SpotlightIndexJournal {
    private struct Entry: Decodable {
        let upserts: [String: SpotlightIndexRecord]
        let removedIDs: [String]
    }

    private var data = Data()
    private var appendCount = 0
    private let failOnAppend: Int?
    private var failNextReset: Bool
    private(set) var encodedRecordCount = 0

    init(failOnAppend: Int? = nil, failNextReset: Bool = false) {
        self.failOnAppend = failOnAppend
        self.failNextReset = failNextReset
    }

    func read() -> Data { data }

    func append(_ entry: Data) throws {
        let decoded = try JSONDecoder().decode(Entry.self, from: entry)
        encodedRecordCount += decoded.upserts.count + decoded.removedIDs.count
        appendCount += 1
        if appendCount == failOnAppend {
            data.append(entry.prefix(entry.count / 2))
            throw SpotlightTestError.failed
        }
        data.append(entry)
    }

    func truncate(to byteCount: UInt64) throws {
        if byteCount == 0 && failNextReset {
            failNextReset = false
            throw SpotlightTestError.failed
        }
        data = Data(data.prefix(Int(byteCount)))
    }

    func appendCorruptEntry() { data.append(Data("corrupted transaction\n".utf8)) }
}

@Suite("Spotlight ordered worker")
struct SpotlightWorkerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fiftyThousandItemBootstrapPersistsLinearRecordVolume() async throws {
        let snapshots = (0..<50_000).map {
            SpotlightTaskSnapshot(id: String(format: "%05d", $0), title: "Task \($0)")
        }
        let sink = SuspendedSpotlightSink()
        let store = SpotlightTestStore()
        let clock = now
        let journal = SpotlightRecordingJournal()
        let persisted = SpotlightJournalStore(baseline: store, journal: journal)
        let worker = SpotlightIndexWorker(sink: sink, store: persisted, batchSize: 100, now: { clock })
        await worker.submit(.refresh(snapshots))
        await worker.flush()

        let journalVolume = await journal.encodedRecordCount
        let baselineVolume = await store.encodedRecordCount
        let volume = journalVolume + baselineVolume
        #expect(journalVolume == 2 * snapshots.count)
        #expect(baselineVolume == snapshots.count)
        #expect(volume <= 3 * snapshots.count,
                "Persistence may encode invalidation + commit + one baseline, not the entire cache twice per batch")
        #expect(await sink.indexCount == snapshots.count)
        #expect(try await persisted.load().count == snapshots.count)
        #expect(await journal.read().isEmpty)
        // A fresh identical full run must not re-encode either persistence layer.
        await worker.submit(.refresh(snapshots))
        await worker.flush()
        #expect(await journal.encodedRecordCount == journalVolume)
        #expect(await store.encodedRecordCount == baselineVolume)
    }

    @Test func oneTaskChangeDoesNotRewriteFiftyThousandCachedRecords() async throws {
        let unchanged = SpotlightIndexRecord(fingerprint: "cached", expiresAt: now.addingTimeInterval(30 * 86_400))
        let baseline = Dictionary(uniqueKeysWithValues: (0..<50_000).map { ("task-\($0)", unchanged) })
        let store = SpotlightTestStore(baseline)
        let sink = SuspendedSpotlightSink()
        let clock = now
        let journal = SpotlightRecordingJournal()
        let persisted = SpotlightJournalStore(baseline: store, journal: journal)
        let worker = SpotlightIndexWorker(sink: sink, store: persisted, now: { clock })
        let changed = SpotlightTaskSnapshot(id: "task-0", title: "Changed")
        await worker.submit(.index(changed))
        await worker.flush()

        #expect(await journal.encodedRecordCount == 2)
        #expect(await store.encodedRecordCount == 0)
        #expect(await sink.indexCount == 1)
        let reopened = SpotlightJournalStore(baseline: store, journal: journal)
        let saved = try await reopened.load()
        #expect(saved.count == 50_000)
        #expect(saved["task-0"]?.fingerprint == (try SpotlightProjection.fingerprint(changed)))
        #expect(saved["task-49999"] == unchanged)
    }

    @Test func failedCommitRepairsAfterRestartWithoutRewritingTheCache() async throws {
        let unchanged = SpotlightIndexRecord(fingerprint: "cached", expiresAt: now.addingTimeInterval(30 * 86_400))
        let baseline = Dictionary(uniqueKeysWithValues: (0..<50_000).map { ("task-\($0)", unchanged) })
        let store = SpotlightTestStore(baseline)
        let journal = SpotlightRecordingJournal(failOnAppend: 2)
        let persisted = SpotlightJournalStore(baseline: store, journal: journal)
        let sink = SuspendedSpotlightSink()
        let clock = now
        let worker = SpotlightIndexWorker(sink: sink, store: persisted, now: { clock })
        let changed = SpotlightTaskSnapshot(id: "task-0", title: "Changed")
        await worker.submit(.index(changed))
        await worker.flush()
        let reopened = SpotlightJournalStore(baseline: store, journal: journal)
        #expect(try await reopened.load()[changed.id]?.fingerprint == "")

        let restarted = SpotlightIndexWorker(sink: sink, store: reopened, now: { clock })
        await restarted.submit(.index(changed))
        await restarted.flush()
        let saved = try await SpotlightJournalStore(baseline: store, journal: journal).load()
        #expect(saved[changed.id]?.fingerprint == (try SpotlightProjection.fingerprint(changed)))
        #expect(saved["task-49999"] == unchanged)
        #expect(await sink.indexCount == 2)
        #expect(await journal.encodedRecordCount == 4)
        #expect(await store.encodedRecordCount == 0)
    }

    @Test func corruptCompleteJournalEntryForcesRepairOfMatchingBaseline() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Original")
        let original = SpotlightIndexRecord(fingerprint: try SpotlightProjection.fingerprint(snapshot),
                                            expiresAt: now.addingTimeInterval(30 * 86_400))
        let baseline = SpotlightTestStore([snapshot.id: original])
        let journal = SpotlightRecordingJournal()
        await journal.appendCorruptEntry()
        let persisted = SpotlightJournalStore(baseline: baseline, journal: journal)
        #expect(try await persisted.load()[snapshot.id]?.fingerprint == "")
        let clock = now
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink, store: persisted, now: { clock })
        await worker.submit(.refresh([snapshot]))
        await worker.flush()
        #expect(await sink.indexCount == 1)
        #expect(try await persisted.load()[snapshot.id]?.fingerprint == original.fingerprint)
    }

    @Test func failedInvalidationStopsExternalWriteAndRestartRetriesIt() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Changed")
        let baseline = SpotlightTestStore()
        let journal = SpotlightRecordingJournal(failOnAppend: 1)
        let clock = now
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink,
            store: SpotlightJournalStore(baseline: baseline, journal: journal), now: { clock })
        await worker.submit(.index(snapshot))
        await worker.flush()
        #expect(await sink.indexCount == 0)

        let reopened = SpotlightJournalStore(baseline: baseline, journal: journal)
        let restarted = SpotlightIndexWorker(sink: sink, store: reopened, now: { clock })
        await restarted.submit(.index(snapshot))
        await restarted.flush()
        #expect(await sink.indexCount == 1)
        #expect(try await reopened.load()[snapshot.id]?.fingerprint == (try SpotlightProjection.fingerprint(snapshot)))
    }

    @Test func checkpointReplayAfterFailedTruncateDoesNotResurrectDeletedIDs() async throws {
        let record = SpotlightIndexRecord(fingerprint: "cached", expiresAt: now.addingTimeInterval(30 * 86_400))
        let baseline = SpotlightTestStore(Dictionary(uniqueKeysWithValues: (0..<100).map { ("task-\($0)", record) }))
        let journal = SpotlightRecordingJournal(failNextReset: true)
        let persisted = SpotlightJournalStore(baseline: baseline, journal: journal)
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink, store: persisted)
        await worker.submit(.refresh([]))
        await worker.flush()
        #expect(await baseline.load().isEmpty)
        #expect(!(await journal.read().isEmpty))

        let reopened = SpotlightJournalStore(baseline: baseline, journal: journal)
        #expect(try await reopened.load().isEmpty)
        try await reopened.compact()
        #expect(await journal.read().isEmpty)
    }

    @Test func repeatedEmptyClearsHaveABoundedJournal() async throws {
        let journal = SpotlightRecordingJournal()
        let persisted = SpotlightJournalStore(baseline: SpotlightTestStore(), journal: journal)
        let worker = SpotlightIndexWorker(sink: SuspendedSpotlightSink(), store: persisted)
        for _ in 0..<100 {
            await worker.submit(.clear)
            await worker.flush()
        }
        #expect(await journal.read().isEmpty)
        #expect(try await persisted.load().isEmpty)
    }

    @Test func fileCheckpointSupersedesLegacyCacheAndInvalidationIsDurable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("baseline.json")
        let journalURL = directory.appendingPathComponent("journal.jsonl")
        let legacy = SpotlightTestStore()
        let snapshots = (0..<100).map { SpotlightTaskSnapshot(id: "task-\($0)", title: "Task \($0)") }
        let fileBaseline = SpotlightFileStateStore(legacy: legacy, url: stateURL)
        let fileJournal = SpotlightFileJournal(url: journalURL)
        let persisted = SpotlightJournalStore(baseline: fileBaseline, journal: fileJournal)
        let clock = now
        let sink = SuspendedSpotlightSink(suspendID: "task-0")
        // Bootstrap without suspension, forcing a durable checkpoint and an empty journal.
        let bootstrap = SpotlightIndexWorker(sink: SuspendedSpotlightSink(), store: persisted, now: { clock })
        await bootstrap.submit(.refresh(snapshots))
        await bootstrap.flush()
        #expect(await legacy.load().isEmpty)
        #expect(try Data(contentsOf: journalURL).isEmpty)

        let reopenedBaseline = SpotlightFileStateStore(legacy: legacy, url: stateURL)
        let reopened = SpotlightJournalStore(baseline: reopenedBaseline, journal: SpotlightFileJournal(url: journalURL))
        #expect(try await reopened.load().count == 100)
        let worker = SpotlightIndexWorker(sink: sink, store: reopened, now: { clock })
        let changed = SpotlightTaskSnapshot(id: "task-0", title: "Changed")
        await worker.submit(.index(changed))
        await sink.waitUntilSuspended()
        let crashView = SpotlightJournalStore(baseline: SpotlightFileStateStore(legacy: legacy, url: stateURL),
                                              journal: SpotlightFileJournal(url: journalURL))
        let uncertain = try await crashView.load()
        await sink.resumeIndex()
        await worker.flush()
        #expect(uncertain[changed.id]?.fingerprint == "")
        #expect(uncertain[changed.id]?.expiresAt == .distantPast)
        #expect(uncertain["task-99"]?.fingerprint == (try SpotlightProjection.fingerprint(snapshots[99])))
        let saved = try await SpotlightJournalStore(baseline: SpotlightFileStateStore(legacy: legacy, url: stateURL),
                                                    journal: SpotlightFileJournal(url: journalURL)).load()
        #expect(saved[changed.id]?.fingerprint == (try SpotlightProjection.fingerprint(changed)))
    }

    @Test func failedCommitCanRetryOnTheSameLoadedJournal() async throws {
        let unchanged = SpotlightIndexRecord(fingerprint: "untouched", expiresAt: now.addingTimeInterval(30 * 86_400))
        let baseline = SpotlightTestStore(["other": unchanged])
        let journal = SpotlightRecordingJournal(failOnAppend: 2)
        let persisted = SpotlightJournalStore(baseline: baseline, journal: journal)
        let clock = now
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink, store: persisted, now: { clock })
        let changed = SpotlightTaskSnapshot(id: "changed", title: "Changed")
        await worker.submit(.index(changed))
        await worker.flush()
        await worker.submit(.index(changed))
        await worker.flush()
        let reopened = SpotlightJournalStore(baseline: baseline, journal: journal)
        let saved = try await reopened.load()
        #expect(saved[changed.id]?.fingerprint == (try SpotlightProjection.fingerprint(changed)))
        #expect(saved["other"] == unchanged)
        #expect(await sink.indexCount == 2)
    }

    @Test func interruptedPlansKeepCheckpointVolumeAmortized() async throws {
        let journal = SpotlightRecordingJournal()
        let baseline = SpotlightTestStore()
        let persisted = SpotlightJournalStore(baseline: baseline, journal: journal)
        let invalid = SpotlightIndexRecord(fingerprint: "", expiresAt: .distantPast)
        let valid = SpotlightIndexRecord(fingerprint: "indexed", expiresAt: now.addingTimeInterval(30 * 86_400))
        for start in stride(from: 0, to: 50_000, by: 100) {
            let ids = (start..<(start + 100)).map { "task-\($0)" }
            try await persisted.apply(upserts: Dictionary(uniqueKeysWithValues: ids.map { ($0, invalid) }), removing: [])
            try await persisted.apply(upserts: Dictionary(uniqueKeysWithValues: ids.map { ($0, valid) }), removing: [])
            // Simulate each batch ending its plan because a newer generation arrived.
            try await persisted.compact()
        }
        let journalVolume = await journal.encodedRecordCount
        let checkpointVolume = await baseline.encodedRecordCount
        #expect(journalVolume == 100_000)
        #expect(checkpointVolume <= journalVolume)
        #expect(try await persisted.load().count == 50_000)
    }

    @Test func injectedLegacyStorePersistsInvalidationAndRepairsAfterReload() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Changed")
        let saved = SpotlightTestStore(failOnSave: 2)
        let store = SpotlightLegacyTestStore(store: saved)
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink, store: store)
        await worker.submit(.index(snapshot))
        await worker.flush()
        #expect(await saved.load()[snapshot.id]?.fingerprint == "")

        let restarted = SpotlightIndexWorker(sink: sink, store: store)
        await restarted.submit(.index(snapshot))
        await restarted.flush()
        #expect(await saved.load()[snapshot.id]?.fingerprint == (try SpotlightProjection.fingerprint(snapshot)))
        #expect(await sink.indexCount == 2)
    }

    @Test func injectedLegacyStoresRemainIndependent() async throws {
        let first = SpotlightTestStore()
        let second = SpotlightTestStore()
        let firstSnapshot = SpotlightTaskSnapshot(id: "first", title: "First")
        let secondSnapshot = SpotlightTaskSnapshot(id: "second", title: "Second")
        let firstWorker = SpotlightIndexWorker(sink: SuspendedSpotlightSink(), store: SpotlightLegacyTestStore(store: first))
        let secondWorker = SpotlightIndexWorker(sink: SuspendedSpotlightSink(), store: SpotlightLegacyTestStore(store: second))
        await firstWorker.submit(.index(firstSnapshot))
        await secondWorker.submit(.index(secondSnapshot))
        await firstWorker.flush()
        await secondWorker.flush()
        let firstSaved = await first.load()
        let secondSaved = await second.load()
        #expect(Set(firstSaved.keys) == ["first"])
        #expect(Set(secondSaved.keys) == ["second"])
        #expect(firstSaved["first"]?.fingerprint == (try SpotlightProjection.fingerprint(firstSnapshot)))
        #expect(secondSaved["second"]?.fingerprint == (try SpotlightProjection.fingerprint(secondSnapshot)))
    }

    @Test func removalQueuedDuringOldIndexCannotBeResurrected() async {
        let sink = SuspendedSpotlightSink(suspendID: "a")
        let worker = SpotlightIndexWorker(sink: sink, store: SpotlightTestStore(), batchSize: 1)
        await worker.submit(.refresh([
            SpotlightTaskSnapshot(id: "a", title: "A"),
            SpotlightTaskSnapshot(id: "b", title: "Old B")
        ]))
        await sink.waitUntilSuspended()
        await worker.submit(.remove("b"))
        await sink.resumeIndex()
        await worker.flush()
        let items = await sink.values()
        #expect(items["a"]?.title == "A")
        #expect(items["b"] == nil)
    }

    @Test func updateQueuedDuringOldIndexKeepsNewValue() async {
        let sink = SuspendedSpotlightSink(suspendID: "a")
        let worker = SpotlightIndexWorker(sink: sink, store: SpotlightTestStore(), batchSize: 1)
        await worker.submit(.refresh([
            SpotlightTaskSnapshot(id: "a", title: "A"),
            SpotlightTaskSnapshot(id: "b", title: "Old B")
        ]))
        await sink.waitUntilSuspended()
        await worker.submit(.index(SpotlightTaskSnapshot(id: "b", title: "New B")))
        await sink.resumeIndex()
        await worker.flush()
        let items = await sink.values()
        #expect(items["a"]?.title == "A")
        #expect(items["b"]?.title == "New B")
    }

    @Test func identicalExpiredItemIsRenewed() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Unchanged")
        let state = SpotlightIndexRecord(fingerprint: try SpotlightProjection.fingerprint(snapshot),
                                         expiresAt: now.addingTimeInterval(-1))
        let store = SpotlightTestStore([snapshot.id: state])
        let sink = SuspendedSpotlightSink()
        let clock = now
        let worker = SpotlightIndexWorker(sink: sink, store: store, now: { clock })
        await worker.submit(.refresh([snapshot]))
        await worker.flush()
        let count = await sink.indexCount
        let saved = await store.load()
        #expect(count == 1)
        #expect(saved[snapshot.id]!.expiresAt > now)
    }

    @Test func successfulBatchIsPersistedEvenIfNextBatchFails() async {
        let sink = SuspendedSpotlightSink(failingID: "b")
        let store = SpotlightTestStore()
        let worker = SpotlightIndexWorker(sink: sink, store: store, batchSize: 1)
        await worker.submit(.refresh([
            SpotlightTaskSnapshot(id: "a", title: "A"),
            SpotlightTaskSnapshot(id: "b", title: "B")
        ]))
        await worker.flush()
        let items = await sink.values()
        let saved = await store.load()
        #expect(items["a"] != nil)
        #expect(saved["a"]?.fingerprint.isEmpty == false)
        #expect(saved["b"]?.fingerprint == "")
        #expect(saved["b"]?.expiresAt == .distantPast)
    }

    @Test func failedCacheCommitLeavesInvalidationAndRetryRepairsIt() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Latest")
        let sink = SuspendedSpotlightSink()
        let store = SpotlightTestStore(failOnSave: 2)
        let worker = SpotlightIndexWorker(sink: sink, store: store)
        await worker.submit(.index(snapshot))
        await worker.flush()
        let invalid = await store.load()
        #expect(invalid[snapshot.id]?.fingerprint == "")
        await worker.submit(.refresh([snapshot]))
        await worker.flush()
        let repaired = await store.load()
        let count = await sink.indexCount
        #expect(count == 2)
        #expect(repaired[snapshot.id]?.fingerprint == (try SpotlightProjection.fingerprint(snapshot)))
    }

    @Test func staleIndexRevertingToCachedContentStillAppliesLatestValue() async throws {
        let original = SpotlightTaskSnapshot(id: "task", title: "Original")
        let record = SpotlightIndexRecord(fingerprint: try SpotlightProjection.fingerprint(original),
                                          expiresAt: now.addingTimeInterval(30 * 86_400))
        let sink = SuspendedSpotlightSink(suspendID: "task")
        let store = SpotlightTestStore([original.id: record])
        let clock = now
        let worker = SpotlightIndexWorker(sink: sink, store: store, now: { clock })
        await worker.submit(.refresh([SpotlightTaskSnapshot(id: "task", title: "Stale")]))
        await sink.waitUntilSuspended()
        await worker.submit(.refresh([original]))
        await sink.resumeIndex()
        await worker.flush()
        let items = await sink.values()
        let saved = await store.load()
        #expect(items[original.id] == original)
        #expect(saved[original.id]?.fingerprint == record.fingerprint)
    }

    @Test func freshIdenticalSnapshotSkipsAllIndexWrites() async throws {
        let snapshot = SpotlightTaskSnapshot(id: "task", title: "Unchanged")
        let record = SpotlightIndexRecord(fingerprint: try SpotlightProjection.fingerprint(snapshot),
                                          expiresAt: now.addingTimeInterval(30 * 86_400))
        let clock = now
        let sink = SuspendedSpotlightSink()
        let worker = SpotlightIndexWorker(sink: sink, store: SpotlightTestStore([snapshot.id: record]),
                                          now: { clock })
        await worker.submit(.refresh([snapshot]))
        await worker.flush()
        let count = await sink.indexCount
        #expect(count == 0)
    }

}
