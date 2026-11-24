import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct SyncScaleTests {
    @Test("nested performance fixture stores exactly 1,650 tasks and their hierarchy")
    func nestedFixtureHasExactCountAndRelationships() throws {
        let fixture = try PerformanceFixture.seedNestedTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())
        let roots = tasks.filter { $0.parentTask == nil }

        #expect(tasks.count == PerformanceFixture.nestedTaskCount)
        #expect(lists.count == 1)
        #expect(roots.count == 1)
        #expect(tasks.filter { $0.parentTask != nil }.count == tasks.count - 1)
        #expect(roots[0].subtasks.count == 2)
        #expect(tasks.allSatisfy { $0.taskList?.id == lists[0].id })

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for index in 1..<tasks.count {
            let expectedParentID = PerformanceFixture.taskID(index: (index - 1) / 2)
            #expect(tasksByID[PerformanceFixture.taskID(index: index)]?.parentTask?.id == expectedParentID)
        }
        withExtendedLifetime(fixture) {}
    }

    @Test("distributed performance fixture stores exactly 10,000 tasks across 100 lists")
    func distributedFixtureHasExactCountsAndRelationships() throws {
        let fixture = try PerformanceFixture.seedDistributedTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())
        let countsByList = Dictionary(grouping: tasks, by: { $0.taskList?.id }).mapValues(\.count)

        #expect(tasks.count == PerformanceFixture.distributedTaskCount)
        #expect(lists.count == PerformanceFixture.distributedListCount)
        #expect(countsByList.count == PerformanceFixture.distributedListCount)
        #expect(countsByList.values.allSatisfy { $0 == PerformanceFixture.distributedTasksPerList })
        #expect(tasks.allSatisfy { $0.parentTask == nil })
        withExtendedLifetime(fixture) {}
    }

    @Test("single-list performance fixture stores exactly 10,000 tasks in one list")
    func singleListFixtureHasExactCountAndRelationships() throws {
        let fixture = try PerformanceFixture.seedSingleListTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let lists = try fixture.context.fetch(FetchDescriptor<TaskList>())

        #expect(tasks.count == PerformanceFixture.distributedTaskCount)
        #expect(lists.count == 1)
        #expect(tasks.allSatisfy { $0.taskList?.id == lists[0].id })
        withExtendedLifetime(fixture) {}
    }

    @Test("calendar week fixture stores 1,000 tasks with dates in each ISO week day")
    func calendarWeekFixtureHasExactDatedTasks() throws {
        let fixture = try PerformanceFixture.seedCalendarWeekTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
        let dates = try #require(tasks.compactMap(\.dueDate).sorted().first)
        let weekStart = PerformanceFixture.calendarWeekStart
        let weekEnd = try #require(Calendar(identifier: .iso8601).date(byAdding: .day, value: 7, to: weekStart))
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = PerformanceFixture.timeZone
        let dayCounts = Dictionary(grouping: tasks.compactMap(\.dueDate), by: { calendar.startOfDay(for: $0) })

        #expect(tasks.count == PerformanceFixture.calendarWeekTaskCount)
        #expect(dates >= weekStart)
        #expect(tasks.allSatisfy { task in
            guard let dueDate = task.dueDate else { return false }
            return dueDate >= weekStart && dueDate < weekEnd
        })
        #expect(dayCounts.count == 7)
        #expect(dayCounts.values.map(\.count).sorted() == [142, 143, 143, 143, 143, 143, 143])
        withExtendedLifetime(fixture) {}
    }

    @Test("attachment fixture emits deterministic ICS with the requested binary payload size")
    func attachmentPayloadHasRequestedSize() {
        let payload = PerformanceFixture.largeAttachmentICS(binaryByteCount: 16 * 1024)
        let expectedAttachment = Data(repeating: 0x41, count: 16 * 1024).base64EncodedString()

        #expect(payload.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//NowThis//Performance Fixture//EN\r\nBEGIN:VTODO\r\n"))
        #expect(payload.contains("ATTACH;ENCODING=BASE64;VALUE=BINARY:\(expectedAttachment)\r\n"))
        #expect(payload.hasSuffix("END:VTODO\r\nEND:VCALENDAR\r\n"))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["NOWTHIS_PERFORMANCE_STRESS"] == "1",
        "Set NOWTHIS_PERFORMANCE_STRESS=1 to run the optional 50,000-task stress case"
    ))
    func optionalStressFixtureStoresExactly50000Tasks() throws {
        let fixture = try PerformanceFixture.seedStressTasks()
        let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())

        #expect(tasks.count == PerformanceFixture.stressTaskCount)
        withExtendedLifetime(fixture) {}
    }

    /// Synthetic component/engine timings, never UI interaction latency. Run with
    /// -configuration Performance -enableCodeCoverage NO and no debugger attached.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOWTHIS_BACKLOG_MEASUREMENTS"] == "1",
                   "Set NOWTHIS_BACKLOG_MEASUREMENTS=1 for five-run backlog measurements"), .serialized,
          arguments: [1_000, 10_000])
    func backlogMeasurement(count: Int) async throws {
        let host = "backlog-" + UUID().uuidString.lowercased() + ".invalid"
        let container = try DAVSyncScenario.container()
        let accountID = try DAVSyncScenario.account(in: container, host: host)
        let credentials = CalDAVClient.Credentials(username: "fixture", password: "fixture")
        let engine = SyncEngine(calDAVClient: CalDAVClient(configuration: ScriptedDAVProtocol.install(
            host: host, responses: measurementDiscovery()
                + [.init(body: DAVSyncScenario.manifest(count: 1)), .init(body: DAVSyncScenario.tasks(count: 1))]),
            retryPolicy: .init(maxAttempts: 1, baseDelay: 0)))
        // Establish production list identity, baseline checkpoint and catch-up state.
        // Bootstrap, deterministic seeding, verification and scripts are outside intervals.
        let baseline = await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
            credentials: credentials, modelContainer: container, reconcileNotifications: false)
        #expect(baseline.status == .completed)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let list = try #require(try context.fetch(FetchDescriptor<TaskList>()).first)
        let listID = list.id
        let shapeScope = try #require(TaskPhotoOwnership.Scope(list: list))
        #expect(!SyncEngine.categoriesCatchUpPending(listID: listID))
        for index in 1..<count {
            let task = TaskItem(id: PerformanceFixture.taskID(index: index), uid: "fixture-\(index)",
                                title: "Moon bakery delivery \(index)")
            task.taskList = list
            task.remoteHref = "/one/\(index).ics"
            task.etag = "e\(index)"
            task.isLocalOnly = false
            task.dueDate = PerformanceFixture.calendarWeekStart.addingTimeInterval(Double(index % 7) * 86_400)
            context.insert(task)
        }
        try context.save()
        let key = SyncImportCheckpoint.identity(accountID: accountID, listID: list.id,
            baseURL: "https://" + host, username: credentials.username, months: 0)
        let scope = SyncCollectionPuller.Scope(accountID: accountID, listID: listID, historyScope: "0")
        for start in stride(from: 1, to: count, by: 100) {
            let resources = (start..<min(start + 100, count)).map { index in
                ParsedRemoteTask(href: "/one/\(index).ics", etag: "e\(index)",
                    todo: .init(uid: "fixture-\(index)"), shape: .singleTask)
            }
            let shapes = ModelContext(container)
            shapes.autosaveEnabled = false
            try SyncResourceState.observe(resources, scope: shapeScope, in: shapes)
            try shapes.save()
            let receipts = resources.map { CalDAVClient.RemoteTask(href: $0.href, etag: $0.etag, icsData: "") }
            try SyncImportCheckpoint.markAccounted(receipts, id: key, container: container)
        }
        let proofReader = ModelContext(container)
        let proofList = try #require(try proofReader.fetch(FetchDescriptor<TaskList>(predicate: #Predicate {
            $0.id == listID
        })).first)
        let classification = try SyncResourceState.needsClassification(list: proofList, in: proofReader)
        let hierarchyPending = try SyncImportCheckpoint.hierarchyPending(id: key, in: proofReader)
        try #require(classification.isEmpty && !hierarchyPending)
        let initialCheckpoint = try #require(try SyncImportCheckpoint.read(id: key, scope: scope, in: proofReader))
        try #require(initialCheckpoint.hasCompletedBaseline && initialCheckpoint.token == "baseline-token")
        #expect(try SyncImportCheckpoint.accountedETags(id: key, container: container).count == count)
        #expect(try context.fetchCount(FetchDescriptor<TaskItem>()) == count)
        let tasks = try context.fetch(FetchDescriptor<TaskItem>())
        let calendarDescriptor = FetchDescriptor(predicate: CalendarContainerView.taskQueryPredicate(listID: list.id))
        var noOpTimes: [Double] = []; var deltaTimes: [Double] = []; var calendarTimes: [Double] = []
        var inventoryTimes: [Double] = []; var ctagTimes: [Double] = []
        for run in 0..<5 {
            let emptyToken = "empty-\(run)"
            _ = ScriptedDAVProtocol.install(host: host, responses: measurementDiscovery()
                + [.init(body: DAVSyncScenario.multistatus("<d:sync-token>\(emptyToken)</d:sync-token>"))])
            let noOpReads = PerformanceTrace.OperationRecorder()
            let noOpStart = ContinuousClock.now
            let noOp = await PerformanceTrace.$operationRecorder.withValue(noOpReads) {
                await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: credentials, modelContainer: container, reconcileNotifications: false)
            }
            noOpTimes.append(Self.milliseconds(since: noOpStart))
            let emptyCheckpoint = try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container))
            #expect(emptyCheckpoint?.token == emptyToken)
            #expect(emptyCheckpoint?.lastIntegrity == initialCheckpoint.lastIntegrity)
            Self.expectSyncReads(noOpReads, count: count, changed: false, ctagOnly: false, run: run)
            #expect(noOp.status == .completed)
            #expect(noOp.updatedCount == 0 && noOp.importedCount == 0 && noOp.deletedCount == 0)
            let noOpRequests = ScriptedDAVProtocol.requests(host: host)
            #expect(noOpRequests.count == 4)
            #expect(noOpRequests.filter { String(decoding: $0.body, as: UTF8.self).contains("sync-collection") }.count == 1)

            let index = count - 1
            let etag = "changed-\(run)"
            let changedResource = DAVSyncScenario.prop("/one/\(index).ics", "<d:getetag>\(etag)</d:getetag>")
            let changedBody = DAVSyncScenario.tasks(count: 1, startIndex: index)
                .replacingOccurrences(of: "<d:getetag>e\(index)</d:getetag>", with: "<d:getetag>\(etag)</d:getetag>")
                .replacingOccurrences(of: "Moon bakery delivery \(index)", with: "Changed delivery \(run)")
            let changedToken = "changed-token-\(run)"
            _ = ScriptedDAVProtocol.install(host: host, responses: measurementDiscovery()
                + [.init(body: DAVSyncScenario.multistatus(changedResource + "<d:sync-token>\(changedToken)</d:sync-token>")),
                   .init(body: changedBody)])
            let deltaReads = PerformanceTrace.OperationRecorder()
            let deltaStart = ContinuousClock.now
            let delta = await PerformanceTrace.$operationRecorder.withValue(deltaReads) {
                await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: credentials, modelContainer: container, reconcileNotifications: false)
            }
            deltaTimes.append(Self.milliseconds(since: deltaStart))
            var deltaCheckpoint = try #require(try SyncImportCheckpoint.read(
                id: key, scope: scope, in: ModelContext(container)))
            #expect(deltaCheckpoint.token == changedToken)
            #expect(deltaCheckpoint.lastIntegrity == initialCheckpoint.lastIntegrity)
            Self.expectSyncReads(deltaReads, count: count, changed: true, ctagOnly: false, run: run)
            #expect(delta.status == .completed)
            #expect(delta.updatedCount == 1 && delta.importedCount == 0 && delta.deletedCount == 0)
            let deltaRequests = ScriptedDAVProtocol.requests(host: host)
            #expect(deltaRequests.count == 5)
            #expect(deltaRequests.filter { String(decoding: $0.body, as: UTF8.self).contains("calendar-multiget") }.count == 1)

            // Exercise an authoritative scoped CTag skip with no token to clear.
            deltaCheckpoint.token = nil
            try SyncImportCheckpoint.commit(deltaCheckpoint, id: key, collectionPath: "/one/", container: container)
            _ = ScriptedDAVProtocol.install(host: host, responses: DAVSyncScenario.discovery(paths: ["/one/"]))
            let ctagReads = PerformanceTrace.OperationRecorder()
            let ctagStart = ContinuousClock.now
            let ctag = await PerformanceTrace.$operationRecorder.withValue(ctagReads) {
                await engine.performFullSyncOutcome(accountID: accountID, serverBaseURL: "https://" + host,
                    credentials: credentials, modelContainer: container, reconcileNotifications: false)
            }
            ctagTimes.append(Self.milliseconds(since: ctagStart))
            #expect(ctag.status == .completed && ctag.changedListIDs.isEmpty && ctag.pendingOutboundCount == 0)
            #expect(ScriptedDAVProtocol.requests(host: host).map(\.method) == ["PROPFIND", "PROPFIND", "PROPFIND"])
            #expect(try SyncImportCheckpoint.read(id: key, scope: scope, in: ModelContext(container)) == deltaCheckpoint)
            Self.expectSyncReads(ctagReads, count: count, changed: false, ctagOnly: true, run: run)
            deltaCheckpoint.token = changedToken
            try SyncImportCheckpoint.commit(deltaCheckpoint, id: key, collectionPath: "/one/", container: container)

            // Replay the production liveness + compact projection + day lookup
            // pipeline 20 times on main. This does not drive SwiftUI invalidation.
            var renderedRows = 0
            let calendarStart = ContinuousClock.now
            for selection in 0..<20 {
                let live = TaskListHelpers.liveTasks(tasks, in: context, matching: calendarDescriptor)
                let projection = CalendarTaskProjection(rows: live.glanceRows(), now: PerformanceFixture.calendarWeekStart)
                let selectedDate = PerformanceFixture.calendarWeekStart.addingTimeInterval(Double(selection % 7) * 86_400)
                renderedRows += projection.bucket(on: selectedDate).rows.count
            }
            calendarTimes.append(Self.milliseconds(since: calendarStart))
            #expect(renderedRows > 0)
            // Isolated replay of the full-inventory preparation in pullCalendar.
            // Fetch counts below describe this replay, not all engine fetches.
            let inventoryListID = list.id
            let inventoryStart = ContinuousClock.now
            let inventory = try await Task.detached { () throws -> (Int, Int) in
                let read = ModelContext(container)
                let id = inventoryListID
                let local = try read.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.taskList?.id == id }))
                var known = try SyncImportCheckpoint.accountedETags(id: key, container: container)
                for task in local {
                    if let href = task.remoteHref {
                        if task.etag == nil { known.removeValue(forKey: href) }
                        else if let etag = task.etag, !task.isDirty || known[href] == nil { known[href] = etag }
                    }
                }
                return (local.count, known.count)
            }.value
            inventoryTimes.append(Self.milliseconds(since: inventoryStart))
            #expect(inventory.0 == count && inventory.1 == count)
            print("BACKLOG_INVENTORY_REPLAY tasks=\(count) run=\(run + 1) fetchedTaskRows=\(inventory.0) knownETags=\(inventory.1) seededReceiptRows=\(count)")
            print("BACKLOG_COUNTS tasks=\(count) run=\(run + 1) noOpRequests=\(noOpRequests.count) deltaRequests=\(deltaRequests.count) replayLivenessCalls=20 replayProjectionCalls=20 bucketRowsConsumed=\(renderedRows)")
        }
        Self.report("engine-valid-token-no-op", count: count, samples: noOpTimes)
        Self.report("engine-one-delta", count: count, samples: deltaTimes)
        Self.report("engine-scoped-ctag-no-op", count: count, samples: ctagTimes)
        Self.report("calendar-20-main-component-replays", count: count, samples: calendarTimes)
        Self.report("off-main-local-inventory-replay", count: count, samples: inventoryTimes)
        withExtendedLifetime(container) {}
    }

    private static func expectSyncReads(_ recorder: PerformanceTrace.OperationRecorder, count: Int,
                                        changed: Bool, ctagOnly: Bool, run: Int) {
        let optimized = ProcessInfo.processInfo.environment["NOWTHIS_T18_EXPECT_OPTIMIZED"] == "1"
        let taskInventory = recorder.count(.matchingTaskInventory)
        let receiptInventory = recorder.count(.receiptInventory)
        let shapeTasks = recorder.count(.shapeTasks)
        let shapes = recorder.count(.genericShapeRecords)
        let captures = recorder.count(.retainedShapeCaptures)
        let matchingTask = recorder.count(.matchingTaskLookup)
        let matchingReceipt = recorder.count(.matchingReceiptLookup)
        let receiptWrite = recorder.count(.receiptWriteLookup)
        let prune = recorder.count(.otherScopePrune)
        let checkpointRead = recorder.count(.checkpointRead)
        let checkpointCommit = recorder.count(.checkpointCommit)
        let hierarchy = recorder.count(.hierarchyScan)
        let deletion = recorder.count(.deletionScan)
        let outbound = recorder.count(.pendingOutbound)
        let workload = ctagOnly ? "ctag" : (changed ? "delta" : "empty")
        let sample = [
            "inventoryTasks=\(taskInventory.calls)/\(taskInventory.rows)",
            "inventoryReceipts=\(receiptInventory.calls)/\(receiptInventory.rows)",
            "shapeTasks=\(shapeTasks.calls)/\(shapeTasks.rows)",
            "shapes=\(shapes.calls)/\(shapes.rows)/\(shapes.maxKeys)",
            "captures=\(captures.calls)/\(captures.rows)",
            "matchTasks=\(matchingTask.calls)/\(matchingTask.rows)/\(matchingTask.maxKeys)",
            "matchReceipts=\(matchingReceipt.calls)/\(matchingReceipt.rows)/\(matchingReceipt.maxKeys)",
            "receiptWrite=\(receiptWrite.calls)/\(receiptWrite.rows)",
            "prune=\(prune.calls)/\(prune.rows)",
            "checkpointRead=\(checkpointRead.calls)/\(checkpointRead.rows)",
            "checkpointCommit=\(checkpointCommit.calls)/\(checkpointCommit.rows)",
            "hierarchy=\(hierarchy.calls)/\(hierarchy.rows)",
            "deletion=\(deletion.calls)/\(deletion.rows)",
            "pendingOutbound=\(outbound.calls)/\(outbound.rows)"
        ].joined(separator: " ")
        print("T18_SYNC_READS workload=\(workload) tasks=\(count) run=\(run + 1) \(sample)")

        let fullInventoryReads = !optimized && !ctagOnly ? 1 : 0
        let shapeScans = !optimized && !ctagOnly ? 2 : 1
        let targeted = optimized && changed ? 1 : 0
        #expect(taskInventory.calls == fullInventoryReads && taskInventory.rows == fullInventoryReads * count)
        #expect(receiptInventory.calls == fullInventoryReads && receiptInventory.rows == fullInventoryReads * count)
        #expect(shapeTasks.calls == shapeScans && shapeTasks.rows == shapeScans * count)
        #expect(shapes.calls == shapeScans * ((count + 99) / 100) && shapes.rows == shapeScans * count)
        #expect(shapes.maxKeys <= 100 && captures.calls == 0)
        #expect(matchingTask.calls == targeted && matchingTask.rows == targeted && matchingTask.maxKeys == targeted)
        #expect(matchingReceipt.calls == targeted && matchingReceipt.rows == targeted && matchingReceipt.maxKeys == targeted)
        #expect(receiptWrite.calls == (changed ? 1 : 0))
        #expect(checkpointCommit.calls == (ctagOnly ? 0 : 1))
        #expect(prune.rows == 0 && hierarchy.calls == 0 && deletion.calls == 0 && outbound.rows == 0)
    }

    private func measurementDiscovery() -> [ScriptedDAVProtocol.Response] {
        var responses = DAVSyncScenario.discovery(paths: ["/one/"])
        let capability = "<d:sync-token>baseline-token</d:sync-token><d:supported-report-set>"
            + "<d:supported-report><d:report><d:sync-collection/></d:report></d:supported-report></d:supported-report-set>"
        responses[2].body = responses[2].body.replacingOccurrences(of: "</d:prop>", with: capability + "</d:prop>")
        return responses
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func report(_ name: String, count: Int, samples: [Double]) {
        let sorted = samples.sorted()
        print("BACKLOG_METRIC name=\(name) tasks=\(count) samples_ms=\(samples) median_ms=\(sorted[sorted.count / 2]) min_ms=\(sorted.first!) max_ms=\(sorted.last!)")
    }

}
