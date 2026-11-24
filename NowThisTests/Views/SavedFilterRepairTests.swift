import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
struct SavedFilterRepairTests {
    @Test func retryReloadsTheSameSelectedFilterAfterATransientReadFailure() throws {
        let container = try DAVSyncScenario.container()
        let filter = SavedFilter(id: "selected", name: "Previously verified", rules: [
            FilterRule(field: .title, comparison: .equals, value: "Old match")
        ])
        container.mainContext.insert(filter)
        try container.mainContext.save()
        var filters = SavedFilterLoadState()
        filters.reload { try SavedFilterStore.snapshots(in: container) }
        #expect(filters.verifiedFilter(id: "selected")?.name == "Previously verified")

        let worker = ModelContext(container)
        let committed = try #require(try SavedFilterStore.filter("selected", in: worker))
        committed.name = "Current selection"
        committed.rules = [FilterRule(field: .title, comparison: .equals, value: "Current match")]
        try worker.save()
        filters.reload { throw TestFailure.forcedRead }
        #expect(filters.loadFailed)
        #expect(filters.verifiedFilters.isEmpty)
        #expect(filters.verifiedFilter(id: "selected") == nil)
        #expect(filters.lastKnownName(id: "selected") == "Previously verified")

        // Retry calls the same reload entry, with the existing navigation ID.
        filters.reload { try SavedFilterStore.snapshots(in: container) }
        #expect(!filters.loadFailed)
        let retried = try #require(filters.verifiedFilter(id: "selected"))
        #expect(retried.name == "Current selection")
        let tasks = [TaskItem(title: "Old match"), TaskItem(title: "Current match")]
        #expect(retried.criteria?.matchingTasks(tasks).map(\.title) == ["Current match"])

        worker.delete(committed)
        try worker.save()
        filters.reload { try SavedFilterStore.snapshots(in: container) }
        #expect(!filters.loadFailed)
        #expect(filters.verifiedFilter(id: "selected") == nil)
        #expect(filters.lastKnownName(id: "selected") == nil)
    }

