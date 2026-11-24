import Foundation
import SwiftData

/// Only committed values cross the transport boundary. Every mutation has a durable intent.
@MainActor
final class NextcloudCalendarSyncManager {
    private let transport: any NextcloudCalendarTransport
    private let keychainManager: KeychainManager
    private let reader = CalendarSnapshotReader()
    private let makeCommitContext: @MainActor (ModelContainer, CommitPhase) -> ModelContext

    // Account IDs serialize destination allocation and writes even across separate manager instances.
    private static var writers: [String: [CheckedContinuation<Void, Never>]] = [:]
    // Retain a negative observation across a local save error until it can be committed.
    private static var contradictions = Set<UUID>()
    private struct StaleOperation: Error {}
    enum CommitPhase { case prepareDestination, proveDestination, holdDestination, prepareEvent, acknowledgeEvent }

    private struct Invocation: Sendable {
        let admitted: CommittedAccountCredentials
        let discovery: NextcloudDiscoverySeed.Selection
        let container: ModelContainer
        var lifecycle: Lifecycle? = nil
    }

    private struct Lifecycle: Sendable {
        let origin: CalendarTaskSnapshot
        let desired: CalendarTaskSnapshot?
        let purge: CalendarMirrorState.Ticket?
        let isEnabled: @MainActor @Sendable () -> Bool
    }

    init(transport: any NextcloudCalendarTransport = NextcloudCalendarHTTPTransport(),
         keychainManager: KeychainManager = KeychainManager(),
         makeCommitContext: @escaping @MainActor (ModelContainer, CommitPhase) -> ModelContext = { container, _ in ModelContext(container) }) {
        self.transport = transport
        self.keychainManager = keychainManager
        self.makeCommitContext = makeCommitContext
    }

