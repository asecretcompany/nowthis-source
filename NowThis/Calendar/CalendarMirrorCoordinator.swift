import Foundation
import SwiftData

/// One app-owned consumer. Extensions only commit CalendarMirrorState tickets.
@MainActor
final class CalendarMirrorCoordinator {
    private let container: ModelContainer
    private let nextcloud: NextcloudCalendarSyncManager
    private let apple: AppleCalendarSyncManager
    private let appleEnabled: @MainActor @Sendable () -> Bool
    private let nextcloudEnabled: @MainActor @Sendable () -> Bool
    private let onFailure: @MainActor (String) -> Void
    private let debounce: Duration
    private var observation: CalendarMirrorObservation?
    private var active: Task<Void, Never>?
    private var cursor: String?
    private var foreground = true
    private var wakeRequested = false
    private var forceReplayRequested = false
    private(set) var pendingWork: Task<Void, Never>?

    init(container: ModelContainer, nextcloud: NextcloudCalendarSyncManager = NextcloudCalendarSyncManager(),
         apple: AppleCalendarSyncManager? = nil,
         appleEnabled: @escaping @MainActor @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "appleCalendarSyncEnabled") },
         nextcloudEnabled: @escaping @MainActor @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "nextcloudCalendarSyncEnabled") },
         debounce: Duration = .milliseconds(400),
         onFailure: @escaping @MainActor (String) -> Void = { ViewPersistence.reportCalendarFailure($0) }) {
        self.container = container; self.nextcloud = nextcloud
        self.apple = apple ?? AppleCalendarSyncManager(permissionManager: CalendarPermissionManager())
        self.appleEnabled = appleEnabled; self.nextcloudEnabled = nextcloudEnabled
        self.debounce = debounce; self.onFailure = onFailure
    }

    func startObserving() {
        guard observation == nil else { return }
        observation = CalendarMirrorObservation(NotificationCenter.default.addObserver(
            forName: CalendarMirrorState.didCommit, object: nil, queue: .main
        ) { [weak self] notification in
            let key = notification.object as? String
            MainActor.assumeIsolated {
                guard let self, key == CalendarMirrorState.storeKey(self.container) else { return }
                self.request()
            }
        })
    }

    /// New tickets wake work; receipt-only saves cannot repeatedly retry a held operation.
    @discardableResult
    func request() -> Task<Void, Never>? {
        guard foreground else { return nil }
        if let active { wakeRequested = true; return active }
        if let pendingWork { return pendingWork }
        pendingWork = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: debounce) } catch { return }
            self.pendingWork = nil
            await self.start(force: false)
        }
        return pendingWork
    }

    func reconcileNow() async {
        foreground = true
        pendingWork?.cancel(); pendingWork = nil
        await start(force: true)
    }

    func pause() {
        foreground = false
        pendingWork?.cancel(); pendingWork = nil
        active?.cancel()
    }

    private func start(force: Bool) async {
        if let active {
            if force { forceReplayRequested = true }
            await active.value
            return
        }
        if force { cursor = nil }
        let run = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.drain(scanExisting: force)
        }
        active = run
        await withTaskCancellationHandler { await run.value } onCancel: { run.cancel() }
        active = nil
        if foreground, forceReplayRequested {
            forceReplayRequested = false
            await start(force: true)
            return
        }
        if wakeRequested {
            wakeRequested = false
            request()
        }
    }

    private func drain(scanExisting: Bool) async {
        guard foreground, !container.mainContext.hasChanges else { return }
        var firstFailure: (any Error)?
        var scanExisting = scanExisting
        var wrapped = false
        var scannedThisPass = Set<String>()
        // A pass admits at most 1,000 tickets, in batches of 100, under one external deadline.
        let cutoff = ContinuousClock.now.advanced(by: .seconds(45))
        await DAVDiscoveryContext.$deadline.withValue(min(DAVDiscoveryContext.deadline ?? cutoff, cutoff)) {
            for _ in 0..<10 {
                guard foreground, !Task.isCancelled, !container.mainContext.hasChanges,
                      ContinuousClock.now < cutoff else { break }
                do {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    let page = try CalendarMirrorState.pendingPage(in: context,
                        excluding: wrapped ? scannedThisPass : [], afterID: cursor, limit: 100)
                    let noMorePhysicalWork: Bool
                    if let nextCursor = page.nextCursor {
                        cursor = nextCursor
                        scannedThisPass.formUnion(page.scannedIDs)
                        noMorePhysicalWork = false
                    } else {
                        if cursor != nil && !wrapped {
                            cursor = nil
                            wrapped = true
                            continue
                        }
                        cursor = nil
                        guard scanExisting else { break }
                        noMorePhysicalWork = true
                    }
                    let tickets = page.tickets
                    if page.hasUnidentifiedRecord, firstFailure == nil {
                        firstFailure = CalendarMirrorState.Held.invalidRecord
                    }
                    if tickets.isEmpty && !scanExisting && !page.hasMore { break }
                    var retained = Set(tickets.filter { !$0.identity.isValid }.map(\.taskID))
                    if !retained.isEmpty, firstFailure == nil { firstFailure = CalendarMirrorState.Held.invalidRecord }
                    let actionable = tickets.filter { $0.identity.isValid }
                    let requested = Set(actionable.map(\.taskID))
                    let filter: Set<String>? = scanExisting ? nil : requested
                    var retainAll = page.hasUnidentifiedRecord
                    do {
                        let ids = try apple.managedTaskIDs(container: container)
                        let relevant = filter.map { ids.intersection($0) } ?? ids
                        if !relevant.isEmpty {
                            if appleEnabled() {
                                do {
                                    _ = try apple.reconcileManaged(container: container, taskIDs: relevant, isEnabled: appleEnabled)
                                    if !appleEnabled() { retained.formUnion(relevant) }
                                } catch {
                                    retained.formUnion(relevant)
                                    if firstFailure == nil { firstFailure = error }
                                }
                            } else { retained.formUnion(relevant) }
                        }
                    } catch {
                        retainAll = true
                        if firstFailure == nil { firstFailure = error }
                    }
                    let destinations = try CalendarReceiptStore.destinationInventory(in: context)
                    retainAll = retainAll || destinations.held
                    if destinations.hasUnmatchedEvidence {
                        retained.formUnion(actionable.map(\.taskID))
                    }
                    if destinations.held, firstFailure == nil { firstFailure = CalendarReceiptStore.Held() }
                    for scope in destinations.scopes {
                        guard !Task.isCancelled else { throw CancellationError() }
                        do {
                            let inventory = try CalendarReceiptStore.managedTaskInventory(for: scope, in: ModelContext(container))
                            let relevant = filter.map { inventory.taskIDs.intersection($0) } ?? inventory.taskIDs
                            if inventory.held {
                                // A task may be mirrored to a destination account other than
                                // its source account. If that destination's receipt inventory
                                // is damaged, its missing row cannot be mapped from the ticket.
                                // Retain unmatched work conservatively while still processing
                                // every independently verified receipt above.
                                let unresolved = actionable.filter { !inventory.taskIDs.contains($0.taskID) }
                                retained.formUnion(unresolved.map(\.taskID))
                                if firstFailure == nil { firstFailure = CalendarReceiptStore.Held() }
                            }
                            guard !relevant.isEmpty else { continue }
                            if nextcloudEnabled() {
                                do {
                                    _ = try await nextcloud.reconcileManaged(accountID: scope.id, container: container,
                                        taskIDs: relevant, isEnabled: nextcloudEnabled)
                                    if !nextcloudEnabled() { retained.formUnion(relevant) }
                                } catch {
                                    retained.formUnion(relevant)
                                    if firstFailure == nil { firstFailure = error }
                                }
                            } else { retained.formUnion(relevant) }
                        } catch {
                            retainAll = true
                            if firstFailure == nil { firstFailure = error }
                        }
                    }
                    guard foreground, !Task.isCancelled, !container.mainContext.hasChanges else { break }
                    if !retainAll {
                        let completed = tickets.filter { !retained.contains($0.taskID) }
                        let commit = ModelContext(container)
                        commit.autosaveEnabled = false
                        try CalendarMirrorState.acknowledge(completed, in: commit)
                        if commit.hasChanges { try commit.save() }
                    }
                    scanExisting = false
                    if noMorePhysicalWork { break }
                } catch {
                    if firstFailure == nil { firstFailure = error }
                    break
                }
            }
        }
        if let firstFailure, !(firstFailure is CancellationError), !(firstFailure is AccountCredentialDeferral),
           !(firstFailure is BackgroundBudgetExhausted) { onFailure(String(describing: firstFailure)) }
    }
}

private final class CalendarMirrorObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
