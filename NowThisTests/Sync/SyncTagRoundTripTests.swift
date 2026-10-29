import Testing
import Foundation
import SwiftData

@testable import NowThis

/// Regression cover for the worst of the sync defects: **tags were parsed
/// inbound, never applied, and then deleted from the server.**
///
/// `ICalendarParser` read `CATEGORIES` into `VTODOData.categories` and nothing
/// consumed it — `task.tags` appeared exactly once in `SyncEngine`, on the push
/// side. So a task's categories arrived, were parsed, and were dropped; the
/// local task had no tags; and the next push wrote that empty set over the
/// categories on the server. A tag added in Nextcloud never reached the device,
/// and checking the task off on the device destroyed it.
///
/// ## Why the obvious fix was worse than the bug
///
/// `categories` was declared `var categories: [String] = []`, which cannot tell
/// **absent** from **empty**: a VTODO with no `CATEGORIES:` line and one with an
/// empty one both produced `[]`. Wiring that straight into `task.tags` would
/// mean any client or server that omits the property wipes the user's tags
/// locally, and the next push writes *that* deletion back — a read bug turned
/// into a worse write bug.
///
/// So it is `[String]?` now, and absence is respected. The precedent is twenty
/// lines away in `applyTodoData`, which already says the same thing about
/// `X-APPLE-SORT-ORDER`: adopt the server's value only when present, so a local
/// one isn't wiped by a VTODO that omits it.
///
/// The two halves are tested separately below because they fail separately:
/// `absent` must change nothing, `present` must be adopted exactly.
@Suite("Sync tag round-trip")
struct SyncTagRoundTripTests {

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

