import CoreSpotlight
import os
import SwiftData

/// Indexes `TaskItem` records into CoreSpotlight for system-wide search.
///
/// When the user searches in Spotlight, matching tasks appear with their title,
/// list name, and priority. Tapping a result deep-links into the app via
/// `nowthis://task/{id}`.
///
/// **Index Strategy:**
/// - Full re-index on app launch (debounced, background)
/// - Incremental updates on task CRUD operations
/// - Items automatically expire after 30 days of no update
@MainActor
final class SpotlightIndexer {

    /// The Spotlight index used for all NowThis task items.
    private let searchableIndex = CSSearchableIndex(name: "com.asecretcompany.nowthis.tasks")

    /// Domain identifier for bulk operations.
    private static let domainID = "com.asecretcompany.nowthis.task"
    private let logger = Logger(subsystem: "com.nowthis", category: "spotlight")

    // MARK: - Full Index

    /// Re-indexes all non-deleted tasks. Called on app launch.
    ///
    /// This replaces the entire index content, ensuring consistency
    /// after offline edits or sync operations.
    func reindexAll(modelContext: ModelContext) async {
        do {
            try Task.checkCancellation()

            let predicate = #Predicate<TaskItem> { !$0.isDeletedLocally }
            let descriptor = FetchDescriptor<TaskItem>(
                predicate: predicate
            )
            let tasks = try modelContext.fetch(descriptor)
            let items = tasks.compactMap { makeSearchableItem(from: $0) }

            try Task.checkCancellation()

            try await searchableIndex.deleteSearchableItems(
                withDomainIdentifiers: [Self.domainID]
            )

            if !items.isEmpty {
                try await searchableIndex.indexSearchableItems(items)
            }
        } catch is CancellationError {
            // Cancelled — exit silently to allow graceful termination
        } catch {
            logger.error("Full re-index failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Incremental Updates

    /// Indexes or updates a single task in Spotlight.
    func index(task: TaskItem) async {
        guard let item = makeSearchableItem(from: task) else { return }
        do {
            try await searchableIndex.indexSearchableItems([item])
        } catch {
            logger.error("Index failed for task: \(error.localizedDescription)")
        }
    }

    /// Removes a single task from the Spotlight index.
    func remove(taskID: String) async {
        do {
            try await searchableIndex.deleteSearchableItems(
                withIdentifiers: [taskID]
            )
        } catch {
            logger.error("Remove failed for task: \(error.localizedDescription)")
        }
    }

    /// Removes all NowThis items from the Spotlight index.
    func removeAll() async {
        do {
            try await searchableIndex.deleteSearchableItems(
                withDomainIdentifiers: [Self.domainID]
            )
        } catch {
            logger.error("Remove all failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// Creates a `CSSearchableItem` from a `TaskItem`.
    ///
    /// - Returns: A searchable item, or `nil` if the task is deleted.
    private func makeSearchableItem(from task: TaskItem) -> CSSearchableItem? {
        guard !task.isDeletedLocally else { return nil }

        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = task.title
        attributes.contentDescription = task.descriptionText

        // Build keywords for better search matching
        var keywords = [task.title]
        if let listName = task.taskList?.name {
            attributes.containerTitle = listName
            keywords.append(listName)
        }
        for tag in task.tags {
            keywords.append(tag.name)
        }
        attributes.keywords = keywords

        // Priority indicator in subtitle
        if task.priority != .none {
            attributes.alternateNames = ["\(task.priority) priority"]
        }

        // Due date for temporal relevance
        if let dueDate = task.dueDate {
            attributes.dueDate = dueDate
            attributes.completionDate = task.completedDate
        }

        // Deep link URL
        attributes.relatedUniqueIdentifier = task.id
        attributes.url = URL(string: "nowthis://task/\(task.id)")

        let item = CSSearchableItem(
            uniqueIdentifier: task.id,
            domainIdentifier: Self.domainID,
            attributeSet: attributes
        )

        // Items expire after 30 days without update
        item.expirationDate = Calendar.current.date(
            byAdding: .day,
            value: 30,
            to: Date()
        )

        return item
    }
}
