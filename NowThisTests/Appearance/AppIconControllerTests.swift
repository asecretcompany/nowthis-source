import Foundation
import Testing
import UIKit
@testable import NowThis

@MainActor
private final class FakeIconClient: AlternateIconClient {
    enum Failure: Error { case system }
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var requestedNames: [String?] = []
    var fails = false
    var beforeChange: (@MainActor () async -> Void)?
    func setAlternateIconName(_ name: String?) async throws {
        requestedNames.append(name)
        await beforeChange?()
        if fails { throw Failure.system }
        alternateIconName = name
    }
}

@Suite("Supporter app icon ownership")
@MainActor
struct AppIconControllerTests {
    private var defaultIcon: AppIconDefinition {
        AppIconDefinition(id: "default", alternateIconName: nil, previewAssetName: "AppLogo", collectionID: nil, title: "Default")
    }
    private var supporter: AppIconDefinition {
        AppIconDefinition(id: "supporter-2026", alternateIconName: "Supporter2026", previewAssetName: "Supporter2026Preview",
                          collectionID: "supporter-2026", title: "Supporter 2026")
    }

    @Test(arguments: ["supporter-midnight", "supporter-confetti"])
    func newArtworkCannotReplaceTheDefaultWithoutOwnership(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        await #expect(throws: AppIconError.self) {
            try await controller.select(icon, ownedCollectionIDs: [])
        }
        #expect(controller.selectedIconID == "default")
        #expect(fake.alternateIconName == nil)
        #expect(fake.requestedNames.isEmpty)
    }

    @Test(arguments: ["supporter-midnight", "supporter-confetti"])
    func earnedNewArtworkRemainsSelectedAfterSubscriptionExpiry(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let expired = ProAccessSnapshot(earnedCollectionIDs: ["supporter-2026"])
        let owned = ProEntitlementPolicy.ownedCollectionIDs(in: expired, collections: AppIconCatalog.collections, at: .distantFuture)
        #expect(!expired.isUnlocked(at: .distantFuture))
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        try await controller.select(icon, ownedCollectionIDs: owned)
        try await controller.reconcileOwnership(owned)
        #expect(controller.selectedIconID == iconID)
        #expect(fake.alternateIconName == icon.alternateIconName)
        #expect(AppIconController(client: fake).selectedIconID == iconID)
    }

    @Test(arguments: ["supporter-midnight", "supporter-confetti"])
    func lifetimeOwnersCanChooseNewArtworkAndReturnToTheDefault(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let lifetime = ProAccessSnapshot(access: .lifetime)
        let owned = ProEntitlementPolicy.ownedCollectionIDs(in: lifetime, collections: AppIconCatalog.collections, at: .distantFuture)
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        try await controller.select(icon, ownedCollectionIDs: owned)
        #expect(controller.selectedIconID == iconID)
        let primary = try #require(AppIconCatalog.icons.first { $0.alternateIconName == nil })
        try await controller.select(primary, ownedCollectionIDs: [])
        #expect(controller.selectedIconID == "default")
        #expect(fake.alternateIconName == nil)
    }

    @Test(arguments: ["supporter-midnight", "supporter-confetti"])
    func revocationOfNewArtworkReturnsToTheDefault(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let fake = FakeIconClient()
        fake.alternateIconName = icon.alternateIconName
        let controller = AppIconController(client: fake)
        try await controller.reconcileOwnership([])
        #expect(controller.selectedIconID == "default")
        #expect(fake.alternateIconName == nil)
    }

    @Test(arguments: ["SupporterMidnight", "SupporterConfetti"])
    func newArtworkHasBundledPreviewsAndSystemIconRegistration(alternateName: String) throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.alternateIconName == alternateName })
        #expect(UIImage(named: icon.previewAssetName) != nil)
        let definitions = try #require(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try #require(definitions["CFBundleAlternateIcons"] as? [String: Any])
        #expect(alternates[alternateName] != nil)
    }

    @Test func defaultNeedsNoOwnershipAndSelectionReadsTheSystem() async throws {
        let fake = FakeIconClient()
        fake.alternateIconName = "Supporter2026"
        let controller = AppIconController(client: fake)
        #expect(controller.selectedIconID == "supporter-2026")
        try await controller.select(defaultIcon, ownedCollectionIDs: [])
        #expect(fake.requestedNames.count == 1)
        #expect(fake.alternateIconName == nil)
        #expect(controller.selectedIconID == "default")
    }

    @Test func lockedArtworkNeverCallsTheSetter() async {
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        await #expect(throws: (any Error).self) {
            try await controller.select(supporter, ownedCollectionIDs: [])
        }
        #expect(fake.requestedNames.isEmpty)
    }

    @Test func successAndFailureReflectActualSystemSelection() async throws {
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        try await controller.select(supporter, ownedCollectionIDs: ["supporter-2026"])
        #expect(controller.selectedIconID == "supporter-2026")
        fake.fails = true
        await #expect(throws: (any Error).self) {
            try await controller.select(defaultIcon, ownedCollectionIDs: [])
        }
        #expect(controller.selectedIconID == "supporter-2026")
        #expect(controller.errorMessage != nil)
    }

    @Test func lostOwnershipResetsAndFailureCanRetry() async throws {
        let fake = FakeIconClient()
        fake.alternateIconName = "Supporter2026"
        fake.fails = true
        let controller = AppIconController(client: fake)
        await #expect(throws: (any Error).self) { try await controller.reconcileOwnership([]) }
        #expect(controller.selectedIconID == "supporter-2026")
        #expect(controller.errorMessage != nil)
        fake.fails = false
        try await controller.reconcileOwnership([])
        #expect(controller.selectedIconID == "default")
        #expect(controller.errorMessage == nil)
    }

    @Test func paidArtworkRemainsSelectableAfterProExpiry() async throws {
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        let expired = ProAccessSnapshot(earnedCollectionIDs: ["supporter-2026"])
        let owned = ProEntitlementPolicy.ownedCollectionIDs(in: expired, collections: AppIconCatalog.collections, at: .distantFuture)
        #expect(!expired.isUnlocked(at: .distantFuture))
        try await controller.select(supporter, ownedCollectionIDs: owned)
        try await controller.reconcileOwnership(owned)
        #expect(fake.alternateIconName == "Supporter2026")
    }

    @Test func unsupportedDeviceProvidesALocalizedState() async {
        let fake = FakeIconClient()
        fake.supportsAlternateIcons = false
        let controller = AppIconController(client: fake)
        await #expect(throws: (any Error).self) {
            try await controller.select(supporter, ownedCollectionIDs: ["supporter-2026"])
        }
        #expect(controller.errorMessage?.isEmpty == false)
        #expect(fake.requestedNames.isEmpty)
    }

    @Test func refundDuringSystemChangeIsReconciledBeforeReturning() async throws {
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        var resume: CheckedContinuation<Void, Never>?
        fake.beforeChange = { await withCheckedContinuation { resume = $0 } }
        let selecting = Task { try await controller.select(supporter, ownedCollectionIDs: ["supporter-2026"]) }
        for _ in 0..<30 where resume == nil { await Task.yield() }
        try #require(resume != nil)
        try await controller.reconcileOwnership([])
        fake.beforeChange = nil
        resume?.resume()
        try await selecting.value
        #expect(fake.alternateIconName == nil)
        #expect(controller.selectedIconID == "default")
        #expect(fake.requestedNames == ["Supporter2026", nil])
    }

    @Test func retryRepeatsAFailedSelectionInsteadOfOnlyCheckingCurrentOwnership() async throws {
        let fake = FakeIconClient()
        fake.fails = true
        let controller = AppIconController(client: fake)
        await #expect(throws: (any Error).self) {
            try await controller.select(supporter, ownedCollectionIDs: ["supporter-2026"])
        }
        fake.fails = false
        try await controller.retry(ownedCollectionIDs: ["supporter-2026"])
        #expect(fake.alternateIconName == "Supporter2026")
        #expect(controller.selectedIconID == "supporter-2026")
    }

    // Literal approved inventory: missing or misregistered artwork must fail at its consumer.
    private nonisolated static let holidayIconIDs = [
        "holiday-new-year",
        "holiday-valentine",
        "holiday-spring",
        "holiday-easter",
        "holiday-halloween",
        "holiday-harvest",
        "holiday-winter",
        "holiday-christmas",
        "holiday-advent",
        "holiday-nikolaus",
        "holiday-saint-martin",
        "holiday-carnival",
        "holiday-oktoberfest",
        "holiday-german-unity",
        "holiday-swiss-national",
        "holiday-kings-day",
        "holiday-sinterklaas",
        "holiday-france-national",
        "holiday-france-may",
        "holiday-epiphany",
        "holiday-bonfire-night",
        "holiday-hogmanay",
        "holiday-saint-patrick",
        "holiday-saint-david",
        "holiday-canada-day",
        "holiday-saint-jean",
        "holiday-us-independence",
        "holiday-midsummer",
        "holiday-hanukkah",
        "holiday-passover",
        "holiday-ramadan",
        "holiday-eid",
        "holiday-diwali",
        "holiday-holi",
        "holiday-vaisakhi",
        "holiday-vesak"
    ]

    @Test(arguments: holidayIconIDs)
    func holidayArtworkIsBundledAndRegisteredForBothDeviceFamilies(iconID: String) throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let name = try #require(icon.alternateIconName)
        #expect(UIImage(named: icon.previewAssetName) != nil)
        // Bundle.infoDictionary resolves device-qualified keys for the current device.
        // Read the shipped plist to verify both registrations in this universal app.
        let plistData = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let definitions = try #require(plist[key] as? [String: Any])
            let alternates = try #require(definitions["CFBundleAlternateIcons"] as? [String: Any])
            #expect(alternates[name] != nil)
        }
    }

    @Test(arguments: holidayIconIDs)
    func holidayArtworkRequiresItsOwnCollection(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        await #expect(throws: AppIconError.self) {
            try await controller.select(icon, ownedCollectionIDs: ["supporter-2026"])
        }
        #expect(controller.selectedIconID == "default")
        #expect(fake.requestedNames.isEmpty)
    }

    @Test(arguments: holidayIconIDs)
    func earnedHolidayArtworkSurvivesExpiryAndRelaunch(iconID: String) async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == iconID })
        let expired = ProAccessSnapshot(earnedCollectionIDs: ["supporter-holidays-2026"])
        let owned = ProEntitlementPolicy.ownedCollectionIDs(in: expired, collections: AppIconCatalog.collections, at: .distantFuture)
        #expect(!expired.isUnlocked(at: .distantFuture))
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        try await controller.select(icon, ownedCollectionIDs: owned)
        try await controller.reconcileOwnership(owned)
        #expect(controller.selectedIconID == iconID)
        #expect(AppIconController(client: fake).selectedIconID == iconID)
        try await controller.reconcileOwnership([])
        #expect(controller.selectedIconID == "default")
    }

    @Test func lifetimeSupportersCanSelectTheHolidayCollection() async throws {
        let icon = try #require(AppIconCatalog.icons.first { $0.id == "holiday-hanukkah" })
        let owned = ProEntitlementPolicy.ownedCollectionIDs(in: ProAccessSnapshot(access: .lifetime),
            collections: AppIconCatalog.collections, at: .distantFuture)
        let fake = FakeIconClient()
        let controller = AppIconController(client: fake)
        try await controller.select(icon, ownedCollectionIDs: owned)
        #expect(controller.selectedIconID == "holiday-hanukkah")
    }

    @Test func paidPeriodEarnsHolidayArtworkOnlyAfterItsRelease() throws {
        let collection = try #require(AppIconCatalog.collections.first { $0.id == "supporter-holidays-2026" })
        let release = Date(timeIntervalSince1970: 1_792_800_000) // 2026-10-24 UTC
        #expect(collection.releasedAt == release)
        let status = VerifiedSubscriptionStatus(transactionID: 1, productID: "com.asecretcompany.nowthis.pro.monthlyg",
            state: .expired, expirationDate: release.addingTimeInterval(1), graceExpirationDate: nil, willAutoRenew: false)
        let snapshot = ProAccessSnapshot(access: .monthly, validUntil: status.expirationDate,
            subscription: status)
        #expect(!ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: AppIconCatalog.collections,
            at: release.addingTimeInterval(-1)).contains("supporter-holidays-2026"))
        #expect(ProEntitlementPolicy.ownedCollectionIDs(in: snapshot, collections: AppIconCatalog.collections,
            at: release.addingTimeInterval(2)).contains("supporter-holidays-2026"))
    }

}
