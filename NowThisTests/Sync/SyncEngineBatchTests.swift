import Testing
import Foundation

@testable import NowThis

@Suite("SyncEngine Batch Processing")
struct SyncEngineBatchTests {

    @Test("partitionByStatus separates active from completed tasks")
    func partitionByStatus() {
        let activeTodo = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:active-1
        SUMMARY:Buy groceries
        STATUS:NEEDS-ACTION
        END:VTODO
        END:VCALENDAR
        """

        let completedTodo = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:done-1
        SUMMARY:Old errand
        STATUS:COMPLETED
        END:VTODO
        END:VCALENDAR
        """

        let cancelledTodo = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:cancelled-1
        SUMMARY:Cancelled thing
        STATUS:CANCELLED
        END:VTODO
        END:VCALENDAR
        """

        let inProgressTodo = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:wip-1
        SUMMARY:Working on it
        STATUS:IN-PROCESS
        END:VTODO
        END:VCALENDAR
        """

        let noStatusTodo = """
        BEGIN:VCALENDAR
        BEGIN:VTODO
        UID:nostatus-1
        SUMMARY:No status set
        END:VTODO
        END:VCALENDAR
        """

        let remoteTasks: [CalDAVClient.RemoteTask] = [
            .init(href: "/active.ics", etag: "1", icsData: activeTodo),
            .init(href: "/done.ics", etag: "2", icsData: completedTodo),
            .init(href: "/cancelled.ics", etag: "3", icsData: cancelledTodo),
            .init(href: "/wip.ics", etag: "4", icsData: inProgressTodo),
            .init(href: "/nostatus.ics", etag: "5", icsData: noStatusTodo),
        ]

        let (active, completed) = SyncEngine.partitionByStatus(remoteTasks)

        #expect(active.count == 3, "Active should include NEEDS-ACTION, IN-PROCESS, and no-status tasks")
        #expect(completed.count == 2, "Completed should include COMPLETED and CANCELLED tasks")

        let activeHrefs = Set(active.map(\.href))
        #expect(activeHrefs.contains("/active.ics"))
        #expect(activeHrefs.contains("/wip.ics"))
        #expect(activeHrefs.contains("/nostatus.ics"))

        let completedHrefs = Set(completed.map(\.href))
        #expect(completedHrefs.contains("/done.ics"))
        #expect(completedHrefs.contains("/cancelled.ics"))
    }

    @Test("partitionByStatus handles empty input")
    func partitionEmpty() {
        let (active, completed) = SyncEngine.partitionByStatus([])
        #expect(active.isEmpty)
        #expect(completed.isEmpty)
    }
}
