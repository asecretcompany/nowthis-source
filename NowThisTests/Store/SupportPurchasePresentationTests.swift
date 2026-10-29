import Foundation
import Testing
@testable import NowThis

@Suite("Optional support presentation")
struct SupportPurchasePresentationTests {
    private let now = Date(timeIntervalSince1970: 100)
    private var subscription: VerifiedSubscriptionStatus {
        VerifiedSubscriptionStatus(transactionID: 1, productID: ProProductCatalog.productID(for: .monthly),
                                   state: .subscribed, expirationDate: now.addingTimeInterval(100), graceExpirationDate: nil, willAutoRenew: true)
    }

    @Test(arguments: [ProStoreClientError.verificationFailed, .invalidProduct, .supersededEvidence])
    func internalStoreFailuresOfferLocalizedRecovery(error: ProStoreClientError) throws {
        let underlying: any Error = error
        let message = underlying.localizedDescription
        #expect(!message.contains("ProStoreClientError"))
        let description = try #require((underlying as? any LocalizedError)?.errorDescription)
        #expect(message == description)
        switch error {
        case .verificationFailed:
            #expect(message == SupportStoreCopy.message(for: .unverified, thankingTip: false))
        case .invalidProduct:
            #expect(message == SupportStoreCopy.loadFailed)
        case .supersededEvidence:
            #expect(message == String(localized: "pro.error.updated",
                                      defaultValue: "Purchase information changed while loading. Try again or restore purchases."))
        }
    }

    @Test func lockedOffersThreeComparableChoices() {
        #expect(SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(), at: now).proOffers == [.monthly, .annual, .lifetime])
    }

    @Test func lifetimeDoesNotSellSubscriptionsButRetainsManagement() {
        let lifetime = ProAccessSnapshot(access: .lifetime, subscription: subscription)
        let layout = SupportPurchasePresentation.make(snapshot: lifetime, at: now)
        #expect(layout.proOffers.isEmpty)
        #expect(layout.showsManageSubscription)
        #expect(!layout.requiresLifetimeRenewalNotice)
        #expect(!SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(access: .lifetime), at: now).showsManageSubscription)
    }

    @Test func subscriberSeesLifetimeRenewalNotice() {
        let layout = SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(access: .monthly, validUntil: subscription.expirationDate, subscription: subscription), at: now)
        #expect(layout.proOffers.contains(.lifetime))
        #expect(layout.requiresLifetimeRenewalNotice)
        #expect(layout.showsManageSubscription)
    }

    @Test(arguments: ProAccessKind.allCasesForSupportTests)
    func restoreAndRepeatableTipsRemainAvailable(kind: ProAccessKind) {
        let layout = SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(access: kind), at: now)
        #expect(layout.showsRestore)
        #expect(layout.tipOffers == [.tipSmall, .tipMedium, .tipLarge, .tipExtra])
    }
    @Test(arguments: [ProSubscriptionState.subscribed, .grace, .billingRetry])
    func lifetimeSubscriptionMessagesCannotDescribeLifetimeExpiry(state: ProSubscriptionState) {
        let status = VerifiedSubscriptionStatus(transactionID: 1, productID: subscription.productID,
            state: state, expirationDate: subscription.expirationDate, graceExpirationDate: subscription.expirationDate,
            willAutoRenew: false)
        let layout = SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(access: .lifetime, subscription: status), at: now)
        #expect(layout.usesLifetimeSubscriptionCopy)
        #expect(layout.showsManageSubscription)
        #expect(!SupportPurchasePresentation.make(snapshot: ProAccessSnapshot(access: .monthly, validUntil: status.expirationDate, subscription: status), at: now).usesLifetimeSubscriptionCopy)
    }

}

private extension ProAccessKind {
    static let allCasesForSupportTests: [Self] = [.locked, .monthly, .annual, .lifetime]
}
