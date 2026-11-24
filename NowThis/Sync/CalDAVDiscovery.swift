import Foundation

struct DAVDiscoveryAddress: Sendable {
    let rawHref: String
    let requestURL: URL
}

struct CalDAVDiscoveryResult: Sendable {
    let principalURL: URL?
    let calendarHomeURL: URL
    let calendars: CalDAVClient.DiscoveredCalendars
    let collectionAddresses: [DAVDiscoveryAddress]
}

struct CalDAVDiscovery {
    let client: CalDAVClient
    var validateAccount: @Sendable () async throws -> Void = {}
    var validateRequestAttempts = false
    private let caldav = "urn:ietf:params:xml:ns:caldav"

    private var attemptValidation: (@Sendable () async throws -> Void)? {
        validateRequestAttempts ? validateAccount : nil
    }

    func discover(address: NextcloudServerAddress, credentials: CalDAVClient.Credentials) async throws -> CalDAVDiscoveryResult {
        let limit = ContinuousClock.now.advanced(by: .seconds(45))
        let deadline = min(DAVDiscoveryContext.deadline ?? limit, limit)
        return try await DAVDiscoveryContext.$deadline.withValue(deadline) {
            try await discoverInternal(address: address, credentials: credentials)
        }
    }

    private func discoverInternal(address: NextcloudServerAddress, credentials: CalDAVClient.Credentials) async throws -> CalDAVDiscoveryResult {
        let origin = address.baseURL
        let root = URL(string: address.baseURL.absoluteString + "/remote.php/dav/")!
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = "/.well-known/caldav"
        let wellKnown = components.url!
        let fallback = URL(string: root.absoluteString + "principals/users/" + NextcloudServerAddress.encodePathSegment(credentials.username) + "/")!
        var candidates: [URL] = []
        for candidate in [address.discoverySeed, root, wellKnown, fallback].compactMap({ $0 }) where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        var lastStatus: Int?
        var deepestStage: DAVDiscoveryFailure.Stage = .principal
        for candidate in candidates {
            let response: DAVDiscoveryResponse
            do {
                try await validateAccount()
                response = try await client.discoveryProperties(at: candidate, properties: ["<d:current-user-principal/>", "<c:calendar-home-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>"], depth: "0", allowedOrigin: origin, credentials: credentials, validateAttempt: attemptValidation)
            } catch CalDAVError.notFound { if deepestStage == .principal { lastStatus = 404 }; continue }
            catch CalDAVError.serverError(statusCode: 405) { if deepestStage == .principal { lastStatus = 405 }; continue }
            try await validateAccount()
            guard let resource = try matchingResource(response) else { continue }
            if let status = resource.responseStatusCode { try checkStatus(status) }
            try checkProperty(resource, "current-user-principal", allowMissing: true)
            try checkProperty(resource, "calendar-home-set", namespace: caldav, allowMissing: true)
            var principal: URL?
            var home: URL?
            if !resource.currentUserPrincipal.isEmpty {
                principal = try Self.resolveHref(resource.currentUserPrincipal, responseURL: response.responseURL, allowedOrigin: origin).requestURL
            }
            if !resource.calendarHomeSet.isEmpty {
                home = try Self.resolveHref(resource.calendarHomeSet, responseURL: response.responseURL, allowedOrigin: origin).requestURL
            }
            if home == nil, let principal {
                deepestStage = .home
                lastStatus = nil
                let principalResponse: DAVDiscoveryResponse
                do {
                    try await validateAccount()
                    principalResponse = try await client.discoveryProperties(at: principal, properties: ["<c:calendar-home-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>"], depth: "0", allowedOrigin: origin, credentials: credentials, stage: .home, validateAttempt: attemptValidation)
                } catch CalDAVError.notFound { lastStatus = 404; continue }
                try await validateAccount()
                guard let principalResource = try matchingResource(principalResponse, stage: .home) else { continue }
                if let status = principalResource.responseStatusCode { try checkStatus(status) }
                try checkProperty(principalResource, "calendar-home-set", namespace: caldav, allowMissing: true)
                if !principalResource.calendarHomeSet.isEmpty {
                    home = try Self.resolveHref(principalResource.calendarHomeSet, responseURL: principalResponse.responseURL, allowedOrigin: origin, stage: .home).requestURL
                }
            }
            guard let home else { continue }
            return try await refreshCalendars(homeURL: home, allowedOrigin: origin, credentials: credentials, principalURL: principal)
        }
        throw DAVDiscoveryFailure(stage: deepestStage, method: .propfind, httpStatus: lastStatus, reason: lastStatus == 405 ? .methodNotAllowed : .metadataMissing)
    }

    func refreshCalendars(homeURL: URL, allowedOrigin: URL, credentials: CalDAVClient.Credentials, principalURL: URL? = nil) async throws -> CalDAVDiscoveryResult {
        let limit = ContinuousClock.now.advanced(by: .seconds(45))
        let deadline = min(DAVDiscoveryContext.deadline ?? limit, limit)
        return try await DAVDiscoveryContext.$deadline.withValue(deadline) {
            try await refreshCalendarsInternal(homeURL: homeURL, allowedOrigin: allowedOrigin, credentials: credentials, principalURL: principalURL)
        }
    }

