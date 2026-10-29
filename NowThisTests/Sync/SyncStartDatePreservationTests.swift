import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Regression cover for **a start date the app withheld being read back as one
/// the user deleted.**
///
/// RFC 5545 requires `DUE` to be later than `DTSTART` in a VTODO, and Sabre
/// rejects violations, so the serializer omits `DTSTART` when the start is not
/// before the due date. That much is deliberate. What was not deliberate is
/// what happened next: the pull takes the remote as the truth, saw a VTODO with
/// no `DTSTART`, and cleared `startDate` locally. The field the user set
/// vanished from the app that chose not to send it.
///
/// The asymmetry is the fix. A start date we withheld was never on the server,
/// so its absence there cannot mean the user cleared it — there was nothing to
/// clear. A start date we *did* send and that comes back absent is a genuine
/// deletion and must still be applied. One rule, `ICalendarSerializer
/// .omitsStart`, decides both the omission and whether the absence counts.
///
/// The same shape already exists a few lines below in the applier for
/// `X-APPLE-SORT-ORDER`, which is only adopted when present. A start date needs
/// the narrower rule because, unlike a sort order, it is something the user can
/// legitimately clear on the server.
@Suite("Sync start-date preservation")
struct SyncStartDatePreservationTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 NowThis.Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    private func makeList(in context: ModelContext) -> TaskList {
        let list = TaskList(serverURL: "/calendars/tasks/", name: "Tasks", colorHex: "#007AFF")
        context.insert(list)
        return list
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    /// A VTODO with a `DUE` and deliberately no `DTSTART` — what the server
    /// holds after a push that suppressed the start.
    private func vtodoWithoutStart(uid: String) -> CalDAVClient.RemoteTask {
        let ics = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nextcloud Tasks//EN",
            "BEGIN:VTODO",
            "UID:\(uid)",
            "SUMMARY:Task",
            "STATUS:NEEDS-ACTION",
            "DUE:20260609T170000Z",
            "DTSTAMP:20260609T120000Z",
            "LAST-MODIFIED:20260609T120000Z",
            "END:VTODO",
            "END:VCALENDAR"
        ].joined(separator: "\r\n")
        return CalDAVClient.RemoteTask(href: "/calendars/tasks/\(uid).ics",
                                       etag: "etag-2",
                                       icsData: ics)
    }

    private func task(uid: String,
                      start: Date,
                      due: Date,
                      in list: TaskList,
                      context: ModelContext) -> TaskItem {
        let item = TaskItem(uid: uid, title: "Task")
        item.etag = "etag-1"
        item.isDirty = false
        item.dueDate = due
        item.startDate = start
        context.insert(item)
        item.taskList = list
        return item
    }

    // MARK: - The rule itself

    @Test("A start on or after the due date is the one the serializer withholds")
    func omitsStartMatchesWhatIsSent() {
        let due = date(2026, 6, 9, 17)

        #expect(ICalendarSerializer.omitsStart(startDate: date(2026, 6, 9, 18), dueDate: due,
                                               isDueDateOnly: false, isStartDateOnly: false))
        #expect(ICalendarSerializer.omitsStart(startDate: due, dueDate: due,
                                               isDueDateOnly: false, isStartDateOnly: false))
        #expect(!ICalendarSerializer.omitsStart(startDate: date(2026, 6, 9, 16), dueDate: due,
                                               isDueDateOnly: false, isStartDateOnly: false))
        #expect(!ICalendarSerializer.omitsStart(startDate: date(2026, 6, 9, 16), dueDate: nil,
                                               isDueDateOnly: false, isStartDateOnly: false),
                "with no due date there is nothing to violate")
        #expect(!ICalendarSerializer.omitsStart(startDate: nil, dueDate: due,
                                               isDueDateOnly: false, isStartDateOnly: false),
                "no start date is not a withheld one")
    }

    /// The rule and the serializer may not disagree. If they ever did, the
    /// applier would either keep a start the server really had cleared or erase
    /// one that was never sent.
    @Test("The rule agrees with what the serializer actually emits")
    func theRuleAgreesWithTheOutput() {
        let due = date(2026, 6, 9, 17)
        for hour in [15, 16, 17, 18, 19] {
            let start = date(2026, 6, 9, hour)
            let ics = ICalendarSerializer.serialize(uid: "u", summary: "Task",
                                                    dueDate: due, startDate: start)
            let omitted = !ics.contains("DTSTART")
            #expect(omitted == ICalendarSerializer.omitsStart(startDate: start, dueDate: due,
                                                              isDueDateOnly: false,
                                                              isStartDateOnly: false),
                    "the rule and the output disagree for a start at \(hour):00")
        }
    }

    // MARK: - The pull must not read the omission as a deletion

    @Test("A withheld start date survives a pull that carries no DTSTART")
    func withheldStartSurvivesThePull() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        // 18:00 start against a 17:00 due — the app never sent this DTSTART.
        let start = date(2026, 6, 9, 18)
        let local = task(uid: "withheld-1", start: start, due: date(2026, 6, 9, 17),
                         in: list, context: context)
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        _ = try engine.testApplyRemoteTask(vtodoWithoutStart(uid: "withheld-1"),
                                           taskList: list, uidMap: &uidMap, modelContext: context)

        #expect(local.startDate == start, "the app withheld this, so the server never had it to clear")
    }

    @Test("A start date the server really cleared is still removed")
    func aGenuinelyClearedStartIsRemoved() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        // 16:00 against a 17:00 due — this one was sent, so its absence is real.
        let local = task(uid: "cleared-1", start: date(2026, 6, 9, 16), due: date(2026, 6, 9, 17),
                         in: list, context: context)
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        _ = try engine.testApplyRemoteTask(vtodoWithoutStart(uid: "cleared-1"),
                                           taskList: list, uidMap: &uidMap, modelContext: context)

        #expect(local.startDate == nil, "this DTSTART was pushed, so the server dropping it is a deletion")
    }

    @Test("The foreground pull preserves a withheld start too")
    func theForegroundPullPreservesItAsWell() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()

        let start = date(2026, 6, 9, 18)
        let local = task(uid: "withheld-2", start: start, due: date(2026, 6, 9, 17),
                         in: list, context: context)
        try context.save()
        var uidMap = engine.testExistingTaskMap(for: list, modelContext: context)

        _ = try engine.testProcessRemoteTask(vtodoWithoutStart(uid: "withheld-2"),
                                             taskList: list, uidMap: &uidMap, modelContext: context)

        #expect(local.startDate == start)
    }
}
