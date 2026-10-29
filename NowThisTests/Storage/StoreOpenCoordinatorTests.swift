import Foundation
import Testing
@testable import NowThis

@MainActor
@Suite struct StoreOpenCoordinatorTests {
    enum SimulatedOpenError: Error, Equatable {
        case protectedFile
        case diskFull
        case unsupportedSchema
    }

    @Test(arguments: [SimulatedOpenError.protectedFile, .diskFull, .unsupportedSchema])
    func failedOpenPreservesOriginalStoreFiles(error: SimulatedOpenError) throws {
        let files = try makeStoreFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var attempts = 0
        let coordinator = StoreOpenCoordinator<String, SimulatedOpenError> {
            attempts += 1
            return .failure(error)
        }

        let result = coordinator.open()

        #expect(failure(in: result) == error)
        #expect(attempts == 1)
        #expect(try contents(of: files.paths) == files.originals)
    }

    @Test func successfulOpenReturnsTheOpenedStore() {
        let originalStore = "original-container"
        let coordinator = StoreOpenCoordinator<String, SimulatedOpenError> {
            .success(originalStore)
        }

        #expect(openedStore(in: coordinator.open()) == originalStore)
    }

    @Test func retryExplicitlyInvokesTheSameOpenOperationAgain() {
        var attempts = 0
        let coordinator = StoreOpenCoordinator<String, SimulatedOpenError> {
            attempts += 1
            return attempts == 1 ? .failure(.diskFull) : .success("original-container")
        }

        #expect(failure(in: coordinator.open()) == .diskFull)
        #expect(attempts == 1)
        #expect(openedStore(in: coordinator.retry()) == "original-container")
        #expect(attempts == 2)
    }

    @Test func dataActionsAreAvailableOnlyAfterTheConfiguredStoreOpens() {
        let recovery = StoreOpenState<String>.recovery(message: "protected store")
        let opened = StoreOpenState<String>.opened("original-container")

        #expect(!recovery.canPerformDataActions)
        #expect(opened.canPerformDataActions)
    }

    @Test func initialOpenAndExplicitRetryEachRunInsideProtection() {
        var protected = false
        var protections = 0
        var attempts = 0
        let coordinator = StoreOpenCoordinator<String, SimulatedOpenError>(protect: { open in
            protections += 1
            protected = true
            defer { protected = false }
            return open()
        }, open: {
            #expect(protected, "Database opening must be protected before it can acquire SQLite locks")
            attempts += 1
            return attempts == 1 ? .failure(.diskFull) : .success("original-container")
        })

        #expect(failure(in: coordinator.open()) == .diskFull)
        #expect(openedStore(in: coordinator.retry()) == "original-container")
        #expect(protections == 2)
        #expect(attempts == 2)
        #expect(!protected)
    }

    private func makeStoreFiles() throws -> (directory: URL, paths: [URL], originals: [[UInt8]]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["Tasks.store", "Tasks.store-wal", "Tasks.store-shm"]
        let originals: [[UInt8]] = [
            [0x53, 0x51, 0x4c, 0x69, 0x74, 0x65],
            [0x57, 0x41, 0x4c, 0x2d, 0x6f, 0x72, 0x69, 0x67],
            [0x53, 0x48, 0x4d, 0x2d, 0x6f, 0x72, 0x69, 0x67]
        ]
        let paths = try zip(names, originals).map { name, bytes -> URL in
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
        return (directory, paths, originals)
    }

    private func contents(of paths: [URL]) throws -> [[UInt8]] {
        try paths.map { Array(try Data(contentsOf: $0)) }
    }

    private func failure<T, E: Error>(in result: Result<T, E>) -> E? {
        guard case .failure(let error) = result else { return nil }
        return error
    }

    private func openedStore<T, E: Error>(in result: Result<T, E>) -> T? {
        guard case .success(let store) = result else { return nil }
        return store
    }
}