    /// A VTODO shaped like the one Nextcloud Tasks writes. `categories: nil`
    /// omits the property entirely, which is the case that must change nothing.
    private func vtodo(uid: String,
                       lastModified: String = "20260805T120000Z",
                       categories: [String]? = nil) -> String {
        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Nextcloud Tasks//EN",
            "BEGIN:VTODO",
            "UID:\(uid)",
            "SUMMARY:Buy milk",
            "STATUS:NEEDS-ACTION",
            "DTSTAMP:\(lastModified)",
            "LAST-MODIFIED:\(lastModified)"
        ]
        if let categories {
            lines.append("CATEGORIES:\(categories.joined(separator: ","))")
        }
        lines.append(contentsOf: ["END:VTODO", "END:VCALENDAR"])
        return lines.joined(separator: "\r\n")
    }

    /// A task the device already has, past the inbound gate: not dirty, and with
    /// an older etag and LAST-MODIFIED than the remote copy.
    @discardableResult
    private func existingTask(uid: String,
                              tags: [NowThis.Tag] = [],
                              in list: TaskList,
                              context: ModelContext) -> TaskItem {
        let task = TaskItem(uid: uid, title: "Buy milk")
        task.lastModifiedDate = Date(timeIntervalSince1970: 1000)
        task.etag = "etag-1"
        task.isDirty = false
        context.insert(task)
        task.taskList = list
        task.tags = tags
        return task
    }

    private func apply(_ ics: String,
                       uid: String,
                       to task: TaskItem,
                       list: TaskList,
                       context: ModelContext) throws {
        let engine = SyncEngine()
        var uidMap: [String: TaskItem] = [uid: task]
        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/\(uid).ics", etag: "etag-2", icsData: ics)
        try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context)
    }

    // MARK: - Present: adopt what the server says

    @Test("Categories on the server become tags on the device")
    func serverCategoriesBecomeTags() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "tag-1", in: list, context: context)

        try apply(vtodo(uid: "tag-1", categories: ["work", "errands"]),
                  uid: "tag-1", to: task, list: list, context: context)

        #expect(Set(task.tags.map(\.name)) == ["work", "errands"])
    }

    /// A task created in Nextcloud *with* categories, arriving for the first
    /// time. Different code path from the update above: the `TaskItem` is not in
    /// the context yet when its fields are applied, so the tags are attached to
    /// a model that is inserted a moment later.
    @Test("A new task arriving with categories keeps them")
    func newInboundTaskKeepsItsCategories() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let engine = SyncEngine()
        var uidMap: [String: TaskItem] = [:]

        let remote = CalDAVClient.RemoteTask(
            href: "/calendars/tasks/new-1.ics",
            etag: "etag-1",
            icsData: vtodo(uid: "new-1", categories: ["work", "errands"]))
        try engine.testApplyRemoteTask(
            remote, taskList: list, uidMap: &uidMap, modelContext: context)
        try context.save()

        let created = try #require(uidMap["new-1"])
        #expect(Set(created.tags.map(\.name)) == ["work", "errands"])

        // And it survives a round trip through the store, not just the relationship
        // held in memory before the insert.
        let fetched = try context.fetch(FetchDescriptor<TaskItem>())
            .first { $0.uid == "new-1" }
        #expect(Set(try #require(fetched).tags.map(\.name)) == ["work", "errands"])
    }

    /// The tag matching rule is not this file's invention — it is the one
    /// `CreateTaskIntent` already uses, and it is deliberately locale-aware:
    /// `lowercased()` would make "I" and "ı" different letters under a Turkish
    /// locale and create the same tag twice, and tags serialize to CATEGORIES,
    /// so the duplicate reaches the server.
    @Test("An inbound category reuses an existing tag rather than duplicating it")
    func inboundCategoryReusesAnExistingTag() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let existing = NowThis.Tag(name: "Work")
        context.insert(existing)
        let task = existingTask(uid: "tag-2", in: list, context: context)

        try apply(vtodo(uid: "tag-2", categories: ["work"]),
                  uid: "tag-2", to: task, list: list, context: context)

        #expect(task.tags.count == 1)
        #expect(task.tags.first?.id == existing.id, "must reuse the existing tag, not make a second")
        let all = try context.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(all.count == 1, "a case variant must not create a second tag")
    }

    /// Search folds accents; identity does not. "café" and "cafe" are different
    /// tags, and merging them would silently retag the user's data.
    @Test("Accents are part of a tag's identity")
    func accentsAreNotFolded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let existing = NowThis.Tag(name: "cafe")
        context.insert(existing)
        let task = existingTask(uid: "tag-3", in: list, context: context)

        try apply(vtodo(uid: "tag-3", categories: ["café"]),
                  uid: "tag-3", to: task, list: list, context: context)

        #expect(task.tags.first?.name == "café")
        let all = try context.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(all.count == 2, "café and cafe are two tags")
    }

    @Test("A tag removed on the server comes off the task")
    func tagRemovedOnServerComesOff() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let work = NowThis.Tag(name: "work")
        let home = NowThis.Tag(name: "home")
        context.insert(work); context.insert(home)
        let task = existingTask(uid: "tag-4", tags: [work, home], in: list, context: context)

        try apply(vtodo(uid: "tag-4", categories: ["work"]),
                  uid: "tag-4", to: task, list: list, context: context)

        #expect(task.tags.map(\.name) == ["work"])
        // Removed from the task, not deleted from the app — the tag may be on
        // other tasks, and it is still in the user's sidebar.
        let all = try context.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(all.count == 2)
    }

    /// The server said "this task has no categories". That is an instruction,
    /// and it is distinguishable from saying nothing.
    @Test("An empty CATEGORIES property clears the task's tags")
    func emptyCategoriesClearsTags() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let work = NowThis.Tag(name: "work")
        context.insert(work)
        let task = existingTask(uid: "tag-5", tags: [work], in: list, context: context)

        try apply(vtodo(uid: "tag-5", categories: []),
                  uid: "tag-5", to: task, list: list, context: context)

        #expect(task.tags.isEmpty)
    }

    // MARK: - The other direction: a tag added here

    /// Adopting the server's list is only safe if a tag added *on this device*
    /// reliably gets to the server first. That is the dirty flag's job, and none
    /// of the three tag-editing paths set it: the picker's toggle, the "create
    /// and add" field, and the x on a pill all mutated `task.tags` directly.
    ///
    /// The consequence was two-sided and neither side was visible. The change
    /// never pushed, so no other device ever saw it; and the task was not dirty,
    /// so the inbound gate did not protect it and the next pull overwrote it.
    /// Before tags were applied inbound at all, the second half was hidden —
    /// nothing overwrote them because nothing wrote them.
    @Test("A tag added on this device is queued for the server")
    func aLocalTagChangeQueuesTheTaskForPush() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "local-1", in: list, context: context)
        let work = NowThis.Tag(name: "work")
        context.insert(work)
        try context.save()

        task.tags.append(work)
        TaskListHelpers.markTagsChanged(on: task)
        try context.save()

        let dirty = SyncEngine().testFindDirtyTasks(for: list, modelContext: context)
        #expect(dirty.contains("local-1"), "an unpushed tag change must be queued")
    }

    /// And until it has been pushed, the server's list must not replace it.
    @Test("A tag added on this device survives the next pull")
    func aLocalTagChangeIsNotOverwrittenByThePull() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "local-2", in: list, context: context)
        let work = NowThis.Tag(name: "work")
        context.insert(work)
        try context.save()

        task.tags.append(work)
        TaskListHelpers.markTagsChanged(on: task)
        try context.save()

        // The server has not heard about "work" yet and says the task has none.
        try apply(vtodo(uid: "local-2", categories: []),
                  uid: "local-2", to: task, list: list, context: context)

        #expect(task.tags.map(\.name) == ["work"], "the unpushed local tag must survive")
    }

    // MARK: - Catch-up: tasks pulled before tags were applied

    /// Applying `CATEGORIES` fixed every task the server changes from then on, and
    /// none of the tasks a device already held. Those were pulled by a build that
    /// threw categories away, and they still carry that pull's etag — so the etag
    /// gate calls them unchanged and never reads their categories again. They stay
    /// untagged until someone edits them on the server, and the first time one is
    /// completed here, the push writes the empty tag set over the server's
    /// categories. Found by a Thunderbird user whose categories reached Nextcloud
    /// and every other client, and not NowThis.
    private func unchangedRemote(uid: String, categories: [String]?) -> CalDAVClient.RemoteTask {
        CalDAVClient.RemoteTask(href: "/calendars/tasks/\(uid).ics", etag: "etag-1",
                                icsData: vtodo(uid: uid, categories: categories))
    }

    @Test("A task pulled before tags were applied gets its categories on the catch-up pass")
    func catchUpAppliesCategoriesTheEtagGateSkips() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "old-1", in: list, context: context)
        let remote = unchangedRemote(uid: "old-1", categories: ["work", "errands"])
        var uidMap: [String: TaskItem] = ["old-1": task]
        let engine = SyncEngine()

        // The gap: the ordinary pull sees the etag it already holds and reads nothing.
        #expect(try engine.testProcessRemoteTask(remote, taskList: list, uidMap: &uidMap, modelContext: context) == false)
        #expect(task.tags.isEmpty)

        let changed = engine.testCatchUpCategories(remoteTasks: [remote], uidMap: uidMap, modelContext: context)

        #expect(changed, "tags appearing must refresh the UI")
        #expect(Set(task.tags.map(\.name)) == ["work", "errands"])
        #expect(!task.isDirty, "the server already has these categories — there is nothing to upload")

        // A second pass has nothing to add, and must not refresh the UI for nothing.
        #expect(engine.testCatchUpCategories(remoteTasks: [remote], uidMap: uidMap, modelContext: context) == false)
    }

    /// Additive, because the device can hold a tag the server never heard of:
    /// until tag edits marked a task dirty, a tag added in Task Detail was never
    /// uploaded. Adopting the server's set here would delete it.
    @Test("The catch-up adds the server's categories and takes nothing away")
    func catchUpIsAdditive() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let home = NowThis.Tag(name: "home")
        let work = NowThis.Tag(name: "work")
        context.insert(home); context.insert(work)
        let task = existingTask(uid: "old-2", tags: [home], in: list, context: context)

        SyncEngine().testCatchUpCategories(
            remoteTasks: [unchangedRemote(uid: "old-2", categories: ["Work"])],
            uidMap: ["old-2": task], modelContext: context)

        #expect(Set(task.tags.map(\.name)) == ["home", "work"])
        let all = try context.fetch(FetchDescriptor<NowThis.Tag>())
        #expect(all.count == 2, "Work must reuse the existing work tag")
    }

    /// A task edited here before the catch-up ran is dirty, so the gate refuses it
    /// — and its push is precisely the write that would erase the server's
    /// categories. The catch-up reaches it anyway, and leaves it dirty so the edit
    /// still goes out, now carrying them.
    @Test("The catch-up reaches a task with unpushed edits, so its upload keeps the server's categories")
    func catchUpReachesDirtyTasks() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "old-3", in: list, context: context)
        task.isDirty = true

        SyncEngine().testCatchUpCategories(
            remoteTasks: [unchangedRemote(uid: "old-3", categories: ["work"])],
            uidMap: ["old-3": task], modelContext: context)

        #expect(task.tags.map(\.name) == ["work"])
        #expect(task.isDirty, "the local edit must still be uploaded")
    }

    /// Nothing is attached to a task on its way out, or its categories would land
    /// in the sidebar as tags belonging to nothing.
    @Test("The catch-up leaves a task awaiting deletion alone")
    func catchUpSkipsTasksAwaitingDeletion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let task = existingTask(uid: "old-4", in: list, context: context)
        task.isDeletedLocally = true

        let changed = SyncEngine().testCatchUpCategories(
            remoteTasks: [unchangedRemote(uid: "old-4", categories: ["work"])],
            uidMap: ["old-4": task], modelContext: context)

        #expect(changed == false)
        #expect(task.tags.isEmpty)
        #expect(try context.fetch(FetchDescriptor<NowThis.Tag>()).isEmpty)
    }

    /// Once per list, not once per sync: after it, the etag gate is right again,
    /// and repeating an additive pass would bring back every tag deleted from the
    /// sidebar — a deletion that never reaches the server.
    @Test("The catch-up is owed once per list")
    func catchUpIsOncePerList() throws {
        let suite = "SyncTagRoundTripTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SyncEngine.categoriesCatchUpPending(listID: "list-a", defaults: defaults))
        SyncEngine.markCategoriesCaughtUp(listID: "list-a", defaults: defaults)
        #expect(!SyncEngine.categoriesCatchUpPending(listID: "list-a", defaults: defaults))
        #expect(SyncEngine.categoriesCatchUpPending(listID: "list-b", defaults: defaults),
                "each list is caught up on its own")
    }

    // MARK: - Absent: change nothing

    /// **The test that stops the fix being worse than the bug.** A VTODO with no
    /// `CATEGORIES:` line at all is not a claim that the task has no tags. Every
    /// client that has never heard of the property omits it, and adopting that
    /// silence as "no tags" deletes the user's tags locally and then pushes the
    /// deletion to the server.
    @Test("A VTODO with no CATEGORIES leaves the task's tags alone")
    func absentCategoriesLeavesTagsAlone() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let list = makeList(in: context)
        let work = NowThis.Tag(name: "work")
        let home = NowThis.Tag(name: "home")
        context.insert(work); context.insert(home)
        let task = existingTask(uid: "tag-6", tags: [work, home], in: list, context: context)

        try apply(vtodo(uid: "tag-6", categories: nil),
                  uid: "tag-6", to: task, list: list, context: context)

        #expect(Set(task.tags.map(\.name)) == ["work", "home"])
    }

    /// The parser has to preserve the distinction the model relies on, or the
    /// two cases above collapse into one at the boundary before `SyncEngine`
    /// ever sees them.
    @Test("The parser tells an absent CATEGORIES from an empty one")
    func parserDistinguishesAbsentFromEmpty() throws {
        let parsedAbsent = try ICalendarParser.parseSingleVTODO(
            from: vtodo(uid: "p-1", categories: nil))
        #expect(try #require(parsedAbsent).categories == nil)

        let parsedEmpty = try ICalendarParser.parseSingleVTODO(
            from: vtodo(uid: "p-2", categories: []))
        #expect(try #require(parsedEmpty).categories == [])

        let parsedPresent = try ICalendarParser.parseSingleVTODO(
            from: vtodo(uid: "p-3", categories: ["work", "errands"]))
        #expect(try #require(parsedPresent).categories == ["work", "errands"])
    }

    /// RFC 5545 escapes a comma, semicolon or backslash inside a category, and
    /// both writers this app meets do: `ICalendarSerializer` joins a task's tags
    /// with commas and escapes the ones inside a name, and Thunderbird writes one
    /// escaped `CATEGORIES` line per category. The parser split on every comma
    /// and unescaped nothing, so "Home, Garden" arrived as two tags, `Home\` and
    /// `Garden`, and the next upload wrote both to the server.
    @Test("A category with a comma, semicolon or backslash in its name arrives whole")
    func escapedCategoriesArriveWhole() throws {
        func categories(_ lines: [String]) throws -> [String]? {
            let ics = (["BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:VTODO", "UID:esc-1"]
                       + lines + ["END:VTODO", "END:VCALENDAR"]).joined(separator: "\r\n")
            return try #require(try ICalendarParser.parseSingleVTODO(from: ics)).categories
        }

        // Thunderbird: one property per category.
        #expect(try categories([#"CATEGORIES:Home\, Garden"#, #"CATEGORIES:R&D\; Q3"#])
                == ["Home, Garden", "R&D; Q3"])

        // This app's serializer: one property, joined.
        let names = ["Home, Garden", "R&D; Q3", #"C:\Temp"#, "Work"]
        let joined = "CATEGORIES:" + names.map(ICalendarSerializer.escapeText).joined(separator: ",")
        #expect(try categories([joined]) == names)
    }

    // MARK: - The catch-up is wired into the pull

    /// `syncCalendar` needs a live server and nothing here stubs one, so its
    /// wiring is pinned on the source — the tactic, and the deliberate
    /// brittleness, `SyncPullCompletenessGuardTests` explains. Each call is load
    /// bearing: the pending check must come before the CTag skip, or a list whose
    /// CTag has not moved never pulls and never catches up; the pass must come
    /// before the upload, or a dirty task goes out without its categories; and
    /// without the mark it repeats every sync, restoring tags deleted from the
    /// sidebar.
    @Test("syncCalendar owes, runs and records the categories catch-up, in order")
    func catchUpIsWiredIntoTheForegroundPull() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let source = try String(contentsOf: root.appendingPathComponent("NowThis/Sync/SyncEngine.swift"),
                                encoding: .utf8)
        let start = try #require(source.range(of: "private func syncCalendar("))
        let end = try #require(source.range(of: "// MARK: - Pull (Remote → Local)",
                                            range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        #expect(body.contains("lastFullPullDate"), "the span found is not syncCalendar's body")

        let order = ["categoriesCatchUpPending(", "shouldSkipPull(",
                     "pullCalendarCheckingPhotoAccess(", "markCategoriesCaughtUp("]
        var previous = body.startIndex
        var examined = 0
        for call in order {
            let found = try #require(body.range(of: call), "syncCalendar never calls \(call)")
            #expect(found.lowerBound >= previous, "\(call) is out of order in syncCalendar")
            previous = found.lowerBound
            examined += 1
        }
        let upload = try #require(body.range(of: "pushLocalTask(", options: .backwards))
        #expect(try #require(body.range(of: "pullCalendarCheckingPhotoAccess(")).lowerBound < upload.lowerBound,
                "the pull must run before the upload it protects")
        let importer = try String(contentsOf: root.appendingPathComponent("NowThis/Sync/SyncInboundBatchWriter.swift"), encoding: .utf8)
        #expect(importer.contains("importer.catchUpCategories("), "The shared bounded writer must perform additive category repair before uploads")
        #expect(examined == order.count,
                "examined \(examined) calls; a guard that examines none reports success")
    }
}
