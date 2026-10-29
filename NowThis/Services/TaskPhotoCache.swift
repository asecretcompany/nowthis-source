import Foundation

actor TaskPhotoCache {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func store(_ data: Data, photoID: String) throws {
        try ensureDirectoryExists()
        let destination = try fileURL(for: photoID)
        #if os(iOS)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: destination, options: [.atomic])
        #endif
    }

    func load(photoID: String) throws -> Data? {
        let file = try fileURL(for: photoID)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func remove(photoID: String) throws {
        let file = try fileURL(for: photoID)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    func retain(photoIDs: Set<String>, olderThan: Date? = nil) throws {
        let retainedNames = try Set(photoIDs.map { try fileURL(for: $0).lastPathComponent })
        try ensureDirectoryExists()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for file in files where isCacheFile(file) && !retainedNames.contains(file.lastPathComponent) {
            if let olderThan {
                guard let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < olderThan else { continue }
            }
            try FileManager.default.removeItem(at: file)
        }
    }

    private func fileURL(for photoID: String) throws -> URL {
        guard let uuid = UUID(uuidString: photoID) else {
            throw CacheError.invalidPhotoID
        }
        return directory.appendingPathComponent(uuid.uuidString.lowercased())
    }

    private func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func isCacheFile(_ file: URL) -> Bool {
        return UUID(uuidString: file.lastPathComponent) != nil
    }

    private enum CacheError: Error {
        case invalidPhotoID
    }
}
