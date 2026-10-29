import Foundation

struct SupportPurchasePresentation {
    let proOffers: [ProOffer]
    let showsManageSubscription: Bool
    let requiresLifetimeRenewalNotice: Bool
    let showsRestore: Bool
    let tipOffers: [ProOffer]
    let usesLifetimeSubscriptionCopy: Bool

    static func make(snapshot: ProAccessSnapshot, at now: Date) -> Self {
        let lifetime = snapshot.access == .lifetime && snapshot.isUnlocked(at: now)
        let subscription = snapshot.subscription
        let renewing = subscription?.willAutoRenew == true &&
            [.subscribed, .grace, .billingRetry].contains(subscription?.state ?? .expired)
        return Self(proOffers: lifetime ? [] : [.monthly, .annual, .lifetime],
                    showsManageSubscription: subscription != nil && subscription?.state != .revoked,
                    requiresLifetimeRenewalNotice: !lifetime && renewing,
                    showsRestore: true, tipOffers: [.tipSmall, .tipMedium, .tipLarge, .tipExtra],
                    usesLifetimeSubscriptionCopy: lifetime && subscription != nil)
    }
}
