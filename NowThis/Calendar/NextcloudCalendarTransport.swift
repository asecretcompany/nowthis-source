import Foundation

typealias CalendarRequestValidation = @Sendable () async throws -> Void

/// These results come only from a pinned, top-level collection proof request.
enum CalendarCollectionProofError: Error {
    case absent
    case contradictoryClaim
}

struct CalendarStrongETag: Sendable, Codable, Equatable {
    let header: String

    init?(_ header: String?) {
        guard let header, header.utf8.count > 2, header.utf8.count <= 1_024,
              header.utf8.first == 34, header.utf8.last == 34,
              header.utf8.dropFirst().dropLast().allSatisfy({
                  $0 == 0x21 || (0x23...0x7e).contains($0) || $0 >= 0x80
              }) else { return nil }
        self.header = header
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let tag = Self(try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid strong ETag")
        }
        self = tag
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(header)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.header.utf8.elementsEqual(rhs.header.utf8) }
}

struct CalendarEventVersion: Sendable, Codable, Equatable {
    let href: String
    let uid: String
    let etag: CalendarStrongETag
}

struct CalendarEventTarget: Sendable, Codable, Equatable {
    let href: String
    let uid: String

    func version(_ etag: CalendarStrongETag) -> CalendarEventVersion { .init(href: href, uid: uid, etag: etag) }
}

enum CalendarEventRead: Sendable {
    case absent
    case unproved
    case present(CalendarEventVersion, operation: UUID, proof: String)
}

enum CalendarEventWrite: Sendable {
    case acknowledged(CalendarEventVersion)
    case indeterminate
}

enum NextcloudCalendarAddress {
    /// Append one encoded segment to the discovered URL without resolving away the installation path.
    static func child(_ name: String, of parent: URL, collection: Bool) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", NextcloudServerAddress.sameOrigin(parent, parent),
              var components = URLComponents(url: parent, resolvingAgainstBaseURL: false) else {
            throw CalDAVError.invalidURL
        }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        components.percentEncodedPath += NextcloudServerAddress.encodePathSegment(name)
        if collection { components.percentEncodedPath += "/" }
        guard let target = components.url else { throw CalDAVError.invalidURL }
        return target
    }
}

/// Network boundary: only immutable values leave a model owner.
protocol NextcloudCalendarTransport: Sendable {
    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult
    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL
    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead
    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite
    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws
}

actor NextcloudCalendarHTTPTransport: NextcloudCalendarTransport {
    private let client: CalDAVClient
    init(client: CalDAVClient = CalDAVClient()) {
        self.client = client
    }

    func discover(address: NextcloudServerAddress, admitted: CommittedAccountCredentials,
                  validate: @escaping CalendarRequestValidation) async throws -> CalDAVDiscoveryResult {
        try await CalDAVDiscovery(client: client, validateAccount: validate, validateRequestAttempts: true)
            .discover(address: address, credentials: admitted.davCredentials)
    }

    func ensureCollection(target: URL, marker: String, create: Bool, admitted: CommittedAccountCredentials,
                          validate: @escaping CalendarRequestValidation) async throws -> URL {
        let origin = try NextcloudServerAddress.parse(admitted.scope.serverBaseURL).baseURL
        guard NextcloudServerAddress.sameOrigin(target, origin) else { throw CalDAVError.invalidURL }
        return try await client.ensureEventCollection(target: target, marker: marker, create: create,
            credentials: admitted.davCredentials, validate: validate)
    }

    func read(target: CalendarEventTarget, admitted: CommittedAccountCredentials,
              validate: @escaping CalendarRequestValidation) async throws -> CalendarEventRead {
        let request = try Self.request("GET", target: target, admitted: admitted)
        let (data, response) = try await client.calendarEventRequest(request, responseLimit: NextcloudEventBody.maximumBytes, validate: validate)
        switch response.statusCode {
        case 404: return .absent
        case 200:
            guard let tag = CalendarStrongETag(response.value(forHTTPHeaderField: "ETag")),
                  data.count <= NextcloudEventBody.maximumBytes,
                  let body = String(data: data, encoding: .utf8),
                  let evidence = NextcloudEventBody.evidence(body, uid: target.uid) else { return .unproved }
            return .present(target.version(tag), operation: evidence.operation, proof: evidence.proof)
        default: throw CalDAVClient.calendarEventHTTPError(response.statusCode)
        }
    }

    func put(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
             validate: @escaping CalendarRequestValidation) async throws -> CalendarEventWrite {
        var request = try Self.request("PUT", target: intent.target, admitted: admitted)
        guard let body = intent.body, body.utf8.count <= NextcloudEventBody.maximumBytes else {
            throw CalDAVError.invalidResponse
        }
        switch intent.kind {
        case .create:
            guard intent.priorVersion == nil else { throw CalDAVError.invalidResponse }
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .update:
            guard let version = intent.priorVersion, intent.target.version(version.etag) == version else {
                throw CalDAVError.invalidResponse
            }
            request.setValue(version.etag.header, forHTTPHeaderField: "If-Match")
        case .remove: throw CalDAVError.invalidResponse
        }
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (_, response) = try await client.calendarEventRequest(request, validate: validate)
        switch response.statusCode {
        case 200, 201, 204:
            guard let tag = CalendarStrongETag(response.value(forHTTPHeaderField: "ETag")) else { return .indeterminate }
            return .acknowledged(intent.target.version(tag))
        default: throw CalDAVClient.calendarEventHTTPError(response.statusCode)
        }
    }

    func remove(_ intent: CalendarEventIntent, admitted: CommittedAccountCredentials,
                validate: @escaping CalendarRequestValidation) async throws {
        guard intent.kind == .remove, let version = intent.priorVersion,
              intent.target.version(version.etag) == version else {
            throw CalDAVError.invalidResponse
        }
        var request = try Self.request("DELETE", target: intent.target, admitted: admitted)
        request.setValue(version.etag.header, forHTTPHeaderField: "If-Match")
        let (_, response) = try await client.calendarEventRequest(request, validate: validate)
        switch response.statusCode {
        case 200, 204, 404: return
        default: throw CalDAVClient.calendarEventHTTPError(response.statusCode)
        }
    }

    private static func request(_ method: String, target: CalendarEventTarget,
                                admitted: CommittedAccountCredentials) throws -> URLRequest {
        let origin = try NextcloudServerAddress.parse(admitted.scope.serverBaseURL).baseURL
        guard let url = URL(string: target.href, encodingInvalidCharacters: false),
              NextcloudServerAddress.sameOrigin(url, origin) else {
            throw CalDAVError.invalidURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue(admitted.davCredentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        return request
    }
}
