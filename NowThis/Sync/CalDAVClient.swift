import Foundation

struct DAVDiscoveryResponse: Sendable {
    let resources: [DAVXMLParser.DAVResource]
    let responseURL: URL
}

enum DAVDiscoveryContext {
    @TaskLocal static var deadline: ContinuousClock.Instant?
}

/// URLSession-based CalDAV HTTP client for Nextcloud Tasks.
///
/// All operations use `async/await` and run on background threads.
/// Credentials are passed per-request via Basic authentication headers.
///
/// **Supported CalDAV operations:**
/// - User principal discovery (`PROPFIND /.well-known/caldav`)
/// - Calendar home discovery (`PROPFIND {principal}`)
/// - Task list discovery (`PROPFIND {calendarHome}`)
/// - Task fetch via calendar-multiget `REPORT`
/// - Single task GET/PUT/DELETE with ETag support
actor CalDAVClient {

    // MARK: - Types

    /// Credentials for a CalDAV request.
    struct Credentials: Sendable {
        let username: String
        let password: String

        /// Returns the Basic auth header value.
        var basicAuthHeader: String {
            let data = "\(username):\(password)".data(using: .utf8) ?? Data()
            return "Basic \(data.base64EncodedString())"
        }
    }

    /// A CalDAV calendar (task list) discovered on the server.
    struct RemoteCalendar: Sendable {
        let href: String
        let displayName: String
        let ctag: String
        let color: String
        let syncToken: String

        /// Advertised report capability; a discovery token alone is insufficient.
        var supportsSyncCollection: Bool = false

        /// Raw `{http://nextcloud.com/ns}deleted-at` value; empty when the server reported none.
        let deletedAtRaw: String

        /// Whether the server has moved this collection to its trash.
        ///
        /// Decided by the marker being *present*, never by whether its value parses as a date.
        /// A format we do not recognise must still keep the collection out of the user's lists.
        var isTrashed: Bool {
            !deletedAtRaw.isEmpty || CalDAVClient.isTrashbinHref(href)
        }

        /// Best-effort deletion date, for display only. `nil` when absent or unrecognised.
        var deletedAt: Date? { CalDAVClient.parseDeletedAt(deletedAtRaw) }

        /// The user's `current-user-privilege-set` on this collection. Empty when the
        /// server did not report one.
        var privileges: Set<String> = []

        /// Whether the user may not change this collection's tasks — typically a list
        /// shared with them read-only.
        ///
        /// A server that reports no privileges is taken at its word as writable, which is
        /// how every list behaved before this was read. Coarse on purpose: a collection
        /// that allows edits but not adding or removing resources is not caught here, and
        /// falls to the 403 rollback instead.
        var isReadOnly: Bool {
            guard !privileges.isEmpty else { return false }
            return privileges.isDisjoint(with: ["all", "write", "write-content"])
        }
    }

    /// The outcome of a calendar-home PROPFIND, split at the source so a caller cannot
    /// accidentally treat a discarded collection as a live one.
    struct DiscoveredCalendars: Sendable {
        let live: [RemoteCalendar]
        let trashed: [RemoteCalendar]
    }

    /// A task resource on the server.
    struct RemoteTask: Sendable {
        let href: String
        let etag: String
        let icsData: String
    }

    // MARK: - Properties

    private let session: URLSession

    /// Retry policy for transient failures (5xx, dropped connections). The first
    /// request after the app resumes from the background frequently hits a stale
    /// keep-alive connection; retrying eliminates the spurious "Server error (500)".
    private let retryPolicy: RetryPolicy
    private let maxResponseBytes: Int
    private var retryDeadline: Date?
    private var runBudget: BackgroundRunBudget?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    init(retryPolicy: RetryPolicy = .default,
         maxResponseBytes: Int = DAVResponseLimit.defaultMaxBytes,
         retryDeadline: Date? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 1...1.2) },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        precondition(maxResponseBytes > 0, "DAV response limit must be positive")
        self.retryPolicy = retryPolicy
        self.maxResponseBytes = maxResponseBytes
        self.retryDeadline = retryDeadline
        self.now = now
        self.sleep = sleep
        self.jitter = jitter

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        // Use a delegate that preserves PROPFIND/REPORT methods across redirects
        self.session = URLSession(
            configuration: config,
            delegate: CalDAVClientRedirectDelegate(),
            delegateQueue: nil
        )
    }

    init(configuration: URLSessionConfiguration, retryPolicy: RetryPolicy = .default,
         maxResponseBytes: Int = DAVResponseLimit.defaultMaxBytes,
         retryDeadline: Date? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 1...1.2) },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        precondition(maxResponseBytes > 0, "DAV response limit must be positive")
        self.retryPolicy = retryPolicy
        self.maxResponseBytes = maxResponseBytes
        self.retryDeadline = retryDeadline
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
        self.session = URLSession(configuration: configuration,
            delegate: CalDAVClientRedirectDelegate(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Sets the absolute deadline for the current serialized collection run.
    /// A later run may replace or clear it before starting its own requests.
    func setRunDeadline(_ deadline: Date?) {
        retryDeadline = deadline
    }

    func setRunBudget(_ budget: BackgroundRunBudget?) {
        runBudget = budget
    }

    func clearRunBudget(runID: UUID) {
        guard runBudget?.runID == runID else { return }
        runBudget = nil
    }

    func discoveryProperties(at url: URL, properties: [String], depth: String,
                             allowedOrigin: URL, credentials: Credentials, stage: DAVDiscoveryFailure.Stage = .principal,
                             strictPropertyEvidence: Bool = false,
                             singleAttempt: Bool = false,
                             requireExactResponse: Bool = false,
                             validateAttempt: (@Sendable () async throws -> Void)? = nil) async throws -> DAVDiscoveryResponse {
        guard NextcloudServerAddress.sameOrigin(url, allowedOrigin),
              let request = Self.makeDAVRequest(method: "PROPFIND", url: url.absoluteString,
                body: propfindBody(properties: properties), credentials: credentials, depth: depth) else {
            throw DAVDiscoveryFailure(stage: stage, method: .propfind, httpStatus: nil, reason: .untrustedAddress)
        }
        let budget = runBudget ?? BackgroundRunBudget.current
        let cutoff = DAVDiscoveryContext.deadline
        let policy = singleAttempt ? RetryPolicy(maxAttempts: 1, baseDelay: 0) : retryPolicy
        // Give retry admission the discovery allowance as well as the run's
        // deadline. An authoritative server wait that exceeds it must become
        // RetryDeferredError, rather than being lost to the outer timeout.
        let discoveryRetryUntil = cutoff.map { cutoff in
            let duration = max(.zero, cutoff - ContinuousClock.now).components
            return now().addingTimeInterval(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        }
        let retryUntil = [budget == nil ? retryDeadline : nil, discoveryRetryUntil].compactMap { $0 }.min()
        let session = session
        let maxBytes = maxResponseBytes
        let clock = now
        let jitter = jitter
        let sleep = sleep
        let data: Data
        let response: URLResponse
        do {
            // Discovery shares normal DAV retry semantics, including durable
            // Retry-After deferral. Its absolute allowance also bounds backoff.
            (data, response) = try await DeadlineRequestExecutor.perform(deadline: cutoff) {
                try await withRetry(policy: policy, deadline: retryUntil, runBudget: budget,
                                    now: clock, jitter: jitter, sleep: sleep) {
                    try await validateAttempt?()
                    let result = try await Self.performRequest(request, session: session,
                        budget: budget, maxResponseBytes: maxBytes, now: clock,
                        exactTarget: strictPropertyEvidence || requireExactResponse, allowRedirects: !requireExactResponse,
                        discoveryOrigin: allowedOrigin,
                        validateRedirect: validateAttempt)
                    guard let http = result.1 as? HTTPURLResponse, let finalURL = http.url,
                          NextcloudServerAddress.sameOrigin(finalURL, allowedOrigin),
                          !requireExactResponse || Self.isPinnedTarget(finalURL, of: url) else {
                        throw DAVDiscoveryFailure(stage: stage, method: .propfind, httpStatus: nil, reason: .untrustedAddress)
                    }
                    if requireExactResponse { try Self.validateCalendarResponseLength(result.0, response: http) }
                    switch http.statusCode {
                    case 200, 207: return result
                    case 401: throw CalDAVError.unauthorized
                    case 403: throw CalDAVError.forbidden
                    case 404 where requireExactResponse: throw CalendarCollectionProofError.absent
                    case 404: throw CalDAVError.notFound
                    case 429: throw CalDAVError.rateLimited(retryAfter: nil)
                    default: throw CalDAVError.serverError(statusCode: http.statusCode)
                    }
                }
            }
        } catch is RetryDeferredError where policy.connectionFailuresOnly {
            // Setup has no later scheduled run to consume retry deferrals. Its
            // connection-only backoff must surface the exhausted allowance.
            throw DAVDiscoveryFailure(stage: stage, method: .propfind,
                httpStatus: nil, reason: .deadlineExceeded)
        } catch let error as DAVRedirectRejection {
            throw DAVDiscoveryFailure(stage: stage, method: .propfind,
                httpStatus: error.httpStatus, reason: .untrustedAddress)
        } catch let error as BackgroundBudgetExhausted {
            if let cutoff, ContinuousClock.now >= cutoff,
               budget == nil || cutoff < budget!.remoteCutoff {
                throw DAVDiscoveryFailure(stage: stage, method: .propfind, httpStatus: nil, reason: .deadlineExceeded)
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw CalDAVError.invalidResponse
        }
        do {
            return DAVDiscoveryResponse(resources: try DAVXMLParser().parse(data: data, strictPropertyEvidence: strictPropertyEvidence),
                responseURL: finalURL)
        } catch {
            throw DAVDiscoveryFailure(stage: stage, method: .propfind, httpStatus: http.statusCode, reason: .unsupportedResponse)
        }
    }

    // MARK: - Discovery

    /// Discovers the CalDAV user principal URL.
    ///
    /// Sends a `PROPFIND` to `/.well-known/caldav` and follows redirects
    /// to find the `current-user-principal` property.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL (e.g., `https://cloud.example.com`).
    ///   - credentials: Authentication credentials.
    /// - Returns: The user principal URL path.
    func discoverPrincipal(
        baseURL: String,
        credentials: Credentials
    ) async throws -> String {
        // Try Nextcloud-specific path first
        guard let encodedUsername = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw CalDAVError.invalidURL
        }
        let principalEndpoint = try nextcloudEndpoint(baseURL: baseURL, suffix: "/remote.php/dav/principals/users/\(encodedUsername)/")
        let nextcloudPath = try resolveURL(baseURL: baseURL, path: principalEndpoint)

        // Verify it exists
        let body = propfindBody(properties: ["<d:current-user-principal/>"])
        let (data, _) = try await sendDAVRequest(
            method: "PROPFIND",
            url: nextcloudPath,
            body: body,
            credentials: credentials,
            depth: "0"
        )

        let parser = DAVXMLParser()
        let resources = try parser.parse(data: data)

        // Look for current-user-principal in the response
        for resource in resources {
            if !resource.currentUserPrincipal.isEmpty {
                return resource.currentUserPrincipal
            }
        }

        // Fallback: the principal is the URL we just hit
        if let url = URL(string: nextcloudPath) {
            return url.path
        }

        throw CalDAVError.noUserPrincipal
    }

    /// Discovers the calendar home URL from the user principal.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - principalPath: The user principal URL path.
    ///   - credentials: Authentication credentials.
    /// - Returns: The calendar home URL path.
    func discoverCalendarHome(
        baseURL: String,
        principalPath: String,
        credentials: Credentials
    ) async throws -> String {
        let url = try resolveURL(baseURL: baseURL, path: principalPath)

        let body = propfindBody(properties: [
            "<c:calendar-home-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>"
        ])

        let (data, _) = try await sendDAVRequest(
            method: "PROPFIND",
            url: url,
            body: body,
            credentials: credentials,
            depth: "0"
        )

        let parser = DAVXMLParser()
        let resources = try parser.parse(data: data)

        for resource in resources {
            if !resource.calendarHomeSet.isEmpty {
                return resource.calendarHomeSet
            }
        }

        // Nextcloud fallback
        let encodedUser = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.username
        let fallback = try nextcloudEndpoint(baseURL: baseURL, suffix: "/remote.php/dav/calendars/\(encodedUser)/")
        return fallback
    }

    /// Discovers all task calendars (VTODO-supporting) in the calendar home.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - calendarHomePath: The calendar home URL path.
    ///   - credentials: Authentication credentials.
    /// - Returns: The VTODO-supporting calendars, split into the ones that should sync and the
    ///   ones the server is holding in its trash.
    func discoverTaskCalendars(
        baseURL: String,
        calendarHomePath: String,
        credentials: Credentials
    ) async throws -> DiscoveredCalendars {
        let url = try resolveURL(baseURL: baseURL, path: calendarHomePath)

        let body = propfindBody(properties: [
            "<d:displayname/>",
            "<d:resourcetype/>",
            "<cs:getctag xmlns:cs=\"http://calendarserver.org/ns/\"/>",
            "<d:sync-token/>",
            "<d:supported-report-set/>",
            "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>",
            "<x:calendar-color xmlns:x=\"http://apple.com/ns/ical/\"/>",
            // RFC 3744. Marks lists shared read-only, so the move picker can refuse them
            // before a PUT is refused. Servers without ACL support answer 404 and every
            // list stays writable, as before.
            "<d:current-user-privilege-set/>",
            // Nextcloud marks a trashed collection with this. Servers that do not implement it
            // answer 404 for the property and are unaffected: the value stays empty, and
            // `partitionTrashed` filters nothing.
            "<nc:deleted-at xmlns:nc=\"http://nextcloud.com/ns\"/>"
        ])

        let (data, _) = try await sendDAVRequest(
            method: "PROPFIND",
            url: url,
            body: body,
            credentials: credentials,
            depth: "1"
        )

        let parser = DAVXMLParser()
        let resources = try parser.parse(data: data)

        return Self.partitionTrashed(resources, calendarHomePath: calendarHomePath)
    }

    /// Splits a parsed calendar-home multistatus into the collections that should sync and the
    /// ones the server has thrown away.
    ///
    /// This split is tested directly with parsed DAV resources and through the live discovery path.
    /// Keeping it pure makes the server's href/name and trash conventions independently testable.
    ///
    /// **Why it exists.** Discovery used to filter on `isVTODOSupported` and "not the home
    /// itself" and nothing else, so a calendar sitting in Nextcloud's trash was imported as an
    /// ordinary list. A user who deletes and recreates a calendar twice ends up with three rows
    /// bearing one name — reported from a Murena account on 2026-08-28, with untouched lists
    /// appearing exactly once alongside, which is what ruled out every whole-collection cause.
    static func partitionTrashed(
        _ resources: [DAVXMLParser.DAVResource],
        calendarHomePath: String
    ) -> DiscoveredCalendars {
        let calendars = resources
            .filter { $0.isVTODOSupported }
            .filter { $0.href != calendarHomePath } // Exclude the home itself
            .map { resource in
                RemoteCalendar(
                    href: resource.href,
                    displayName: resource.displayName,
                    ctag: resource.ctag,
                    color: resource.calendarColor,
                    syncToken: resource.syncToken,
                    supportsSyncCollection: resource.supportsSyncCollection,
                    deletedAtRaw: resource.deletedAt,
                    privileges: resource.privileges
                )
            }

        return DiscoveredCalendars(
            live: calendars.filter { !$0.isTrashed },
            trashed: calendars.filter(\.isTrashed)
        )
    }

    /// Whether an href sits under a `trashbin` path segment.
    ///
    /// Belt and braces beside the `deleted-at` marker: the reporting user's server could not be
    /// inspected, so which of the two shapes Nextcloud used there is unconfirmed. Matched as a
    /// whole path segment, so a user's own calendar named "trashbin-archive" is untouched.
    static func isTrashbinHref(_ href: String) -> Bool {
        href.split(separator: "/").contains { $0.lowercased() == "trashbin" }
    }

    /// Parses a `deleted-at` value **for display only**.
    ///
    /// Nextcloud sends a Unix timestamp; other servers and later versions may not. An
    /// unparseable value must never change whether the collection counts as trashed, which is
    /// why `isTrashed` does not consult this.
    static func parseDeletedAt(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let iso = ISO8601DateFormatter().date(from: raw) {
            return iso
        }
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(identifier: "GMT")
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return httpDate.date(from: raw)
    }

    // MARK: - Task Operations

    /// A complete VTODO-filtered inventory. Only ETags are requested; a failed
    /// report cannot become an empty snapshot eligible for absence deletion.
    func fetchTaskManifest(
        baseURL: String,
        calendarPath: String,
        credentials: Credentials
    ) async throws -> [RemoteResource] {
        let scope = try DAVCollectionScope(baseURL: baseURL, calendarPath: calendarPath)
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/></d:prop>
          <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO"/></c:comp-filter></c:filter>
        </c:calendar-query>
        """
        let (data, response) = try await sendDAVRequest(method: "REPORT", url: scope.collectionURL.absoluteString,
            body: body, credentials: credentials, depth: "1")
        guard (response as? HTTPURLResponse)?.statusCode == 207 else { throw CalDAVError.invalidResponse }
        let resources = try DAVXMLParser().parse(data: data)
        var seen: Set<String> = []
        var result: [RemoteResource] = []
        for resource in resources {
            let href = try scope.href(resource.href, allowCollection: true)
            guard seen.insert(href).inserted else { throw CalDAVError.invalidResponse }
            try Self.requireSuccessfulResponse(resource)
            if scope.isCollection(href) { continue }
            try Self.requireProperty("getetag", in: resource)
            guard !resource.etag.isEmpty else { throw CalDAVError.invalidResponse }
            result.append(RemoteResource(href: href, etag: resource.etag))
        }
        return result
    }

    /// The caller chooses batches of at most 100. Every requested href must
    /// appear once with ETag and full content; a 404 here is a failed batch.
    func fetchTaskBatch(
        baseURL: String,
        calendarPath: String,
        hrefs: [String],
        credentials: Credentials
    ) async throws -> [RemoteTask] {
        guard hrefs.count <= 100 else { throw CalDAVError.invalidResponse }
        let scope = try DAVCollectionScope(baseURL: baseURL, calendarPath: calendarPath)
        var requested: [String: String] = [:]
        for href in hrefs {
            let canonical = try scope.href(href)
            guard requested.updateValue(href, forKey: canonical) == nil else { throw CalDAVError.invalidResponse }
        }
        if hrefs.isEmpty { return [] }
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop><d:getetag/><c:calendar-data/></d:prop>
          \(hrefs.map { "<d:href>\(Self.xmlEscape($0))</d:href>" }.joined(separator: "\n  "))
        </c:calendar-multiget>
        """
        let (data, response) = try await sendDAVRequest(method: "REPORT", url: scope.collectionURL.absoluteString,
            body: body, credentials: credentials, depth: "1")
        guard (response as? HTTPURLResponse)?.statusCode == 207 else { throw CalDAVError.invalidResponse }
        let resources = try DAVXMLParser().parse(data: data)
        var seen: Set<String> = []
        var result: [RemoteTask] = []
        for resource in resources {
            let href = try scope.href(resource.href)
            guard let original = requested[href], seen.insert(href).inserted else { throw CalDAVError.invalidResponse }
            try Self.requireSuccessfulResponse(resource)
            try Self.requireProperty("getetag", in: resource)
            try Self.requireProperty("calendar-data", namespace: "urn:ietf:params:xml:ns:caldav", in: resource)
            guard !resource.etag.isEmpty, !resource.calendarData.isEmpty else { throw CalDAVError.invalidResponse }
            result.append(RemoteTask(href: original, etag: resource.etag, icsData: resource.calendarData))
        }
        guard seen == Set(requested.keys) else { throw CalDAVError.invalidResponse }
        return result
    }

    /// Requests one RFC 6578 page. The caller supplies a token from an accounted
    /// local baseline and persists nextToken only after applying the changes.
    func fetchSyncDelta(
        baseURL: String,
        calendarPath: String,
        syncToken: String,
        credentials: Credentials
    ) async throws -> SyncDeltaPage {
        guard !syncToken.isEmpty else { throw CalDAVError.invalidResponse }
        let scope = try DAVCollectionScope(baseURL: baseURL, calendarPath: calendarPath)
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:sync-collection xmlns:d="DAV:">
          <d:sync-token>\(Self.xmlEscape(syncToken))</d:sync-token>
          <d:sync-level>1</d:sync-level>
          <d:limit><d:nresults>100</d:nresults></d:limit>
          <d:prop><d:getetag/></d:prop>
        </d:sync-collection>
        """
        let (data, response) = try await sendDAVRequest(method: "REPORT", url: scope.collectionURL.absoluteString,
            body: body, credentials: credentials, depth: "0", recognizesInvalidSyncToken: true)
        guard (response as? HTTPURLResponse)?.statusCode == 207 else { throw CalDAVError.invalidResponse }
        let parser = DAVXMLParser()
        let resources = try parser.parse(data: data)
        guard !parser.syncToken.isEmpty else { throw CalDAVError.invalidResponse }
        var seen: Set<String> = []
        var updated: [RemoteResource] = []
        var deleted: [String] = []
        var hasMore = false
        for resource in resources {
            let href = try scope.href(resource.href, allowCollection: true)
            guard seen.insert(href).inserted else { throw CalDAVError.invalidResponse }
            if scope.isCollection(href) {
                // A collection 507 inside 207 is the continuation sentinel.
                guard resource.responseStatusCode == 507 else { throw CalDAVError.invalidResponse }
                hasMore = true
            } else if resource.responseStatusCode == 404 {
                deleted.append(href)
            } else {
                try Self.requireSuccessfulResponse(resource)
                try Self.requireProperty("getetag", in: resource)
                guard !resource.etag.isEmpty else { throw CalDAVError.invalidResponse }
                updated.append(RemoteResource(href: href, etag: resource.etag))
            }
        }
        guard !hasMore || parser.syncToken != syncToken else { throw CalDAVError.invalidResponse }
        return SyncDeltaPage(resources: updated, deletedHrefs: deleted, nextToken: parser.syncToken, hasMore: hasMore)
    }

    private static func requireSuccessfulResponse(_ resource: DAVXMLParser.DAVResource) throws {
        if resource.statusCode == 403 || resource.propstatStatusCodes.contains(403) { throw CalDAVError.forbidden }
        if resource.statusCode == 404 { throw CalDAVError.notFound }
        guard (200..<300).contains(resource.statusCode) else { throw CalDAVError.invalidResponse }
    }

    private static func requireProperty(_ name: String, namespace: String = "DAV:",
                                        in resource: DAVXMLParser.DAVResource) throws {
        guard resource.propertyStatus(name, namespace: namespace) == 200 else { throw CalDAVError.invalidResponse }
    }

    /// Fetches all tasks from a calendar collection.
    ///
    /// Uses a CalDAV REPORT with `calendar-query` to retrieve all VTODOs.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - calendarPath: The calendar collection path.
    ///   - credentials: Authentication credentials.
    /// - Returns: Array of remote tasks with their ETags and ICS data.
    func fetchAllTasks(
        baseURL: String,
        calendarPath: String,
        credentials: Credentials
    ) async throws -> [RemoteTask] {
        let url = try resolveURL(baseURL: baseURL, path: calendarPath)

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <d:getetag/>
            <c:calendar-data/>
          </d:prop>
          <c:filter>
            <c:comp-filter name="VCALENDAR">
              <c:comp-filter name="VTODO"/>
            </c:comp-filter>
          </c:filter>
        </c:calendar-query>
        """

        let (data, _) = try await sendDAVRequest(
            method: "REPORT",
            url: url,
            body: body,
            credentials: credentials,
            depth: "1"
        )

        let parser = DAVXMLParser()
        let resources = try parser.parse(data: data)

        return try Self.remoteTasks(from: resources, calendarPath: calendarPath)
    }

    /// The task resources in a multistatus, or a failure if any of them arrived
    /// without its content.
    ///
    /// A missing body makes the collection inventory incomplete. The bounded live
    /// pull uses complete-manifest absence to reconcile server deletions, so dropping
    /// this resource would make its local task look absent and could delete it.
    ///
    /// The collection itself is the one response that legitimately carries no
    /// calendar data, and it identifies itself: its href *is* the calendar
    /// path. Compared with the trailing slash normalised away, because a server
    /// that spells it the other way would otherwise turn its own collection
    /// into a phantom deletion of the whole list.
    ///
    /// - Throws: `CalDAVError.invalidResponse` when a resource that is not the
    ///   collection carries no calendar data.
    static func remoteTasks(from resources: [DAVXMLParser.DAVResource],
                            calendarPath: String) throws -> [RemoteTask] {
        func normalized(_ path: String) -> String {
            path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let collection = normalized(calendarPath)

        var tasks: [RemoteTask] = []
        for resource in resources where !resource.calendarData.isEmpty
            || normalized(resource.href) != collection {
            guard !resource.calendarData.isEmpty else {
                throw CalDAVError.invalidResponse
            }
            tasks.append(RemoteTask(href: resource.href,
                                    etag: resource.etag,
                                    icsData: resource.calendarData))
        }
        return tasks
    }

    /// Fetches a single task by its href.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - taskPath: The task resource path.
    ///   - credentials: Authentication credentials.
    /// - Returns: The task with etag and ICS data.
    func fetchTask(
        baseURL: String,
        taskPath: String,
        credentials: Credentials
    ) async throws -> RemoteTask {
        let url = try resolveURL(baseURL: baseURL, path: taskPath)

        let (data, response) = try await sendDAVRequest(
            method: "GET",
            url: url,
            body: nil,
            credentials: credentials,
            depth: nil, exactTarget: true
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalDAVError.invalidResponse
        }

        let etag = (httpResponse.value(forHTTPHeaderField: "ETag") ?? "")
            .replacingOccurrences(of: "\"", with: "")

        guard let icsString = String(data: data, encoding: .utf8) else {
            throw CalDAVError.invalidResponse
        }

        return RemoteTask(href: taskPath, etag: etag, icsData: icsString)
    }

    /// Creates or updates a task on the server.
    ///
    /// Uses `PUT` with `If-Match` (for updates) or `If-None-Match: *` (for creates).
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - taskPath: The task resource path.
    ///   - icsData: The serialized VTODO .ics content.
    ///   - etag: The current ETag for conflict detection. `nil` for new tasks.
    ///   - credentials: Authentication credentials.
    /// - Returns: The new ETag from the server response.
    func putTask(
        baseURL: String,
        taskPath: String,
        icsData: String,
        etag: String?,
        credentials: Credentials,
        validateAttempt: (@Sendable () async throws -> Void)? = nil
    ) async throws -> String {
        let url = try resolveURL(baseURL: baseURL, path: taskPath)

        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = icsData.data(using: .utf8)

        // ETag-based conflict detection. Load-bearing: without the If-Match /
        // If-None-Match pair a concurrent edit on another device is silently
        // overwritten instead of surfacing as a 412 the sync engine can resolve.
        if let existingEtag = etag {
            request.setValue("\"\(existingEtag)\"", forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        let budget = runBudget ?? BackgroundRunBudget.current
        return try await withRetry(policy: retryPolicy, deadline: budget == nil ? retryDeadline : nil, runBudget: budget, now: now, jitter: jitter, sleep: sleep) { [request, session, now, budget, maxResponseBytes] in
            try await validateAttempt?()
            let (_, response) = try await Self.performRequest(request, session: session, budget: budget,
                maxResponseBytes: maxResponseBytes, now: now, exactTarget: true, validateRedirect: validateAttempt)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CalDAVError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200, 201, 204:
                let newEtag = (httpResponse.value(forHTTPHeaderField: "ETag") ?? "")
                    .replacingOccurrences(of: "\"", with: "")
                return newEtag
            case 401:
                throw CalDAVError.unauthorized
            case 403:
                throw CalDAVError.forbidden
            case 429:
                throw CalDAVError.rateLimited(retryAfter: nil)
            case 412:
                // Precondition Failed — the resource was modified on the server
                let serverEtag = (httpResponse.value(forHTTPHeaderField: "ETag") ?? "")
                    .replacingOccurrences(of: "\"", with: "")
                throw CalDAVError.conflict(etag: serverEtag.isEmpty ? nil : serverEtag)
            default:
                throw CalDAVError.serverError(statusCode: httpResponse.statusCode)
            }
        }
    }

    /// Deletes a task from the server.
    ///
    /// Uses `If-Match` with the current ETag to prevent accidental deletion
    /// of a task that was modified server-side.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - taskPath: The task resource path.
    ///   - etag: The current ETag for safe deletion.
    ///   - credentials: Authentication credentials.
    func deleteTask(
        baseURL: String,
        taskPath: String,
        etag: String?,
        credentials: Credentials,
        validateAttempt: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        let url = try resolveURL(baseURL: baseURL, path: taskPath)

        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")

        if let existingEtag = etag {
            request.setValue("\"\(existingEtag)\"", forHTTPHeaderField: "If-Match")
        }

        let budget = runBudget ?? BackgroundRunBudget.current
        try await withRetry(policy: retryPolicy, deadline: budget == nil ? retryDeadline : nil, runBudget: budget, now: now, jitter: jitter, sleep: sleep) { [request, session, now, budget, maxResponseBytes] in
            try await validateAttempt?()
            let (_, response) = try await Self.performRequest(request, session: session, budget: budget,
                maxResponseBytes: maxResponseBytes, now: now, exactTarget: true, validateRedirect: validateAttempt)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CalDAVError.invalidResponse
            }

            if httpResponse.statusCode == 429 {
                throw CalDAVError.rateLimited(retryAfter: nil)
            }
            try Self.checkDeleteStatus(httpResponse.statusCode)
        }
    }

    /// Maps a DELETE's status code to success or a `CalDAVError`.
    ///
    /// 403 used to fall through to `serverError`, which the sync banner words as
    /// "the server is having problems" — wrong, and it hid that the user may not
    /// remove from a list shared with them.
    nonisolated static func checkDeleteStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200, 204:
            return
        case 401:
            throw CalDAVError.unauthorized
        case 403:
            throw CalDAVError.forbidden
        case 404:
            return // Already deleted — idempotent
        case 412:
            throw CalDAVError.conflict(etag: nil)
        default:
            throw CalDAVError.serverError(statusCode: statusCode)
        }
    }

    // MARK: - Calendar Management

    /// Normalises a hex colour to `calendar-color`'s `#RRGGBBAA` convention.
    ///
    /// A 6-digit colour is opaque and gains the alpha byte; one that already carries alpha
    /// is left alone. Appending unconditionally produced 10-digit values that
    /// `Color(hex:)` then refused, which is how a list came back blue.
    nonisolated static func calendarColorValue(_ hex: String) -> String {
        let digits = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        return digits.count == 6 ? "#\(digits)FF" : "#\(digits)"
    }

    /// Builds the `PROPPATCH` body that writes a calendar's display name and colour.
    nonisolated static func calendarPropertyPatchBody(name: String, colorHex: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propertyupdate xmlns:d="DAV:" xmlns:x="http://apple.com/ns/ical/">
          <d:set>
            <d:prop>
              <d:displayname>\(xmlEscape(name))</d:displayname>
              <x:calendar-color>\(xmlEscape(calendarColorValue(colorHex)))</x:calendar-color>
            </d:prop>
          </d:set>
        </d:propertyupdate>
        """
    }

    /// A metadata write is accepted only with successful results for both requested properties.
    func updateCalendarProperties(
        baseURL: String,
        calendarPath: String,
        name: String,
        colorHex: String,
        credentials: Credentials,
        validateAttempt: @escaping @Sendable () async throws -> Void = {}
    ) async throws {
        let url = try resolveURL(baseURL: baseURL, path: calendarPath)
        guard let target = URL(string: url), CalDAVDiscovery.sameCollection(target, target) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: target)
        request.httpMethod = "PROPPATCH"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.calendarPropertyPatchBody(name: name, colorHex: colorHex).utf8)

        let budget = runBudget ?? BackgroundRunBudget.current
        try await withRetry(policy: retryPolicy, deadline: budget == nil ? retryDeadline : nil,
            runBudget: budget, now: now, jitter: jitter, sleep: sleep) { [request, session, now, budget, maxResponseBytes] in
            try await validateAttempt()
            let (data, response) = try await Self.performRequest(request, session: session,
                budget: budget, maxResponseBytes: maxResponseBytes, now: now, exactTarget: true, validateRedirect: validateAttempt)

            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  CalDAVDiscovery.sameCollection(target, finalURL) else { throw CalDAVError.invalidResponse }
            switch http.statusCode {
            case 207:
                let resources = try DAVXMLParser().parse(data: data, strictPropertyEvidence: true)
                let resource = try Self.exactPropertyResponse(resources, responseURL: finalURL, target: target)
                guard resource.propertyOccurrences == [
                    "{DAV:}displayname": 1, "{http://apple.com/ns/ical/}calendar-color": 1
                ],
                let nameStatus = resource.propertyStatus("displayname"),
                let colorStatus = resource.propertyStatus("calendar-color", namespace: "http://apple.com/ns/ical/") else {
                    throw CalDAVError.invalidResponse
                }
                let statuses = [nameStatus, colorStatus]
                if statuses.contains(403) || statuses.contains(424) { throw CalDAVError.forbidden }
                guard statuses.allSatisfy({ (200..<300).contains($0) }) else { throw CalDAVError.invalidResponse }
            case 200, 204: throw CalDAVError.invalidResponse
            case 401: throw CalDAVError.unauthorized
            case 403: throw CalDAVError.forbidden
            case 404: throw CalDAVError.notFound
            case 429: throw CalDAVError.rateLimited(retryAfter: nil)
            default: throw CalDAVError.serverError(statusCode: http.statusCode)
            }
        }
    }

    struct CalendarCreation: Sendable {
        let href: String
        let adopted: Bool
    }

    /// Creates or verifies the one target allocated to a persisted local list identity.
    func createCalendar(
        baseURL: String,
        calendarHomePath: String,
        listID: String,
        name: String,
        color: String?,
        credentials: Credentials,
        alreadyDiscovered: Bool = false,
        validateAccount: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> CalendarCreation {
        let home = try resolveURL(baseURL: baseURL, path: calendarHomePath)
        guard let homeURL = URL(string: home) else { throw CalDAVError.invalidURL }
        let target = try CalDAVDiscovery.creationTarget(listID: listID, homeURL: homeURL)
        let marker = CalDAVDiscovery.creationMarker(listID: listID)
        if alreadyDiscovered {
            try await verifyCalendarCreation(target: target, marker: marker, credentials: credentials,
                validateAttempt: validateAccount)
            return CalendarCreation(href: target.absoluteString, adopted: true)
        }

        var colorProp = ""
        if let color, !color.isEmpty {
            colorProp = """
                <x:calendar-color xmlns:x="http://apple.com/ns/ical/">\(Self.xmlEscape(Self.calendarColorValue(color)))</x:calendar-color>
            """
        }

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:n="https://nowthis.app/ns/caldav">
          <d:set>
            <d:prop>
              <d:displayname>\(Self.xmlEscape(name))</d:displayname>
              <c:supported-calendar-component-set>
                <c:comp name="VTODO"/>
              </c:supported-calendar-component-set>
              <n:creation-id>\(marker)</n:creation-id>
              \(colorProp)
            </d:prop>
          </d:set>
        </c:mkcalendar>
        """

        var request = URLRequest(url: target)
        request.httpMethod = "MKCALENDAR"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        request.httpBody = Data(body.utf8)

        let budget = runBudget ?? BackgroundRunBudget.current
        let created = try await withRetry(policy: retryPolicy, deadline: budget == nil ? retryDeadline : nil,
            runBudget: budget, now: now, jitter: jitter, sleep: sleep) { [request, session, now, budget, maxResponseBytes] in
            try await validateAccount()
            let (_, response) = try await Self.performRequest(request, session: session,
                budget: budget, maxResponseBytes: maxResponseBytes, now: now, exactTarget: true, validateRedirect: validateAccount)
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  CalDAVDiscovery.sameCollection(target, finalURL) else { throw CalDAVError.invalidResponse }

            switch http.statusCode {
            case 201: return true
            case 401: throw CalDAVError.unauthorized
            case 403: throw CalDAVError.forbidden
            case 405, 412: return false
            case 429: throw CalDAVError.rateLimited(retryAfter: nil)
            default: throw CalDAVError.serverError(statusCode: http.statusCode)
            }
        }
        if !created {
            try await verifyCalendarCreation(target: target, marker: marker, credentials: credentials,
                validateAttempt: validateAccount)
        }
        return CalendarCreation(href: target.absoluteString, adopted: !created)
    }

    private func verifyCalendarCreation(target: URL, marker: String, credentials: Credentials,
                                        validateAttempt: @escaping @Sendable () async throws -> Void) async throws {
        let cutoff = ContinuousClock.now.advanced(by: .seconds(45))
        let deadline = min(DAVDiscoveryContext.deadline ?? cutoff, cutoff)
        let response = try await DAVDiscoveryContext.$deadline.withValue(deadline) {
            try await discoveryProperties(at: target, properties: [
                "<d:resourcetype/>",
                "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>",
                "<x:deleted-at xmlns:x=\"http://nextcloud.com/ns\"/>",
                "<n:creation-id xmlns:n=\"https://nowthis.app/ns/caldav\"/>"
            ], depth: "0", allowedOrigin: target, credentials: credentials, stage: .collections,
                strictPropertyEvidence: true, validateAttempt: validateAttempt)
        }
        let resource = try Self.exactPropertyResponse(response.resources, responseURL: response.responseURL, target: target)
        let deletedStatus = resource.uniquePropertyStatus("deleted-at", namespace: "http://nextcloud.com/ns")
        guard resource.isCalendar, resource.isVTODOSupported, resource.deletedAt.isEmpty,
              (resource.propertyStatus("deleted-at", namespace: "http://nextcloud.com/ns") == nil
                  || deletedStatus == 404 || (200..<300).contains(deletedStatus ?? 0)),
              (200..<300).contains(resource.uniquePropertyStatus("resourcetype") ?? 0),
              (200..<300).contains(resource.uniquePropertyStatus("supported-calendar-component-set",
                  namespace: "urn:ietf:params:xml:ns:caldav") ?? 0),
              (200..<300).contains(resource.uniquePropertyStatus("creation-id", namespace: "https://nowthis.app/ns/caldav") ?? 0),
              resource.creationID == marker else { throw CalDAVDiscovery.ambiguousCollection }
    }

    private static func exactPropertyResponse(_ resources: [DAVXMLParser.DAVResource],
        responseURL: URL, target: URL) throws -> DAVXMLParser.DAVResource {
        guard CalDAVDiscovery.sameCollection(target, responseURL), resources.count == 1,
              let resource = resources.first, resource.hrefOccurrences == 1, !resource.href.isEmpty,
              resource.responseStatusCode == nil,
              URL(string: resource.href, encodingInvalidCharacters: false) != nil,
              let href = URL(string: resource.href, relativeTo: responseURL)?.absoluteURL,
              CalDAVDiscovery.sameCollection(target, href) else { throw CalDAVError.invalidResponse }
        return resource
    }

    /// Creates only the caller's retained target, then independently proves its binding.
    func ensureEventCollection(target: URL, marker: String, create: Bool, credentials: Credentials,
                               validate: @escaping CalendarRequestValidation) async throws -> URL {
        if create {
            guard var request = Self.makeDAVRequest(method: "MKCALENDAR", url: target.absoluteString,
                body: Self.eventCollectionCreationBodyV1(marker: marker), credentials: credentials,
                depth: nil) else { throw CalDAVError.invalidURL }
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
            do {
                let (_, response) = try await calendarEventRequest(request, validate: validate)
                switch response.statusCode {
                case 201, 405, 409, 412, 500...506, 508...599: break
                default: throw Self.calendarEventHTTPError(response.statusCode)
                }
            } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
                // The server may have applied the conditional create before the response was lost.
            }
        }

        let response = try await discoveryProperties(at: target, properties: [
            "<d:resourcetype/>", "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>",
            "<n:creation-id xmlns:n=\"https://nowthis.app/ns/caldav\"/>",
            "<x:deleted-at xmlns:x=\"http://nextcloud.com/ns\"/>", "<d:current-user-privilege-set/>"
        ], depth: "0", allowedOrigin: target, credentials: credentials, stage: .collections,
           strictPropertyEvidence: true, singleAttempt: true, requireExactResponse: true, validateAttempt: validate)
        let resource = try Self.exactPropertyResponse(response.resources, responseURL: response.responseURL, target: target)
        let trashNamespace = "http://nextcloud.com/ns"
        let markerNamespace = "https://nowthis.app/ns/caldav"
        let deletedStatus = resource.uniquePropertyStatus("deleted-at", namespace: trashNamespace)
        let markerStatus = resource.uniquePropertyStatus("creation-id", namespace: markerNamespace)
        let components = resource.uniquePropertyStatus("supported-calendar-component-set", namespace: "urn:ietf:params:xml:ns:caldav")
        let markerSucceeded = (200..<300).contains(markerStatus ?? 0)
        let markerMatches = !marker.isEmpty && resource.creationID.utf8.elementsEqual(marker.utf8)
        let hasResourceType = (200..<300).contains(resource.uniquePropertyStatus("resourcetype") ?? 0)
        if markerSucceeded && !resource.creationID.isEmpty && !markerMatches {
            throw CalendarCollectionProofError.contradictoryClaim
        }
        if hasResourceType && (!resource.isCalendar || !resource.deletedAt.isEmpty || Self.isTrashbinHref(target.path)
            || markerStatus == 404 || resource.propertyStatus("creation-id", namespace: markerNamespace) == nil
            || (markerSucceeded && !markerMatches)
            || ((200..<300).contains(components ?? 0) && resource.veventComponentCount == 0)) {
            throw CalendarCollectionProofError.contradictoryClaim
        }
        guard hasResourceType, resource.isCalendar, resource.veventComponentCount == 1, resource.deletedAt.isEmpty,
              resource.propertyStatus("deleted-at", namespace: trashNamespace) == nil
                  || deletedStatus == 404 || (200..<300).contains(deletedStatus ?? 0),
              (200..<300).contains(components ?? 0), markerSucceeded, markerMatches else {
            throw CalDAVDiscovery.ambiguousCollection
        }
        if resource.propertyStatus("current-user-privilege-set") != nil {
            let status = resource.uniquePropertyStatus("current-user-privilege-set")
            guard status == 404 || ((200..<300).contains(status ?? 0)
                && !resource.privileges.isDisjoint(with: ["all", "write", "write-content"])) else {
                throw CalDAVError.forbidden
            }
        }
        try await validate()
        return target
    }

    /// Immutable wire template for the v1 destination envelope. A future template needs a new version.
    private nonisolated static func eventCollectionCreationBodyV1(marker: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:n="https://nowthis.app/ns/caldav">
          <d:set><d:prop>
            <d:displayname>NowThis</d:displayname>
            <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set>
            <n:creation-id>\(xmlEscape(marker))</n:creation-id>
          </d:prop></d:set>
        </c:mkcalendar>
        """
    }

    /// One bounded attempt. A caller with a durable intent decides whether an uncertain response can be recovered.
    func calendarEventRequest(_ request: URLRequest, responseLimit: Int? = nil, validate: @escaping CalendarRequestValidation)
        async throws -> (Data, HTTPURLResponse) {
        guard let target = request.url, NextcloudServerAddress.sameOrigin(target, target) else {
            throw CalDAVError.invalidURL
        }
        let budget = runBudget ?? BackgroundRunBudget.current
        let policy = RetryPolicy(maxAttempts: 1, baseDelay: 0)
        let limit = min(maxResponseBytes, responseLimit ?? maxResponseBytes)
        do {
            return try await withRetry(policy: policy, deadline: budget == nil ? retryDeadline : nil,
                runBudget: budget, now: now) { [session, now] in
                try await validate()
                let (data, response) = try await Self.performRequest(request, session: session, budget: budget,
                    maxResponseBytes: limit, now: now, exactTarget: true, allowRedirects: false, discoveryOrigin: target)
                guard let http = response as? HTTPURLResponse, let url = http.url,
                      Self.isPinnedTarget(url, of: target) else { throw CalDAVError.invalidResponse }
                try Self.validateCalendarResponseLength(data, response: http)
                return (data, http)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private nonisolated static func validateCalendarResponseLength(_ body: Data, response: HTTPURLResponse) throws {
        // Bodyless statuses carry no comparable representation, and URLSession may deliver decoded bytes.
        guard response.statusCode != 204, response.statusCode != 304, response.expectedContentLength >= 0 else { return }
        if let coding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces),
           !coding.isEmpty, coding.caseInsensitiveCompare("identity") != .orderedSame { return }
        guard response.expectedContentLength == Int64(body.count) else { throw CalDAVError.invalidResponse }
    }

    nonisolated static func calendarEventHTTPError(_ status: Int) -> CalDAVError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 412: .conflict(etag: nil)
        case 429: .rateLimited(retryAfter: nil)
        default: .serverError(statusCode: status)
        }
    }

    // MARK: - Private Helpers

    /// Builds a WebDAV read request (PROPFIND / REPORT / etc.).
    ///
    /// Pinned to `.reloadIgnoringLocalCacheData`: CalDAV collection properties —
    /// notably `getctag` — are context-dependent and (RFC 4918 §9) must never be
    /// served from a cache. A stale cached `getctag` makes the `SyncEngine` delta
    /// check believe nothing changed and silently skip the inbound pull, so
    /// server-created tasks and manual-order changes never reach the device.
    ///
    /// Extracted as a non-isolated seam so the request's caching behavior can be
    /// unit-tested without the network. Returns `nil` for an unparseable URL.
    static func makeDAVRequest(
        method: String,
        url: String,
        body: String?,
        credentials: Credentials,
        depth: String?
    ) -> URLRequest? {
        guard let requestURL = URL(string: url) else { return nil }

        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        if let depth = depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }

        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        return request
    }

    /// Rebuilds the request URLSession proposes for a 301/302 redirect so it
    /// keeps the original CalDAV request's method, body, same-origin credentials,
    /// and headers (URLSession otherwise downgrades the method to GET and drops
    /// these). Extracted as a non-isolated seam so the redirect behavior — most
    /// importantly that it preserves the cache policy — is unit-testable.
    static func makeRedirectRequest(
        from originalRequest: URLRequest,
        proposed request: URLRequest
    ) -> URLRequest? {
        guard let source = originalRequest.url, let target = request.url,
              sameOrigin(source, target), target.user == nil, target.password == nil else { return nil }
        var redirectRequest = request
        redirectRequest.httpMethod = originalRequest.httpMethod
        redirectRequest.httpBody = originalRequest.httpBody
        // Preserve the no-cache policy across redirects, or a redirected
        // PROPFIND/REPORT would revert to the default cache and could serve a
        // stale `getctag` — reintroducing the skipped-pull bug.
        redirectRequest.cachePolicy = originalRequest.cachePolicy
        redirectRequest.timeoutInterval = originalRequest.timeoutInterval

        if let auth = originalRequest.value(forHTTPHeaderField: "Authorization") {
            redirectRequest.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        // Non-sensitive headers — always preserve for CalDAV compatibility
        for header in ["Content-Type", "Depth", "If-Match", "If-None-Match"] {
            if let value = originalRequest.value(forHTTPHeaderField: header) {
                redirectRequest.setValue(value, forHTTPHeaderField: header)
            }
        }

        return redirectRequest
    }

    /// Sends a WebDAV request with the given method, body, and depth.
    private func sendDAVRequest(
        method: String,
        url: String,
        body: String?,
        credentials: Credentials,
        depth: String?,
        recognizesInvalidSyncToken: Bool = false,
        exactTarget: Bool = false
    ) async throws -> (Data, URLResponse) {
        guard let request = Self.makeDAVRequest(
            method: method,
            url: url,
            body: body,
            credentials: credentials,
            depth: depth
        ) else {
            throw CalDAVError.invalidURL
        }

        let interval = PerformanceTrace.begin("DAVRequest", bytes: request.httpBody?.count ?? 0)
        defer { PerformanceTrace.end("DAVRequest", interval) }
        let budget = runBudget ?? BackgroundRunBudget.current
        do {
            return try await withRetry(policy: retryPolicy, deadline: budget == nil ? retryDeadline : nil, runBudget: budget, now: now, jitter: jitter, sleep: sleep) { [request, session, now, maxResponseBytes, budget] in
                let (data, response) = try await Self.performRequest(request, session: session,
                    budget: budget, maxResponseBytes: maxResponseBytes, now: now, exactTarget: exactTarget)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CalDAVError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200, 201, 207:
                    return (data, response)
                case 401:
                    throw CalDAVError.unauthorized
                case 403:
                    if recognizesInvalidSyncToken && DAVXMLParser.isInvalidSyncTokenError(data) {
                        throw CalDAVSyncError.invalidSyncToken
                    }
                    throw CalDAVError.forbidden
                case 404:
                    throw CalDAVError.notFound
                case 429:
                    throw CalDAVError.rateLimited(retryAfter: nil)
                default:
                    throw CalDAVError.serverError(statusCode: httpResponse.statusCode)
                }
            }
        } catch let error as BackgroundBudgetExhausted {
            throw error
        } catch let error as DAVResponseLimitError {
            throw error
        } catch let error as CalDAVSyncError {
            throw error
        } catch let error as RetryDeferredError {
            throw error
        } catch let error as HTTPRetryError {
            throw error
        } catch let error as CalDAVError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // A sync cancelled on backgrounding must not surface as a "Sync failed"
            // alert — present it as cancellation so the engine swallows it cleanly.
            throw CancellationError()
        } catch {
            throw CalDAVError.networkError(underlying: error)
        }
    }

    /// The request and absolute cutoff are immutable for this attempt, including
    /// redirects. URLSession's idle allowance alone cannot stop a trickling body.
    private static func performRequest(_ original: URLRequest, session: URLSession,
        budget: BackgroundRunBudget?, maxResponseBytes: Int, now: @escaping @Sendable () -> Date,
        exactTarget: Bool = false, allowRedirects: Bool = true, discoveryOrigin: URL? = nil,
        validateRedirect: (@Sendable () async throws -> Void)? = nil) async throws -> (Data, URLResponse) {
        try BackgroundBudgetExhausted.checkAdmission(budget)
        var adjusted = original
        if let budget {
            adjusted.timeoutInterval = min(adjusted.timeoutInterval, BackgroundBudgetExhausted.remainingSeconds(budget))
        }
        let request = adjusted
        let deadline = [budget?.remoteCutoff, DAVDiscoveryContext.deadline].compactMap { $0 }.min()
        let redirectValidator: (@Sendable () async throws -> Void)?
        if let validateRedirect {
            // URLSession delegate callbacks do not inherit the operation's task-local budget.
            let phase = BackgroundRunBudget.phase
            redirectValidator = {
                try BackgroundBudgetExhausted.checkAdmission(budget)
                try await BackgroundRunBudget.$current.withValue(budget) {
                    try await BackgroundRunBudget.$phase.withValue(phase) {
                        try await validateRedirect()
                    }
                }
                try BackgroundBudgetExhausted.checkAdmission(budget)
            }
        } else {
            redirectValidator = nil
        }
        let admission = ServerRetryAdmission.current
        let receipt = RetryAfterReceipt()
        let collector = DAVResponseLimit(maxBytes: maxResponseBytes) { response in
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 429 || ((500...599).contains(http.statusCode) && http.statusCode != 507),
                  let header = http.value(forHTTPHeaderField: "Retry-After"),
                  let target = http.url, let source = request.url,
                  request.value(forHTTPHeaderField: "Authorization") != nil,
                  Self.sameOrigin(source, target), target.user == nil, target.password == nil,
                  !exactTarget || Self.isPinnedTarget(target, of: source),
                  discoveryOrigin.map({ NextcloudServerAddress.sameOrigin(target, $0) }) ?? true else { return }
            let receivedAt = now()
            guard let wait = RetryPolicy.retryAfter(header, now: receivedAt) else { return }
            let retryDeadline = wait > 0 ? receivedAt.addingTimeInterval(wait) : nil
            let error = HTTPRetryError(statusCode: http.statusCode, retryAfter: wait, retryDeadline: retryDeadline)
            if receipt.store(error), let retryDeadline {
                admission?.retain(RetryDeferredError(deadline: retryDeadline, httpStatusCode: http.statusCode))
            }
        }
        let result = try await DeadlineRequestExecutor.perform(deadline: deadline) {
            try await collector.data(
                for: request, configuration: session.configuration, session: session, validateRedirect: redirectValidator
            ) { proposed in
                guard allowRedirects else { return nil }
                if exactTarget {
                    guard let source = request.url, let destination = proposed.url,
                          Self.isPinnedTarget(destination, of: source) else { return nil }
                }
                return Self.makeRedirectRequest(from: request, proposed: proposed)
            }
        }
        // A complete retry response uses the same absolute deadline already recorded
        // at receipt. Body, cancellation and cutoff failures propagate separately.
        if let error = receipt.error { throw error }
        return result
    }

    private static func isPinnedTarget(_ candidate: URL, of request: URL) -> Bool {
        CalDAVDiscovery.sameCollection(request, candidate) && request.query == candidate.query && candidate.fragment == nil
    }

    private final class RetryAfterReceipt: @unchecked Sendable {
        private let lock = NSLock()
        private var received: HTTPRetryError?

        var error: HTTPRetryError? { lock.withLock { received } }

        func store(_ error: HTTPRetryError) -> Bool {
            lock.withLock {
                guard received == nil else { return false }
                received = error
                return true
            }
        }
    }

    /// Generates a PROPFIND XML body.
    private func propfindBody(properties: [String]) -> String {
        let props = properties.joined(separator: "\n    ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            \(props)
          </d:prop>
        </d:propfind>
        """
    }

    /// Construct only Nextcloud's fallback endpoints beneath its installation path.
    /// Server-returned hrefs continue to resolve as ordinary DAV URLs, so an
    /// already-prefixed href never acquires the installation path twice.
    private func nextcloudEndpoint(baseURL: String, suffix: String) throws -> String {
        guard let base = URLComponents(string: baseURL), base.query == nil, base.fragment == nil else {
            throw CalDAVError.invalidURL
        }
        var prefix = base.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return prefix + suffix
    }

    /// Resolves a relative path against a base URL.
    private func resolveURL(baseURL: String, path: String) throws -> String {
        guard let base = URL(string: baseURL),
              let target = URL(string: path, relativeTo: base)?.absoluteURL,
              Self.sameOrigin(base, target), target.user == nil, target.password == nil else {
            throw CalDAVError.invalidURL
        }
        return target.absoluteString
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        guard let scheme = lhs.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = lhs.host?.lowercased(), !host.isEmpty else { return false }
        return scheme == rhs.scheme?.lowercased() && host == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    /// Escapes special XML characters for safe interpolation into XML bodies.
    private nonisolated static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// URLSession delegate that preserves CalDAV HTTP methods (PROPFIND, REPORT, etc.) across redirects.
///
/// By default, `URLSession` changes non-standard HTTP methods to GET when following
/// 301/302 redirects. This delegate rebuilds the redirected request to keep the
/// original method, body, and headers (especially Authorization), which is required
/// for CalDAV operations.
private final class CalDAVClientRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let redirectBudget = DAVRedirectBudget()
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        redirectBudget.complete(taskID: task.taskIdentifier)
    }
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalRequest = task.originalRequest else {
            completionHandler(request)
            return
        }

        guard redirectBudget.allow(taskID: task.taskIdentifier) else { completionHandler(nil); return }
        completionHandler(
            CalDAVClient.makeRedirectRequest(from: originalRequest, proposed: request)
        )
    }
}
