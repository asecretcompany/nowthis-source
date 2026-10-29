import Foundation
import StoreKit
import OSLog

enum ProStoreClientError: LocalizedError {
    case verificationFailed, invalidProduct, supersededEvidence

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            SupportStoreCopy.message(for: .unverified, thankingTip: false)
        case .invalidProduct:
            SupportStoreCopy.loadFailed
        case .supersededEvidence:
            String(localized: "pro.error.updated",
                   defaultValue: "Purchase information changed while loading. Try again or restore purchases.",
                   comment: "Purchase or restore information changed during a concurrent refresh. Retry without claiming payment or access succeeded.")
        }
    }
}

/// StoreKit is the only source of purchase evidence. Unverified or incomplete
/// evidence throws so reconciliation can preserve the last verified snapshot.
@MainActor
final class StoreKitProStoreClient: ProStoreClient {
    private static let logger = Logger(subsystem: "com.asecretcompany.nowthis", category: "store-products")
    private var storeProducts: [ProOffer: Product] = [:]
    private var transactionsByID: [UInt64: StoreKit.Transaction] = [:]
    let updates: AsyncStream<ProPurchaseResult>
    private let continuation: AsyncStream<ProPurchaseResult>.Continuation
    private nonisolated(unsafe) var updateTasks: [Task<Void, Never>] = []

    init() {
        let stream = AsyncStream<ProPurchaseResult>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
        updateTasks = [
            Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard let self else { break }
                    self.continuation.yield(self.purchaseResult(result))
                }
            },
            Task { [weak self] in
                for await result in StoreKit.Transaction.unfinished {
                    guard let self else { break }
                    self.continuation.yield(self.purchaseResult(result))
                }
            },
            Task { [weak self] in
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard let self else { break }
                    // Grace and billing recovery can change without a new purchase.
                    self.continuation.yield(self.purchaseResult(status.transaction))
                }
            }
        ]
    }

    func loadProducts() async throws -> [ProOffer: ProProductInfo] {
        let requested = ProOffer.allCases.map(ProProductCatalog.productID)
        let loaded: [Product]
        do {
            loaded = try await Product.products(for: requested)
        } catch {
            let failure = error as NSError
            Self.logger.error("Product request failed: domain=\(failure.domain, privacy: .public), code=\(failure.code); requested=\(requested.joined(separator: ","), privacy: .public)")
            throw error
        }
        let missing = Set(requested).subtracting(loaded.map(\.id)).sorted()
        if !missing.isEmpty {
            Self.logger.warning("App Store did not return products: \(missing.joined(separator: ","), privacy: .public)")
        }
        var result: [ProOffer: ProProductInfo] = [:]
        var fetched: [ProOffer: Product] = [:]
        for product in loaded {
            guard let offer = ProProductCatalog.offer(for: product.id) else { continue }
            let expected: Product.ProductType = offer.isSubscription ? .autoRenewable : (offer.isTip ? .consumable : .nonConsumable)
            guard product.type == expected else { throw ProStoreClientError.invalidProduct }
            fetched[offer] = product
            result[offer] = ProProductInfo(offer: offer, displayName: product.displayName, displayPrice: product.displayPrice)
        }
        storeProducts = fetched
        return result
    }

    func purchase(_ offer: ProOffer) async throws -> ProPurchaseResult {
        if storeProducts[offer] == nil { _ = try await loadProducts() }
        guard let product = storeProducts[offer] else { return .unavailable }
        switch try await product.purchase() {
        case .success(let result): return purchaseResult(result)
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .unverified
        }
    }

    func loadEvidence() async throws -> ProEvidence {
        var evidence = ProEvidence()
        var groupIDs = Set<String>()
        for await result in StoreKit.Transaction.all {
            if let transaction = try verifiedCatalogTransaction(result) {
                transactionsByID[transaction.id] = transaction
                evidence.transactions.append(Self.normalized(transaction))
                if let group = transaction.subscriptionGroupID { groupIDs.insert(group) }
            }
        }
        for await result in StoreKit.Transaction.currentEntitlements {
            if let transaction = try verifiedCatalogTransaction(result) {
                transactionsByID[transaction.id] = transaction
                evidence.currentTransactionIDs.insert(transaction.id)
                evidence.transactions.append(Self.normalized(transaction))
                if let group = transaction.subscriptionGroupID { groupIDs.insert(group) }
            }
        }
        // Group IDs come from signed transactions, so offline lifetime restores
        // don't depend on loading today's product catalogue from the network.
        for groupID in groupIDs {
            for status in try await Product.SubscriptionInfo.status(for: groupID) {
                guard let transaction = try verifiedCatalogTransaction(status.transaction),
                      case .verified(let renewal) = status.renewalInfo,
                      let expiration = transaction.expirationDate else {
                    throw ProStoreClientError.verificationFailed
                }
                evidence.transactions.append(Self.normalized(transaction))
                evidence.subscriptions.append(VerifiedSubscriptionStatus(
                    transactionID: transaction.id, productID: transaction.productID,
                    state: Self.normalized(status.state), expirationDate: expiration,
                    graceExpirationDate: renewal.gracePeriodExpirationDate, willAutoRenew: renewal.willAutoRenew))
            }
        }
        try evidence.validate(at: Date())
        return evidence
    }

    func sync() async throws { try await AppStore.sync() }

    func finish(transactionID: UInt64) async {
        guard let transaction = transactionsByID[transactionID] else { return }
        await transaction.finish()
    }

    private func purchaseResult(_ result: VerificationResult<StoreKit.Transaction>) -> ProPurchaseResult {
        guard case .verified(let transaction) = result else { return .unverified }
        transactionsByID[transaction.id] = transaction
        return .verified(Self.normalized(transaction))
    }

    private func verifiedCatalogTransaction(_ result: VerificationResult<StoreKit.Transaction>) throws -> StoreKit.Transaction? {
        switch result {
        case .verified(let transaction):
            return ProProductCatalog.offer(for: transaction.productID) == nil ? nil : transaction
        case .unverified(let transaction, _):
            if ProProductCatalog.offer(for: transaction.productID) != nil { throw ProStoreClientError.verificationFailed }
            return nil
        }
    }

    private static func normalized(_ transaction: StoreKit.Transaction) -> VerifiedProTransaction {
        VerifiedProTransaction(id: transaction.id, productID: transaction.productID,
                               purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
                               revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded)
    }

    private static func normalized(_ state: Product.SubscriptionInfo.RenewalState) -> ProSubscriptionState {
        switch state {
        case .subscribed: .subscribed
        case .inGracePeriod: .grace
        case .inBillingRetryPeriod: .billingRetry
        case .revoked: .revoked
        default: .expired
        }
    }

    deinit { updateTasks.forEach { $0.cancel() } }
}
