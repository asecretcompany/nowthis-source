import Foundation
import Testing
@testable import NowThis

@Suite("Pro entitlement lifecycle", .serialized)
@MainActor
struct ProEntitlementLifecycleTests {
    private let base = Date(timeIntervalSince1970: 1_790_899_200)

    @MainActor
    private final class Fixture {
        let suite = "NowThis.ProLifecycle.\(UUID().uuidString)"
        let defaults: UserDefaults
        let cache: ProEntitlementCache
        let client = ProStoreTestClient()
        var now: Date
        lazy var entitlement = ProEntitlement(client: client, cache: cache, now: { [unowned self] in self.now },
                                              testerBuild: { false }, forcePaywall: { false })
        init(now: Date) {
            self.now = now
            defaults = UserDefaults(suiteName: suite)!
            cache = ProEntitlementCache(defaults: defaults)
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private func lifetime(_ id: UInt64 = 1, revoked: Bool = false) -> VerifiedProTransaction {
        VerifiedProTransaction(id: id, productID: "com.asecretcompany.nowthis.pro", purchaseDate: base,
                               expirationDate: nil, revocationDate: revoked ? base.addingTimeInterval(150) : nil,
                               isUpgraded: false)
    }
    private var lifetimeEvidence: ProEvidence { ProEvidence(transactions: [lifetime()], currentTransactionIDs: [1]) }
    private var monthlyEvidence: ProEvidence {
        let expiration = base.addingTimeInterval(200)
        let tx = VerifiedProTransaction(id: 2, productID: "com.asecretcompany.nowthis.pro.monthly", purchaseDate: base,
                                        expirationDate: expiration, revocationDate: nil, isUpgraded: false)
        let status = VerifiedSubscriptionStatus(transactionID: 2, productID: tx.productID, state: .subscribed,
                                                expirationDate: expiration, graceExpirationDate: nil, willAutoRenew: true)
        return ProEvidence(transactions: [tx], currentTransactionIDs: [2], subscriptions: [status])
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < end { await Task.yield() }
        try #require(condition())
    }

    @Test func cacheRoundTripsPurchasedDeadlineAndEarnedArtwork() {
        let f = Fixture(now: base)
        defer { f.cleanUp() }
        let snapshot = ProAccessSnapshot(access: .monthly, validUntil: base.addingTimeInterval(200),
                                         earnedCollectionIDs: ["supporter-2026"])
        f.cache.save(snapshot)
        #expect(f.cache.load() == snapshot)
        #expect(f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs == ["supporter-2026"])
    }

    @Test func unknownAndCorruptCachedEvidenceDoesNotUnlock() throws {
        let f = Fixture(now: base)
        defer { f.cleanUp() }
        f.defaults.set(Data("invalid".utf8), forKey: ProEntitlementCache.snapshotKey)
        #expect(f.cache.load() == nil)
        var future = ProAccessSnapshot(access: .lifetime)
        future.schemaVersion = 99
        f.defaults.set(try JSONEncoder().encode(future), forKey: ProEntitlementCache.snapshotKey)
        #expect(f.cache.load() == nil)
        #expect(!f.entitlement.isUnlocked)
    }

    @Test func legacyBooleanDoesNotBecomeLifetimeOrArtwork() async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.defaults.set(true, forKey: "proUnlocked")
        #expect(!f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs.isEmpty)
        f.client.evidence = lifetimeEvidence
        await f.entitlement.refresh()
        #expect(f.entitlement.snapshot.access == .lifetime)
        #expect(f.cache.load()?.access == .lifetime)
        #expect(f.entitlement.ownedCollectionIDs == ["supporter-2026"])
        #expect(f.defaults.object(forKey: "proUnlocked") == nil)
    }

