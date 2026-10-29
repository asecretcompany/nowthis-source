import Foundation
import Testing
@testable import NowThis

@Suite("CalDAV manifest and batch accounting")
struct CalDAVManifestTests {
    private let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")

    private func response(_ href: String, etag: String = "e", content: String? = nil, status: Int = 200) -> String {
        let data = content.map { "<c:calendar-data>\($0)</c:calendar-data>" } ?? ""
        return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:getetag>\(etag)</d:getetag>\(data)</d:prop><d:status>HTTP/1.1 \(status) Result</d:status></d:propstat></d:response>"
    }
    private func xml(_ body: String) -> String {
        "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">\(body)</d:multistatus>"
    }
    private func client(_ body: String) -> (CalDAVClient, String, String) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        return (CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: [.init(body: body)]), retryPolicy: .init(maxAttempts: 1, baseDelay: 0)), "https://" + host, host)
    }

    @Test("Manifest queries all VTODO ETags without requesting bodies")
    func lightweightManifest() async throws {
        let (client, base, host) = client(xml(response("/tasks/a.ics") + response("/tasks/b.ics", etag: "e2")))
        let manifest = try await client.fetchTaskManifest(baseURL: base, calendarPath: "/tasks/", credentials: credentials)
        #expect(manifest.map(\.href) == ["/tasks/a.ics", "/tasks/b.ics"])
        #expect(manifest.map(\.etag) == ["e", "e2"])
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.count == 1)
        let body = String(decoding: try #require(requests.first).body, as: UTF8.self)
        #expect(body.contains("calendar-query"))
        #expect(body.contains("name=\"VTODO\""))
        #expect(body.contains("getetag"))
        #expect(!body.contains("calendar-data"))
        #expect(!body.contains("time-range"))
    }

    @Test("Manifest rejects failed properties, duplicates, out of scope, and missing ETags", arguments: ["failed", "duplicate", "outside", "missing", "truncated", "html", "collection507"])
    func incompleteManifest(kind: String) async {
        let body: String
        switch kind {
        case "failed": body = xml(response("/tasks/a.ics", status: 403))
        case "duplicate": body = xml(response("/tasks/a.ics") + response("/tasks/a.ics"))
        case "outside": body = xml(response("/other/a.ics"))
        case "missing": body = xml(response("/tasks/a.ics", etag: ""))
        case "truncated": body = String(xml(response("/tasks/a.ics")).dropLast(10))
        case "collection507": body = xml("<d:response><d:href>/tasks/</d:href><d:status>HTTP/1.1 507 Result</d:status></d:response>")
        default: body = "<html><body>Login</body></html>"
        }
        let (client, base, _) = client(body)
        await #expect(throws: (any Error).self) {
            try await client.fetchTaskManifest(baseURL: base, calendarPath: "/tasks/", credentials: credentials)
        }
    }

    @Test("Successful props survive unrelated failed propstats and rejected values stay absent")
    func propstatIsolation() throws {
        let body = xml("""
        <d:response><d:href>/tasks/a.ics</d:href>
        <d:propstat><d:prop><d:getetag>good</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:displayname>must not escape</d:displayname><d:getetag>bad</d:getetag></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response>
        """)
        let resource = try #require(DAVXMLParser().parse(data: Data(body.utf8)).first)
        #expect(resource.etag == "good")
        #expect(resource.displayName.isEmpty)
        #expect(resource.statusCode == 200)
    }

    @Test("Batch fetch accounts for every requested href and requests full content")
    func fullBatch() async throws {
        let (client, base, host) = client(xml(response("/tasks/b.ics", content: "BEGIN:VCALENDAR") + response("/tasks/a.ics", content: "BEGIN:VCALENDAR")))
        let tasks = try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: ["/tasks/a.ics", "/tasks/b.ics"], credentials: credentials)
        #expect(Set(tasks.map(\.href)) == ["/tasks/a.ics", "/tasks/b.ics"])
        #expect(tasks.allSatisfy { $0.icsData == "BEGIN:VCALENDAR" })
        let body = String(decoding: try #require(ScriptedDAVProtocol.requests(host: host).first).body, as: UTF8.self)
        #expect(body.contains("calendar-multiget"))
        #expect(body.contains("calendar-data"))
    }

    @Test("Batch omissions, duplicates, alien responses and resource failures fail the whole batch", arguments: ["omitted", "duplicate", "outside", "403", "404", "noContent", "noETag"])
    func incompleteBatch(kind: String) async {
        let good = response("/tasks/a.ics", content: "BEGIN:VCALENDAR")
        let second: String
        switch kind {
        case "duplicate": second = good
        case "outside": second = response("/other/b.ics", content: "BEGIN:VCALENDAR")
        case "403", "404": second = "<d:response><d:href>/tasks/b.ics</d:href><d:status>HTTP/1.1 \(kind) Result</d:status></d:response>"
        case "noContent": second = response("/tasks/b.ics")
        case "noETag": second = response("/tasks/b.ics", etag: "", content: "BEGIN:VCALENDAR")
        default: second = ""
        }
        let (client, base, _) = client(xml(good + second))
        await #expect(throws: (any Error).self) {
            try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: ["/tasks/a.ics", "/tasks/b.ics"], credentials: credentials)
        }
    }

    @Test("Invalid batch requests are rejected before HTTP", arguments: ["duplicate", "oversize", "outside", "foreignOrigin"])
    func invalidBatch(kind: String) async {
        let (client, base, host) = client(xml(""))
        let hrefs: [String]
        switch kind {
        case "duplicate": hrefs = ["/tasks/a.ics", "/tasks/a.ics"]
        case "oversize": hrefs = (0..<101).map { "/tasks/\($0).ics" }
        case "foreignOrigin": hrefs = ["https://elsewhere.invalid/tasks/a.ics"]
        default: hrefs = ["/other/a.ics"]
        }
        await #expect(throws: (any Error).self) {
            try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: hrefs, credentials: credentials)
        }
        #expect(ScriptedDAVProtocol.requests(host: host).isEmpty)
    }

    @Test("Absolute and percent encoded hrefs match their requested resources")
    func hrefEquivalence() async throws {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let base = "https://" + host
        let config = ScriptedDAVProtocol.install(host: host, responses: [.init(body: xml(response(base + "/tasks/a%20b.ics", content: "BEGIN:VCALENDAR")))])
        let client = CalDAVClient(configuration: config, retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        let tasks = try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: ["/tasks/a%20b.ics"], credentials: credentials)
        #expect(tasks.map(\.href) == ["/tasks/a%20b.ics"])
    }
    @Test("Ten thousand resources are downloaded through one manifest and bounded hundred href batches")
    func tenThousandResources() async throws {
        let count = 10_000
        let host = UUID().uuidString.lowercased() + ".invalid"
        let hrefs = (0..<count).map { "/tasks/\($0).ics" }
        var responses: [ScriptedDAVProtocol.Response] = [.init(body: xml(hrefs.map { response($0) }.joined()))]
        for offset in stride(from: 0, to: count, by: 100) {
            responses.append(.init(body: xml(hrefs[offset..<offset + 100].map { response($0, content: "BEGIN:VCALENDAR") }.joined())))
        }
        let client = CalDAVClient(configuration: ScriptedDAVProtocol.install(host: host, responses: responses), retryPolicy: .init(maxAttempts: 1, baseDelay: 0))
        let manifest = try await client.fetchTaskManifest(baseURL: "https://" + host, calendarPath: "/tasks/", credentials: credentials)
        #expect(manifest.count == 10_000)
        var fetched: Set<String> = []
        for offset in stride(from: 0, to: count, by: 100) {
            let tasks = try await client.fetchTaskBatch(baseURL: "https://" + host, calendarPath: "/tasks/", hrefs: Array(hrefs[offset..<offset + 100]), credentials: credentials)
            fetched.formUnion(tasks.map(\.href))
        }
        #expect(fetched.count == 10_000)
        let requests = ScriptedDAVProtocol.requests(host: host)
        #expect(requests.count == 101)
        #expect(requests.dropFirst().allSatisfy { String(decoding: $0.body, as: UTF8.self).components(separatedBy: "<d:href>").count - 1 == 100 })
    }

    @Test("Relative resource hrefs resolve under a collection even without its trailing slash")
    func relativeHref() async throws {
        let (client, base, _) = client(xml(response("a.ics", content: "BEGIN:VCALENDAR")))
        let tasks = try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks", hrefs: ["/tasks/a.ics"], credentials: credentials)
        #expect(tasks.map(\.href) == ["/tasks/a.ics"])
    }

    @Test("Batch rejects unspecified property status despite legacy parser compatibility")
    func unspecifiedStatus() async {
        let body = xml(response("/tasks/a.ics", content: "BEGIN:VCALENDAR").replacingOccurrences(of: "<d:status>HTTP/1.1 200 Result</d:status>", with: ""))
        let (client, base, _) = client(body)
        await #expect(throws: (any Error).self) {
            try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: ["/tasks/a.ics"], credentials: credentials)
        }
    }

    @Test("Large embedded calendar content remains complete")
    func largeContent() async throws {
        let content = "BEGIN:VCALENDAR\nATTACH:" + String(repeating: "A", count: 524_288) + "\nEND:VCALENDAR"
        let (client, base, _) = client(xml(response("/tasks/a.ics", content: content)))
        let tasks = try await client.fetchTaskBatch(baseURL: base, calendarPath: "/tasks/", hrefs: ["/tasks/a.ics"], credentials: credentials)
        #expect(tasks.first?.icsData == content)
    }

    @Test("Legacy quoted ETag parsing still works without propstat status")
    func legacyETag() throws {
        let body = xml("<d:response><d:href>/tasks/a.ics</d:href><d:propstat><d:prop><d:getetag>&quot;quoted&quot;</d:getetag></d:prop></d:propstat></d:response>")
        #expect(try DAVXMLParser().parse(data: Data(body.utf8)).first?.etag == "quoted")
    }

}
