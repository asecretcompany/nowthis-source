import UIKit

/// Keeps a synchronous database-open attempt from being suspended with a file lock.
@MainActor
final class StoreOpenBackgroundTask {
    typealias Begin = (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let begin: Begin
    private let end: (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        begin: @escaping Begin = {
            UIApplication.shared.beginBackgroundTask(withName: "open-task-store", expirationHandler: $0)
        },
        end: @escaping (UIBackgroundTaskIdentifier) -> Void = {
            UIApplication.shared.endBackgroundTask($0)
        }
    ) {
        self.begin = begin
        self.end = end
    }

    func perform<Container>(
        open: () -> Result<Container, StoreOpenFailure>
    ) -> Result<Container, StoreOpenFailure> {
        // Acquire execution time before SwiftData can take any SQLite/WAL locks.
        // Starting this in a scenePhase callback would be too late for a cold launch.
        identifier = begin { [weak self] in self?.finish() }
        guard identifier != .invalid else {
            return .failure(StoreOpenFailure(message: String(
                localized: "NowThis couldn’t safely open your saved tasks yet. Please bring the app to the foreground and tap Retry.",
                comment: "Shown on the saved-task recovery screen when iOS refuses extra execution time for opening the database. Retry is the existing button."
            )))
        }
        defer { finish() }
        return open()
    }

    private func finish() {
        guard identifier != .invalid else { return }
        let completed = identifier
        identifier = .invalid
        end(completed)
    }
}
