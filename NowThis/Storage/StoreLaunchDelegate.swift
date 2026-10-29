import SwiftData
import SwiftUI
import UIKit

/// Opens the store once UIKit can grant execution time, before scene connection.
@MainActor
final class StoreLaunchDelegate: NSObject, UIApplicationDelegate, ObservableObject {
    @Published private(set) var storeOpenState: StoreOpenState<ModelContainer>?
    @Published private(set) var watchBridge: WatchBridge?
    private var coordinator: StoreOpenCoordinator<ModelContainer, StoreOpenFailure>?
    private var onOpened: ((ModelContainer) -> WatchBridge?)?
    private var onLaunch: (() -> Void)?
    private var hasLaunched = false

    func prepare(
        coordinator: StoreOpenCoordinator<ModelContainer, StoreOpenFailure>,
        onLaunch: @escaping () -> Void = {},
        onOpened: @escaping (ModelContainer) -> WatchBridge? = { _ in nil }
    ) {
        self.coordinator = coordinator
        self.onLaunch = onLaunch
        self.onOpened = onOpened
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !hasLaunched else { return true }
        hasLaunched = true
        onLaunch?()
        openStore()
        return true
    }

    func retry() {
        guard hasLaunched, storeOpenState?.container == nil else { return }
        openStore()
    }

    private func openStore() {
        guard let coordinator else { return }
        switch coordinator.open() {
        case .success(let container):
            watchBridge = onOpened?(container)
            storeOpenState = .opened(container)
        case .failure(let failure):
            watchBridge = nil
            storeOpenState = .recovery(message: failure.message)
        }
    }
}
