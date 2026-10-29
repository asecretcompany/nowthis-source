import Foundation
import StoreKit

/// Optional Supporter ownership controls Watch writes and cosmetic artwork only.
/// The cache contains purchased evidence; tester access never persists.
@MainActor
@Observable
final class ProEntitlement {
    private(set) var snapshot: ProAccessSnapshot
    private(set) var products: [ProOffer: ProProductInfo] = [:]
    private(set) var productLoadingFailed = false
    private(set) var isLoadingProducts = false
    var isTesterBuild = false { didSet { publishAccessChanges() } }
    private var accessRevision = 0

    @ObservationIgnored private let client: any ProStoreClient
    @ObservationIgnored private let coordinator: ProPurchaseCoordinator
    @ObservationIgnored private let cache: ProEntitlementCache
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let testerBuild: @MainActor () async -> Bool
    @ObservationIgnored private let forcePaywall: @MainActor () -> Bool
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var knownRevocations: [UInt64: VerifiedProTransaction] = [:]
    @ObservationIgnored private var lastPublishedSnapshot: ProAccessSnapshot
    @ObservationIgnored private var lastPublishedUnlocked: Bool
    @ObservationIgnored private var lastPublishedCollections: Set<String>
    @ObservationIgnored private nonisolated(unsafe) var updatesTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var startupTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    static let forcePaywallKey = "NowThisForcePaywall"
    static func forcePaywallOverride() -> Bool { UserDefaults.standard.bool(forKey: forcePaywallKey) }

    init(client: (any ProStoreClient)? = nil, cache: ProEntitlementCache = ProEntitlementCache(),
         now: @escaping @MainActor () -> Date = Date.init,
         testerBuild: @escaping @MainActor () async -> Bool = ProEntitlement.detectTesterBuild,
         forcePaywall: @escaping @MainActor () -> Bool = ProEntitlement.forcePaywallOverride) {
        let client = client ?? StoreKitProStoreClient()
        self.client = client
        self.coordinator = ProPurchaseCoordinator(client: client)
        self.cache = cache
        self.now = now
        self.testerBuild = testerBuild
        self.forcePaywall = forcePaywall
        let cached = cache.load() ?? ProAccessSnapshot()
        snapshot = cached
        for transaction in cached.verifiedEvidence?.transactions ?? [] where transaction.revocationDate != nil {
            knownRevocations[transaction.id] = transaction
        }
        lastPublishedSnapshot = cached
        lastPublishedUnlocked = cached.isUnlocked(at: now())
        lastPublishedCollections = ProEntitlementPolicy.ownedCollectionIDs(in: cached, collections: AppIconCatalog.collections, at: now())
    }

