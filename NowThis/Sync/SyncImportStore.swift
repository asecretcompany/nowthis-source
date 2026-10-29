import Foundation
import SwiftData

/// Confined to one context owner and one import run. No models cross suspension points.
final class SyncImportStore {
    private let context: ModelContext
    private var knownTags: [Tag]
    private(set) var parseCount = 0
    private(set) var tagFetchCount = 0
    let formatterCache = ICalendarParser.FormatterCache()

    init(context: ModelContext) throws {
        self.context = context
        knownTags = try context.fetch(FetchDescriptor<Tag>())
        tagFetchCount = 1
    }

    func parse(_ resource: CalDAVClient.RemoteTask) throws -> ParsedRemoteTask {
        parseCount += 1
        let interval = PerformanceTrace.begin("ICSParse", bytes: resource.icsData.utf8.count)
        defer { PerformanceTrace.end("ICSParse", interval) }
        return ParsedRemoteTask(href: resource.href, etag: resource.etag,
            todo: try ICalendarParser.parseSingleVTODO(from: resource.icsData, using: formatterCache))
    }

    func apply(_ resource: ParsedRemoteTask, list: TaskList,
               uidMap: inout [String: TaskItem], movedAway: Set<String> = []) -> Bool {
        guard let todo = resource.todo else { return false }
        if let task = uidMap[todo.uid] {
            guard !task.isDeletedLocally else { return false }
            guard !task.isDirty || task.remoteHref != nil else { return false }
            // A server rename can keep both UID and ETag. Accept its location without
            // replacing dirty content or suppressing a changed-content comparison.
            let hrefChanged = task.remoteHref != resource.href
            if hrefChanged { task.remoteHref = resource.href; task.isLocalOnly = false }
            // This return value describes content changes; the transaction still
            // saves accepted href metadata when the body itself is unchanged.
            guard !task.isDirty, task.etag != resource.etag else { return false }
            applyFields(todo, to: task)
            task.etag = resource.etag
            task.remoteHref = resource.href
            return true
        }
        guard !movedAway.contains(todo.uid) else { return false }
        let task = TaskItem(uid: todo.uid, title: todo.summary)
        applyFields(todo, to: task)
        task.etag = resource.etag; task.remoteHref = resource.href
        task.isDirty = false; task.taskList = list
        context.insert(task); uidMap[todo.uid] = task
        return true
    }

    func applyFields(_ data: ICalendarParser.VTODOData, to task: TaskItem) {
        TaskPhotoSyncStore.apply(data.photos, opaque: data.opaqueAttachments, to: task, in: context)
        task.isLocalOnly = false
        task.title = data.summary; task.notes = data.description ?? ""
        if let status = data.status { task.status = TaskStatus(rawValue: status) ?? .needsAction }
        task.priorityRaw = data.priority; task.percentComplete = data.percentComplete
        let startWasWithheld = SyncEngine.startWasWithheldFromServer(task)
        task.dueDate = data.dueDate; task.isDueDateOnly = data.isDueDateOnly
        if data.startDate != nil || !startWasWithheld {
            task.startDate = data.startDate; task.isStartDateOnly = data.isStartDateOnly
        }
        task.completedDate = data.completedDate; task.createdDate = data.createdDate ?? task.createdDate
        task.lastModifiedDate = data.lastModifiedDate
        task.location = data.location; task.latitude = data.latitude; task.longitude = data.longitude
        task.url = data.url; task.parentUID = data.parentUID
        task.reminderOffset = data.alarmTriggerSeconds; task.recurrenceRule = data.recurrenceRule
        if let order = data.manualSortOrder { task.manualSortOrder = order }
        if let categories = data.categories { task.tags = resolve(categories) }
    }

    private func resolve(_ categories: [String]) -> [Tag] {
        var resolved: [Tag] = []
        var seen = Set<String>()
        for name in categories {
            let tag: Tag
            if let existing = Tag.matching(name, in: knownTags) { tag = existing }
            else {
                tag = Tag(name: name); context.insert(tag); knownTags.append(tag)
            }
            if seen.insert(tag.id).inserted { resolved.append(tag) }
        }
        return resolved
    }

    /// The one-time category repair adds remote tags without removing pending local tags.
    func catchUpCategories(_ resources: [ParsedRemoteTask], uidMap: [String: TaskItem]) -> Bool {
        var added = false
        for resource in resources {
            guard let data = resource.todo, let categories = data.categories,
                  let task = uidMap[data.uid], !task.isDeletedLocally else { continue }
            let existingIDs = Set(task.tags.map(\.id))
            let missing = resolve(categories).filter { !existingIDs.contains($0.id) }
            if !missing.isEmpty { task.tags.append(contentsOf: missing); added = true }
        }
        return added
    }
}
