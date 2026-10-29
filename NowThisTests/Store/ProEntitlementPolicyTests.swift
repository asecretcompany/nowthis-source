import Foundation
import Testing
@testable import NowThis

@Suite("Pro entitlement policy")
struct ProEntitlementPolicyTests {
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private var collections: [AppIconCollection] {
        [AppIconCollection(id: "old", releasedAt: date(10)),
         AppIconCollection(id: "paid", releasedAt: date(150)),
         AppIconCollection(id: "grace", releasedAt: date(250)),
         AppIconCollection(id: "future", releasedAt: date(500))]
    }
    private func transaction(
        _ id: UInt64 = 1, product: String = "com.asecretcompany.nowthis.pro.monthly",
        start: Double = 100, end: Double? = 200, revoked: Bool = false, upgraded: Bool = false
    ) -> VerifiedProTransaction {
        VerifiedProTransaction(id: id, productID: product, purchaseDate: date(start),
                              expirationDate: end.map(date), revocationDate: revoked ? date(180) : nil,
                              isUpgraded: upgraded)
    }
    private func status(
        _ state: ProSubscriptionState = .subscribed, id: UInt64 = 1,
        product: String = "com.asecretcompany.nowthis.pro.monthly", end: Double = 200,
        grace: Double? = nil, renews: Bool = true
    ) -> VerifiedSubscriptionStatus {
        VerifiedSubscriptionStatus(transactionID: id, productID: product, state: state,
                                   expirationDate: date(end), graceExpirationDate: grace.map(date),
                                   willAutoRenew: renews)
    }
    private func evaluate(
        _ transactions: [VerifiedProTransaction], current: Set<UInt64> = [1],
        statuses: [VerifiedSubscriptionStatus] = [], now: Double = 175
    ) -> ProAccessSnapshot {
        ProEntitlementPolicy.evaluate(
            ProEvidence(transactions: transactions, currentTransactionIDs: current, subscriptions: statuses),
            collections: collections, at: date(now))
    }

