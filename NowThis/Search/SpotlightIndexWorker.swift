import Foundation

struct SpotlightIndexRecord: Codable, Equatable, Sendable {
    let fingerprint: String
    let expiresAt: Date
}

protocol SpotlightIndexSink: Sendable {
    func index(_ snapshots: [SpotlightTaskSnapshot], expiresAt: Date) async throws
    func remove(_ identifiers: [String]) async throws
    func removeAll() async throws
}

protocol SpotlightIndexStateStore: Sendable {
    func load() async throws -> [String: SpotlightIndexRecord]
    func save(_ records: [String: SpotlightIndexRecord]) async throws
}

/// Baseline stores keep their load/save API; worker writes use only changed IDs.
protocol SpotlightIncrementalIndexStateStore: SpotlightIndexStateStore {
    func apply(upserts: [String: SpotlightIndexRecord], removing identifiers: [String]) async throws
    func compact() async throws
}

/// Compatibility for injected stores that only implement snapshots. Their
/// own persistence API remains the authority; no process-global file is used.
private actor SpotlightSnapshotStoreAdapter: SpotlightIncrementalIndexStateStore {
    private let store: any SpotlightIndexStateStore

    init(store: any SpotlightIndexStateStore) { self.store = store }

    func load() async throws -> [String: SpotlightIndexRecord] { try await store.load() }

    func save(_ records: [String: SpotlightIndexRecord]) async throws { try await store.save(records) }

    func apply(upserts: [String: SpotlightIndexRecord], removing identifiers: [String]) async throws {
        var records = try await store.load()
        for id in identifiers { records.removeValue(forKey: id) }
        records.merge(upserts, uniquingKeysWith: { _, latest in latest })
        try await store.save(records)
    }

    func compact() {}
}

protocol SpotlightIndexJournal: Sendable {
    func read() async throws -> Data
    func append(_ entry: Data) async throws
    func truncate(to byteCount: UInt64) async throws
}

/// Each synchronized line is a complete transaction. A torn final line is
/// discarded on load; the preceding invalidation still forces crash repair.
actor SpotlightFileJournal: SpotlightIndexJournal {
    private let url: URL

    init(url: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Spotlight/fingerprint-journal.jsonl")) {
        self.url = url
    }

    func read() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        return try Data(contentsOf: url)
    }

    func append(_ entry: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: entry)
        try handle.synchronize()
    }

    func truncate(to byteCount: UInt64) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: byteCount)
        try handle.synchronize()
    }
}

