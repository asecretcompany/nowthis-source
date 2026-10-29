import Foundation
import SwiftData
@testable import NowThis

enum DAVSyncScenario {
    static func container() throws -> ModelContainer {
        try ModelContainer(for: TaskItem.self, TaskList.self, JournalEntry.self,
            Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    static func multistatus(_ responses: String) -> String {
        "<d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\" xmlns:cs=\"http://calendarserver.org/ns/\">" + responses + "</d:multistatus>"
    }
    static func prop(_ href: String, _ properties: String) -> String {
        "<d:response><d:href>" + href + "</d:href><d:propstat><d:prop>" + properties
            + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    }
    static func discovery(paths: [String]) -> [ScriptedDAVProtocol.Response] {
        [.init(body: multistatus(prop("/principal/", "<d:current-user-principal><d:href>/principal/</d:href></d:current-user-principal>"))),
         .init(body: multistatus(prop("/principal/", "<c:calendar-home-set><d:href>/calendars/</d:href></c:calendar-home-set>"))),
         .init(body: multistatus(paths.map { path in
             prop(path, "<d:displayname>Fixture</d:displayname><d:resourcetype><c:calendar/></d:resourcetype><c:supported-calendar-component-set><c:comp name=\"VTODO\"/></c:supported-calendar-component-set><cs:getctag>c1</cs:getctag>")
         }.joined()))]
    }
    static func tasks(count: Int, path: String = "/one/", startIndex: Int = 0) -> String {
        multistatus((startIndex..<(startIndex + count)).map { index in
            prop(path + "\(index).ics", "<d:getetag>e\(index)</d:getetag><c:calendar-data>BEGIN:VCALENDAR\nBEGIN:VTODO\nUID:fixture-\(index)\nSUMMARY:Moon bakery delivery \(index)\nEND:VTODO\nEND:VCALENDAR</c:calendar-data>")
        }.joined())
    }
    static func manifest(count: Int, path: String = "/one/") -> String {
        multistatus((0..<count).map { index in prop(path + "\(index).ics", "<d:getetag>e\(index)</d:getetag>") }.joined())
    }
    @MainActor
    static func account(in container: ModelContainer) throws -> String {
        let account = ServerAccount(displayName: "Fixture", serverBaseURL: "https://unused.invalid", username: "fixture")
        container.mainContext.insert(account); try container.mainContext.save()
        return account.id
    }
}
