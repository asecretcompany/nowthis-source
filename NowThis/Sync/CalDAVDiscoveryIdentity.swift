import Foundation
import CryptoKit

struct SyncCollectionAddress: Sendable {
    let storageHref: String
    let requestURL: URL
}

struct DiscoveredCollection: Sendable {
    let address: SyncCollectionAddress
    let calendar: CalDAVClient.RemoteCalendar
}

extension CalDAVDiscovery {
    static func creationTarget(listID: String, homeURL: URL) throws -> URL {
        guard var home = URLComponents(url: homeURL, resolvingAgainstBaseURL: false),
              NextcloudServerAddress.sameOrigin(homeURL, homeURL) else { throw CalDAVError.invalidURL }
        if !home.percentEncodedPath.hasSuffix("/") { home.percentEncodedPath += "/" }
        home.percentEncodedPath += "nowthis-" + creationDigest(domain: "path", listID: listID) + "/"
        guard let target = home.url else { throw CalDAVError.invalidURL }
        return target
    }

    static func creationMarker(listID: String) -> String {
        creationDigest(domain: "marker", listID: listID)
    }

    private static func creationDigest(domain: String, listID: String) -> String {
        SHA256.hash(data: Data("nowthis.caldav.\(domain).v1:\(listID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func sameCollection(_ lhs: URL, _ rhs: URL) -> Bool {
        guard NextcloudServerAddress.sameOrigin(lhs, rhs),
              let path = encodedPath(lhs) else { return false }
        return encodedPath(rhs) == path
    }

    private static func encodedPath(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    static var ambiguousCollection: DAVDiscoveryFailure {
        DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .ambiguousIdentity)
    }

    /// Discovery can see a collection from a prior create before its reply can be verified.
    /// Keep the full listing authoritative and withhold just the unresolved imports.
    static func heldCreationHrefs(
        _ live: [CalDAVClient.RemoteCalendar], unboundIDs: [String], boundHrefs: Set<String>, homeURL: URL
    ) throws -> Set<String> {
        let reservedPaths = Set(try unboundIDs.compactMap { listID in
            encodedPath(try creationTarget(listID: listID, homeURL: homeURL))
        })
        return Set(live.compactMap { calendar in
            guard !boundHrefs.contains(calendar.href), let url = URL(string: calendar.href),
                  NextcloudServerAddress.sameOrigin(url, homeURL),
                  let path = encodedPath(url), reservedPaths.contains(path) else { return nil }
            return calendar.href
        })
    }

    /// Equivalent authorities and an identical encoded path address the same resource.
    /// Do not collapse path case, escaped delimiters, or trailing slashes.
    static func matchExistingList(
        discovered: DAVDiscoveryAddress,
        existing: [(storageHref: String, requestURL: URL)]
    ) throws -> String? {
        guard encodedPath(discovered.requestURL) != nil else {
            throw CalDAVError.invalidURL
        }
        let matches = existing.filter { sameCollection($0.requestURL, discovered.requestURL) }
        guard matches.count <= 1 else { throw ambiguousCollection }
        return matches.first?.storageHref
    }

    static func preservingStorageIdentities(
        _ calendars: CalDAVClient.DiscoveredCalendars,
        existingHrefs: [String], baseURL: String
    ) throws -> CalDAVClient.DiscoveredCalendars {
        guard let base = URL(string: baseURL) else { throw CalDAVError.invalidURL }
        let existing = existingHrefs.filter { !$0.isEmpty }.compactMap { href -> (storageHref: String, requestURL: URL)? in
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  NextcloudServerAddress.sameOrigin(base, url), url.user == nil, url.password == nil else { return nil }
            return (href, url)
        }
        func adapt(_ calendar: CalDAVClient.RemoteCalendar) throws -> CalDAVClient.RemoteCalendar {
            guard let requestURL = URL(string: calendar.href),
                  NextcloudServerAddress.sameOrigin(base, requestURL) else { throw CalDAVError.invalidURL }
            let address = DAVDiscoveryAddress(rawHref: calendar.href, requestURL: requestURL)
            let href = try matchExistingList(discovered: address, existing: existing) ?? requestURL.absoluteString
            // The legacy engine treats href as a storage identity. Its transport resolves this
            // href against the same base above, proving equivalent authority and encoded path.
            return CalDAVClient.RemoteCalendar(href: href, displayName: calendar.displayName,
                ctag: calendar.ctag, color: calendar.color, syncToken: calendar.syncToken,
                supportsSyncCollection: calendar.supportsSyncCollection, deletedAtRaw: calendar.deletedAtRaw,
                privileges: calendar.privileges)
        }
        return try .init(live: calendars.live.map(adapt), trashed: calendars.trashed.map(adapt))
    }
}
