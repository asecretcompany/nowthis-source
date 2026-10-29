import Foundation

extension CalDAVClient {
    struct RemoteResource: Sendable, Equatable {
        let href: String
        let etag: String
    }

    /// A page is transport accounting only. Its token becomes a checkpoint only
    /// after the caller has durably applied this page and all body requests.
    struct SyncDeltaPage: Sendable {
        let resources: [RemoteResource]
        let deletedHrefs: [String]
        let nextToken: String
        let hasMore: Bool
    }
}

enum CalDAVSyncError: Error, Equatable {
    case invalidSyncToken
}

/// RFC 6578 scope is the collection and its immediate members. Normalize href
/// spellings before detecting duplicates, while rejecting other origins/paths.
struct DAVCollectionScope {
    let collectionURL: URL
    private let collectionPath: String

    init(baseURL: String, calendarPath: String) throws {
        guard let base = URL(string: baseURL),
              let origin = URL(string: "/", relativeTo: base)?.absoluteURL,
              let collection = URL(string: calendarPath, relativeTo: origin)?.absoluteURL,
              Self.sameOrigin(base, collection),
              ["http", "https"].contains(collection.scheme?.lowercased() ?? ""),
              collection.host != nil, collection.query == nil, collection.fragment == nil,
              collection.user == nil, collection.password == nil else { throw CalDAVError.invalidURL }
        collectionPath = try Self.decodedPath(collection).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: collection, resolvingAgainstBaseURL: true)!
        components.path = "/" + collectionPath + "/"
        guard let url = components.url else { throw CalDAVError.invalidURL }
        collectionURL = url
    }

    func href(_ raw: String, allowCollection: Bool = false) throws -> String {
        guard !raw.isEmpty,
              let url = URL(string: raw, relativeTo: collectionURL)?.absoluteURL,
              Self.sameOrigin(url, collectionURL), url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { throw CalDAVError.invalidResponse }
        let decoded = try Self.decodedPath(url)
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if allowCollection && trimmed == collectionPath { return "/" + collectionPath + "/" }
        let prefix = "/" + collectionPath + "/"
        guard decoded.hasPrefix(prefix) else { throw CalDAVError.invalidResponse }
        let member = String(decoded.dropFirst(prefix.count))
        guard !member.isEmpty, !member.contains("/") else { throw CalDAVError.invalidResponse }
        var components = URLComponents()
        components.path = decoded
        return components.percentEncodedPath
    }

    func isCollection(_ href: String) -> Bool {
        href == "/" + collectionPath + "/"
    }

    private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }

    private static func decodedPath(_ url: URL) throws -> String {
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath else {
            throw CalDAVError.invalidResponse
        }
        let segments = try encoded.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            guard let value = String(part).removingPercentEncoding,
                  value != ".", value != "..", !value.contains("/"), !value.contains("\\") else {
                throw CalDAVError.invalidResponse
            }
            return value
        }
        return segments.joined(separator: "/")
    }
}
