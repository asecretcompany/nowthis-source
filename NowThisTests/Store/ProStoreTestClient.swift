import Foundation
@testable import NowThis

@MainActor
final class ProStoreTestClient: ProStoreClient {
    enum Failure: Error { case offline }
    var offeredProducts: [ProOffer: ProProductInfo] = [
        .lifetime: ProProductInfo(offer: .lifetime, displayName: "NowThis Pro", displayPrice: "€39,99"),
        .tipSmall: ProProductInfo(offer: .tipSmall, displayName: "Small tip", displayPrice: "€1,99")
    ]
    var evidence = ProEvidence()
    var productError: Failure?
    var productLoads = 0
    var productLoader: (@MainActor () async throws -> [ProOffer: ProProductInfo])?
    var evidenceError: Failure?
    var syncError: Failure?
    var result: ProPurchaseResult = .cancelled
    var purchaseOffers: [ProOffer] = []
    var finishedIDs: [UInt64] = []
    var events: [String] = []
    var evidenceLoads = 0
    var evidenceLoader: (@MainActor () async throws -> ProEvidence)?
    var syncCalls = 0
    let updates: AsyncStream<ProPurchaseResult>
    let continuation: AsyncStream<ProPurchaseResult>.Continuation

    init() {
        let stream = AsyncStream<ProPurchaseResult>.makeStream()
        updates = stream.stream
        continuation = stream.continuation
    }
    func loadProducts() async throws -> [ProOffer: ProProductInfo] {
        productLoads += 1
        if let productLoader { return try await productLoader() }
        if let productError { throw productError }
        return offeredProducts
    }
    func loadEvidence() async throws -> ProEvidence {
        evidenceLoads += 1
        if let evidenceLoader { return try await evidenceLoader() }
        if let evidenceError { throw evidenceError }
        return evidence
    }
    func purchase(_ offer: ProOffer) async throws -> ProPurchaseResult {
        purchaseOffers.append(offer)
        return result
    }
    func sync() async throws {
        syncCalls += 1
        if let syncError { throw syncError }
    }
    func finish(transactionID: UInt64) async {
        events.append("finish")
        finishedIDs.append(transactionID)
    }
}
