#if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
import EventKit
import SwiftData
import SwiftUI

/// Opt-in, local-source-only runtime evidence. Never part of a shipping build.
@MainActor
final class AppleCalendarProbe: ObservableObject {
    @Published var status = "Calendar probe ready"
    private let container: ModelContainer
    private let scheduler: SyncScheduler
    private let run: String
    private let file: URL
    private var evidence: Evidence

    struct Observation: Codable {
        var phase: String
        var date = Date()
        var authorization: Int
        var storeID: String
        var calendar: AppleCalendarBinding?
        var event: AppleEventValue?
        var freshCalendarFound: Bool?
        var freshEventIDFound: Bool?
        var freshItemIDFound: Bool?
        var note: String?
    }
    struct Evidence: Codable {
        var run: String
        var baselineCalendarIDs: [String]
        var mirrorCreationProcessID: Int32?
        var createdCalendar: AppleCalendarBinding?
        var dueClearEvent: AppleEventValue?
        var deleteAfterRelaunchEvent: AppleEventValue?
        var manualEvent: AppleEventValue?
        var observations: [Observation] = []
    }

    init(container: ModelContainer, run: String, scheduler: SyncScheduler) {
        self.container = container
        self.scheduler = scheduler
        self.run = run
        file = container.configurations.first!.url.deletingLastPathComponent().appendingPathComponent("calendar-probe.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Evidence.self, from: data), saved.run == run {
            evidence = saved
        } else {
            evidence = Evidence(run: run, baselineCalendarIDs: [])
        }
    }

    func permission() async {
        do {
            let granted = try await EKEventStore().requestFullAccessToEvents()
            record("permission", note: "granted=\(granted); localSources=\(EKEventStore().sources.filter { $0.sourceType == .local }.count)")
            status = granted ? "Full access ready" : "Calendar access unavailable"
        } catch { failure(error) }
    }

    private func manager() -> AppleCalendarSyncManager {
        let adapter = EventKitCalendarStore(localSourceOnly: true)
        adapter.trace = { [weak self] phase, calendar, event in
            self?.record(phase.rawValue, calendar: calendar?.binding, event: event)
            if phase == .calendarCommitted, let calendar {
                self?.evidence.createdCalendar = calendar.binding
                self?.persist()
            }
        }
        return AppleCalendarSyncManager(store: adapter, makeJournal: { [run] in
            AppleCalendarOwnershipJournal(container: $0, selector: "calendar-probe/" + run)
        })
    }

    func createMirrors() {
        do {
            let reader = EKEventStore()
            defer { withExtendedLifetime(reader) {} }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                  reader.sources.contains(where: { $0.sourceType == .local }) else {
                record("blocked", note: "No full access or no local source; no account fallback.")
                status = "Blocked: full access and local source required"
                return
            }
            if evidence.createdCalendar == nil {
                evidence.baselineCalendarIDs = reader.calendars(for: .event).map(\.calendarIdentifier)
                persist()
            }
            let first = try task(0)
            let second = try task(1)
            let firstAcknowledged = try manager().syncSingleTask(first)
            let secondAcknowledged = try manager().syncSingleTask(second)
            evidence.mirrorCreationProcessID = ProcessInfo.processInfo.processIdentifier
            let journal = AppleCalendarOwnershipJournal(container: container, selector: "calendar-probe/" + run)
            let state = try journal.load()
            if let identity = state.links[first.id]?.event { evidence.dueClearEvent = EventKitCalendarStore(store: reader).event(identity) }
            if let identity = state.links[second.id]?.event { evidence.deleteAfterRelaunchEvent = EventKitCalendarStore(store: reader).event(identity) }
            let renamer = EKEventStore()
            if let binding = evidence.createdCalendar,
               let calendar = renamer.calendar(withIdentifier: binding.id),
               EventKitCalendarStore.value(calendar)?.binding == binding {
                calendar.title = "NowThis probe " + run
                try renamer.saveCalendar(calendar, commit: true)
            }
            record("two-mirrors-created", calendar: evidence.createdCalendar, event: evidence.dueClearEvent,
                   note: "task00000Acknowledged=\(firstAcknowledged); task00001Acknowledged=\(secondAcknowledged); bothManagedLinks=\(evidence.dueClearEvent != nil && evidence.deleteAfterRelaunchEvent != nil)")
            status = "Two managed mirrors ready. Export task 00001 manually, then capture it."
        } catch { failure(error) }
    }

    func captureManual() {
        do {
            let task = try task(1)
            let reader = EKEventStore()
            defer { withExtendedLifetime(reader) {} }
            guard let id = task.calendarEventID,
                  let event = reader.event(withIdentifier: id),
                  EventKitCalendarStore.value(event)?.calendar == evidence.createdCalendar else {
                status = "Save task 00001 through Add to Calendar first"
                return
            }
            evidence.manualEvent = EventKitCalendarStore.value(event)
            record("manual-captured", event: evidence.manualEvent)
            status = "Manual export captured alongside task 00001's managed mirror"
        } catch { failure(error) }
    }

    func clearOwnedDue() async {
        do {
            guard let owned = evidence.dueClearEvent, let manual = evidence.manualEvent else { return }
            let dueTask = try task(0)
            dueTask.dueDate = nil
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
            await scheduler.reconcileCalendarMirrors()
            let reader = EKEventStore()
            defer { withExtendedLifetime(reader) {} }
            let ownedGone = reader.event(withIdentifier: owned.id) == nil && reader.calendarItem(withIdentifier: owned.itemID) == nil
            let mirrorLinks = try AppleCalendarOwnershipJournal(container: container, selector: "calendar-probe/" + run).load().links
            let current = reader.event(withIdentifier: manual.id).flatMap(EventKitCalendarStore.value)
            let manualTask = try task(1)
            let manualMatches = current == manual && manualTask.calendarEventID == manual.id
            let linkRemoved = mirrorLinks[dueTask.id] == nil
            record("managed-after-committed-due-clear", event: owned,
                   note: "ownedAbsent=\(ownedGone); managedLinkRemoved=\(linkRemoved); manualUnchanged=\(manualMatches)")
            status = ownedGone && linkRemoved && manualMatches ? "Due-cleared mirror removed; manual export retained" : "FAIL: due-clear result"
        } catch { failure(error) }
    }

