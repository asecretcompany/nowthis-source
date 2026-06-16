import Foundation
import SwiftData

/// Pushes tasks with due dates to Nextcloud Calendar as VEVENT entries via CalDAV.
///
/// Reuses the existing `CalDAVClient` infrastructure and `ServerAccount` credentials.
/// Creates a dedicated "nowthis-calendar" collection on the Nextcloud server via
/// `MKCALENDAR` if it doesn't already exist.
///
/// Each task's VEVENT uses a UID of `{task.uid}-event` to avoid collisions
/// with the existing VTODO entries. The VEVENT includes `RELATED-TO` pointing
/// back to the original VTODO UID for cross-referencing.
actor NextcloudCalendarSyncManager {

    private let calDAVClient = CalDAVClient()

    /// The CalDAV collection name for the NowThis calendar.
    private static let calendarSlug = "nowthis-calendar"

    /// Syncs all tasks with due dates to Nextcloud Calendar.
    ///
    /// - Parameters:
    ///   - account: The Nextcloud server account.
    ///   - modelContext: SwiftData context for fetching tasks.
    func syncAll(
        account: ServerAccount,
        modelContext: ModelContext
    ) async throws {
        let credentials = try await loadCredentials(for: account)
        let calendarPath = try await ensureCalendarCollection(
            baseURL: account.serverBaseURL,
            username: credentials.username,
            credentials: credentials
        )

        let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate
        )
        let tasks = try modelContext.fetch(descriptor)

        for task in tasks {
            try await syncTask(
                task,
                calendarPath: calendarPath,
                baseURL: account.serverBaseURL,
                credentials: credentials
            )
        }

        try modelContext.save()
    }

    /// Syncs a single task's VEVENT to Nextcloud Calendar.
    ///
    /// - Parameters:
    ///   - task: The task to sync.
    ///   - account: The Nextcloud server account.
    func syncSingleTask(
        _ task: TaskItem,
        account: ServerAccount
    ) async throws {
        let credentials = try await loadCredentials(for: account)
        let calendarPath = try await ensureCalendarCollection(
            baseURL: account.serverBaseURL,
            username: credentials.username,
            credentials: credentials
        )

        try await syncTask(
            task,
            calendarPath: calendarPath,
            baseURL: account.serverBaseURL,
            credentials: credentials
        )
    }

    /// Deletes a single task's VEVENT from Nextcloud Calendar.
    ///
    /// - Parameters:
    ///   - task: The task whose VEVENT should be removed.
    ///   - account: The Nextcloud server account.
    func deleteEvent(
        for task: TaskItem,
        account: ServerAccount
    ) async throws {
        guard let href = task.calendarEventHref else { return }

        let credentials = try await loadCredentials(for: account)
        try await calDAVClient.deleteTask(
            baseURL: account.serverBaseURL,
            taskPath: href,
            etag: nil,
            credentials: credentials
        )
        task.calendarEventHref = nil
    }

    // MARK: - Private

    /// Ensures the "nowthis-calendar" collection exists on the server.
    ///
    /// Sends a `MKCALENDAR` request. If the collection already exists (405/409),
    /// this is a no-op.
    ///
    /// - Returns: The full path to the calendar collection.
    private func ensureCalendarCollection(
        baseURL: String,
        username: String,
        credentials: CalDAVClient.Credentials
    ) async throws -> String {
        let calendarPath = "/remote.php/dav/calendars/\(username)/\(Self.calendarSlug)/"

        let mkCalBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <C:mkcalendar xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
          <D:set>
            <D:prop>
              <D:displayname>NowThis</D:displayname>
              <C:supported-calendar-component-set>
                <C:comp name="VEVENT"/>
              </C:supported-calendar-component-set>
              <D:resourcetype>
                <D:collection/>
                <C:calendar/>
              </D:resourcetype>
            </D:prop>
          </D:set>
        </C:mkcalendar>
        """

        var cleanBase = baseURL
        while cleanBase.hasSuffix("/") {
            cleanBase = String(cleanBase.dropLast())
        }
        let url = "\(cleanBase)\(calendarPath)"
        guard let requestURL = URL(string: url) else {
            throw CalDAVError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "MKCALENDAR"
        request.setValue(credentials.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = mkCalBody.data(using: .utf8)

        let session = URLSession.shared
        let (_, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            switch httpResponse.statusCode {
            case 201:
                break // Created successfully
            case 405, 409:
                break // Already exists — that's fine
            case 401:
                throw CalDAVError.unauthorized
            default:
                break // Best-effort — continue anyway
            }
        }

        return calendarPath
    }

    /// Syncs a single task to the Nextcloud calendar collection.
    private func syncTask(
        _ task: TaskItem,
        calendarPath: String,
        baseURL: String,
        credentials: CalDAVClient.Credentials
    ) async throws {
        let eventUID = "\(task.uid)-event"

        // No due date — remove existing event
        guard let icsData = VEventSerializer.serialize(task: task, eventUID: eventUID) else {
            if let href = task.calendarEventHref {
                try await calDAVClient.deleteTask(
                    baseURL: baseURL,
                    taskPath: href,
                    etag: nil,
                    credentials: credentials
                )
                task.calendarEventHref = nil
            }
            return
        }

        let eventPath = "\(calendarPath)\(eventUID).ics"

        do {
            _ = try await calDAVClient.putTask(
                baseURL: baseURL,
                taskPath: eventPath,
                icsData: icsData,
                etag: nil, // We don't track VEVENT etags — always overwrite
                credentials: credentials
            )
            task.calendarEventHref = eventPath
        } catch CalDAVError.conflict {
            // Conflict — overwrite anyway (we're the source of truth)
            _ = try await calDAVClient.putTask(
                baseURL: baseURL,
                taskPath: eventPath,
                icsData: icsData,
                etag: nil,
                credentials: credentials
            )
            task.calendarEventHref = eventPath
        }
    }

    /// Loads Keychain credentials for the server account.
    private func loadCredentials(for account: ServerAccount) async throws -> CalDAVClient.Credentials {
        let keychainManager = KeychainManager()
        guard let password = try await keychainManager.retrieve(for: account.id) else {
            throw CalDAVError.unauthorized
        }
        return CalDAVClient.Credentials(
            username: account.username,
            password: password
        )
    }
}