/// The defaults adapter is a migration source only. Atomic file checkpoints
/// must finish before discarding the durable journal; UserDefaults.set alone
/// does not provide that durability boundary.
actor SpotlightFileStateStore: SpotlightIndexStateStore {
    private let legacy: any SpotlightIndexStateStore
    private let url: URL

    init(legacy: any SpotlightIndexStateStore,
         url: URL = URL.applicationSupportDirectory
            .appendingPathComponent("Spotlight/fingerprint-baseline.json")) {
        self.legacy = legacy
        self.url = url
    }

    func load() async throws -> [String: SpotlightIndexRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return try await legacy.load() }
        return try JSONDecoder().decode([String: SpotlightIndexRecord].self, from: Data(contentsOf: url))
    }

    func save(_ records: [String: SpotlightIndexRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}

/// Journal encoding is proportional to changes. A snapshot is written only
/// after at least a cache's worth of changes, at the end of a worker plan.
/// Replaying a journal over its own checkpoint is idempotent, so a crash
/// between saving the baseline and truncating the journal remains safe.
actor SpotlightJournalStore: SpotlightIncrementalIndexStateStore {
    private struct Change: Codable {
        let upserts: [String: SpotlightIndexRecord]
        let removedIDs: [String]
        var clearsBaseline = false

        var recordCount: Int { upserts.count + removedIDs.count + (clearsBaseline ? 1 : 0) }

        func apply(to records: inout [String: SpotlightIndexRecord]) {
            if clearsBaseline { records.removeAll(keepingCapacity: true) }
            for id in removedIDs { records.removeValue(forKey: id) }
            records.merge(upserts, uniquingKeysWith: { _, latest in latest })
        }
    }

    private let baseline: any SpotlightIndexStateStore
    private let journal: any SpotlightIndexJournal
    private var records: [String: SpotlightIndexRecord]?
    private var baselineCount = 0
    private var journalRecordCount = 0
    private var journalByteCount = 0
    private var appendFailed = false
    private var operationRunning = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(baseline: any SpotlightIndexStateStore,
         journal: any SpotlightIndexJournal) {
        self.baseline = baseline
        self.journal = journal
    }

    func load() async throws -> [String: SpotlightIndexRecord] {
        await beginOperation()
        defer { endOperation() }
        try await ensureLoaded()
        return records ?? [:]
    }

    // Actor reentrancy must not let an append race checkpoint truncation.
    private func beginOperation() async {
        if operationRunning {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            operationRunning = true
        }
    }

    private func endOperation() {
        if operationWaiters.isEmpty {
            operationRunning = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func ensureLoaded() async throws {
        guard records == nil else { return }
        var restored = try await baseline.load()
        let count = restored.count
        let data = try await journal.read()
        let completeByteCount = data.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
        var volume = 0
        var corrupt = false
        for line in data.prefix(completeByteCount).split(separator: 0x0a) {
            do {
                let change = try JSONDecoder().decode(Change.self, from: Data(line))
                change.apply(to: &restored)
                volume += change.recordCount
            } catch {
                // A corrupt complete entry may hide an invalidation. Never
                // trust matching baseline fingerprints after such corruption.
                corrupt = true
            }
        }
        if corrupt {
            for id in restored.keys {
                restored[id] = SpotlightIndexRecord(fingerprint: "", expiresAt: .distantPast)
            }
        }
        // Drop a partial append before writing another line. No sink write
        // can have started until its complete invalidation was synchronized.
        if completeByteCount < data.count {
            try await journal.truncate(to: UInt64(completeByteCount))
        }
        baselineCount = count
        journalRecordCount = volume
        journalByteCount = completeByteCount
        records = restored
    }

    func apply(upserts: [String: SpotlightIndexRecord], removing identifiers: [String]) async throws {
        guard !upserts.isEmpty || !identifiers.isEmpty else { return }
        await beginOperation()
        defer { endOperation() }
        try await append(Change(upserts: upserts, removedIDs: identifiers))
    }

    func save(_ records: [String: SpotlightIndexRecord]) async throws {
        await beginOperation()
        defer { endOperation() }
        try await append(Change(upserts: records, removedIDs: [], clearsBaseline: true))
    }

    private func append(_ change: Change) async throws {
        try await ensureLoaded()
        var entry = try JSONEncoder().encode(change)
        entry.append(0x0a)
        if appendFailed {
            try await journal.truncate(to: UInt64(journalByteCount))
            appendFailed = false
        }
        do {
            try await journal.append(entry)
        } catch {
            // A failed write may have left a partial line, even without a
            // restart. Remove it before the next durable invalidation.
            appendFailed = true
            throw error
        }
        journalByteCount += entry.count
        change.apply(to: &records!)
        journalRecordCount += change.recordCount
    }

    func compact() async throws {
        await beginOperation()
        defer { endOperation() }
        try await ensureLoaded()
        // The checkpoint's encoding cost cannot exceed the changes accumulated
        // since its predecessor, including when generations interrupt a run.
        guard journalRecordCount >= max(100, baselineCount, records?.count ?? 0) else { return }
        try await baseline.save(records ?? [:])
        try await journal.truncate(to: 0)
        baselineCount = records?.count ?? 0
        journalRecordCount = 0
        journalByteCount = 0
        appendFailed = false
    }
}

enum SpotlightIndexRequest: Sendable {
    case refresh([SpotlightTaskSnapshot])
    case index(SpotlightTaskSnapshot)
    case remove(String)
    case clear
}

/// Merges queued CRUD edits into the latest full snapshot. Only this drain
/// calls the sink; an in-flight batch completes before a newer plan applies.
actor SpotlightIndexWorker {
    private struct PendingWork {
        var values: [String: SpotlightTaskSnapshot] = [:]
        var removedIDs: Set<String> = []
        var isFullSnapshot = false
        var clearDomain = false

        mutating func absorb(_ request: SpotlightIndexRequest) {
            switch request {
            case .refresh(let snapshots):
                values = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
                removedIDs = []
                isFullSnapshot = true
                clearDomain = false
            case .index(let snapshot):
                values[snapshot.id] = snapshot
                removedIDs.remove(snapshot.id)
            case .remove(let id):
                values.removeValue(forKey: id)
                removedIDs.insert(id)
            case .clear:
                values = [:]
                removedIDs = []
                isFullSnapshot = true
                clearDomain = true
            }
        }
    }

    private let sink: any SpotlightIndexSink
    private let store: any SpotlightIncrementalIndexStateStore
    private let now: @Sendable () -> Date
    private let reportError: @Sendable (String) -> Void
    private let batchSize: Int
    private var records: [String: SpotlightIndexRecord]?
    private var pending: PendingWork?
    private var generation = 0
    private var draining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(sink: any SpotlightIndexSink, store: any SpotlightIndexStateStore,
         batchSize: Int = 100, now: @escaping @Sendable () -> Date = { Date() },
         reportError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sink = sink
        self.store = (store as? any SpotlightIncrementalIndexStateStore)
            ?? SpotlightSnapshotStoreAdapter(store: store)
        self.batchSize = max(1, batchSize)
        self.now = now
        self.reportError = reportError
    }

    @discardableResult
    func submit(_ request: SpotlightIndexRequest) -> Int {
        generation += 1
        var work = pending ?? PendingWork()
        work.absorb(request)
        pending = work
        if !draining {
            draining = true
            Task { await self.drain() }
        }
        return generation
    }

    func flush() async {
        guard draining else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func drain() async {
        while let work = pending {
            let currentGeneration = generation
            do {
                try await apply(work, generation: currentGeneration)
            } catch {
                reportError(error.localizedDescription)
            }
            do {
                try await store.compact()
            } catch {
                reportError(error.localizedDescription)
            }
            if currentGeneration == generation { pending = nil }
        }
        draining = false
        let completed = waiters
        waiters.removeAll()
        completed.forEach { $0.resume() }
    }

    private func ensureLoaded() async throws {
        guard records == nil else { return }
        records = try await store.load()
    }

    private func persist(upserts: [String: SpotlightIndexRecord], removing identifiers: [String] = []) async throws {
        try await store.apply(upserts: upserts, removing: identifiers)
        for id in identifiers { records?.removeValue(forKey: id) }
        records?.merge(upserts, uniquingKeysWith: { _, latest in latest })
    }

    /// Persist uncertainty before the external write. Failed writes or a crash
    /// cannot leave a matching fingerprint that suppresses the next repair.
    private func invalidate(_ identifiers: [String]) async throws {
        let invalid = SpotlightIndexRecord(fingerprint: "", expiresAt: .distantPast)
        try await persist(upserts: Dictionary(uniqueKeysWithValues: identifiers.map { ($0, invalid) }))
    }

    private func apply(_ work: PendingWork, generation currentGeneration: Int) async throws {
        try await ensureLoaded()
        guard currentGeneration == generation else { return }
        if work.clearDomain {
            try await invalidate(Array(records!.keys))
            guard currentGeneration == generation else { return }
            try await sink.removeAll()
            // Later queued upserts share the cleared baseline and must survive.
            pending?.clearDomain = false
            try await store.save([:])
            records = [:]
        }
        guard currentGeneration == generation else { return }
        let current = work.values.values.sorted { $0.id < $1.id }
        let clock = now()
        var fingerprints: [String: String] = [:]
        var changed: [SpotlightTaskSnapshot] = []
        for snapshot in current {
            let fingerprint = try SpotlightProjection.fingerprint(snapshot)
            fingerprints[snapshot.id] = fingerprint
            let record = records?[snapshot.id]
            // Renew a day before expiration, including migrated timestamp-less state.
            if record?.fingerprint != fingerprint ||
                (record?.expiresAt ?? .distantPast) <= clock.addingTimeInterval(86_400) {
                changed.append(snapshot)
            }
        }
        let absentIDs = work.isFullSnapshot
            ? Set(records!.keys).subtracting(work.values.keys) : []
        let removedIDs = absentIDs.union(work.removedIDs).sorted()

        for batch in SpotlightProjection.batches(changed, maximumCount: batchSize) {
            guard currentGeneration == generation else { return }
            let ids = batch.map(\.id)
            try await invalidate(ids)
            guard currentGeneration == generation else { return }
            let expiry = now().addingTimeInterval(30 * 86_400)
            try await sink.index(batch, expiresAt: expiry)
            var committed: [String: SpotlightIndexRecord] = [:]
            for id in ids {
                if let fingerprint = fingerprints[id] {
                    committed[id] = SpotlightIndexRecord(fingerprint: fingerprint, expiresAt: expiry)
                }
            }
            // Record the actual completed side effect even if a newer request arrived.
            try await persist(upserts: committed)
        }
        for batch in SpotlightProjection.batches(removedIDs, maximumCount: batchSize) {
            guard currentGeneration == generation else { return }
            try await invalidate(batch)
            guard currentGeneration == generation else { return }
            try await sink.remove(batch)
            try await persist(upserts: [:], removing: batch)
        }
    }
}