    func deleteOwnedAfterRelaunch() async {
        do {
            guard let owned = evidence.deleteAfterRelaunchEvent, let manual = evidence.manualEvent else { return }
            guard let creationProcessID = evidence.mirrorCreationProcessID,
                  creationProcessID != ProcessInfo.processInfo.processIdentifier else {
                record("blocked", note: "Relaunch this fixture run before deleting task 00001.")
                status = "Relaunch the app before deleting task 00001"
                return
            }
            let task = try task(1)
            let deletedTaskID = task.id
            container.mainContext.delete(task)
            try ReminderSchedulingJournal.saveTaskChanges(in: container.mainContext)
            await scheduler.reconcileCalendarMirrors()
            let reader = EKEventStore()
            defer { withExtendedLifetime(reader) {} }
            let ownedGone = reader.event(withIdentifier: owned.id) == nil && reader.calendarItem(withIdentifier: owned.itemID) == nil
            let manualNow = reader.event(withIdentifier: manual.id).flatMap(EventKitCalendarStore.value)
            let links = try AppleCalendarOwnershipJournal(container: container, selector: "calendar-probe/" + run).load().links
            record("managed-after-delete-following-relaunch", event: owned,
                   note: "ownedAbsent=\(ownedGone); managedLinkRemoved=\(links[deletedTaskID] == nil); manualUnchanged=\(manualNow == manual)")
            status = ownedGone && links[deletedTaskID] == nil && manualNow == manual ? "Deleted mirror removed; manual export retained" : "FAIL: post-relaunch deletion result"
        } catch { failure(error) }
    }

    func cleanup() {
        do {
            let reader = EKEventStore()
            defer { withExtendedLifetime(reader) {} }
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                  let receipt = evidence.createdCalendar,
                  !evidence.baselineCalendarIDs.contains(receipt.id),
                  receipt.sourceType == EKSourceType.local.rawValue,
                  let calendar = reader.calendar(withIdentifier: receipt.id),
                  EventKitCalendarStore.value(calendar)?.binding == receipt else {
                record("cleanup-held", note: "No unambiguous creation receipt.")
                status = "Cleanup held"
                return
            }
            try reader.removeCalendar(calendar, commit: true)
            let absent = EKEventStore().calendar(withIdentifier: receipt.id) == nil
            record("cleanup", calendar: receipt, note: "absent=\(absent)")
            status = absent ? "Probe calendar removed" : "Cleanup unresolved"
        } catch { failure(error) }
    }

    private func task(_ index: Int) throws -> TaskItem {
        let id = String(format: "performance-fixture-task-%08d", index)
        guard let task = try container.mainContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first else {
            throw CalendarSyncError.ownershipUncertain
        }
        return task
    }

    private func record(_ phase: String, calendar: AppleCalendarBinding? = nil, event: AppleEventValue? = nil, note: String? = nil) {
        let fresh = EKEventStore()
        evidence.observations.append(Observation(phase: phase,
            authorization: EKEventStore.authorizationStatus(for: .event).rawValue,
            storeID: fresh.eventStoreIdentifier, calendar: calendar, event: event,
            freshCalendarFound: calendar.map { fresh.calendar(withIdentifier: $0.id) != nil },
            freshEventIDFound: event.map { !$0.id.isEmpty && fresh.event(withIdentifier: $0.id) != nil },
            freshItemIDFound: event.map { !$0.itemID.isEmpty && fresh.calendarItem(withIdentifier: $0.itemID) != nil }, note: note))
        persist()
    }
    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: file, options: .atomic)
        } catch { status = "Probe trace write failed" }
    }
    private func failure(_ error: Error) {
        let value = error as NSError
        record("error", note: "\(value.domain):\(value.code): \(value.localizedDescription)")
        status = error.localizedDescription
    }
}

struct AppleCalendarProbePanel: View {
    @StateObject private var probe: AppleCalendarProbe
    private let scheduler: SyncScheduler
    @State private var expanded = false
    init(container: ModelContainer, run: String, scheduler: SyncScheduler) {
        self.scheduler = scheduler
        _probe = StateObject(wrappedValue: AppleCalendarProbe(container: container, run: run, scheduler: scheduler))
    }
    var body: some View {
        VStack(spacing: 6) {
            Button { expanded.toggle() } label: { Text(verbatim: expanded ? "Hide calendar probe" : "Calendar probe") }
            if expanded {
                Text(verbatim: probe.status).font(.caption)
                HStack {
                    Button { Task { await probe.permission() } } label: { Text(verbatim: "Permission") }
                    Button { probe.createMirrors() } label: { Text(verbatim: "Create two mirrors") }
                    Button { probe.captureManual() } label: { Text(verbatim: "Capture export") }
                }
                HStack {
                    Button { Task { await probe.clearOwnedDue() } } label: { Text(verbatim: "Clear owned due") }
                    Button { Task { await probe.deleteOwnedAfterRelaunch() } } label: { Text(verbatim: "Delete after relaunch") }
                    Button { probe.cleanup() } label: { Text(verbatim: "Cleanup") }
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
#endif
