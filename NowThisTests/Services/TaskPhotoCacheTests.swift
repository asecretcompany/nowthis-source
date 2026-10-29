import Foundation
import Testing

@testable import NowThis

struct TaskPhotoCacheTests {
    @Test func storesLoadsAndRemovesUUIDNamedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        let id = UUID().uuidString.lowercased()
        let data = Data([1, 2, 3, 4])
        try await cache.store(data, photoID: id)
        #expect(try await cache.load(photoID: id) == data)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files == [id])
        try await cache.remove(photoID: id)
        #expect(try await cache.load(photoID: id) == nil)
    }

    @Test func rejectsInvalidIDsWithoutEscapingDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        await #expect(throws: (any Error).self) { try await cache.store(Data([7]), photoID: "../outside") }
        await #expect(throws: (any Error).self) { try await cache.load(photoID: "../outside") }
        await #expect(throws: (any Error).self) { try await cache.remove(photoID: "../outside") }
        await #expect(throws: (any Error).self) { try await cache.retain(photoIDs: ["../outside"]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func retainRemovesOnlyUUIDsNotInSet() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        let retained = UUID().uuidString.lowercased()
        let removed = UUID().uuidString.lowercased()
        let unrelatedFile = directory.appendingPathComponent("notes.txt")
        try Data([9]).write(to: unrelatedFile)
        try await cache.store(Data([1]), photoID: retained)
        try await cache.store(Data([2]), photoID: removed)
        try await cache.retain(photoIDs: [retained])
        #expect(try await cache.load(photoID: retained) == Data([1]))
        #expect(try await cache.load(photoID: removed) == nil)
        #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    @Test func pruningGraceRetainsAnImportThatHasNotSavedItsModelYet() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TaskPhotoCache(directory: directory)
        let id = UUID().uuidString
        try await cache.store(Data([3]), photoID: id)
        try await cache.retain(photoIDs: [], olderThan: Date().addingTimeInterval(-3600))
        #expect(try await cache.load(photoID: id) == Data([3]))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
