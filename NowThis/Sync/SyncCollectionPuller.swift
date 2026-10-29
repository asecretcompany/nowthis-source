import Foundation

/// The existing client provides transport completeness and canonical collection hrefs.
protocol SyncCollectionPullTransport: Sendable {
    func fetchTaskManifest(baseURL: String, calendarPath: String,
                           credentials: CalDAVClient.Credentials) async throws -> [CalDAVClient.RemoteResource]
    func fetchTaskBatch(baseURL: String, calendarPath: String, hrefs: [String],
                        credentials: CalDAVClient.Credentials) async throws -> [CalDAVClient.RemoteTask]
    func fetchSyncDelta(baseURL: String, calendarPath: String, syncToken: String,
                        credentials: CalDAVClient.Credentials) async throws -> CalDAVClient.SyncDeltaPage
}

extension CalDAVClient: SyncCollectionPullTransport {}

/// Network orchestration only. All persistence and history filtering belong to the caller.
actor SyncCollectionPuller {
    struct Scope: Sendable, Equatable {
        let accountID: String
        let listID: String
        /// The parent changes this identity when the eligible completed-history window changes.
        var historyScope: String? = nil
    }

    struct Checkpoint: Sendable, Equatable {
        let scope: Scope
        var token: String? = nil
        var ctag: String? = nil
        var lastIntegrity: Date? = nil
        var hasCompletedBaseline = false
    }

    /// Each callback must return only after its changes are durable. It may throw
    /// on cancellation/save failure; imported href/ETags then allow a later resume.
    struct Callbacks: Sendable {
        var progress: (@Sendable (SyncProgress.Stage, Int, Int?) async -> Void)? = nil
        let applyBodies: @Sendable ([CalDAVClient.RemoteTask]) async throws -> Void
        let deleteExplicit: @Sendable ([String]) async throws -> Void
        let reconcileCompleteManifest: @Sendable ([CalDAVClient.RemoteResource]) async throws -> Void
        let commitCheckpoint: @Sendable (Checkpoint) async throws -> Void
    }

    enum PullError: Error, Equatable {
        case alreadyRunning
        case incompleteBatch
        case etagChanged(href: String)
        case invalidContinuation
    }

    private let transport: any SyncCollectionPullTransport
    private let now: @Sendable () -> Date
    private var isRunning = false
    private static let batchSize = 100
    private static let integrityInterval: TimeInterval = 600

    init(client: CalDAVClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = client
        self.now = now
    }

    init(transport: any SyncCollectionPullTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    /// `knownETags` describes already durable full bodies, including interrupted imports.
    /// The parent supplies canonical hrefs and preserves dirty edits/history inside callbacks.
    /// `checkpointEligible = false` forces manifest accounting without persisting a cursor.
    /// `forceBodies` also forces a manifest, for a category/history catch-up pass.
    /// Concurrent calls on this coordinator are rejected to keep callbacks serial.
    @discardableResult
    func pull(baseURL: String, calendar: CalDAVClient.RemoteCalendar,
              credentials: CalDAVClient.Credentials, scope: Scope, checkpoint: Checkpoint?,
              knownETags: [String: String], checkpointEligible: Bool = true,
              forceIntegrity: Bool = false, forceBodies: Bool = false,
              callbacks: Callbacks) async throws -> Checkpoint? {
        guard !isRunning else { throw PullError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()

        var cursor = checkpointEligible && checkpoint?.scope == scope
            ? checkpoint! : Checkpoint(scope: scope)
        let startedAt = now()
        let integrityDue = cursor.lastIntegrity.map {
            startedAt.timeIntervalSince($0) >= Self.integrityInterval || $0 > startedAt
        } ?? true
        let requiresManifest = forceIntegrity || forceBodies || integrityDue || !cursor.hasCompletedBaseline

        // Only advertised capability loss and valid-sync-token failure invalidate
        // a token. Ordinary 403, 401, malformed/limited responses propagate unchanged.
        if checkpointEligible && !calendar.supportsSyncCollection && cursor.token != nil {
            cursor.token = nil
            try await commit(cursor, callbacks: callbacks)
        }

        if checkpointEligible, cursor.hasCompletedBaseline, !requiresManifest,
           calendar.supportsSyncCollection, let token = cursor.token, !token.isEmpty {
            do {
                return try await pullDelta(baseURL: baseURL, calendar: calendar, credentials: credentials,
                    cursor: cursor, knownETags: knownETags, callbacks: callbacks)
            } catch CalDAVSyncError.invalidSyncToken {
                cursor.token = nil
                cursor.ctag = nil
                cursor.lastIntegrity = nil
                try await commit(cursor, callbacks: callbacks)
            }
        } else if checkpointEligible, !requiresManifest, !calendar.ctag.isEmpty,
                  cursor.ctag == calendar.ctag {
            return cursor
        }

        // Capture the discovery token BEFORE fetching the inventory. A token
        // discovered after the scan could skip concurrent changes absent from it.
        let baselineToken = calendar.supportsSyncCollection && !calendar.syncToken.isEmpty
            ? calendar.syncToken : nil
        try Task.checkCancellation()
        await callbacks.progress?(.inventory, 0, nil)
        let manifest = try await transport.fetchTaskManifest(baseURL: baseURL,
            calendarPath: calendar.href, credentials: credentials)
        try Task.checkCancellation()
        try validateResources(manifest)
        try await applyResources(manifest, baseURL: baseURL, calendarPath: calendar.href,
            credentials: credentials, knownETags: knownETags, forceBodies: forceBodies, callbacks: callbacks)
        try Task.checkCancellation()
        await callbacks.progress?(.finishing, manifest.count, manifest.count)
        try await callbacks.reconcileCompleteManifest(manifest)
        try Task.checkCancellation()

        guard checkpointEligible else { return nil }
        cursor = Checkpoint(scope: scope, token: baselineToken, ctag: calendar.ctag,
            lastIntegrity: startedAt, hasCompletedBaseline: true)
        try await commit(cursor, callbacks: callbacks)
        return cursor
    }

    private func pullDelta(baseURL: String, calendar: CalDAVClient.RemoteCalendar,
                           credentials: CalDAVClient.Credentials, cursor initial: Checkpoint,
                           knownETags: [String: String], callbacks: Callbacks) async throws -> Checkpoint {
        var cursor = initial
        var known = knownETags
        var seenTokens: Set<String> = []
        while let token = cursor.token {
            try Task.checkCancellation()
            seenTokens.insert(token)
            let page = try await transport.fetchSyncDelta(baseURL: baseURL, calendarPath: calendar.href,
                syncToken: token, credentials: credentials)
            try Task.checkCancellation()
            guard !page.nextToken.isEmpty,
                  !page.hasMore || !seenTokens.contains(page.nextToken) else {
                throw PullError.invalidContinuation
            }
            try validateResources(page.resources)
            let deleted = Set(page.deletedHrefs)
            guard deleted.count == page.deletedHrefs.count, !deleted.contains(""),
                  deleted.isDisjoint(with: page.resources.map(\.href)) else {
                throw PullError.incompleteBatch
            }
            try await applyResources(page.resources, baseURL: baseURL, calendarPath: calendar.href,
                credentials: credentials, knownETags: known, forceBodies: false, callbacks: callbacks)
            if !page.deletedHrefs.isEmpty {
                try Task.checkCancellation()
                try await callbacks.deleteExplicit(page.deletedHrefs)
                try Task.checkCancellation()
            }
            // A page may be replayed if its commit fails. The caller's operations
            // must be idempotent and their durable href/ETags remain authoritative.
            for resource in page.resources { known[resource.href] = resource.etag }
            for href in page.deletedHrefs { known.removeValue(forKey: href) }
            cursor.token = page.nextToken
            if !page.hasMore { cursor.ctag = calendar.ctag }
            try await commit(cursor, callbacks: callbacks)
            if !page.hasMore { return cursor }
        }
        throw PullError.invalidContinuation
    }

    private func validateResources(_ resources: [CalDAVClient.RemoteResource]) throws {
        var seen: Set<String> = []
        for resource in resources {
            guard !resource.href.isEmpty, !resource.etag.isEmpty,
                  seen.insert(resource.href).inserted else { throw PullError.incompleteBatch }
        }
    }

    private func applyResources(_ resources: [CalDAVClient.RemoteResource], baseURL: String,
                                calendarPath: String, credentials: CalDAVClient.Credentials,
                                knownETags: [String: String], forceBodies: Bool,
                                callbacks: Callbacks) async throws {
        // Inventory entries are small values. Keep only one body request/application
        // in flight; neither this layer nor the inventory claims a total byte cap.
        let needed = resources.filter { forceBodies || knownETags[$0.href] != $0.etag }
        var completed = 0
        await callbacks.progress?(.downloading, 0, needed.count)
        var batch: [CalDAVClient.RemoteResource] = []
        batch.reserveCapacity(Self.batchSize)
        for resource in needed {
            try Task.checkCancellation()
            batch.append(resource)
            if batch.count == Self.batchSize {
                try await applyBatch(batch, baseURL: baseURL, calendarPath: calendarPath,
                    credentials: credentials, callbacks: callbacks)
                completed += batch.count
                await callbacks.progress?(.downloading, completed, needed.count)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            try await applyBatch(batch, baseURL: baseURL, calendarPath: calendarPath,
                credentials: credentials, callbacks: callbacks)
            completed += batch.count
            await callbacks.progress?(.downloading, completed, needed.count)
        }
    }

    private func applyBatch(_ resources: [CalDAVClient.RemoteResource], baseURL: String,
                            calendarPath: String, credentials: CalDAVClient.Credentials,
                            callbacks: Callbacks) async throws {
        try Task.checkCancellation()
        let bodies: [CalDAVClient.RemoteTask]
        do {
            bodies = try await transport.fetchTaskBatch(baseURL: baseURL, calendarPath: calendarPath,
                hrefs: resources.map(\.href), credentials: credentials)
        } catch {
            try Task.checkCancellation()
            guard resources.count > 1, Self.isBatchLimit(error) else { throw error }
            let middle = resources.count / 2
            try await applyBatch(Array(resources[..<middle]), baseURL: baseURL, calendarPath: calendarPath,
                credentials: credentials, callbacks: callbacks)
            try await applyBatch(Array(resources[middle...]), baseURL: baseURL, calendarPath: calendarPath,
                credentials: credentials, callbacks: callbacks)
            return
        }
        try Task.checkCancellation()
        let expected = Dictionary(uniqueKeysWithValues: resources.map { ($0.href, $0.etag) })
        var seen: Set<String> = []
        guard bodies.count == resources.count else { throw PullError.incompleteBatch }
        for body in bodies {
            guard let etag = expected[body.href], seen.insert(body.href).inserted,
                  !body.icsData.isEmpty else { throw PullError.incompleteBatch }
            // A race is not a complete scan, even if every href was returned.
            // Revalidate next run before any snapshot-absence reconciliation.
            guard body.etag == etag else { throw PullError.etagChanged(href: body.href) }
        }
        try await callbacks.applyBodies(bodies)
        try Task.checkCancellation()
    }

    private static func isBatchLimit(_ error: any Error) -> Bool {
        if error is DAVResponseLimitError { return true }
        if case CalDAVError.serverError(statusCode: 507) = error { return true }
        if let error = error as? HTTPRetryError { return error.statusCode == 507 }
        return false
    }

    private func commit(_ cursor: Checkpoint, callbacks: Callbacks) async throws {
        try Task.checkCancellation()
        try await callbacks.commitCheckpoint(cursor)
        try Task.checkCancellation()
    }
}