    var testerUnlocked: Bool { isTesterBuild && !forcePaywall() }
    var isUnlocked: Bool {
        _ = accessRevision
        return snapshot.isUnlocked(at: now()) || testerUnlocked
    }
    var ownedCollectionIDs: Set<String> {
        _ = accessRevision
        if testerUnlocked { return Set(AppIconCatalog.collections.filter { $0.releasedAt <= now() }.map(\.id)) }
        return ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: AppIconCatalog.collections, at: now())
    }

    static func cachedUnlocked() -> Bool {
        ProEntitlementCache().load()?.isUnlocked(at: Date()) ?? false
    }

    func start() {
        guard updatesTask == nil else { return }
        let updates = client.updates
        updatesTask = Task { [weak self] in
            for await result in updates {
                guard let self else { break }
                guard case .verified(let transaction) = result,
                      ProProductCatalog.offer(for: transaction.productID) != nil else { continue }
                if transaction.revocationDate != nil { self.applyRevocation(transaction) }
                // Refunds and grace changes can reuse an already-finished ID.
                await self.refresh()
                _ = try? await self.coordinator.process(result) { [weak self] transaction in
                    try await self?.deliver(transaction)
                }
            }
        }
        startupTask = Task { [weak self] in
            guard let self else { return }
            self.isTesterBuild = await self.testerBuild()
            try? await self.loadProducts()
            await self.refresh()
        }
        scheduleDeadline()
    }

    static func detectTesterBuild() async -> Bool {
        guard case .verified(let appTransaction) = try? await AppTransaction.shared else { return false }
        return appTransaction.environment != .production
    }

    func loadProducts() async throws {
        isLoadingProducts = true
        productLoadingFailed = false
        defer { isLoadingProducts = false }
        do {
            try await coordinator.loadProducts()
            products = coordinator.products
            productLoadingFailed = false
        } catch {
            productLoadingFailed = true
            throw error
        }
    }

    func refresh() async {
        do { try await refreshVerifiedEvidence() }
        catch { reconcileDeadline() }
    }

    private func refreshVerifiedEvidence(delivering purchase: VerifiedProTransaction? = nil) async throws {
        refreshGeneration += 1
        let generation = refreshGeneration
        let loaded = try await client.loadEvidence()
        guard generation == refreshGeneration else { throw ProStoreClientError.supersededEvidence }
        let evidence = incorporatingRevocations(in: loaded)
        try evidence.validate(at: now())
        if let purchase, !evidence.confirmsDelivery(of: purchase, at: now()) {
            throw ProEvidenceError.deliveryPending
        }
        apply(evidence)
    }

    private func incorporatingRevocations(in original: ProEvidence) -> ProEvidence {
        var evidence = original
        for transaction in evidence.transactions where transaction.revocationDate != nil {
            knownRevocations[transaction.id] = transaction
        }
        for transaction in knownRevocations.values {
            evidence.transactions.removeAll { $0.id == transaction.id }
            evidence.transactions.append(transaction)
            evidence.currentTransactionIDs.remove(transaction.id)
            evidence.subscriptions = evidence.subscriptions.map { status in
                guard status.transactionID == transaction.id else { return status }
                return VerifiedSubscriptionStatus(transactionID: status.transactionID, productID: status.productID,
                    state: .revoked, expirationDate: status.expirationDate, graceExpirationDate: nil, willAutoRenew: false)
            }
        }
        return evidence
    }

    private func applyRevocation(_ transaction: VerifiedProTransaction) {
        // Invalidate suspended reads before persisting the independently signed
        // revocation. A later partial or stale read cannot restore this grant.
        refreshGeneration += 1
        knownRevocations[transaction.id] = transaction
        if let evidence = snapshot.verifiedEvidence {
            apply(incorporatingRevocations(in: evidence))
        } else if transaction.productID == AppConstants.proProductID && snapshot.access == .lifetime ||
                    transaction.id == snapshot.subscription?.transactionID {
            // Early schema-1 caches have no grant attribution. Clear an affected
            // grant conservatively; a complete verified read can recover others.
            snapshot.access = .locked
            snapshot.validUntil = nil
            snapshot.earnedCollectionIDs = []
            snapshot.verifiedEvidence = ProEvidence(transactions: [transaction])
            cache.save(snapshot)
            publishAccessChanges()
            scheduleDeadline()
        }
    }

    private func apply(_ evidence: ProEvidence) {
        snapshot = ProEntitlementPolicy.evaluate(evidence, collections: AppIconCatalog.collections, at: now())
        cache.save(snapshot)
        publishAccessChanges()
        scheduleDeadline()
    }

    func purchase(_ offer: ProOffer) async throws -> ProPurchaseResult {
        let result = try await coordinator.purchase(offer)
        products = coordinator.products
        _ = try await coordinator.process(result) { [weak self] transaction in
            try await self?.deliver(transaction)
        }
        return result
    }

    private func deliver(_ transaction: VerifiedProTransaction) async throws {
        guard ProProductCatalog.offer(for: transaction.productID)?.isTip != true else { return }
        if transaction.revocationDate != nil { applyRevocation(transaction); return }
        if knownRevocations[transaction.id] != nil { return }
        try await refreshVerifiedEvidence(delivering: transaction)
    }

    func restorePurchases() async throws {
        refreshGeneration += 1
        let generation = refreshGeneration
        let loaded = try await coordinator.restore()
        guard generation == refreshGeneration else { throw ProStoreClientError.supersededEvidence }
        let evidence = incorporatingRevocations(in: loaded)
        try evidence.validate(at: now())
        apply(evidence)
    }

    func reconcileDeadline() {
        publishAccessChanges()
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = snapshot.validUntil, deadline > now() else { return }
        let delay = deadline.timeIntervalSince(now())
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.publishAccessChanges()
            await self?.refresh()
        }
    }

    func accessChanges() -> AsyncStream<Void> {
        let id = UUID()
        let stream = AsyncStream<Void>.makeStream()
        subscribers[id] = stream.continuation
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
        }
        return stream.stream
    }

    private func publishAccessChanges() {
        let unlocked = isUnlocked
        let collections = ownedCollectionIDs
        guard snapshot != lastPublishedSnapshot || unlocked != lastPublishedUnlocked || collections != lastPublishedCollections else { return }
        lastPublishedSnapshot = snapshot
        lastPublishedUnlocked = unlocked
        lastPublishedCollections = collections
        accessRevision += 1
        subscribers.values.forEach { $0.yield(()) }
    }

    deinit {
        updatesTask?.cancel()
        startupTask?.cancel()
        deadlineTask?.cancel()
        subscribers.values.forEach { $0.finish() }
    }
}
