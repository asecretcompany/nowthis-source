import Foundation

enum ProEvidenceError: LocalizedError {
    case incomplete, deliveryPending
    var errorDescription: String? {
        String(localized: "pro.purchase.waiting",
               defaultValue: "Your purchase is verified, but the App Store hasn’t provided its access yet. Try again or restore purchases.",
               comment: "A verified purchase stays unfinished until its benefits appear in verified ownership. The user can retry or restore.")
    }
}

struct VerifiedProTransaction: Codable, Equatable, Sendable {
    let id: UInt64
    let productID: String
    let purchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool
}

enum ProSubscriptionState: String, Codable, Sendable {
    case subscribed, grace, billingRetry, expired, revoked
}

struct VerifiedSubscriptionStatus: Codable, Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let state: ProSubscriptionState
    let expirationDate: Date
    let graceExpirationDate: Date?
    let willAutoRenew: Bool
}

struct ProEvidence: Codable, Equatable, Sendable {
    var transactions: [VerifiedProTransaction] = []
    var currentTransactionIDs: Set<UInt64> = []
    var subscriptions: [VerifiedSubscriptionStatus] = []

    /// Transaction history, current entitlements, and status are separate reads.
    /// A renewal between them must be retried rather than treated as lost access.
    func validate(at now: Date) throws {
        let currentSubscriptions = transactions.filter {
            currentTransactionIDs.contains($0.id) && $0.revocationDate == nil && !$0.isUpgraded &&
            ProProductCatalog.offer(for: $0.productID)?.isSubscription == true
        }
        for transaction in currentSubscriptions {
            guard subscriptions.contains(where: {
                $0.transactionID == transaction.id && $0.productID == transaction.productID &&
                $0.expirationDate == transaction.expirationDate
            }) else { throw ProEvidenceError.incomplete }
        }
        for status in subscriptions {
            let deadline = status.state == .grace ? status.graceExpirationDate : status.expirationDate
            guard [.subscribed, .grace].contains(status.state), let deadline, now < deadline else { continue }
            guard currentSubscriptions.contains(where: {
                $0.id == status.transactionID && $0.productID == status.productID &&
                $0.expirationDate == status.expirationDate
            }) else { throw ProEvidenceError.incomplete }
        }
    }

    func confirmsDelivery(of purchase: VerifiedProTransaction, at now: Date) -> Bool {
        guard let recorded = transactions.first(where: {
            $0.id == purchase.id && $0.productID == purchase.productID &&
            $0.purchaseDate == purchase.purchaseDate && $0.expirationDate == purchase.expirationDate
        }) else { return false }
        if recorded.revocationDate != nil { return true }
        if recorded.isUpgraded { return true }
        if purchase.expirationDate.map({ $0 <= now }) == true { return true }
        return currentTransactionIDs.contains(purchase.id)
    }
}

enum ProAccessKind: String, Codable, Sendable {
    case locked, monthly, annual, lifetime
}

struct ProAccessSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var access: ProAccessKind = .locked
    var validUntil: Date?
    var earnedCollectionIDs: Set<String> = []
    var subscription: VerifiedSubscriptionStatus?
    /// Optional for compatibility with early schema-1 caches. Signed grant
    /// provenance supports offline artwork and independently received refunds.
    var verifiedEvidence: ProEvidence?

    func isUnlocked(at now: Date) -> Bool {
        guard schemaVersion == 1 else { return false }
        switch access {
        case .locked: return false
        case .lifetime: return validUntil == nil
        case .monthly, .annual:
            guard let validUntil else { return false }
            return now < validUntil
        }
    }
}
