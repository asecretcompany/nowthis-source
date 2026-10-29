import Foundation

enum ProOffer: String, CaseIterable, Codable, Sendable {
    case monthly, annual, lifetime, tipSmall, tipMedium, tipLarge, tipExtra

    var isSubscription: Bool { self == .monthly || self == .annual }
    var isTip: Bool { self != .lifetime && !isSubscription }
}

enum ProProductCatalog {
    static func productID(for offer: ProOffer) -> String {
        switch offer {
        case .lifetime: AppConstants.proProductID
        // These are the existing, immutable App Store Connect identifiers.
        case .monthly: AppConstants.proProductID + ".monthlyg"
        case .annual: AppConstants.proProductID + ".annualg"
        case .tipSmall: "com.asecretcompany.nowthis.tip.small"
        case .tipMedium: "com.asecretcompany.nowthis.tip.medium"
        case .tipLarge: "com.asecretcompany.nowthis.tip.large"
        case .tipExtra: "com.asecretcompany.nowthis.tip.extra"
        }
    }

    static func offer(for productID: String) -> ProOffer? {
        if let offer = ProOffer.allCases.first(where: { self.productID(for: $0) == productID }) { return offer }
        // Continue recognizing verified evidence from the original catalog.
        switch productID {
        case AppConstants.proProductID + ".monthly": return .monthly
        case AppConstants.proProductID + ".annual": return .annual
        default: return nil
        }
    }
}