    private func refreshCalendarsInternal(homeURL: URL, allowedOrigin: URL, credentials: CalDAVClient.Credentials, principalURL: URL?) async throws -> CalDAVDiscoveryResult {
        let listing: DAVDiscoveryResponse
        do {
            try await validateAccount()
            listing = try await client.discoveryProperties(at: homeURL, properties: ["<d:displayname/>", "<d:resourcetype/>", "<cs:getctag xmlns:cs=\"http://calendarserver.org/ns/\"/>", "<d:sync-token/>", "<d:supported-report-set/>", "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>", "<x:calendar-color xmlns:x=\"http://apple.com/ns/ical/\"/>", "<d:current-user-privilege-set/>", "<nc:deleted-at xmlns:nc=\"http://nextcloud.com/ns\"/>"], depth: "1", allowedOrigin: allowedOrigin, credentials: credentials, stage: .collections, validateAttempt: attemptValidation)
        } catch CalDAVError.notFound {
            throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: 404, reason: .metadataMissing)
        }
        try await validateAccount()
        guard !listing.resources.isEmpty else { throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .incompleteListing) }
        var resources: [DAVXMLParser.DAVResource] = []
        var addresses: [DAVDiscoveryAddress] = []
        var seen: [URL] = []
        var foundHome = false
        for var item in listing.resources {
            try checkStatus(item.statusCode)
            let resolved = try Self.resolveHref(item.href, responseURL: listing.responseURL, allowedOrigin: allowedOrigin, stage: .collections)
            guard !seen.contains(where: { Self.sameResource($0, resolved.requestURL) }) else { throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .incompleteListing) }
            seen.append(resolved.requestURL)
            for status in item.propertyStatusCodes.values where status != 404 { try checkStatus(status) }
            if Self.sameResource(resolved.requestURL, listing.responseURL) {
                guard item.propertyStatus("resourcetype") == 200 else {
                    throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .incompleteListing)
                }
                foundHome = true
                continue
            }
            guard Self.isDirectChild(resolved.requestURL, of: listing.responseURL) else {
                throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .incompleteListing)
            }
            try checkProperty(item, "resourcetype", allowMissing: false)
            if item.isCalendar { try checkProperty(item, "supported-calendar-component-set", namespace: caldav, allowMissing: false) }
            addresses.append(resolved)
            item.href = resolved.requestURL.absoluteString
            resources.append(item)
        }
        guard foundHome else { throw DAVDiscoveryFailure(stage: .collections, method: .propfind, httpStatus: nil, reason: .incompleteListing) }
        let calendars = CalDAVClient.partitionTrashed(resources, calendarHomePath: listing.responseURL.absoluteString)
        return CalDAVDiscoveryResult(principalURL: principalURL, calendarHomeURL: listing.responseURL, calendars: calendars, collectionAddresses: addresses)
    }

    private static func sameResource(_ lhs: URL, _ rhs: URL) -> Bool {
        guard NextcloudServerAddress.sameOrigin(lhs, rhs),
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return left.percentEncodedPath == right.percentEncodedPath
    }

    private static func isDirectChild(_ child: URL, of home: URL) -> Bool {
        guard let childPath = URLComponents(url: child, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let homePath = URLComponents(url: home, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        func segments(_ path: String) -> [String]? {
            guard path.hasPrefix("/") else { return nil }
            var parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            guard parts.allSatisfy({ part in
                guard !part.isEmpty, let decoded = part.removingPercentEncoding else { return false }
                return decoded != "." && decoded != ".."
            }) else { return nil }
            return parts
        }
        guard let parentSegments = segments(homePath), let childSegments = segments(childPath) else { return false }
        return childSegments.count == parentSegments.count + 1 && childSegments.starts(with: parentSegments)
    }

    private func matchingResource(_ response: DAVDiscoveryResponse, stage: DAVDiscoveryFailure.Stage = .principal) throws -> DAVXMLParser.DAVResource? {
        let matches = try response.resources.filter {
            try Self.sameResource(Self.resolveHref($0.href, responseURL: response.responseURL, allowedOrigin: response.responseURL, stage: stage).requestURL, response.responseURL)
        }
        guard matches.count <= 1 else { throw CalDAVError.invalidResponse }
        return matches.first
    }

    private func checkStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw CalDAVError.unauthorized
        case 403: throw CalDAVError.forbidden
        case 404: throw CalDAVError.notFound
        case 429: throw CalDAVError.rateLimited(retryAfter: nil)
        case 500...599: throw CalDAVError.serverError(statusCode: status)
        default: throw CalDAVError.invalidResponse
        }
    }

    private func checkProperty(_ resource: DAVXMLParser.DAVResource, _ name: String, namespace: String = "DAV:", allowMissing: Bool) throws {
        guard let status = resource.propertyStatus(name, namespace: namespace) else {
            if allowMissing { return }; throw CalDAVError.invalidResponse
        }
        if status == 404 && allowMissing { return }
        try checkStatus(status)
    }

    static func resolveHref(_ raw: String, responseURL: URL, allowedOrigin: URL, stage: DAVDiscoveryFailure.Stage = .principal) throws -> DAVDiscoveryAddress {
        guard !raw.isEmpty, let url = URL(string: raw, relativeTo: responseURL)?.absoluteURL,
              NextcloudServerAddress.sameOrigin(url, allowedOrigin) else { throw DAVDiscoveryFailure(stage: stage, method: .propfind, httpStatus: nil, reason: .untrustedAddress) }
        return DAVDiscoveryAddress(rawHref: raw, requestURL: url)
    }
}
