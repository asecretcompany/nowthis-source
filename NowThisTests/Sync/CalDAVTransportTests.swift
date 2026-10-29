import Foundation
import Testing
@testable import NowThis

@Suite("Injected CalDAV transport", .serialized)
struct CalDAVTransportTests {
    @Test("A paused REPORT imports the released response using the configured session")
    func pausedReport() async throws {
        let host = "report-" + UUID().uuidString.lowercased() + ".invalid"
        let gate = ScriptedDAVProtocol.Gate()
        let xml = """
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
        <d:response><d:href>/tasks/a.ics</d:href><d:propstat><d:prop>
        <d:getetag>etag-a</d:getetag><c:calendar-data>BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:a
        SUMMARY:Launch the moon bakery
        END:VTODO
        END:VCALENDAR</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat></d:response></d:multistatus>
        """
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(body: xml, gate: gate)])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        let request = Task {
            try await client.fetchAllTasks(baseURL: "https://" + host, calendarPath: "/tasks/",
                credentials: .init(username: "fixture", password: "fixture"))
        }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = ScriptedDAVProtocol.requests(host: host)
        #expect(recorded.count == 1)
        #expect(recorded.first?.method == "REPORT")
        #expect(recorded.first?.path == "/tasks")
        #expect((recorded.first?.bodyBytes ?? 0) > 100)
        gate.release()
        let tasks = try await request.value
        #expect(tasks.map(\.href) == ["/tasks/a.ics"])
        #expect(tasks.first?.etag == "etag-a")
    }
}
