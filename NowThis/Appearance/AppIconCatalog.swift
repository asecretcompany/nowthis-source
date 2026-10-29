import Foundation

struct AppIconCollection: Equatable, Sendable {
    let id: String
    let releasedAt: Date
}

struct AppIconDefinition {
    let id: String
    let alternateIconName: String?
    let previewAssetName: String
    let collectionID: String?
    let title: LocalizedStringResource
}

enum AppIconCatalog {
    static let icons: [AppIconDefinition] = [
        AppIconDefinition(id: "default", alternateIconName: nil, previewAssetName: "AppLogo", collectionID: nil, title: "Default"),
        AppIconDefinition(id: "supporter-2026", alternateIconName: "Supporter2026", previewAssetName: "Supporter2026Preview",
                          collectionID: "supporter-2026", title: "Supporter 2026"),
        AppIconDefinition(id: "supporter-midnight", alternateIconName: "SupporterMidnight", previewAssetName: "SupporterMidnightPreview",
                          collectionID: "supporter-2026", title: LocalizedStringResource("icon.midnight.title", defaultValue: "Midnight", comment: "Name of the dark navy Supporter app icon.")),
        AppIconDefinition(id: "supporter-confetti", alternateIconName: "SupporterConfetti", previewAssetName: "SupporterConfettiPreview",
                          collectionID: "supporter-2026", title: LocalizedStringResource("icon.confetti.title", defaultValue: "Confetti", comment: "Name of the colorful celebratory Supporter app icon."))
    ]
    static let collections = [
        AppIconCollection(id: "supporter-2026", releasedAt: Date(timeIntervalSince1970: 1_790_899_200)) // 2026-10-02 UTC
    ]
}
