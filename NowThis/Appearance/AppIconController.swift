import Foundation
import UIKit

@MainActor
protocol AlternateIconClient {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ name: String?) async throws
}

@MainActor
struct SystemAlternateIconClient: AlternateIconClient {
    var supportsAlternateIcons: Bool { UIApplication.shared.supportsAlternateIcons }
    var alternateIconName: String? { UIApplication.shared.alternateIconName }
    func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

enum AppIconError: LocalizedError {
    case locked, unsupported, changeFailed
    var errorDescription: String? {
        switch self {
        case .locked:
            String(localized: "icon.locked", defaultValue: "Available with Supporter", comment: "Cosmetic collection requires Supporter ownership.")
        case .unsupported:
            String(localized: "icon.unsupported", defaultValue: "App icons cannot be changed on this device.", comment: "Device does not support alternate app icons.")
        case .changeFailed:
            String(localized: "icon.failed", defaultValue: "Couldn't change the app icon. Try again.", comment: "Icon change or reset failed. Keep actual selection and allow retry.")
        }
    }
}

/// UIKit owns the selection. Entitlement events can arrive during a system
/// change; defer their reconciliation until that change finishes.
@MainActor
@Observable
final class AppIconController {
    @ObservationIgnored private let client: any AlternateIconClient
    @ObservationIgnored private var pendingOwnership: Set<String>?
    @ObservationIgnored private var retryIcon: AppIconDefinition?
    @ObservationIgnored nonisolated(unsafe) private var accessTask: Task<Void, Never>?
    private(set) var selectedIconID: String
    private(set) var errorMessage: String?
    private(set) var isChanging = false
    var supportsAlternateIcons: Bool { client.supportsAlternateIcons }

    init(client: any AlternateIconClient = SystemAlternateIconClient()) {
        self.client = client
        selectedIconID = Self.iconID(for: client.alternateIconName)
    }

    private static func iconID(for name: String?) -> String {
        AppIconCatalog.icons.first { $0.alternateIconName == name }?.id ?? "unknown"
    }

    func start(entitlement: ProEntitlement) {
        guard accessTask == nil else { return }
        let changes = entitlement.accessChanges()
        accessTask = Task { [weak self, weak entitlement] in
            for await _ in changes {
                guard let self, let entitlement else { break }
                try? await self.reconcileOwnership(entitlement.ownedCollectionIDs)
            }
        }
    }

    func select(_ icon: AppIconDefinition, ownedCollectionIDs: Set<String>) async throws {
        guard supportsAlternateIcons else {
            errorMessage = AppIconError.unsupported.localizedDescription
            throw AppIconError.unsupported
        }
        guard icon.collectionID.map(ownedCollectionIDs.contains) ?? true else { throw AppIconError.locked }
        guard !isChanging else { return }
        try await change(to: icon.alternateIconName)
    }

    func reconcileOwnership(_ ownedCollectionIDs: Set<String>) async throws {
        if isChanging { pendingOwnership = ownedCollectionIDs; return }
        selectedIconID = Self.iconID(for: client.alternateIconName)
        guard let name = client.alternateIconName else { errorMessage = nil; return }
        let selected = AppIconCatalog.icons.first { $0.alternateIconName == name }
        guard let collection = selected?.collectionID, ownedCollectionIDs.contains(collection) else {
            try await change(to: nil)
            return
        }
        errorMessage = nil
    }

    func retry(ownedCollectionIDs: Set<String>) async throws {
        if let retryIcon, retryIcon.collectionID.map(ownedCollectionIDs.contains) ?? true {
            try await select(retryIcon, ownedCollectionIDs: ownedCollectionIDs)
        } else {
            try await reconcileOwnership(ownedCollectionIDs)
        }
    }

    private func change(to name: String?) async throws {
        isChanging = true
        do {
            try await client.setAlternateIconName(name)
            selectedIconID = Self.iconID(for: client.alternateIconName)
            errorMessage = nil
            retryIcon = nil
            isChanging = false
            if let pendingOwnership {
                self.pendingOwnership = nil
                try await reconcileOwnership(pendingOwnership)
            }
        } catch {
            selectedIconID = Self.iconID(for: client.alternateIconName)
            errorMessage = AppIconError.changeFailed.localizedDescription
            retryIcon = AppIconCatalog.icons.first { $0.alternateIconName == name }
            isChanging = false
            if let pendingOwnership {
                self.pendingOwnership = nil
                try? await reconcileOwnership(pendingOwnership)
            }
            throw error
        }
    }

    deinit { accessTask?.cancel() }
}
