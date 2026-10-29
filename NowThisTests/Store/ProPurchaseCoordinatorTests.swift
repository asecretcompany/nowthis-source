import Foundation
import Testing
@testable import NowThis

@Suite("Pro purchase coordinator")
@MainActor
struct ProPurchaseCoordinatorTests {
    private func tip(_ id: UInt64 = 1, product: String = "com.asecretcompany.nowthis.tip.small") -> VerifiedProTransaction {
        VerifiedProTransaction(id: id, productID: product, purchaseDate: Date(timeIntervalSince1970: 100),
                               expirationDate: nil, revocationDate: nil, isUpgraded: false)
    }

    @Test func localizedProductPriceComesFromStoreClient() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        try await coordinator.loadProducts()
        #expect(coordinator.products[.lifetime]?.displayPrice == "€39,99")
    }

    @Test func productLoadingFailureCanBeRetried() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        client.productError = .offline
        await #expect(throws: ProStoreTestClient.Failure.self) { try await coordinator.loadProducts() }
        client.productError = nil
        try await coordinator.loadProducts()
        #expect(coordinator.products.count == 2)
    }

    @Test func transientCatalogFailureRecoversWithoutManualRetry() async throws {
        let client = ProStoreTestClient()
        client.productLoader = {
            if client.productLoads == 1 { throw ProStoreTestClient.Failure.offline }
            return client.offeredProducts
        }
        let coordinator = ProPurchaseCoordinator(client: client)
        try await coordinator.loadProducts()
        #expect(client.productLoads == 2)
        #expect(coordinator.products[.lifetime] != nil)
    }

    @Test func emptyCatalogIsRetriedAndNeverReportedAsSuccess() async {
        let client = ProStoreTestClient()
        client.offeredProducts = [:]
        let coordinator = ProPurchaseCoordinator(client: client)
        await #expect(throws: ProStoreClientError.self) { try await coordinator.loadProducts() }
        #expect(client.productLoads == 3)
        #expect(coordinator.products.isEmpty)
    }

    @Test func catalogCanRecoverAfterAnEmptyStoreResponse() async throws {
        let client = ProStoreTestClient()
        client.productLoader = { client.productLoads == 1 ? [:] : client.offeredProducts }
        let coordinator = ProPurchaseCoordinator(client: client)
        try await coordinator.loadProducts()
        #expect(client.productLoads == 2)
        #expect(coordinator.products[.lifetime] != nil)
    }

    @Test func concurrentCatalogLoadsShareTheSameRequest() async throws {
        let client = ProStoreTestClient()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        client.productLoader = {
            for await _ in gate.stream { break }
            return client.offeredProducts
        }
        let coordinator = ProPurchaseCoordinator(client: client)
        let first = Task { try await coordinator.loadProducts() }
        for _ in 0..<1_000 where client.productLoads == 0 { await Task.yield() }
        try #require(client.productLoads == 1)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            try await coordinator.loadProducts()
        }
        for _ in 0..<1_000 where !secondStarted { await Task.yield() }
        try #require(secondStarted)
        #expect(client.productLoads == 1)
        gate.continuation.finish()
        try await first.value
        try await second.value
        #expect(coordinator.products[.lifetime] != nil)
    }

    @Test func partialCatalogKeepsAvailableProductsPurchasable() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        try await coordinator.loadProducts()
        #expect(client.productLoads == 1)
        #expect(try await coordinator.purchase(.lifetime) == .cancelled)
        #expect(client.purchaseOffers == [.lifetime])
    }

    @Test func cancelledCatalogLoadIsNotRetried() async {
        let client = ProStoreTestClient()
        client.productLoader = { throw CancellationError() }
        let coordinator = ProPurchaseCoordinator(client: client)
        await #expect(throws: CancellationError.self) { try await coordinator.loadProducts() }
        #expect(client.productLoads == 1)
    }

    @Test func verifiedDeliveryPrecedesFinishAndDuplicateUpdatesDoNotRedeliver() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        var delivered: [UInt64] = []
        let first = try await coordinator.process(.verified(tip())) { tx in
            client.events.append("deliver")
            delivered.append(tx.id)
        }
        let duplicate = try await coordinator.process(.verified(tip())) { tx in delivered.append(tx.id) }
        #expect(first)
        #expect(!duplicate)
        #expect(delivered == [1])
        #expect(client.events == ["deliver", "finish"])
        #expect(client.finishedIDs == [1])
    }

    @Test func simultaneousDuplicateDoesNotDeliverTwice() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var entered = false
        let first = Task {
            try await coordinator.process(.verified(tip())) { _ in
                entered = true
                for await _ in gate.stream { break }
            }
        }
        for _ in 0..<1_000 where !entered { await Task.yield() }
        try #require(entered, "Verified delivery must run before the transaction is finished")
        let second = try await coordinator.process(.verified(tip())) { _ in Issue.record("Duplicate delivery") }
        #expect(!second)
        gate.continuation.yield(())
        #expect(try await first.value)
        #expect(client.finishedIDs == [1])
    }

    @Test func failedDeliveryIsUnfinishedAndRetryable() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        await #expect(throws: ProStoreTestClient.Failure.self) {
            try await coordinator.process(.verified(tip())) { _ in throw ProStoreTestClient.Failure.offline }
        }
        #expect(client.finishedIDs.isEmpty)
        #expect(try await coordinator.process(.verified(tip())) { _ in })
        #expect(client.finishedIDs == [1])
    }

    @Test func differentTipTransactionsCanBePurchasedAndDeliveredRepeatedly() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        try await coordinator.loadProducts()
        client.result = .verified(tip(1))
        let first = try await coordinator.purchase(.tipSmall)
        #expect(try await coordinator.process(first) { _ in })
        client.result = .verified(tip(2))
        let second = try await coordinator.purchase(.tipSmall)
        #expect(try await coordinator.process(second) { _ in })
        #expect(client.purchaseOffers == [.tipSmall, .tipSmall])
        #expect(client.finishedIDs == [1, 2])
    }

    @Test(arguments: [ProPurchaseResult.pending, .cancelled, .unverified, .unavailable])
    func incompletePurchasesNeverDeliver(result: ProPurchaseResult) async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        let processed = try await coordinator.process(result) { _ in Issue.record("Unverified delivery") }
        #expect(!processed)
        #expect(client.finishedIDs.isEmpty)
    }

    @Test func unrelatedVerifiedTransactionIsNotFinished() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        #expect(try await !coordinator.process(.verified(tip(product: "another.product"))) { _ in
            Issue.record("Unknown product delivery")
        })
        #expect(client.finishedIDs.isEmpty)
    }

    @Test func unavailableProductDoesNotInitiatePurchase() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        #expect(try await coordinator.purchase(.annual) == .unavailable)
        #expect(client.purchaseOffers.isEmpty)
    }

    @Test func restoreSyncsAndPropagatesFailures() async throws {
        let client = ProStoreTestClient()
        let coordinator = ProPurchaseCoordinator(client: client)
        client.syncError = .offline
        await #expect(throws: ProStoreTestClient.Failure.self) { try await coordinator.restore() }
        client.syncError = nil
        client.evidence = ProEvidence(transactions: [tip()])
        let restored = try await coordinator.restore()
        #expect(client.syncCalls == 2)
        #expect(restored.transactions.map(\.id) == [1])
    }
}
