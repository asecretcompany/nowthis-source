import Foundation

struct ProProductInfo: Equatable, Sendable {
    let offer: ProOffer
    let displayName: String
    let displayPrice: String
}

enum ProPurchaseResult: Equatable, Sendable {
    case verified(VerifiedProTransaction)
    case pending, cancelled, unverified, unavailable
}

@MainActor
protocol ProStoreClient: AnyObject {
    func loadProducts() async throws -> [ProOffer: ProProductInfo]
    func loadEvidence() async throws -> ProEvidence
    func purchase(_ offer: ProOffer) async throws -> ProPurchaseResult
    func sync() async throws
    func finish(transactionID: UInt64) async
    var updates: AsyncStream<ProPurchaseResult> { get }
}
