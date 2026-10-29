import Foundation

enum ProEntitlementPolicy {
    static func evaluate(_ evidence: ProEvidence, collections: [AppIconCollection], at now: Date) -> ProAccessSnapshot {
        // A revoked record wins over an older duplicate of the same transaction.
        let transactions = Dictionary(grouping: evidence.transactions, by: \.id).values.compactMap { records in
            records.first(where: { $0.revocationDate != nil }) ?? records.first
        }
        let subscriptions = transactions.filter { ProProductCatalog.offer(for: $0.productID)?.isSubscription == true }
        let statuses = evidence.subscriptions.filter { ProProductCatalog.offer(for: $0.productID)?.isSubscription == true }
        let managementStatus = statuses.max {
            ($0.expirationDate, $0.transactionID) < ($1.expirationDate, $1.transactionID)
        }
        let activeStatuses = statuses.filter { status in
            guard evidence.currentTransactionIDs.contains(status.transactionID),
                  subscriptions.contains(where: {
                      $0.id == status.transactionID && $0.productID == status.productID &&
                      $0.revocationDate == nil && !$0.isUpgraded && $0.purchaseDate <= now
                  }), let deadline = accessDeadline(status) else { return false }
            return now < deadline
        }
        let active = activeStatuses.max {
            (accessDeadline($0) ?? .distantPast) < (accessDeadline($1) ?? .distantPast)
        }
        let lifetime = transactions.contains {
            $0.productID == AppConstants.proProductID && $0.revocationDate == nil &&
            $0.purchaseDate <= now && evidence.currentTransactionIDs.contains($0.id)
        }
        let released = collections.filter { $0.releasedAt <= now }
        var earned = Set<String>()
        for transaction in subscriptions where transaction.revocationDate == nil && transaction.purchaseDate <= now {
            guard var paidEnd = transaction.expirationDate else { continue }
            if transaction.isUpgraded {
                let replacement = subscriptions.filter {
                    $0.id != transaction.id && $0.purchaseDate > transaction.purchaseDate
                }.map(\.purchaseDate).min()
                paidEnd = min(paidEnd, replacement ?? transaction.purchaseDate)
            }
            earned.formUnion(released.filter { $0.releasedAt < paidEnd }.map(\.id))
        }
        if lifetime { earned.formUnion(released.map(\.id)) }
        let kind: ProAccessKind
        if lifetime { kind = .lifetime }
        else if let active { kind = ProProductCatalog.offer(for: active.productID) == .annual ? .annual : .monthly }
        else { kind = .locked }
        return ProAccessSnapshot(access: kind, validUntil: lifetime ? nil : active.flatMap(accessDeadline),
                                 earnedCollectionIDs: earned, subscription: active ?? managementStatus,
                                 verifiedEvidence: ProEvidence(transactions: transactions.sorted { $0.id < $1.id },
                                     currentTransactionIDs: evidence.currentTransactionIDs, subscriptions: evidence.subscriptions))
    }

    static func ownedCollectionIDs(in snapshot: ProAccessSnapshot, collections: [AppIconCollection], at now: Date) -> Set<String> {
        let released = Set(collections.filter { $0.releasedAt <= now }.map(\.id))
        if snapshot.isUnlocked(at: now) { return released }
        var earned = snapshot.earnedCollectionIDs
        if let evidence = snapshot.verifiedEvidence {
            earned = evaluate(evidence, collections: collections, at: now).earnedCollectionIDs
            return earned.intersection(released)
        }
        // A catalog can grow while offline. The last verified paid period still
        // earns its releases, even after access expires; unpaid grace does not.
        if [.monthly, .annual].contains(snapshot.access), let subscription = snapshot.subscription,
           subscription.state != .revoked {
            earned.formUnion(collections.filter {
                $0.releasedAt <= now && $0.releasedAt < subscription.expirationDate
            }.map(\.id))
        }
        return earned.intersection(released)
    }

    private static func accessDeadline(_ status: VerifiedSubscriptionStatus) -> Date? {
        switch status.state {
        case .subscribed: status.expirationDate
        case .grace: status.graceExpirationDate
        case .billingRetry, .expired, .revoked: nil
        }
    }
}
