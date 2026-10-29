import Foundation
import Testing
@testable import NowThis

@Suite("Retry After deadlines")
struct RetryAfterTests {
    private let instant = Date(timeIntervalSince1970: 1_445_412_470)

    @Test("Retry After accepts seconds and HTTP dates without capping a server wait")
    func headerForms() {
        #expect(RetryPolicy.retryAfter("120", now: instant) == 120)
        #expect(RetryPolicy.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT", now: instant) == 10)
        #expect(RetryPolicy.retryAfter("Wed, 21 Oct 2015 07:27:00 GMT", now: instant) == 0)
        #expect(RetryPolicy.retryAfter("-10", now: instant) == nil)
        #expect(RetryPolicy.retryAfter("NaN", now: instant) == nil)
        #expect(RetryPolicy.retryAfter("not a date", now: instant) == nil)
    }

    @Test("A server wait exceeding the run budget defers at the full deadline")
    func budgetDefers() async {
        let recorder = RetryAfterRecorder()
        do {
            _ = try await withRetry(policy: .init(maxAttempts: 3, baseDelay: 0), deadline: instant.addingTimeInterval(5), now: { instant }, sleep: { await recorder.record($0) }) { () -> String in
                await recorder.attempt()
                throw CalDAVError.rateLimited(retryAfter: 120)
            }
            Issue.record("Expected deferred retry")
        } catch let error as RetryDeferredError {
            #expect(error.deadline == instant.addingTimeInterval(120))
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    @Test("Server delays bypass jitter while client backoff can be jittered")
    func serverWaitNeverShortened() async throws {
        let recorder = RetryAfterRecorder()
        let value = try await withRetry(policy: .init(maxAttempts: 3, baseDelay: 2), now: { instant }, jitter: { $0 * 0.5 }, sleep: { await recorder.record($0) }) { () -> String in
            let attempt = await recorder.attempt()
            if attempt == 1 { throw CalDAVError.rateLimited(retryAfter: 120) }
            if attempt == 2 { throw CalDAVError.serverError(statusCode: 500) }
            return "done"
        }
        #expect(value == "done")
        #expect(await recorder.sleeps == [120, 2])
    }

    @Test("Transport date header uses injected clock and sleep", arguments: [429, 503])
    func transportDateHeader(code: Int) async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: code, body: "", headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"]),
            .init(body: "<d:multistatus xmlns:d=\"DAV:\"/>")
        ])
        let recorder = RetryAfterRecorder()
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 2, baseDelay: 0), now: { instant }, sleep: { await recorder.record($0) })
        let resources = try await client.fetchTaskManifest(baseURL: "https://" + host, calendarPath: "/tasks/", credentials: .init(username: "fixture", password: "fixture"))
        #expect(resources.isEmpty)
        #expect(await recorder.sleeps == [10])
    }
    @Test("All write operations respect service unavailable Retry After", arguments: ["put", "delete", "patch", "create"])
    func writeRetryAfter(operation: String) async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 503, body: "", headers: ["Retry-After": "60"]),
            .init(status: operation == "create" ? 201 : 204, body: "")
        ])
        let recorder = RetryAfterRecorder()
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 2, baseDelay: 0), now: { instant }, sleep: { await recorder.record($0) })
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let base = "https://" + host
        switch operation {
        case "put": _ = try await client.putTask(baseURL: base, taskPath: "/tasks/a.ics", icsData: "BEGIN:VCALENDAR", etag: nil, credentials: credentials)
        case "delete": try await client.deleteTask(baseURL: base, taskPath: "/tasks/a.ics", etag: nil, credentials: credentials)
        case "patch": try await client.updateCalendarProperties(baseURL: base, calendarPath: "/tasks/", name: "Tasks", colorHex: "FF0000", credentials: credentials)
        default: _ = try await client.createCalendar(baseURL: base, calendarHomePath: "/home/", name: "Tasks", color: nil, credentials: credentials)
        }
        #expect(await recorder.sleeps == [60])
    }

}

private actor RetryAfterRecorder {
    private(set) var attempts = 0
    private(set) var sleeps: [TimeInterval] = []
    @discardableResult func attempt() -> Int { attempts += 1; return attempts }
    func record(_ delay: TimeInterval) { sleeps.append(delay) }
}
