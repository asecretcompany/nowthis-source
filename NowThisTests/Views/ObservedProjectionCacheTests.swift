import Foundation
import Observation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct ObservedProjectionCacheTests {
    @Test("Search-only reads reuse a sorted projection and observe unsaved changes immediately")
    func sortedSourceIsReusedUntilItsInputsChange() throws {
        let container = try ModelContainer(for: TaskItem.self, TaskList.self, ServerAccount.self,
            NowThis.Tag.self, JournalEntry.self, SyncMetadata.self, SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let beta = TaskItem(title: "Beta")
        let alpha = TaskItem(title: "Alpha")
        context.insert(beta); context.insert(alpha)
        let tasks = [beta, alpha]
        let cache = ObservedProjectionCache<String, [TaskItem]>()
        var sorts = 0
        func source(_ key: String = "ascending") -> [TaskItem] {
            cache.value(for: key) {
                sorts += 1
                return TaskListHelpers.sortedWithCompletedLast(tasks, by: .title, ascending: key == "ascending")
            }
        }
        #expect(source().map(\.title) == ["Alpha", "Beta"])
        #expect(source().filter { $0.title.localizedStandardContains("al") }.map(\.title) == ["Alpha"])
        #expect(source().filter { $0.title.localizedStandardContains("be") }.map(\.title) == ["Beta"])
        #expect(sorts == 1)
        beta.title = "Aardvark" // No save and no query revision yet.
        #expect(source().map(\.title) == ["Aardvark", "Alpha"])
        #expect(sorts == 2)
        #expect(source("descending").map(\.title) == ["Alpha", "Aardvark"])
        #expect(sorts == 3)
        withExtendedLifetime(container) {}
    }

    @Test("A new observation generation cannot be invalidated by an old dependency")
    func replacedDependenciesDoNotInvalidateCurrentProjection() {
        let old = Input(1), current = Input(7)
        let cache = ObservedProjectionCache<Int, Int>()
        var builds = 0
        #expect(cache.value(for: 1) { builds += 1; return old.number } == 1)
        #expect(cache.value(for: 2) { builds += 1; return current.number } == 7)
        old.number = 9
        #expect(cache.value(for: 2) { builds += 1; return current.number } == 7)
        #expect(builds == 2)
        current.number = 8
        #expect(cache.value(for: 2) { builds += 1; return current.number } == 8)
        #expect(builds == 3)
    }

    @Test("Observed mutations publish an invalidation to the view that consumed the cache")
    func invalidationReachesConsumer() async {
        let input = Input(2)
        let cache = ObservedProjectionCache<Int, Int>()
        _ = cache.value(for: 0) { input.number * 2 } // Observe a hit, not its model reads.
        let changed = Flag()
        withObservationTracking {
            _ = cache.value(for: 0) { input.number * 2 }
        } onChange: { changed.set() }
        input.number = 3
        for _ in 0..<100 where !changed.value { await Task.yield() }
        #expect(changed.value)
        #expect(cache.value(for: 0) { input.number * 2 } == 6)
    }

    @Test("A synchronous rebuild cannot swallow the notification owed to an earlier consumer")
    func synchronousRebuildStillNotifiesConsumer() async {
        let input = Input(2)
        let cache = ObservedProjectionCache<Int, Int>()
        _ = cache.value(for: 0) { input.number * 2 }
        let changed = Flag()
        withObservationTracking {
            _ = cache.value(for: 0) { input.number * 2 }
        } onChange: { changed.set() }
        input.number = 3
        #expect(cache.value(for: 0) { input.number * 2 } == 6)
        for _ in 0..<100 where !changed.value { await Task.yield() }
        #expect(changed.value)
    }

    @Test("Search can find a matching duplicate UID after sorting the source")
    func searchPrecedesUIDDeduplication() throws {
        let container = try ModelContainer(for: TaskItem.self, TaskList.self, ServerAccount.self,
            NowThis.Tag.self, JournalEntry.self, SyncMetadata.self, SavedFilter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let first = TaskItem(uid: "shared", title: "Alpha")
        let matchingCopy = TaskItem(uid: "shared", title: "Grüße")
        let locationMatch = TaskItem(title: "Meeting")
        locationMatch.locationName = "Café"
        for task in [first, matchingCopy, locationMatch] { context.insert(task) }
        #expect(TaskListHelpers.searchAndDeduplicate([first, matchingCopy], query: "grusse").map(\.id) == [matchingCopy.id])
        #expect(TaskListHelpers.searchAndDeduplicate([locationMatch], query: "cafe").map(\.id) == [locationMatch.id])
        #expect(TaskListHelpers.searchAndDeduplicate([first, matchingCopy], query: "").map(\.id) == [first.id])
        withExtendedLifetime(container) {}
    }

    @Test(arguments: [SmartList.upcoming, .overdue], [false, true])
    func sectionedSearchMatchesMetadataBeforeUIDDedup(smartList: SmartList, usesTag: Bool) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let now = Date()
        let calendar = Calendar.current
        let days = smartList == .upcoming ? 5 : -5
        let due = try #require(calendar.date(byAdding: .day, value: days, to: now))
        let otherDay = try #require(calendar.date(byAdding: .day, value: -days, to: now))
        let tag = NowThis.Tag(name: "Café annex")
        context.insert(tag)

        func task(_ id: String, uid: String, due: Date, matches: Bool, priority: TaskPriority = .high,
                  status: TaskStatus = .needsAction) -> TaskItem {
            let task = TaskItem(id: id, uid: uid, title: "Neutral", priority: priority)
            task.dueDate = due
            task.status = status
            if matches {
                if usesTag { task.tags = [tag] } else { task.locationName = "Café annex" }
            }
            context.insert(task)
            return task
        }
        let tasks = [
            task("first", uid: "shared", due: due, matches: false),
            task("second", uid: "shared", due: due, matches: true),
            task("wrong-date", uid: "wrong-date", due: otherDay, matches: true),
            task("wrong-priority", uid: "wrong-priority", due: due, matches: true, priority: .low),
            task("completed", uid: "completed", due: due, matches: true, status: .completed)
        ]
        let occurrences = TaskListView.sectionedTaskOccurrences(from: tasks, smartList: smartList,
                                                               searchText: "cafe annex", priority: .high, now: now)
        #expect(occurrences.map(\.task.id) == ["second"])
        #expect(occurrences.map(\.occurrenceDate) == [due])
        withExtendedLifetime(container) {}
    }

    @Observable final class Input {
        var number: Int
        init(_ number: Int) { self.number = number }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
    }
}
