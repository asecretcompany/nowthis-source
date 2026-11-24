import EventKit
import SwiftData

/// Only objects created and durably recorded by this local mirror may be changed.
/// Explicit exports keep their separate legacy link on TaskItem.
@MainActor
final class AppleCalendarSyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var lastError: String?
    private let store: any AppleCalendarStore
    private let makeJournal: (ModelContainer) -> AppleCalendarOwnershipJournal

    init(permissionManager: CalendarPermissionManager) {
        // Never batch writes into the store used by the system event editor.
        store = EventKitCalendarStore()
        makeJournal = { AppleCalendarOwnershipJournal(container: $0) }
    }

    init(store: any AppleCalendarStore,
         makeJournal: @escaping (ModelContainer) -> AppleCalendarOwnershipJournal = { AppleCalendarOwnershipJournal(container: $0) }) {
        self.store = store
        self.makeJournal = makeJournal
    }

    func managedTaskIDs(container: ModelContainer) throws -> Set<String> {
        let journal = makeJournal(container)
        guard try journal.hasOwnershipEvidence() else { return [] }
        return Set(try journal.taskIDs())
    }

    @discardableResult
    func reconcileManaged(container: ModelContainer, taskIDs: Set<String>? = nil,
                          isEnabled: @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: "appleCalendarSyncEnabled") }) throws -> Bool {
        guard isEnabled(), !container.mainContext.hasChanges else { return false }
        guard store.hasAccess else { throw CalendarSyncError.noAccess }
        defer { store.reset() }
        let journal = makeJournal(container)
        let ids = try journal.taskIDs()
        var changed = false
        var held = false
        for id in ids where taskIDs?.contains(id) != false {
            try Task.checkCancellation()
            guard isEnabled(), !container.mainContext.hasChanges else { throw CalendarSyncError.linkUncertain }
            do {
                guard let link = try journal.loadLink(taskID: id), let identity = link.taskIdentity else {
                    throw CalendarSyncError.linkUncertain
                }
                let context = ModelContext(container)
                context.autosaveEnabled = false
                if let task = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first {
                    guard CalendarMirrorState.Identity(task) == identity else { throw CalendarSyncError.linkUncertain }
                    changed = try syncTask(task, journal: journal, requireFrozenProof: true) || changed
                } else {
                    guard try CalendarMirrorState.purge(for: identity, in: context) != nil else { throw CalendarSyncError.linkUncertain }
                    changed = try removeLink(id, journal: journal, requireFrozenProof: true) || changed
                }
            } catch CalendarSyncError.linkUncertain {
                store.reset()
                held = true
            } catch is CalendarMirrorState.Held {
                store.reset()
                held = true
            }
        }
        if held { throw CalendarSyncError.linkUncertain }
        return changed
    }

    @discardableResult
    func syncAll(modelContext: ModelContext) async -> Bool {
        guard store.hasAccess else { lastError = CalendarSyncError.noAccess.localizedDescription; return false }
        guard !modelContext.container.mainContext.hasChanges else { return false }
        isSyncing = true
        lastError = nil
        var acknowledged = false
        defer { isSyncing = false; store.reset() }
        do {
            let context = ModelContext(modelContext.container)
            context.autosaveEnabled = false
            let tasks = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { !$0.isDeletedLocally }))
            let journal = makeJournal(context.container)
            _ = try journal.loadDestination()
            let linkedIDs = try journal.taskIDs()
            for task in tasks {
                do { acknowledged = try syncTask(task, journal: journal) || acknowledged }
                catch CalendarSyncError.linkUncertain {
                    store.reset()
                    lastError = CalendarSyncError.linkUncertain.localizedDescription
                }
            }
            let ids = Set(tasks.map(\.id))
            for id in linkedIDs where !ids.contains(id) {
                do { acknowledged = try removeLink(id, journal: journal) || acknowledged }
                catch CalendarSyncError.linkUncertain {
                    store.reset()
                    lastError = CalendarSyncError.linkUncertain.localizedDescription
                }
            }
        } catch { lastError = error.localizedDescription }
        return acknowledged
    }

    @discardableResult
    func syncSingleTask(_ task: TaskItem, to calendarIdentifier: String? = nil) throws -> Bool {
        guard store.hasAccess else { throw CalendarSyncError.noAccess }
        guard let container = task.modelContext?.container, !container.mainContext.hasChanges else { return false }
        defer { store.reset() }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = task.id
        guard let committed = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })).first else { return false }
        let journal = makeJournal(container)
        if let calendarIdentifier, try journal.loadDestination()?.binding?.id != calendarIdentifier {
            throw CalendarSyncError.ownershipUncertain
        }
        return try syncTask(committed, journal: journal)
    }

    private func destination(journal: AppleCalendarOwnershipJournal) throws -> AppleCalendarOwnership.Destination {
        guard store.hasAccess else { throw CalendarSyncError.noAccess }
        if var destination = try journal.loadDestination() {
            try verifyDestination(destination)
            if !destination.acknowledged {
                destination.acknowledged = true
                try journal.persistDestination(&destination)
            }
            return destination
        }
        var destination = AppleCalendarOwnership.Destination(scope: try journal.scope(), eventStoreID: store.storeIdentifier)
        try journal.persistDestination(&destination)
        let staged = try store.stageCalendar()
        guard AppleCalendarOwnership.validBinding(staged.binding) else { throw CalendarSyncError.ownershipUncertain }
        destination.binding = staged.binding
        try journal.persistDestination(&destination)
        let receipt = try store.commitCalendar()
        guard AppleCalendarOwnership.validBinding(receipt.binding), receipt.binding.sourceID == staged.binding.sourceID,
              receipt.binding.sourceType == staged.binding.sourceType else { throw CalendarSyncError.ownershipUncertain }
        destination.binding = receipt.binding
        destination.acknowledged = true
        try journal.persistDestination(&destination)
        return destination
    }

    private func verifyDestination(_ destination: AppleCalendarOwnership.Destination) throws {
        guard store.hasAccess else { throw CalendarSyncError.noAccess }
        guard destination.eventStoreID == store.storeIdentifier,
              let binding = destination.binding, store.calendar(binding) != nil else { throw CalendarSyncError.ownershipUncertain }
    }

    /// Permission, destination and journal errors stop their scope. An unresolved
    /// event holds only its link; the next item reloads independent committed rows.
    private func eventOperation<T>(destination: AppleCalendarOwnership.Destination,
                                   _ operation: () throws -> T) throws -> T {
        try verifyDestination(destination)
        do { return try operation() }
        catch {
            try verifyDestination(destination)
            throw CalendarSyncError.linkUncertain
        }
    }

    private func syncTask(_ task: TaskItem, journal: AppleCalendarOwnershipJournal,
                          requireFrozenProof: Bool = false) throws -> Bool {
        // Validate an existing link before any destination promotion or EventKit write.
        let stored = try journal.loadLink(taskID: task.id)
        if let stored, let source = stored.taskIdentity, source != CalendarMirrorState.Identity(task) {
            throw CalendarSyncError.linkUncertain
        }
        if task.dueDate == nil || task.isDeletedLocally {
            return try removeLink(task.id, journal: journal, requireFrozenProof: requireFrozenProof)
        }
        let target = try destination(journal: journal)
        guard let binding = target.binding, let due = task.dueDate else { throw CalendarSyncError.ownershipUncertain }
        let start = task.startDate ?? due
        let content = AppleEventContent(title: task.status == .completed ? "✓ \(task.title)" : task.title,
            start: start, end: Calendar.current.date(byAdding: .minute, value: 30, to: start) ?? start,
            notes: task.descriptionText, location: task.locationName, url: task.url.flatMap(URL.init(string:)))
        let requested = try content.ownershipFingerprint()
        if var link = stored {
            guard let recorded = link.event, let existing = store.event(recorded) else { throw CalendarSyncError.linkUncertain }
            if link.pending?.action == .remove {
                return try removeLink(task.id, journal: journal, requireFrozenProof: requireFrozenProof)
            }
            var changed = false
            let actual = try existing.content.ownershipFingerprint()
            if link.pending?.action == .create || link.pending?.action == .update {
                if link.pending?.expectedFingerprint == actual {
                    link.event = existing.identity
                    link.pending = nil
                    try journal.persistLink(&link)
                    changed = true
                } else if requireFrozenProof {
                    throw CalendarSyncError.linkUncertain
                }
            }
            if link.pending == nil && actual == requested { return changed }
            if link.pending == nil {
                link.pending = .init(action: .update, fingerprint: requested)
            } else {
                // Retain the original operation and requested version until a retry
                // proves the latest committed task fields. No identity-only ack.
                link.pending?.retryFingerprint = requested
            }
            try journal.persistLink(&link)
            let staged = try eventOperation(destination: target) { try store.stageUpdate(existing, content: content) }
            guard staged.identity == existing.identity, !staged.recurring,
                  try staged.content.ownershipFingerprint() == requested else { throw CalendarSyncError.linkUncertain }
            let receipt = try eventOperation(destination: target) { try store.commitEvent() }
            guard receipt.identity == existing.identity, !receipt.recurring,
                  try receipt.content.ownershipFingerprint() == requested else { throw CalendarSyncError.linkUncertain }
            link.event = receipt.identity
            link.pending = nil
            try journal.persistLink(&link)
            return true
        }
        var link = AppleCalendarOwnership.Link(scope: target.scope, taskID: task.id,
            taskIdentity: CalendarMirrorState.Identity(task), destinationGeneration: target.generation, pending: .init(action: .create, fingerprint: requested))
        try journal.persistLink(&link)
        let staged = try eventOperation(destination: target) { try store.stageEvent(calendar: binding, content: content) }
        guard !staged.itemID.isEmpty, staged.calendar == binding, !staged.recurring,
              try staged.content.ownershipFingerprint() == requested else { throw CalendarSyncError.linkUncertain }
        link.event = staged.identity
        try journal.persistLink(&link)
        let receipt = try eventOperation(destination: target) { try store.commitEvent() }
        guard !receipt.itemID.isEmpty, receipt.calendar == binding, !receipt.recurring,
              try receipt.content.ownershipFingerprint() == requested else { throw CalendarSyncError.linkUncertain }
        link.event = receipt.identity
        link.pending = nil
        try journal.persistLink(&link)
        return true
    }

    private func removeLink(_ id: String, journal: AppleCalendarOwnershipJournal,
                            requireFrozenProof: Bool = false) throws -> Bool {
        guard var link = try journal.loadLink(taskID: id) else { return false }
        let target = try destination(journal: journal)
        guard let recorded = link.event, let existing = store.event(recorded) else { throw CalendarSyncError.linkUncertain }
        if let pending = link.pending, pending.action != .remove {
            let matches = pending.expectedFingerprint.map { expected in
                (try? existing.content.ownershipFingerprint()) == expected
            } ?? false
            if requireFrozenProof && !matches { throw CalendarSyncError.linkUncertain }
        }
        if link.pending?.action != .remove {
            link.pending = .init(action: .remove)
            try journal.persistLink(&link)
        }
        try eventOperation(destination: target) { try store.stageRemoval(existing) }
        try eventOperation(destination: target) { try store.commitRemoval() }
        try journal.removeLink(link)
        return true
    }
}

// MARK: - Errors

enum CalendarSyncError: LocalizedError {
    case noAccess
    case noCalendarSource
    case ownershipUncertain
    case linkUncertain

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return String(
                localized: "calendarSync.error.noAccess",
                defaultValue: "Calendar access not granted. Please enable in Settings.",
                comment: "Apple Calendar sync error. \"Settings\" is the iOS system app.")
        case .ownershipUncertain, .linkUncertain:
            return String(localized: "calendarSync.error.ownershipUncertain",
                defaultValue: "Calendar sync paused because ownership could not be verified.",
                comment: "Apple Calendar mirror safety error: local ownership is missing or uncertain; existing events are preserved.")
        case .noCalendarSource:
            return String(
                localized: "calendarSync.error.noSource",
                defaultValue: "No calendar source available on this device.",
                comment: "Apple Calendar sync error: EventKit reported no account (iCloud, Exchange, local) that a new calendar could be created in.")
        }
    }
}