    @Test func legacyLifetimeGrantsEveryReleasedCollection() {
        let snapshot = evaluate([transaction(product: "com.asecretcompany.nowthis.pro", end: nil)])
        #expect(snapshot.access == .lifetime)
        #expect(snapshot.validUntil == nil)
        #expect(snapshot.isUnlocked(at: date(10_000)))
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: collections, at: date(175)) == ["old", "paid"])
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: collections, at: date(600)) == ["old", "paid", "grace", "future"])
    }

    @Test(arguments: ["com.asecretcompany.nowthis.tip.small", "another.product"])
    func unrelatedPurchasesDoNotUnlock(product: String) {
        let snapshot = evaluate([transaction(product: product, end: nil)])
        #expect(!snapshot.isUnlocked(at: date(175)))
        #expect(snapshot.earnedCollectionIDs.isEmpty)
    }

    @Test(arguments: ["monthly", "annual"])
    func subscriptionRemainsActiveUntilPaidBoundary(duration: String) {
        let product = "com.asecretcompany.nowthis.pro.\(duration)"
        let snapshot = evaluate([transaction(product: product)], statuses: [status(product: product, renews: false)])
        #expect(snapshot.access.rawValue == duration)
        #expect(snapshot.validUntil == date(200))
        #expect(snapshot.isUnlocked(at: date(199)))
        #expect(!snapshot.isUnlocked(at: date(200)))
        #expect(snapshot.earnedCollectionIDs == ["old", "paid"])
    }

    @Test func expiryPreservesPaidArtworkAfterReinstall() {
        let snapshot = evaluate([transaction()], current: [], statuses: [status(.expired)], now: 300)
        #expect(snapshot.access == .locked)
        #expect(snapshot.earnedCollectionIDs == ["old", "paid"])
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: collections, at: date(300)) == ["old", "paid"])
        #expect(evaluate([transaction()], current: [], statuses: [status(.expired)], now: 300) == snapshot)
    }

    @Test func graceArtworkIsTemporaryUntilRecovery() {
        let snapshot = evaluate([transaction()], statuses: [status(.grace, grace: 300)], now: 275)
        #expect(snapshot.isUnlocked(at: date(299)))
        #expect(!snapshot.isUnlocked(at: date(300)))
        #expect(snapshot.earnedCollectionIDs == ["old", "paid"])
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: collections, at: date(275)) == ["old", "paid", "grace"])
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: collections, at: date(300)) == ["old", "paid"])
        let recovered = evaluate([transaction(), transaction(2, start: 200, end: 400)], current: [2],
                                 statuses: [status(id: 2, end: 400)], now: 350)
        #expect(recovered.earnedCollectionIDs == ["old", "paid", "grace"])
    }

    @Test func billingRetryWithoutGraceDoesNotExtendAccess() {
        let snapshot = evaluate([transaction()], statuses: [status(.billingRetry)], now: 275)
        #expect(!snapshot.isUnlocked(at: date(275)))
        #expect(snapshot.earnedCollectionIDs == ["old", "paid"])
    }

    @Test func newlyShippedPaidArtworkRemainsOwnedAfterOfflineExpiry() {
        let snapshot = evaluate([transaction()], statuses: [status()])
        let expanded = collections + [AppIconCollection(id: "late", releasedAt: date(190))]
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: expanded, at: date(300)) == ["old", "paid", "late"])
        let grace = evaluate([transaction()], statuses: [status(.grace, grace: 300)], now: 275)
        #expect(!ProEntitlementPolicy.ownedCollectionIDs(in: grace, collections: expanded, at: date(300)).contains("grace"))
        let revoked = evaluate([transaction(revoked: true)], current: [], statuses: [status(.revoked)], now: 300)
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: revoked, collections: expanded, at: date(300)).isEmpty)
    }

    @Test func refundedPurchaseRemovesOnlyItsAwards() {
        let snapshot = evaluate([transaction(revoked: true), transaction(2, start: 20, end: 90)], current: [], now: 300)
        #expect(snapshot.access == .locked)
        #expect(snapshot.earnedCollectionIDs == ["old"])
    }

    @Test func revokedLifetimeDoesNotOverrideAnActiveSubscription() {
        let snapshot = evaluate([transaction(9, product: "com.asecretcompany.nowthis.pro", end: nil, revoked: true), transaction()],
                                current: [1, 9], statuses: [status()])
        #expect(snapshot.access == .monthly)
        #expect(snapshot.validUntil == date(200))
    }

    @Test func lifetimeRetainsIndependentSubscriptionManagement() {
        let subscription = status()
        let snapshot = evaluate([transaction(), transaction(9, product: "com.asecretcompany.nowthis.pro", end: nil)],
                                current: [1, 9], statuses: [subscription])
        #expect(snapshot.access == .lifetime)
        #expect(snapshot.subscription == subscription)
    }

    @Test func upgradedCoverageStopsAtReplacementEvenWhenReplacementWasRefunded() {
        let old = transaction(end: 400, upgraded: true)
        let replacement = transaction(2, product: "com.asecretcompany.nowthis.pro.annual", start: 200, end: 600, revoked: true)
        let snapshot = evaluate([replacement, old, old], current: [], now: 600)
        #expect(snapshot.earnedCollectionIDs == ["old", "paid"])
        #expect(snapshot.access == .locked)
    }

    @Test func missingReplacementDoesNotAwardUncertainCoverage() {
        let snapshot = evaluate([transaction(end: 400, upgraded: true)], current: [], now: 600)
        #expect(snapshot.earnedCollectionIDs == ["old"])
    }

    @Test func releaseExactlyAtCoverageEndIsNotEarned() {
        let snapshot = evaluate([transaction(end: 150)], current: [], now: 300)
        #expect(snapshot.earnedCollectionIDs == ["old"])
    }

    @Test func expiredSnapshotWithNoDeadlineCannotUnlock() {
        let malformed = ProAccessSnapshot(access: .monthly, validUntil: nil)
        #expect(!malformed.isUnlocked(at: date(100)))
    }

    @Test func catalogueRestoresOldSKUAndRecognizesEverySupportOffer() {
        #expect(ProProductCatalog.productID(for: .lifetime) == "com.asecretcompany.nowthis.pro")
        #expect(ProProductCatalog.offer(for: "com.asecretcompany.nowthis.pro.annual") == .annual)
        #expect(ProProductCatalog.offer(for: "unknown") == nil)
        #expect(Set(ProOffer.allCases.map(ProProductCatalog.productID)).count == 7)
    }
    @Test func authoritativeExpiryStillReconstructsNewCatalogAwardsOffline() throws {
        let before = [AppIconCollection(id: "old", releasedAt: date(50))]
        let evidence = ProEvidence(transactions: [transaction()], subscriptions: [status(.expired)])
        let expired = ProEntitlementPolicy.evaluate(evidence, collections: before, at: date(300))
        #expect(expired.access == .locked)
        let decoded = try JSONDecoder().decode(ProAccessSnapshot.self, from: JSONEncoder().encode(expired))
        let expanded = before + [AppIconCollection(id: "paid-new", releasedAt: date(150)),
                                 AppIconCollection(id: "unpaid-new", releasedAt: date(250))]
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: decoded, collections: expanded, at: date(300)) == ["old", "paid-new"])
    }

    @Test func evidenceValidationRejectsMissingOrMismatchedCurrentStatuses() {
        let current = ProEvidence(transactions: [transaction()], currentTransactionIDs: [1])
        #expect(throws: ProEvidenceError.self) { try current.validate(at: date(100)) }
        var mismatch = current
        mismatch.subscriptions = [VerifiedSubscriptionStatus(transactionID: 99, productID: transaction().productID, state: .subscribed, expirationDate: date(200), graceExpirationDate: nil, willAutoRenew: true)]
        #expect(throws: ProEvidenceError.self) { try mismatch.validate(at: date(100)) }
    }

}