    @discardableResult
    func reconcileManaged(accountID: String, container: ModelContainer, taskIDs: Set<String>? = nil,
                          isEnabled: @escaping @MainActor @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "nextcloudCalendarSyncEnabled") },
                          onCommit: @MainActor () -> Void = {}) async throws -> Bool {
        guard isEnabled(), !container.mainContext.hasChanges else { return false }
        if Self.writers[accountID] == nil { Self.writers[accountID] = [] }
        else { await withCheckedContinuation { Self.writers[accountID, default: []].append($0) } }
        defer {
            if Self.writers[accountID]?.isEmpty == false { Self.writers[accountID]?.removeFirst().resume() }
            else { Self.writers.removeValue(forKey: accountID) }
        }
        try Task.checkCancellation()
        guard isEnabled(), !container.mainContext.hasChanges else { return false }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let account = try context.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })).first,
              account.mode != .vault else { throw CalendarReceiptStore.Held() }
        let scope = AccountCredentialScope(account)
        guard let destination = try CalendarReceiptStore.destination(for: scope, in: context) else { return false }
        // Shared prepared collection state is not authority to create an event on launch.
        guard destination.owned else { throw CalendarReceiptStore.Held() }
        let keys = try CalendarReceiptStore.eventKeys(for: destination, in: context)
        let selection = try NextcloudDiscoverySeed.capture(accountID: accountID, serverURL: scope.serverBaseURL, in: context)
        let admitted: CommittedAccountCredentials
        switch try await AccountManager.admitCredentials(accountID: accountID, expected: scope, container: container, keychainManager: keychainManager) {
        case .available(let value): admitted = value
        case .deferred(let reason): throw reason
        case .missing: throw CalDAVError.unauthorized
        }
        let cutoff = ContinuousClock.now.advanced(by: .seconds(45))
        return try await DAVDiscoveryContext.$deadline.withValue(min(DAVDiscoveryContext.deadline ?? cutoff, cutoff)) {
            try await ServerRetryAdmission.$current.withValue(ServerRetryAdmission.current?.forAccount(accountID)) {
                var changed = false
                var firstHold: (any Error)?
                var verified: CalendarDestinationReceipt?
                defer { if changed { onCommit() } }
                for key in keys {
                    try Task.checkCancellation()
                    do {
                        let fresh = ModelContext(container)
                        fresh.autosaveEnabled = false
                        guard let event = try CalendarReceiptStore.managedEvent(key: key, destination: destination, taskIDs: taskIDs, in: fresh),
                              !event.wasRemoved || event.pending != nil else { continue }
                        guard let origin = event.lifecycleOrigin,
                              let identity = origin.mirrorIdentity else { throw CalendarReceiptStore.Held() }
                        let id = event.taskID
                        let live = try fresh.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
                        let desired = try live.map { try CalendarTaskSnapshot($0, account: scope, role: .managedMirror) }
                        let purge = live == nil ? try CalendarMirrorState.purge(for: identity, in: fresh) : nil
                        guard desired?.mirrorIdentity == identity || (live == nil && purge != nil) else { throw CalendarReceiptStore.Held() }
                        let snapshot = desired ?? origin
                        var invocation = Invocation(admitted: admitted, discovery: selection, container: container)
                        invocation.lifecycle = Lifecycle(origin: origin, desired: desired, purge: purge, isEnabled: isEnabled)
                        _ = try currentContext(snapshot, invocation: invocation)
                        if event.pending == nil, let desired, !desired.deleted, desired.hasDueDate,
                           event.acknowledged?.contentProof == desired.contentProof { continue }
                        if verified == nil { verified = try await verifyDestination(destination, for: snapshot, invocation: invocation) }
                        guard let binding = verified else { throw CalendarReceiptStore.Held() }
                        let remove = desired == nil || snapshot.deleted || !snapshot.hasDueDate
                        var expectedEvent = event
                        if let pending = event.pending, pending.snapshot != snapshot || (remove && pending.kind != .remove) {
                            let old = Prepared(binding: binding, event: event, intent: pending, recovering: true)
                            let transition = try await recoverManagedOutcome(old, removalRequested: remove, invocation: invocation)
                            changed = true
                            let refreshed = try currentContext(snapshot, invocation: invocation)
                            guard let recovered = try CalendarReceiptStore.event(for: snapshot, destination: binding, in: refreshed),
                                  recovered == transition else {
                                throw CalendarReceiptStore.Held()
                            }
                            if recovered.wasRemoved { continue }
                            expectedEvent = recovered
                        }
                        var inventory = CalendarReceiptStore.Inventory()
                        if let prepared = try prepare(snapshot, remove: remove, binding: binding, inventory: &inventory,
                                                      invocation: invocation, selected: expectedEvent) {
                            changed = try await perform(prepared, removalRequested: remove, invocation: invocation) || changed
                        }
                    } catch is StaleOperation {
                        if firstHold == nil { firstHold = CalendarReceiptStore.Held() }
                    } catch let error as CalendarReceiptStore.Held {
                        if firstHold == nil { firstHold = error }
                    } catch is CalendarMirrorState.Held {
                        if firstHold == nil { firstHold = CalendarReceiptStore.Held() }
                    } catch let error as CalDAVError {
                        guard case .conflict = error else { throw error }
                        if firstHold == nil { firstHold = error }
                    }
                }
                if let firstHold { throw firstHold }
                return changed
            }
        }
    }

    @discardableResult
    func syncAll(accountID: String, container: ModelContainer,
                 onCommit: @MainActor () -> Void = {}) async throws -> Bool {
        try await sync(accountID: accountID, taskID: nil, role: .managedMirror, container: container, onCommit: onCommit)
    }

    @discardableResult
    func syncSingleTask(taskID: String, accountID: String, role: CalendarEventRole, container: ModelContainer,
                        onCommit: @MainActor () -> Void = {}) async throws -> Bool {
        try await sync(accountID: accountID, taskID: taskID, role: role, container: container, onCommit: onCommit)
    }

    @discardableResult
    func deleteManagedEvent(taskID: String, accountID: String, container: ModelContainer,
                            onCommit: @MainActor () -> Void = {}) async throws -> Bool {
        try await sync(accountID: accountID, taskID: taskID, role: .managedMirror, remove: true,
                       container: container, onCommit: onCommit)
    }

    private func sync(accountID: String, taskID: String?, role: CalendarEventRole, remove: Bool = false,
                      container: ModelContainer, onCommit: @MainActor () -> Void) async throws -> Bool {
        if Self.writers[accountID] == nil {
            Self.writers[accountID] = []
        } else {
            await withCheckedContinuation { Self.writers[accountID, default: []].append($0) }
        }
        defer {
            if Self.writers[accountID]?.isEmpty == false {
                Self.writers[accountID]?.removeFirst().resume()
            } else {
                Self.writers.removeValue(forKey: accountID)
            }
        }
        try Task.checkCancellation()
        guard !container.mainContext.hasChanges,
              let batch = try await reader.read(accountID: accountID, taskID: taskID, includeDeleted: remove,
                                                role: role, container: container),
              !container.mainContext.hasChanges else { return false }

        let admission = try await AccountManager.admitCredentials(accountID: accountID, expected: batch.account,
            container: container, keychainManager: keychainManager)
        let admitted: CommittedAccountCredentials
        switch admission {
        case .available(let credentials): admitted = credentials
        case .missing: throw CalDAVError.unauthorized
        case .deferred: return false
        }
        let invocation = Invocation(admitted: admitted, discovery: batch.discovery, container: container)
        let cutoff = ContinuousClock.now.advanced(by: .seconds(45))
        let deadline = min(DAVDiscoveryContext.deadline ?? cutoff, cutoff)
        do {
            return try await DAVDiscoveryContext.$deadline.withValue(deadline) {
                try await ServerRetryAdmission.$current.withValue(ServerRetryAdmission.current?.forAccount(accountID)) {
                    try await reconcile(batch, remove: remove, bulk: taskID == nil, invocation: invocation, onCommit: onCommit)
                }
            }
        } catch is AccountCredentialDeferral {
            return false
        }
    }

    private func reconcile(_ batch: CalendarSyncBatch, remove: Bool, bulk: Bool, invocation: Invocation,
                           onCommit: @MainActor () -> Void) async throws -> Bool {
        var changed = false
        defer { if changed { onCommit() } }
        var verified: CalendarDestinationReceipt?
        var verificationFailure: (any Error)?
        var inventory = CalendarReceiptStore.Inventory()
        var firstHold: (any Error)?
        for task in batch.tasks {
            do {
                let context = try currentContext(task, invocation: invocation)
                guard task.legacyHref == nil else { throw CalendarReceiptStore.Held() }
                let needsRemoval = remove || !task.hasDueDate
                guard task.role != .manualExport || !needsRemoval else { continue }
                let stored = try CalendarReceiptStore.destination(for: task.account, in: context)
                if bulk, !inventory.loaded, let stored, stored.owned {
                    inventory = try CalendarReceiptStore.inventory(for: stored, in: context)
                }
                if needsRemoval {
                    guard let stored, stored.owned,
                          let event = try CalendarReceiptStore.event(for: task, destination: stored, in: context),
                          event.acknowledged != nil || event.pending != nil else { continue }
                }
                if verified == nil {
                    if let verificationFailure { throw verificationFailure }
                    do {
                        verified = try await verifyDestination(stored, for: task, invocation: invocation)
                    } catch {
                        if !(error is StaleOperation) || stored?.owned != true { verificationFailure = error }
                        throw error
                    }
                }
                guard let verified else { continue }
                let intent = try prepare(task, remove: needsRemoval, binding: verified, inventory: &inventory,
                                         invocation: invocation)
                guard let intent else { continue }
                if try await perform(intent, removalRequested: needsRemoval, invocation: invocation) { changed = true }
            } catch is StaleOperation {
                inventory.verifiedCount = nil
                continue
            } catch let error as CalendarReceiptStore.Held {
                if firstHold == nil { firstHold = error }
            } catch let error as CalDAVError {
                guard case .conflict = error else { throw error }
                if firstHold == nil { firstHold = error }
            }
        }
        if let firstHold { throw firstHold }
        return changed
    }

    private func verifyDestination(_ existing: CalendarDestinationReceipt?, for task: CalendarTaskSnapshot,
                                   invocation: Invocation)
        async throws -> CalendarDestinationReceipt {
        let initial = try currentContext(task, invocation: invocation)
        if let existing, !existing.owned {
            guard existing.state == .prepared else { throw CalendarReceiptStore.Held() }
            if Self.contradictions.contains(existing.id) {
                try holdDestination(existing, container: invocation.container)
                throw CalendarReceiptStore.Held()
            }
            try CalendarReceiptStore.requireNoEventEvidence(for: task.account, in: initial)
        }
        let admitted = invocation.admitted
        let validate: CalendarRequestValidation = { [self] in
            try await validateTask(task, invocation: invocation)
        }
        let discovery = try await transport.discover(address: invocation.discovery.address, admitted: admitted, validate: validate)
        let context = try currentContext(task, invocation: invocation, commit: existing == nil ? .prepareDestination : nil)
        guard try CalendarReceiptStore.destination(for: task.account, in: context) == existing else { throw StaleOperation() }
        let receipt: CalendarDestinationReceipt
        if let existing {
            guard existing.matches(discovery) else { throw CalendarReceiptStore.Held() }
            if existing.state == .prepared {
                try CalendarReceiptStore.requireNoEventEvidence(for: task.account, in: context)
                guard !discovery.collectionAddresses.contains(where: { address in
                    CalendarDestinationReceipt.isReserved(address) && !CalDAVDiscovery.sameCollection(address.requestURL, existing.collection)
                }) else { throw CalendarReceiptStore.Held() }
            }
            receipt = existing
        } else {
            guard !discovery.collectionAddresses.contains(where: CalendarDestinationReceipt.isReserved) else {
                throw CalendarReceiptStore.Held()
            }
            receipt = try CalendarDestinationReceipt(scope: task.account, discovery: discovery)
            try CalendarReceiptStore.store(receipt, in: context)
            try save(context)
        }
        let validateProof: CalendarRequestValidation = { [self] in
            try await validateTask(task, invocation: invocation)
            try await requireBinding(receipt, task: task, invocation: invocation)
        }
        let href: URL
        do {
            if existing == nil {
                href = try await transport.ensureCollection(target: receipt.collection, marker: receipt.marker,
                    create: true, admitted: admitted, validate: validateProof)
            } else {
                do {
                    href = try await transport.ensureCollection(target: receipt.collection, marker: receipt.marker,
                        create: false, admitted: admitted, validate: validateProof)
                } catch CalendarCollectionProofError.absent where receipt.state == .prepared {
                    href = try await transport.ensureCollection(target: receipt.collection, marker: receipt.marker,
                        create: true, admitted: admitted, validate: validateProof)
                }
            }
        } catch CalendarCollectionProofError.contradictoryClaim {
            if receipt.state == .prepared {
                Self.contradictions.insert(receipt.id)
                try holdDestination(receipt, container: invocation.container)
            }
            throw CalendarReceiptStore.Held()
        } catch CalendarCollectionProofError.absent {
            throw CalendarReceiptStore.Held()
        }
        guard CalDAVDiscovery.sameCollection(href, receipt.collection) else { throw CalDAVError.invalidResponse }
        try await validateProof()
        let confirmed = try currentContext(task, invocation: invocation, commit: receipt.owned ? nil : .proveDestination)
        var current = try boundDestination(receipt, task: task, in: confirmed)
        if !current.owned {
            try CalendarReceiptStore.requireNoEventEvidence(for: task.account, in: confirmed)
            current.revision = 2
            current.state = .owned
            try CalendarReceiptStore.store(current, in: confirmed)
            try save(confirmed)
        }
        return current
    }

    private func holdDestination(_ receipt: CalendarDestinationReceipt, container: ModelContainer) throws {
        // Negative evidence belongs to the exact prepared binding even after the initiating task changes.
        let context = makeCommitContext(container, .holdDestination)
        context.autosaveEnabled = false
        guard var current = try CalendarReceiptStore.destination(for: receipt.scope, in: context),
              current.state == .prepared, current.matchesBinding(receipt) else { throw StaleOperation() }
        current.state = .held
        current.revision = 2
        try CalendarReceiptStore.store(current, in: context)
        try save(context)
        Self.contradictions.remove(receipt.id)
    }

    private struct Prepared {
        let binding: CalendarDestinationReceipt
        let event: CalendarEventReceipt
        let intent: CalendarEventIntent
        let recovering: Bool
    }

    private func prepare(_ snapshot: CalendarTaskSnapshot, remove: Bool, binding: CalendarDestinationReceipt,
                         inventory: inout CalendarReceiptStore.Inventory, invocation: Invocation,
                         selected: CalendarEventReceipt? = nil) throws -> Prepared? {
        let context = try currentContext(snapshot, invocation: invocation)
        let current = try boundDestination(binding, task: snapshot, in: context)
        let existing = try CalendarReceiptStore.event(for: snapshot, destination: current, in: context)
        if let selected, existing != selected { throw CalendarReceiptStore.Held() }
        if existing != nil { inventory.observed.insert(try CalendarReceiptKey.event(task: snapshot, binding: current.id)) }
        if let existing, let pending = existing.pending {
            guard pending.snapshot == snapshot, !remove || pending.kind == .remove else {
                throw CalendarReceiptStore.Held()
            }
            return Prepared(binding: current, event: existing, intent: pending, recovering: true)
        }
        if remove {
            guard existing?.acknowledged != nil else { return nil }
        } else if existing?.acknowledged?.contentProof == snapshot.contentProof {
            return nil
        }
        let commit = try currentContext(snapshot, invocation: invocation, commit: .prepareEvent)
        let destination = try boundDestination(current, task: snapshot, in: commit)
        let task = try matchingTask(snapshot, in: commit)
        guard (task != nil || (remove && invocation.lifecycle?.purge != nil)),
              try CalendarReceiptStore.event(for: snapshot, destination: destination, in: commit) == existing else {
            throw StaleOperation()
        }
        var event = try existing ?? CalendarEventReceipt(task: snapshot, destination: destination)
        let operation = UUID()
        let stamp = Date()
        let body: String?
        if remove { body = nil }
        else {
            guard let task else { throw StaleOperation() }
            body = try NextcloudEventBody.make(task: task, uid: event.target.uid, operation: operation, stamp: stamp)
        }
        let kind: CalendarEventIntent.Kind = remove ? .remove : event.acknowledged == nil ? .create : .update
        let intent = CalendarEventIntent(kind: kind, target: event.target, bindingID: destination.id,
            bindingRevision: destination.revision, receiptRevision: event.revision, operation: operation,
            snapshot: snapshot, priorVersion: event.acknowledged?.version, stamp: stamp,
            body: body, bodyProof: body.map(SyncResourceState.fingerprint))
        guard event.revision < Int.max - 2 else { throw CalendarReceiptStore.Held() }
        event.revision += 1
        event.pending = intent
        if existing == nil {
            try BackgroundRunBudget.protectingCurrent {
                try CalendarReceiptStore.add(event, task: snapshot, destination: destination, inventory: &inventory, in: commit)
            }
        } else {
            try CalendarReceiptStore.store(event, task: snapshot, destination: destination, in: commit)
            try save(commit)
        }
        return Prepared(binding: destination, event: event, intent: intent, recovering: false)
    }

    private func perform(_ prepared: Prepared, removalRequested: Bool, invocation: Invocation) async throws -> Bool {
        let intent = prepared.intent
        let admitted = invocation.admitted
        let validate: CalendarRequestValidation = { [self] in
            try await validateTask(intent.snapshot, invocation: invocation)
            try await requirePending(prepared, invocation: invocation)
        }
        let version: CalendarEventVersion?
        if prepared.recovering {
            version = try await recover(prepared, mayRetryCreate: true, mayRetryRemoval: removalRequested,
                admitted: admitted, validate: validate)
        } else if intent.kind == .remove {
            try await transport.remove(intent, admitted: admitted, validate: validate)
            version = nil
        } else if let result = try await put(intent, admitted: admitted, validate: validate) {
            version = result
        } else {
            // The write and proof can be separated by remote replacement of the collection.
            let href = try await transport.ensureCollection(target: prepared.binding.collection, marker: prepared.binding.marker,
                create: false, admitted: admitted, validate: validate)
            guard CalDAVDiscovery.sameCollection(href, prepared.binding.collection) else { throw CalDAVError.invalidResponse }
            version = try await recover(prepared, mayRetryCreate: false, mayRetryRemoval: false,
                admitted: admitted, validate: validate)
        }
        try await validate()
        return try acknowledge(prepared, version: version, invocation: invocation)
    }

    /// Only this managed path separates an old operation's proof from today's desired state.
    /// The invocation still pins today's row or committed purge, source, credentials and seed.
    private func recoverManagedOutcome(_ prepared: Prepared, removalRequested: Bool,
                                       invocation: Invocation) async throws -> CalendarEventReceipt {
        guard invocation.lifecycle != nil, prepared.intent.snapshot.role == .managedMirror else { throw StaleOperation() }
        let validate: CalendarRequestValidation = { [self] in
            try await validateTask(prepared.intent.snapshot, invocation: invocation)
            try await requirePending(prepared, invocation: invocation)
        }
        // T7's exact-baseline DELETE recovery is the single removal retry mechanism.
        if prepared.intent.kind == .remove {
            let version = try await recover(prepared, mayRetryCreate: false, mayRetryRemoval: removalRequested,
                                            admitted: invocation.admitted, validate: validate)
            try await validate()
            return try acknowledgeReceipt(prepared, version: version, invocation: invocation)
        }
        let intent = prepared.intent
        switch try await transport.read(target: intent.target, admitted: invocation.admitted, validate: validate) {
        case .present(let version, let operation, let proof) where operation == intent.operation && proof == intent.bodyProof:
            try await validate()
            return try acknowledgeReceipt(prepared, version: version, invocation: invocation)
        case .absent where intent.kind == .create && prepared.event.acknowledged == nil:
            try await validate()
            let context = try currentContext(intent.snapshot, invocation: invocation, commit: .acknowledgeEvent)
            let binding = try boundDestination(prepared.binding, task: intent.snapshot, in: context)
            guard var event = try CalendarReceiptStore.event(for: intent.snapshot, destination: binding, in: context),
                  event == prepared.event, event.revision == 1 else { throw StaleOperation() }
            event.pending = nil
            event.wasRemoved = true
            event.cancelledFirstCreate = true
            event.revision = 2
            try CalendarReceiptStore.store(event, task: intent.snapshot, destination: binding, in: context)
            try save(context)
            return event
        default: throw CalDAVError.conflict(etag: nil)
        }
    }

    private func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                     validate: @escaping CalendarRequestValidation) async throws -> CalendarEventVersion? {
        do {
            switch try await transport.put(intent, admitted: admitted, validate: validate) {
            case .acknowledged(let version): return version
            case .indeterminate: return nil
            }
        } catch CalDAVError.conflict {
            return nil
        } catch CalDAVError.serverError(let code) where (500...599).contains(code) && code != 507 {
            return nil
        } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
            return nil
        }
    }

    private func recover(_ prepared: Prepared, mayRetryCreate: Bool, mayRetryRemoval: Bool, admitted: CommittedAccountCredentials,
                         validate: @escaping CalendarRequestValidation) async throws -> CalendarEventVersion? {
        let intent = prepared.intent
        switch try await transport.read(target: intent.target, admitted: admitted, validate: validate) {
        case .present(let version, let operation, let proof) where intent.kind != .remove
            && operation == intent.operation && proof == intent.bodyProof:
            return version
        case .absent where intent.kind == .remove:
            return nil
        case .present(let version, let operation, let proof) where intent.kind == .remove && mayRetryRemoval:
            if let owned = prepared.event.acknowledged, owned.version == intent.priorVersion,
               version == owned.version, operation == owned.operation, proof == owned.bodyProof {
                try await transport.remove(intent, admitted: admitted, validate: validate)
                return nil
            }
        case .absent where mayRetryCreate && intent.kind == .create:
            if let version = try await put(intent, admitted: admitted, validate: validate) { return version }
        default:
            break
        }
        throw CalDAVError.conflict(etag: nil)
    }

    private func acknowledge(_ prepared: Prepared, version: CalendarEventVersion?, invocation: Invocation) throws -> Bool {
        _ = try acknowledgeReceipt(prepared, version: version, invocation: invocation)
        return true
    }

    private func acknowledgeReceipt(_ prepared: Prepared, version: CalendarEventVersion?, invocation: Invocation) throws -> CalendarEventReceipt {
        let intent = prepared.intent
        let snapshot = intent.snapshot
        let context = try currentContext(snapshot, invocation: invocation, commit: .acknowledgeEvent)
        let binding = try boundDestination(prepared.binding, task: snapshot, in: context)
        guard var event = try CalendarReceiptStore.event(for: snapshot, destination: binding, in: context),
              event == prepared.event, event.pending == intent else { throw StaleOperation() }
        if let version, let bodyProof = intent.bodyProof, intent.kind != .remove,
           intent.target.version(version.etag) == version {
            event.acknowledged = .init(version: version, operation: intent.operation, bodyProof: bodyProof,
                                       contentProof: snapshot.contentProof)
            event.wasRemoved = false
            event.cancelledFirstCreate = nil
        } else if intent.kind == .remove && version == nil {
            event.acknowledged = nil
            event.wasRemoved = true
        } else {
            throw CalDAVError.invalidResponse
        }
        event.pending = nil
        event.revision += 1
        try CalendarReceiptStore.store(event, task: snapshot, destination: binding, in: context)
        try save(context)
        return event
    }

    private func validateTask(_ task: CalendarTaskSnapshot, invocation: Invocation) async throws {
        _ = try currentContext(task, invocation: invocation)
        switch try await AccountManager.admitCredentials(accountID: task.account.id, expected: task.account,
            container: invocation.container, keychainManager: keychainManager) {
        case .available(let current):
            guard current.password.utf8.elementsEqual(invocation.admitted.password.utf8) else {
                throw AccountCredentialDeferral.staleAccount
            }
        case .deferred(let reason): throw reason
        case .missing: throw CalDAVError.unauthorized
        }
        _ = try currentContext(task, invocation: invocation)
    }

    private func requireBinding(_ expected: CalendarDestinationReceipt, task: CalendarTaskSnapshot,
                                invocation: Invocation) throws {
        let context = try currentContext(task, invocation: invocation)
        let current = try boundDestination(expected, task: task, in: context)
        if current.state == .prepared {
            guard !Self.contradictions.contains(current.id) else { throw CalendarReceiptStore.Held() }
            try CalendarReceiptStore.requireNoEventEvidence(for: task.account, in: context)
        }
    }

    private func requirePending(_ prepared: Prepared, invocation: Invocation) throws {
        let task = prepared.intent.snapshot
        let context = try currentContext(task, invocation: invocation)
        let binding = try boundDestination(prepared.binding, task: task, in: context)
        guard try CalendarReceiptStore.event(for: task, destination: binding, in: context) == prepared.event else {
            throw StaleOperation()
        }
    }

    private func boundDestination(_ expected: CalendarDestinationReceipt, task: CalendarTaskSnapshot,
                                  in context: ModelContext) throws -> CalendarDestinationReceipt {
        guard let current = try CalendarReceiptStore.destination(for: task.account, in: context),
              current.matchesBinding(expected) else { throw StaleOperation() }
        return current
    }

    private func currentContext(_ task: CalendarTaskSnapshot, invocation: Invocation, commit: CommitPhase? = nil) throws -> ModelContext {
        try BackgroundBudgetExhausted.checkAdmission(BackgroundRunBudget.current)
        if let deadline = DAVDiscoveryContext.deadline, ContinuousClock.now >= deadline { throw BackgroundBudgetExhausted() }
        let container = invocation.container
        guard !container.mainContext.hasChanges else { throw StaleOperation() }
        let context = commit.map { makeCommitContext(container, $0) } ?? ModelContext(container)
        context.autosaveEnabled = false
        if let lifecycle = invocation.lifecycle {
            guard lifecycle.isEnabled(), let identity = lifecycle.origin.mirrorIdentity,
                  task.id == lifecycle.origin.id, task.uid == lifecycle.origin.uid,
                  task.created == lifecycle.origin.created, task.role == .managedMirror,
                  task.account == lifecycle.origin.account else { throw StaleOperation() }
            let accountID = task.account.id
            guard let account = try context.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })).first,
                  AccountCredentialScope(account) == task.account else { throw StaleOperation() }
            let id = identity.taskID
            let live = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first
            if let desired = lifecycle.desired {
                guard let live, CalendarMirrorState.Identity(live) == identity, try desired.matches(live) else { throw StaleOperation() }
            } else {
                guard live == nil, let purge = lifecycle.purge, purge.purged, purge.identity == identity else {
                    throw StaleOperation()
                }
                let purgeTickets: [CalendarMirrorState.Ticket]
                do { purgeTickets = try CalendarMirrorState.purgeEvidence(for: id, in: context) }
                catch is CalendarMirrorState.Held { throw StaleOperation() }
                guard purgeTickets.contains(purge),
                      purgeTickets.allSatisfy({ $0.identity.isValid && $0.identity == identity }) else {
                    throw StaleOperation()
                }
            }
        } else {
            guard try matchingTask(task, in: context) != nil else { throw StaleOperation() }
        }
        guard try invocation.discovery.isCurrent(in: context) else { throw AccountCredentialDeferral.staleAccount }
        return context
    }

    private func matchingTask(_ snapshot: CalendarTaskSnapshot, in context: ModelContext) throws -> TaskItem? {
        let accountID = snapshot.account.id
        guard let account = try context.fetch(FetchDescriptor<ServerAccount>(predicate: #Predicate { $0.id == accountID })).first,
              AccountCredentialScope(account) == snapshot.account else { return nil }
        let taskID = snapshot.id
        guard let task = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == taskID })).first,
              try snapshot.matches(task) else { return nil }
        return task
    }

    private func save(_ context: ModelContext) throws {
        try BackgroundRunBudget.protectingCurrent { try context.save() }
    }
}
