import Foundation

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
    struct Credentials {
        let username: String
        let password: String

        /// Returns the Basic auth header value.
        var basicAuthHeader: String {
            let data = "\(username):\(password)".data(using: .utf8) ?? Data()
            return "Basic \(data.base64EncodedString())"
        }
    }

    /// A CalDAV calendar (task list) discovered on the server.
    struct RemoteCalendar {
        let href: String
        let displayName: String
        let ctag: String
        let color: String
        let syncToken: String
    }

    /// A task resource on the server.
    struct RemoteTask {
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

    init(retryPolicy: RetryPolicy = .default) {
        self.retryPolicy = retryPolicy

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
        let nextcloudPath = resolveURL(baseURL: baseURL, path: "/remote.php/dav/principals/users/\(encodedUsername)/")

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
        let resources = parser.parse(data: data)

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
        let url = resolveURL(baseURL: baseURL, path: principalPath)

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
        let resources = parser.parse(data: data)

        for resource in resources {
            if !resource.calendarHomeSet.isEmpty {
                return resource.calendarHomeSet
            }
        }

        // Nextcloud fallback
        let encodedUser = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.username
        let fallback = "/remote.php/dav/calendars/\(encodedUser)/"
        return fallback
    }

    /// Discovers all task calendars (VTODO-supporting) in the calendar home.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - calendarHomePath: The calendar home URL path.
    ///   - credentials: Authentication credentials.
    /// - Returns: Array of discovered calendars that support VTODO.
    func discoverTaskCalendars(
        baseURL: String,
        calendarHomePath: String,
        credentials: Credentials
    ) async throws -> [RemoteCalendar] {
        let url = resolveURL(baseURL: baseURL, path: calendarHomePath)

        let body = propfindBody(properties: [
            "<d:displayname/>",
            "<d:resourcetype/>",
            "<cs:getctag xmlns:cs=\"http://calendarserver.org/ns/\"/>",
            "<d:sync-token/>",
            "<c:supported-calendar-component-set xmlns:c=\"urn:ietf:params:xml:ns:caldav\"/>",
            "<x:calendar-color xmlns:x=\"http://apple.com/ns/ical/\"/>"
        ])

        let (data, _) = try await sendDAVRequest(
            method: "PROPFIND",
            url: url,
            body: body,
            credentials: credentials,
            depth: "1"
        )

        let parser = DAVXMLParser()
        let resources = parser.parse(data: data)

        return resources
            .filter { $0.isVTODOSupported }
            .filter { $0.href != calendarHomePath } // Exclude the home itself
            .map { resource in
                RemoteCalendar(
                    href: resource.href,
                    displayName: resource.displayName,
                    ctag: resource.ctag,
                    color: resource.calendarColor,
                    syncToken: resource.syncToken
                )
            }
    }

    // MARK: - Task Operations

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
        let url = resolveURL(baseURL: baseURL, path: calendarPath)

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
        let resources = parser.parse(data: data)

        return resources
            .filter { !$0.calendarData.isEmpty }
            .map { RemoteTask(href: $0.href, etag: $0.etag, icsData: $0.calendarData) }
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
        let url = resolveURL(baseURL: baseURL, path: taskPath)

        let (data, response) = try await sendDAVRequest(
            method: "GET",
            url: url,
            body: nil,
            credentials: credentials,
            depth: nil
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
        credentials: Credentials
    ) async throws -> String {
        let url = resolveURL(baseURL: baseURL, path: taskPath)

        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "PUT"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = icsData.data(using: .utf8)

        // ETag-based conflict detection — prevents silent overwrites
        if let existingEtag = etag {
            request.setValue("\"\(existingEtag)\"", forHTTPHeaderField: "If-Match")
        } else {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }

        return try await withRetry(policy: retryPolicy) { [request, session] in
            let (_, response) = try await session.data(for: request)

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
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0) }
                throw CalDAVError.rateLimited(retryAfter: retryAfter)
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
        credentials: Credentials
    ) async throws {
        let url = resolveURL(baseURL: baseURL, path: taskPath)

        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")

        if let existingEtag = etag {
            request.setValue("\"\(existingEtag)\"", forHTTPHeaderField: "If-Match")
        }

        try await withRetry(policy: retryPolicy) { [request, session] in
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CalDAVError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200, 204:
                return
            case 401:
                throw CalDAVError.unauthorized
            case 404:
                return // Already deleted — idempotent
            case 429:
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0) }
                throw CalDAVError.rateLimited(retryAfter: retryAfter)
            case 412:
                throw CalDAVError.conflict(etag: nil)
            default:
                throw CalDAVError.serverError(statusCode: httpResponse.statusCode)
            }
        }
    }

    // MARK: - Calendar Management

    /// Creates a new VTODO calendar on the server using `MKCALENDAR`.
    ///
    /// - Parameters:
    ///   - baseURL: The server base URL.
    ///   - calendarHomePath: The calendar home URL path.
    ///   - name: Display name for the new calendar.
    ///   - color: Optional hex color (e.g., "#007AFF").
    ///   - credentials: Authentication credentials.
    /// - Returns: The href of the newly created calendar.
    func createCalendar(
        baseURL: String,
        calendarHomePath: String,
        name: String,
        color: String?,
        credentials: Credentials
    ) async throws -> String {
        // Sanitize name into a URL-safe slug
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let calendarPath = calendarHomePath.hasSuffix("/")
            ? "\(calendarHomePath)\(slug)/"
            : "\(calendarHomePath)/\(slug)/"
        let url = resolveURL(baseURL: baseURL, path: calendarPath)

        // Build MKCALENDAR XML body
        var colorProp = ""
        if let color = color, !color.isEmpty {
            colorProp = """
                <x:calendar-color xmlns:x="http://apple.com/ns/ical/">\(xmlEscape(color))FF</x:calendar-color>
            """
        }

        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <c:mkcalendar xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:set>
            <d:prop>
              <d:displayname>\(xmlEscape(name))</d:displayname>
              <c:supported-calendar-component-set>
                <c:comp name="VTODO"/>
              </c:supported-calendar-component-set>
              \(colorProp)
            </d:prop>
          </d:set>
        </c:mkcalendar>
        """

        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "MKCALENDAR"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        return try await withRetry(policy: retryPolicy) { [request, session, calendarPath] in
            let (_, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CalDAVError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 201:
                return calendarPath
            case 401:
                throw CalDAVError.unauthorized
            case 403:
                throw CalDAVError.forbidden
            case 429:
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { TimeInterval($0) }
                throw CalDAVError.rateLimited(retryAfter: retryAfter)
            case 405:
                // Calendar already exists — return the path
                return calendarPath
            default:
                throw CalDAVError.serverError(statusCode: httpResponse.statusCode)
            }
        }
    }

    // MARK: - Private Helpers

    /// Sends a WebDAV request with the given method, body, and depth.
    private func sendDAVRequest(
        method: String,
        url: String,
        body: String?,
        credentials: Credentials,
        depth: String?
    ) async throws -> (Data, URLResponse) {
        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")

        if let depth = depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }

        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        do {
            return try await withRetry(policy: retryPolicy) { [request, session] in
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw CalDAVError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200, 201, 207:
                    return (data, response)
                case 401:
                    throw CalDAVError.unauthorized
                case 403:
                    throw CalDAVError.forbidden
                case 404:
                    throw CalDAVError.notFound
                case 429:
                    let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { TimeInterval($0) }
                    throw CalDAVError.rateLimited(retryAfter: retryAfter)
                default:
                    throw CalDAVError.serverError(statusCode: httpResponse.statusCode)
                }
            }
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

    /// Resolves a relative path against a base URL.
    private func resolveURL(baseURL: String, path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }

        // Strip trailing slashes from baseURL to prevent double-slash paths
        var cleanBase = baseURL
        while cleanBase.hasSuffix("/") {
            cleanBase = String(cleanBase.dropLast())
        }

        guard let base = URL(string: cleanBase) else { return cleanBase + path }
        let scheme = base.scheme ?? "https"
        let host = base.host ?? ""
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// Escapes special XML characters for safe interpolation into XML bodies.
    private nonisolated func xmlEscape(_ text: String) -> String {
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

        var redirectRequest = request
        redirectRequest.httpMethod = originalRequest.httpMethod
        redirectRequest.httpBody = originalRequest.httpBody

        // Only forward credentials to same-origin redirects to prevent leaking
        let sameOrigin = originalRequest.url?.host == request.url?.host
            && originalRequest.url?.scheme == request.url?.scheme
            && originalRequest.url?.port == request.url?.port

        if sameOrigin {
            if let auth = originalRequest.value(forHTTPHeaderField: "Authorization") {
                redirectRequest.setValue(auth, forHTTPHeaderField: "Authorization")
            }
        }

        // Non-sensitive headers — always preserve for CalDAV compatibility
        for header in ["Content-Type", "Depth"] {
            if let value = originalRequest.value(forHTTPHeaderField: header) {
                redirectRequest.setValue(value, forHTTPHeaderField: header)
            }
        }

        completionHandler(redirectRequest)
    }
}
