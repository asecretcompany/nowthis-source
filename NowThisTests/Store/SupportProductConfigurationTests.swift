import Foundation
import Testing
@testable import NowThis

@Suite("Support product configuration")
struct SupportProductConfigurationTests {
    @Test func subscriptionRequestsMatchTheExistingAppStoreConnectRecords() {
        #expect(ProProductCatalog.productID(for: .monthly) == "com.asecretcompany.nowthis.pro.monthlyg")
        #expect(ProProductCatalog.productID(for: .annual) == "com.asecretcompany.nowthis.pro.annualg")
        #expect(ProProductCatalog.offer(for: "com.asecretcompany.nowthis.pro.monthlyg") == .monthly)
        #expect(ProProductCatalog.offer(for: "com.asecretcompany.nowthis.pro.annualg") == .annual)
        // Preserve recognition of signed history from the original catalog.
        #expect(ProProductCatalog.offer(for: "com.asecretcompany.nowthis.pro.monthly") == .monthly)
        #expect(ProProductCatalog.offer(for: "com.asecretcompany.nowthis.pro.annual") == .annual)
    }

    private func products() throws -> [[String: Any]] {
        let url = try LocalizationCatalogFixture.repositoryRoot().appendingPathComponent("NowThis/Store/NowThisStore.storekit")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let groups = root["subscriptionGroups"] as? [[String: Any]] ?? []
        return (root["products"] as? [[String: Any]] ?? []) + groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }
    }

    @Test func everyOfferHasTheCorrectProductTypeAndLocalizedMetadata() throws {
        let all = try products()
        #expect(all.count == 7)
        var examined = 0
        for offer in ProOffer.allCases {
            let item = try #require(all.first { $0["productID"] as? String == ProProductCatalog.productID(for: offer) })
            let expectedType = offer.isSubscription ? "RecurringSubscription" : (offer.isTip ? "Consumable" : "NonConsumable")
            #expect(item["type"] as? String == expectedType)
            #expect(item["familyShareable"] as? Bool == false)
            if offer.isSubscription { #expect(item["recurringSubscriptionPeriod"] as? String == (offer == .monthly ? "P1M" : "P1Y")) }
            let localizations = try #require(item["localizations"] as? [[String: String]])
            #expect(Set(localizations.compactMap { $0["locale"] }) == ["en_US", "de_DE", "es_ES", "fr_FR", "it", "nl_NL"])
            for block in localizations {
                examined += 1
                let name = try #require(block["displayName"])
                let description = try #require(block["description"])
                #expect(!name.isEmpty && name.utf16.count <= 30)
                #expect(!description.isEmpty && description.utf16.count <= 45)
                #expect(StoreProductRules.isNFC(name) && StoreProductRules.isNFC(description))
                if !offer.isTip { #expect(name.hasPrefix("NowThis Supporter") && description.contains("Apple Watch")) }
                else { #expect(!description.contains("Apple Watch")) }
            }
        }
        #expect(examined == 42)
    }
}
