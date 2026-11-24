import EventKit

struct AppleCalendarBinding: Codable, Equatable {
    var id: String
    var sourceID: String
    var sourceType: Int
}

struct AppleCalendarValue: Equatable {
    var binding: AppleCalendarBinding
    var title: String
}

struct AppleEventContent: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var notes: String?
    var location: String?
    var url: URL?
}

struct AppleEventIdentity: Codable, Equatable {
    var id: String
    var itemID: String
    var calendar: AppleCalendarBinding
}

struct AppleEventValue: Codable, Equatable {
    var id: String
    var itemID: String
    var externalID: String?
    var calendar: AppleCalendarBinding
    var recurring: Bool
    var content: AppleEventContent
    var identity: AppleEventIdentity { .init(id: id, itemID: itemID, calendar: calendar) }
}

/// Dedicated serialized writer: staging never commits another caller's work.
@MainActor
protocol AppleCalendarStore: AnyObject {
    var hasAccess: Bool { get }
    var storeIdentifier: String { get }
    func calendar(_ binding: AppleCalendarBinding) -> AppleCalendarValue?
    func event(_ identity: AppleEventIdentity) -> AppleEventValue?
    func stageCalendar() throws -> AppleCalendarValue
    func commitCalendar() throws -> AppleCalendarValue
    func stageEvent(calendar: AppleCalendarBinding, content: AppleEventContent) throws -> AppleEventValue
    func stageUpdate(_ identity: AppleEventValue, content: AppleEventContent) throws -> AppleEventValue
    func commitEvent() throws -> AppleEventValue
    func stageRemoval(_ identity: AppleEventValue) throws
    func commitRemoval() throws
    func reset()
}

@MainActor
final class EventKitCalendarStore: AppleCalendarStore {
    private let store: EKEventStore
    private var stagedCalendar: EKCalendar?
    private var stagedEvent: EKEvent?
    private let localSourceOnly: Bool
    enum TracePhase: String {
        case calendarBeforeStage, calendarStaged, calendarCommitted
        case eventBeforeStage, eventStaged, eventCommitted
    }
    /// Fixture-only observations do not influence ownership decisions.
    var trace: ((TracePhase, AppleCalendarValue?, AppleEventValue?) -> Void)?

    init(store: EKEventStore = EKEventStore(), localSourceOnly: Bool = false) {
        self.store = store
        self.localSourceOnly = localSourceOnly
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var storeIdentifier: String { store.eventStoreIdentifier }

    func calendar(_ binding: AppleCalendarBinding) -> AppleCalendarValue? {
        guard hasAccess, let calendar = store.calendar(withIdentifier: binding.id),
              calendar.allowsContentModifications, Self.value(calendar)?.binding == binding else { return nil }
        return Self.value(calendar)
    }

    func event(_ identity: AppleEventIdentity) -> AppleEventValue? {
        resolvedEvent(identity).flatMap(Self.value)
    }

    private func resolvedEvent(_ identity: AppleEventIdentity) -> EKEvent? {
        guard hasAccess, calendar(identity.calendar) != nil,
              let event = store.calendarItem(withIdentifier: identity.itemID) as? EKEvent else { return nil }
        guard let value = Self.value(event) else { return nil }
        guard value.itemID == identity.itemID, value.calendar == identity.calendar, !value.recurring,
              identity.id.isEmpty || value.id == identity.id else { return nil }
        return event
    }

    func stageCalendar() throws -> AppleCalendarValue {
        guard hasAccess else { throw CalendarSyncError.noAccess }
        reset()
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "NowThis"
        calendar.cgColor = CGColor(red: 0.55, green: 0.35, blue: 0.85, alpha: 1)
        let source = localSourceOnly ? store.sources.first(where: { $0.sourceType == .local })
            : store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) ?? store.sources.first
        guard let source else { throw CalendarSyncError.noCalendarSource }
        calendar.source = source
        trace?(.calendarBeforeStage, Self.value(calendar), nil)
        try store.saveCalendar(calendar, commit: false)
        stagedCalendar = calendar
        guard let value = Self.value(calendar) else { throw CalendarSyncError.ownershipUncertain }
        trace?(.calendarStaged, value, nil)
        return value
    }

