import Foundation

@MainActor
final class ProPurchaseCoordinator {
    private let client: any ProStoreClient
    private(set) var products: [ProOffer: ProProductInfo] = [:]
    private var processingIDs = Set<UInt64>()
    private var finishedIDs = Set<UInt64>()
    private var productLoadTask: Task<Void, Error>?

    init(client: any ProStoreClient) { self.client = client }
    func loadProducts() async throws {
        if let productLoadTask { return try await productLoadTask.value }
        // Startup, Settings, and purchase recovery share one catalog request.
        let task = Task { @MainActor in
            defer { productLoadTask = nil }
            for attempt in 0..<3 {
                do {
                    let loaded = try await client.loadProducts()
                    guard !loaded.isEmpty else { throw ProStoreClientError.invalidProduct }
                    products = loaded
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard attempt < 2 else { throw error }
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        }
        productLoadTask = task
        try await task.value
    }

    func purchase(_ offer: ProOffer) async throws -> ProPurchaseResult {
        if products[offer] == nil { try await loadProducts() }
        guard products[offer] != nil else { return .unavailable }
        return try await client.purchase(offer)
    }

    func restore() async throws -> ProEvidence {
        try await client.sync()
        return try await client.loadEvidence()
    }

    func process(_ result: ProPurchaseResult,
                 deliver: @MainActor (VerifiedProTransaction) async throws -> Void) async throws -> Bool {
        guard case .verified(let transaction) = result,
              ProProductCatalog.offer(for: transaction.productID) != nil,
              !finishedIDs.contains(transaction.id),
              processingIDs.insert(transaction.id).inserted else { return false }
        defer { processingIDs.remove(transaction.id) }
        try await deliver(transaction)
        await client.finish(transactionID: transaction.id)
        finishedIDs.insert(transaction.id)
        return true
    }
}