    @Test func subscriptionStopsAtDeadlineDuringNetworkFailureButKeepsArtwork() async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.evidence = monthlyEvidence
        await f.entitlement.refresh()
        #expect(f.entitlement.isUnlocked)
        f.client.evidenceError = .offline
        f.now = base.addingTimeInterval(199)
        await f.entitlement.refresh()
        #expect(f.entitlement.isUnlocked)
        f.now = base.addingTimeInterval(200)
        f.entitlement.reconcileDeadline()
        #expect(!f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs == ["supporter-2026"])
        await f.entitlement.refresh()
        #expect(!f.entitlement.isUnlocked)
    }

    @Test func offlineLifetimeRemainsUnlocked() async {
        let f = Fixture(now: base)
        defer { f.cleanUp() }
        f.cache.save(ProAccessSnapshot(access: .lifetime, earnedCollectionIDs: ["supporter-2026"]))
        f.client.evidenceError = .offline
        await f.entitlement.refresh()
        #expect(f.entitlement.isUnlocked)
        #expect(f.cache.load()?.access == .lifetime)
    }

    @Test func authoritativeRefundRemovesAccessAndSoleArtworkGrant() async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.evidence = lifetimeEvidence
        await f.entitlement.refresh()
        #expect(f.entitlement.isUnlocked)
        f.client.evidence = ProEvidence(transactions: [lifetime(revoked: true)])
        await f.entitlement.refresh()
        #expect(!f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs.isEmpty)
        #expect(f.cache.load()?.access == .locked)
    }

    @Test func staleRefreshCannotUndoANewerRefund() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var started = false
        let old = lifetimeEvidence
        f.client.evidenceLoader = {
            if !started {
                started = true
                for await _ in gate.stream { break }
                return old
            }
            return ProEvidence()
        }
        let first = Task { await f.entitlement.refresh() }
        try await waitUntil { started }
        await f.entitlement.refresh()
        gate.continuation.yield(())
        await first.value
        #expect(!f.entitlement.isUnlocked)
        #expect(f.cache.load()?.access == .locked)
    }

    @Test func startIsIdempotentAndObservesRefundOfAnAlreadyFinishedPurchase() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.entitlement.start()
        f.entitlement.start()
        try await waitUntil { f.client.evidenceLoads == 1 }
        f.client.evidence = lifetimeEvidence
        f.client.result = .verified(lifetime())
        #expect(try await f.entitlement.purchase(.lifetime) == .verified(lifetime()))
        #expect(f.entitlement.isUnlocked)
        #expect(f.client.finishedIDs == [1])
        f.client.evidence = ProEvidence(transactions: [lifetime(revoked: true)])
        f.client.continuation.yield(.verified(lifetime(revoked: true)))
        try await waitUntil { !f.entitlement.isUnlocked }
        #expect(f.client.finishedIDs == [1])
    }

    @Test func accessChangesBroadcastToEverySubscriber() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        var first = f.entitlement.accessChanges().makeAsyncIterator()
        var second = f.entitlement.accessChanges().makeAsyncIterator()
        f.client.evidence = lifetimeEvidence
        await f.entitlement.refresh()
        #expect(await first.next() != nil)
        #expect(await second.next() != nil)
    }

    @Test func testerAccessAndArtworkNeverPersistAsOwnership() async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.entitlement.isTesterBuild = true
        await f.entitlement.refresh()
        #expect(f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs == ["supporter-2026"])
        #expect(f.cache.load()?.access == .locked)
        #expect(f.cache.load()?.earnedCollectionIDs.isEmpty == true)
    }

    @Test func restoreFailureIsVisibleAndDoesNotDiscardCachedOwnership() async {
        let f = Fixture(now: base)
        defer { f.cleanUp() }
        f.cache.save(ProAccessSnapshot(access: .lifetime))
        f.client.syncError = .offline
        await #expect(throws: ProStoreTestClient.Failure.self) { try await f.entitlement.restorePurchases() }
        #expect(f.entitlement.isUnlocked)
    }
    @Test func verifiedPurchaseWaitsForItsOwnDeliveryEvidenceBeforeFinishing() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.result = .verified(lifetime())
        await #expect(throws: ProEvidenceError.self) { try await f.entitlement.purchase(.lifetime) }
        #expect(f.client.finishedIDs.isEmpty)
        #expect(!f.entitlement.isUnlocked)
        f.client.evidence = lifetimeEvidence
        #expect(try await f.entitlement.purchase(.lifetime) == .verified(lifetime()))
        #expect(f.entitlement.isUnlocked)
        #expect(f.client.finishedIDs == [1])
    }

    @Test func aDifferentLifetimeGrantCannotConfirmTheNewPurchase() async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.evidence = lifetimeEvidence
        await f.entitlement.refresh()
        f.client.result = .verified(lifetime(9))
        await #expect(throws: ProEvidenceError.self) { try await f.entitlement.purchase(.lifetime) }
        #expect(f.client.finishedIDs.isEmpty)
        #expect(f.entitlement.isUnlocked)
    }

    @Test(arguments: [false, true])
    func incompleteSuccessfulSubscriptionReadPreservesItsKnownDeadline(mismatchedStatus: Bool) async {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.evidence = monthlyEvidence
        await f.entitlement.refresh()
        let previous = f.entitlement.snapshot
        var partial = monthlyEvidence
        if mismatchedStatus {
            let old = partial.subscriptions[0]
            partial.subscriptions = [VerifiedSubscriptionStatus(transactionID: 99, productID: old.productID,
                state: .subscribed, expirationDate: old.expirationDate, graceExpirationDate: nil, willAutoRenew: true)]
        } else { partial.subscriptions = [] }
        f.client.evidence = partial
        await f.entitlement.refresh()
        #expect(f.entitlement.snapshot == previous)
        #expect(f.cache.load() == previous)
        #expect(f.entitlement.isUnlocked)
        f.now = base.addingTimeInterval(200)
        f.entitlement.reconcileDeadline()
        #expect(!f.entitlement.isUnlocked)
    }

    @Test func verifiedRefundRemovesFinishedLifetimeWhenRereadFails() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        f.client.evidence = lifetimeEvidence
        f.client.result = .verified(lifetime())
        _ = try await f.entitlement.purchase(.lifetime)
        f.entitlement.start()
        try await waitUntil { f.client.evidenceLoads >= 2 }
        f.client.evidenceError = .offline
        let loads = f.client.evidenceLoads
        f.client.continuation.yield(.verified(lifetime(revoked: true)))
        try await waitUntil { f.client.evidenceLoads > loads }
        await Task.yield()
        #expect(!f.entitlement.isUnlocked)
        #expect(f.entitlement.ownedCollectionIDs.isEmpty)
        #expect(f.cache.load()?.access == .locked)
        #expect(f.client.finishedIDs == [1])
    }

    @Test func verifiedRefundAfterReinstallKeepsAnotherPurchasedGrantWhenRereadFails() async throws {
        let f = Fixture(now: base.addingTimeInterval(100))
        defer { f.cleanUp() }
        var evidence = monthlyEvidence
        evidence.transactions.append(lifetime())
        evidence.currentTransactionIDs.insert(1)
        f.client.evidence = evidence
        await f.entitlement.refresh()
        let recovered = ProEntitlement(client: f.client, cache: f.cache, now: { self.base.addingTimeInterval(100) },
                                       testerBuild: { false }, forcePaywall: { false })
        f.client.evidenceError = .offline
        recovered.start()
        try await waitUntil { f.client.evidenceLoads >= 2 }
        let loads = f.client.evidenceLoads
        f.client.continuation.yield(.verified(lifetime(revoked: true)))
        try await waitUntil { f.client.evidenceLoads > loads }
        await Task.yield()
        #expect(recovered.snapshot.access == .monthly)
        #expect(recovered.isUnlocked)
        #expect(recovered.ownedCollectionIDs == ["supporter-2026"])
        #expect(f.cache.load()?.access == .monthly)
    }

}
