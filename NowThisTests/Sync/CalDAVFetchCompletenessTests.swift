import Testing
import Foundation

@testable import NowThis

/// Cover for **a task resource arriving with no calendar data being read as a
/// task the server no longer has.**
///
/// `fetchAllTasks` drops every response whose `calendar-data` is empty. That
/// filter is not defensive dressing — it exists because such responses really
/// do arrive, and while the pull could only add and update, dropping them was
/// right: there was nothing to apply.
///
/// `SyncEngine.tasksDeletedOnServer` changed what a drop means. A resource
/// dropped here never reaches `remoteUIDSet`, so it contributes no UID, so the
/// local task it belongs to is absent from the fetched set — which is now the
/// definition of "deleted on the server". A propstat that came back without
/// its data, for one request, deletes the task permanently.
///
/// The collection itself is the one response that legitimately carries no
/// calendar data, and it is identifiable: its href **is** the calendar path.
/// Anything else missing its data is a task whose content did not arrive, and
/// that is a reason to fail the fetch rather than to proceed as though the
/// server had disowned it.
@Suite("CalDAV fetch completeness")
struct CalDAVFetchCompletenessTests {

    private func resource(href: String, data: String, etag: String = "e") -> DAVXMLParser.DAVResource {
        var found = DAVXMLParser.DAVResource()
        found.href = href
        found.etag = etag
        found.calendarData = data
        return found
    }

    private let calendarPath = "/remote.php/dav/calendars/user/tasks/"

    @Test("Task resources become remote tasks")
    func taskResourcesBecomeRemoteTasks() throws {
        let resources = [
            resource(href: calendarPath + "1.ics", data: "BEGIN:VCALENDAR"),
            resource(href: calendarPath + "2.ics", data: "BEGIN:VCALENDAR")
        ]

        let tasks = try CalDAVClient.remoteTasks(from: resources, calendarPath: calendarPath)

        #expect(tasks.count == 2)
        #expect(Set(tasks.map(\.href)) == Set(resources.map(\.href)))
    }

    /// The collection may appear in the multistatus with no calendar data of
    /// its own. That is not a missing task and must not fail the fetch.
    @Test("The calendar collection itself is skipped, not treated as a loss")
    func theCollectionIsSkipped() throws {
        let resources = [
            resource(href: calendarPath, data: ""),
            resource(href: calendarPath + "1.ics", data: "BEGIN:VCALENDAR")
        ]

        let tasks = try CalDAVClient.remoteTasks(from: resources, calendarPath: calendarPath)

        #expect(tasks.count == 1)
        #expect(tasks.first?.href == calendarPath + "1.ics")
    }

    /// Trailing-slash spellings of the same collection must both be recognised,
    /// or a server that omits it turns its own collection into a phantom
    /// deletion of every task in the list.
    @Test("The collection is recognised with or without its trailing slash")
    func theCollectionIsRecognisedEitherWay() throws {
        let withoutSlash = String(calendarPath.dropLast())
        let resources = [
            resource(href: withoutSlash, data: ""),
            resource(href: calendarPath + "1.ics", data: "BEGIN:VCALENDAR")
        ]

        let tasks = try CalDAVClient.remoteTasks(from: resources, calendarPath: calendarPath)
        #expect(tasks.count == 1)
    }

    /// The failure this exists for.
    @Test("A task resource with no calendar data fails the fetch")
    func aTaskWithNoDataFailsTheFetch() {
        let resources = [
            resource(href: calendarPath + "1.ics", data: "BEGIN:VCALENDAR"),
            resource(href: calendarPath + "2.ics", data: "")
        ]

        #expect(throws: (any Error).self) {
            _ = try CalDAVClient.remoteTasks(from: resources, calendarPath: calendarPath)
        }
    }

    @Test("An empty multistatus is still an empty list, not a failure")
    func anEmptyListIsNotAFailure() throws {
        let tasks = try CalDAVClient.remoteTasks(from: [], calendarPath: calendarPath)
        #expect(tasks.isEmpty)
    }
}
