import Testing
import UIKit
@testable import NowThis

@MainActor
@Suite struct StoreOpenBackgroundTaskTests {
    @Test(arguments: [false, true])
    func protectionEnclosesTheOpenAndEndsOnEitherResult(fails: Bool) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        var protected = false
        var events: [String] = []
        let protection = StoreOpenBackgroundTask(begin: { _ in
            protected = true
            events.append("begin")
            return identifier
        }, end: { ended in
            #expect(ended == identifier)
            #expect(protected)
            protected = false
            events.append("end")
        })

        let result: Result<String, StoreOpenFailure> = protection.perform {
            #expect(protected)
            events.append("open")
            return fails ? .failure(StoreOpenFailure(message: "disk full")) : .success("original-store")
        }

        #expect(events == ["begin", "open", "end"])
        #expect(!protected)
        switch result {
        case .success(let store): #expect(!fails && store == "original-store")
        case .failure(let error): #expect(fails && error.message == "disk full")
        }
    }

    @Test func deniedProtectionDoesNotTouchTheStore() {
        var attempts = 0
        var ends = 0
        let protection = StoreOpenBackgroundTask(begin: { _ in .invalid }, end: { _ in ends += 1 })
        let result: Result<String, StoreOpenFailure> = protection.perform {
            attempts += 1
            return .success("original-store")
        }

        #expect(attempts == 0)
        #expect(ends == 0)
        guard case .failure(let error) = result else {
            Issue.record("Denied execution time must defer opening instead of taking an unprotected lock")
            return
        }
        #expect(!error.message.isEmpty)
        let state = StoreOpenState<String>.recovery(message: error.message)
        #expect(!state.canPerformDataActions)
    }

    @Test func expirationAndCompletionEndTheAssertionOnlyOnce() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        var expire: (@MainActor @Sendable () -> Void)?
        var ended: [UIBackgroundTaskIdentifier] = []
        let protection = StoreOpenBackgroundTask(begin: { handler in
            expire = handler
            return identifier
        }, end: { ended.append($0) })

        let result: Result<String, StoreOpenFailure> = protection.perform {
            #expect(expire != nil)
            expire?()
            expire?()
            #expect(ended == [identifier])
            return .success("original-store")
        }

        expire?()
        #expect(ended == [identifier])
        guard case .success(let store) = result else { Issue.record("Result must be preserved"); return }
        #expect(store == "original-store")
    }

    @Test func retryAfterDeniedProtectionRequestsFreshExecutionTime() {
        let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
        var begins = 0
        var ends = 0
        var attempts = 0
        let coordinator = StoreOpenCoordinator<String, StoreOpenFailure>(protect: { open in
            StoreOpenBackgroundTask(begin: { _ in
                begins += 1
                return begins == 1 ? .invalid : identifier
            }, end: { _ in ends += 1 }).perform(open: open)
        }, open: {
            attempts += 1
            return .success("original-store")
        })

        if case .success = coordinator.open() { Issue.record("First attempt should defer opening") }
        #expect(attempts == 0)
        guard case .success(let store) = coordinator.retry() else { Issue.record("Retry should succeed"); return }
        #expect(store == "original-store")
        #expect(begins == 2)
        #expect(attempts == 1)
        #expect(ends == 1)
    }
}