    func commitCalendar() throws -> AppleCalendarValue {
        guard hasAccess, let calendar = stagedCalendar else { throw CalendarSyncError.ownershipUncertain }
        try store.commit()
        guard let value = Self.value(calendar) else { throw CalendarSyncError.ownershipUncertain }
        trace?(.calendarCommitted, value, nil)
        stagedCalendar = nil
        return value
    }

    func stageEvent(calendar: AppleCalendarBinding, content: AppleEventContent) throws -> AppleEventValue {
        guard self.calendar(calendar) != nil,
              let target = store.calendar(withIdentifier: calendar.id) else { throw CalendarSyncError.ownershipUncertain }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        Self.apply(content, to: event)
        trace?(.eventBeforeStage, nil, Self.value(event))
        try store.save(event, span: .thisEvent, commit: false)
        stagedEvent = event
        guard let value = Self.value(event) else { throw CalendarSyncError.ownershipUncertain }
        trace?(.eventStaged, nil, value)
        return value
    }

    func stageUpdate(_ identity: AppleEventValue, content: AppleEventContent) throws -> AppleEventValue {
        guard let event = resolvedEvent(identity.identity) else {
            throw CalendarSyncError.ownershipUncertain
        }
        // User URLs are not mirror-owned fields, even on a positively owned event.
        let url = event.url
        Self.apply(content, to: event)
        event.url = url
        try store.save(event, span: .thisEvent, commit: false)
        stagedEvent = event
        guard let value = Self.value(event) else { throw CalendarSyncError.ownershipUncertain }
        return value
    }

    func commitEvent() throws -> AppleEventValue {
        guard hasAccess, let event = stagedEvent else { throw CalendarSyncError.ownershipUncertain }
        try store.commit()
        guard let value = Self.value(event) else { throw CalendarSyncError.ownershipUncertain }
        trace?(.eventCommitted, nil, value)
        stagedEvent = nil
        return value
    }

    func stageRemoval(_ identity: AppleEventValue) throws {
        guard let event = resolvedEvent(identity.identity) else {
            throw CalendarSyncError.ownershipUncertain
        }
        try store.remove(event, span: .thisEvent, commit: false)
    }

    func commitRemoval() throws {
        guard hasAccess else { throw CalendarSyncError.noAccess }
        try store.commit()
    }

    func reset() {
        store.reset()
        stagedCalendar = nil
        stagedEvent = nil
    }

    static func value(_ calendar: EKCalendar) -> AppleCalendarValue? {
        guard let source = calendar.source else { return nil }
        return AppleCalendarValue(binding: AppleCalendarBinding(id: calendar.calendarIdentifier,
            sourceID: source.sourceIdentifier, sourceType: source.sourceType.rawValue), title: calendar.title)
    }

    static func value(_ event: EKEvent) -> AppleEventValue? {
        // EventKit objects may lose fields after invalidation or store release.
        // An incomplete object is unresolved evidence, never a mutation handle.
        guard let calendar = event.calendar, let binding = value(calendar)?.binding,
              let start = event.startDate, let end = event.endDate else { return nil }
        return AppleEventValue(id: event.eventIdentifier ?? "", itemID: event.calendarItemIdentifier,
            externalID: event.calendarItemExternalIdentifier, calendar: binding,
            recurring: event.hasRecurrenceRules || event.isDetached,
            content: AppleEventContent(title: event.title ?? "", start: start,
                end: end, notes: event.notes, location: event.location, url: event.url))
    }

    static func apply(_ content: AppleEventContent, to event: EKEvent) {
        event.title = content.title
        event.startDate = content.start
        event.endDate = content.end
        event.notes = content.notes
        event.location = content.location
        event.url = content.url
    }
}