    @Test(arguments: [FilterField.priority, .hasDueDate, .dueDateBefore, .dueDateAfter])
    func changingFieldSavesTheDisplayedDefault(field: FilterField) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T19:30:00Z"))
        var rule = FilterRule(id: "retained", field: .status, comparison: .notEquals, value: "NEEDS-ACTION")
        rule.changeField(to: field, now: now)
        let filter = SavedFilter(name: "Transition", rules: [rule])
        context.insert(filter)
        try context.save()
        let persisted = try #require(filter.rules.first)
        let expected: String
        switch field {
        case .priority: expected = "high"
        case .hasDueDate: expected = "true"
        case .dueDateBefore, .dueDateAfter: expected = "2026-03-08T19:30:00Z"
        default: throw TestFailure.unexpectedField
        }
        #expect(persisted.id == "retained")
        #expect(persisted.field == field)
        #expect(persisted.comparison == .equals)
        #expect(persisted.value == expected)
        let match = TaskItem(id: "match", title: "Match", priority: .high)
        let miss = TaskItem(id: "miss", title: "Miss", priority: .low)
        let offset: TimeInterval = field == .dueDateBefore ? -3600 : 3600
        match.dueDate = now.addingTimeInterval(offset)
        if field == .dueDateBefore || field == .dueDateAfter { miss.dueDate = now }
        #expect(filter.snapshot.criteria?.matchingTasks([match, miss]).map(\.id) == ["match"])
    }

    enum BadCriteria: CaseIterable {
        case corrupt, unknownField, unknownComparison, empty, badLogic, invalidBoolean, invalidComparison, blankTitle, mixedOR, duplicateIDs
    }

    @Test(arguments: BadCriteria.allCases)
    func unusableCriteriaReturnNoTasks(kind: BadCriteria) throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let high = FilterRule(field: .priority, comparison: .equals, value: "high")
        let invalidBoolean = FilterRule(field: .hasDueDate, comparison: .equals, value: "maybe")
        let filter = SavedFilter(id: "repair", name: "Keep this name", rules: [high])
        let match = TaskItem(id: "matching", title: "Matching branch", priority: .high)
        let other = TaskItem(id: "unrelated", title: "Unrelated task", priority: .low)
        switch kind {
        case .corrupt: filter.rulesData = Data("{broken".utf8)
        case .unknownField: filter.rulesData = Data(#"[{"id":"x","field":"Future field","comparison":"is","value":"abc"}]"#.utf8)
        case .unknownComparison: filter.rulesData = Data(#"[{"id":"x","field":"Title","comparison":"unknown","value":"abc"}]"#.utf8)
        case .empty: filter.rules = []
        case .badLogic: filter.logicOperator = "XOR"
        case .invalidBoolean: filter.rules = [invalidBoolean]
        case .invalidComparison: filter.rules = [FilterRule(field: .priority, comparison: .notContains, value: "high")]
        case .blankTitle: filter.rules = [FilterRule(field: .title, comparison: .contains, value: "")]
        case .mixedOR:
            filter.logic = .or
            filter.rules = [high, invalidBoolean]
        case .duplicateIDs: filter.rules = [high, high]
        }
        context.insert(filter)
        try context.save()
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<SavedFilter>()).first)
        #expect(saved.name == "Keep this name")
        #expect(saved.snapshot.criteria == nil)
        let matches = saved.snapshot.criteria?.matchingTasks([match, other]) ?? []
        #expect(matches.isEmpty)
    }

    @Test func legacyTokensAndMissingNamesKeepTheirMeaning() throws {
        let filter = SavedFilter(name: "Old", rules: [
            FilterRule(field: .status, comparison: .equals, value: "needs-action"),
            FilterRule(field: .priority, comparison: .equals, value: "High"),
            FilterRule(field: .hasDueDate, comparison: .equals, value: "TRUE"),
            FilterRule(field: .list, comparison: .notEquals, value: "Deleted List"),
            FilterRule(field: .tag, comparison: .notEquals, value: "Deleted Tag")
        ])
        let raw = filter.rulesData
        let snapshot = filter.snapshot
        #expect(SavedFilterEdits.editableRules(from: snapshot).map(\.value) == [
            "NEEDS-ACTION", "high", "true", "Deleted List", "Deleted Tag"
        ])
        #expect(filter.rulesData == raw)
        let task = TaskItem(title: "Matching", priority: .high)
        task.dueDate = Date()
        let miss = TaskItem(title: "Not dated", priority: .high)
        let criteria = try #require(snapshot.criteria)
        #expect(criteria.matchingTasks([task, miss]).map(\.title) == ["Matching"])
    }

    @Test func openingInvalidRowsDoesNotChangeTheirStoredBytes() throws {
        let good = FilterRule(id: "same", field: .priority, comparison: .equals, value: "High")
        let bad = FilterRule(id: "same", field: .status, comparison: .contains, value: "bad")
        let filter = SavedFilter(name: "Old", rules: [good, bad], logicOperator: .or)
        let raw = filter.rulesData
        let draft = SavedFilterEdits.editableRules(from: filter.snapshot)
        #expect(Set(draft.map(\.id)).count == 2)
        #expect(draft.first?.value == "high")
        #expect(draft.last?.value == "bad")
        #expect(draft.last?.isValid == false)
        #expect(filter.rulesData == raw)
    }

    @Test func failedRepairAndUnrelatedSaveKeepTheExactStoredFilter() throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        main.autosaveEnabled = false
        let filter = SavedFilter(id: "repair", name: "Original", icon: "flag", colorHex: "#123456", sortOrder: 7)
        filter.rulesData = Data("{legacy payload".utf8)
        filter.logicOperator = "XOR"
        main.insert(filter)
        try main.save()
        let original = try #require(SavedFilterStore.snapshots(in: container).first)
        let errors = ErrorState()
        let invalid = SavedFilterEdits(name: "Invalid", icon: "star", colorHex: "#654321", logic: nil, rules: [])
        #expect(throws: SavedFilterEdits.Failure.invalidCriteria) {
            try invalid.save(over: original, in: container, errorState: errors)
        }
        let repair = SavedFilterEdits(name: "Repaired", icon: "star", colorHex: "#654321", logic: .or, rules: [
            FilterRule(field: .priority, comparison: .equals, value: "high")
        ])
        #expect(try !repair.save(over: original, in: container, errorState: errors, save: { throw TestFailure.forcedSave }))
        main.insert(TaskItem(title: "Unrelated commit"))
        try main.save()
        #expect(try SavedFilterStore.snapshots(in: container) == [original])

        let revision = FilterCommits(container: container)
        defer { revision.stop() }
        #expect(try repair.save(over: original, in: container, errorState: errors))
        #expect(revision.count == 1)
        let saved = try #require(SavedFilterStore.snapshots(in: container).first)
        #expect(saved.id == "repair")
        #expect(saved.sortOrder == 7)
        #expect(saved.name == "Repaired")
        #expect(saved.logic == .or)
        let task = TaskItem(title: "Expected", priority: .high)
        let unrelated = TaskItem(title: "Unrelated")
        #expect(saved.criteria?.matchingTasks([task, unrelated]).map(\.title) == ["Expected"])
        #expect(throws: SavedFilterEdits.Failure.changed) {
            try repair.save(over: original, in: container, errorState: errors)
        }
    }

    @Test func failedCreateDoesNotLeaveADraftAndRetryCreatesOnce() throws {
        let container = try DAVSyncScenario.container()
        let errors = ErrorState()
        let draft = SavedFilterEdits(name: "New", icon: "star", colorHex: "#654321", logic: .and, rules: [
            FilterRule(field: .title, comparison: .equals, value: "Target")
        ])
        #expect(try !draft.save(over: nil, in: container, errorState: errors, save: { throw TestFailure.forcedSave }))
        #expect(try SavedFilterStore.snapshots(in: container).isEmpty)
        #expect(try draft.save(over: nil, in: container, errorState: errors))
        #expect(try SavedFilterStore.snapshots(in: container).map(\.name) == ["New"])
    }

    @Test func deleteRetryPreservesANewerEditAndCannotResurrectADeletedFilter() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let filter = SavedFilter(name: "Original", rules: [FilterRule(field: .title, comparison: .equals, value: "A")])
        context.insert(filter)
        try context.save()
        let original = filter.snapshot
        let errors = ErrorState()
        SavedFilterStore.delete([original], in: container, errorState: errors, save: { throw TestFailure.forcedSave })
        let retry = try #require(errors.retryAction)
        let draft = SavedFilterEdits(name: "Newer", icon: original.icon, colorHex: original.colorHex,
                                    logic: .and, rules: original.rules ?? [])
        #expect(try draft.save(over: original, in: container, errorState: ErrorState()))
        retry()
        let newer = try #require(SavedFilterStore.snapshots(in: container).first)
        #expect(newer.name == "Newer")
        #expect(errors.retryAction == nil)
        let revision = FilterCommits(container: container)
        defer { revision.stop() }
        SavedFilterStore.delete([newer], in: container, errorState: errors)
        #expect(revision.count == 1)
        #expect(try SavedFilterStore.snapshots(in: container).isEmpty)
        #expect(throws: SavedFilterEdits.Failure.changed) {
            try draft.save(over: newer, in: container, errorState: errors)
        }
    }

    private final class FilterCommits: @unchecked Sendable {
        private let lock = NSLock()
        private var received = 0
        private var observer: NSObjectProtocol?

        init(container: ModelContainer) {
            let store = CalendarMirrorState.storeKey(container)
            observer = NotificationCenter.default.addObserver(forName: SavedFilterStore.didCommit, object: nil, queue: nil) { [weak self] notification in
                guard let self, notification.object as? String == store else { return }
                lock.withLock { received += 1 }
            }
        }

        var count: Int { lock.withLock { received } }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    private enum TestFailure: Error { case unexpectedField, forcedSave, forcedRead }
}
