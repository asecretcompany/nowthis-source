import SwiftData
import Testing
import UIKit
@testable import NowThis

@MainActor
@Suite struct StoreLaunchDelegateTests {
    @Test func preparingStartupDoesNotOpenUntilUIKitLaunches() throws {
        let container = try makeContainer()
        var events: [String] = []
        let delegate = StoreLaunchDelegate()
        delegate.prepare(coordinator: StoreOpenCoordinator {
            events.append("open")
            return .success(container)
        }, onLaunch: {
            events.append("register")
        }, onOpened: { opened in
            #expect(opened === container)
            events.append("configure")
            return nil
        })

        #expect(events.isEmpty, "SwiftUI App.init is too early to request UIKit execution time")
        #expect(delegate.storeOpenState == nil)
        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(events == ["register", "open", "configure"])
        #expect(delegate.storeOpenState?.container === container)
        // Registration and listeners must not be started twice.
        #expect(delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #expect(events == ["register", "open", "configure"])
    }

    @Test func retryWaitsForLaunchAndConfiguresOnlyAfterSuccessfulOpen() throws {
        let container = try makeContainer()
        var attempts = 0
        var configurations = 0
        var registrations = 0
        let delegate = StoreLaunchDelegate()
        delegate.prepare(coordinator: StoreOpenCoordinator {
            attempts += 1
            return attempts == 1 ? .failure(StoreOpenFailure(message: "deferred")) : .success(container)
        }, onLaunch: { registrations += 1 }, onOpened: { _ in configurations += 1; return nil })

        delegate.retry()
        #expect(attempts == 0)
        #expect(configurations == 0)
        #expect(registrations == 0)
        _ = delegate.application(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        #expect(attempts == 1)
        #expect(delegate.storeOpenState?.recoveryMessage == "deferred")
        #expect(configurations == 0)
        #expect(registrations == 1, "The handler must be registered before launch completes, even when opening fails")
        delegate.retry()
        #expect(attempts == 2)
        #expect(delegate.storeOpenState?.container === container)
        #expect(configurations == 1)
        #expect(registrations == 1)
        delegate.retry()
        #expect(attempts == 2, "A queued Retry after success must not reopen or restart services")
        #expect(configurations == 1)
        #expect(registrations == 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
