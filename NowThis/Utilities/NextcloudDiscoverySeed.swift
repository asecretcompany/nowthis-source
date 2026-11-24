import Foundation
import SwiftData

/// User-supplied DAV starting point, stored separately from discovered endpoints.
enum NextcloudDiscoverySeed {
    /// An invocation can validate the selection without making the seed part of destination identity.
    struct Selection: Sendable {
        let address: NextcloudServerAddress
        fileprivate let accountID: String
        fileprivate let storedPath: String?

        func isCurrent(in context: ModelContext) throws -> Bool {
            let rows = try NextcloudDiscoverySeed.records(accountID: accountID, limit: 2, in: context)
            guard rows.count <= 1 else { return false }
            guard let current = rows.first else { return storedPath == nil }
            guard let storedPath else { return false }
            return current.collectionPath.utf8.elementsEqual(storedPath.utf8)
        }
    }

    struct InvalidSelection: Error {}

    static func capture(accountID: String, serverURL: String, in context: ModelContext) throws -> Selection {
        let base = try NextcloudServerAddress.parse(serverURL)
        let rows = try records(accountID: accountID, limit: 2, in: context)
        guard rows.count <= 1 else { throw InvalidSelection() }
        guard let path = rows.first?.collectionPath else {
            return Selection(address: base, accountID: accountID, storedPath: nil)
        }
        guard let seed = try? NextcloudServerAddress.parse(path), seed.discoverySeed != nil,
              matches(seed.baseURL, base.baseURL) else { throw InvalidSelection() }
        return Selection(address: seed, accountID: accountID, storedPath: path)
    }

    static func address(accountID: String, serverURL: String, in context: ModelContext) throws -> NextcloudServerAddress {
        let base = try NextcloudServerAddress.parse(serverURL)
        let row = try records(accountID: accountID, limit: 1, in: context).first
        guard let value = row?.collectionPath,
              let seed = try? NextcloudServerAddress.parse(value),
              seed.discoverySeed != nil,
              matches(seed.baseURL, base.baseURL) else { return base }
        return seed
    }

    private static func records(accountID: String, limit: Int, in context: ModelContext) throws -> [SyncMetadata] {
        let key = "nextcloud-user-seed:" + accountID
        var descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    static func store(accountID: String, seed: URL?, baseURL: URL, in context: ModelContext) throws {
        guard let seed else { try remove(accountID: accountID, in: context); return }
        let parsed = try NextcloudServerAddress.parse(seed.absoluteString)
        guard parsed.discoverySeed != nil, matches(parsed.baseURL, baseURL) else {
            throw NextcloudServerAddress.ParseError.invalid
        }
        let key = "nextcloud-user-seed:" + accountID
        if let row = try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })).first {
            row.collectionPath = seed.absoluteString
        } else {
            context.insert(SyncMetadata(id: key, collectionPath: seed.absoluteString))
        }
    }

    static func remove(accountID: String, in context: ModelContext) throws {
        let key = "nextcloud-user-seed:" + accountID
        for row in try context.fetch(FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.id == key })) {
            context.delete(row)
        }
    }

    private static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        NextcloudServerAddress.sameOrigin(lhs, rhs) &&
            URLComponents(url: lhs, resolvingAgainstBaseURL: false)?.percentEncodedPath ==
            URLComponents(url: rhs, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }
}
