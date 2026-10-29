import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Off-main inbound planning", .serialized)
@MainActor
struct SyncInboundPlannerTests {
    @Test("Ten thousand clean roots produce no parent edits")
    func unchangedLargeList() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        for index in 0..<10_000 { fixture.task("root-\(index)") }
        try fixture.context.save()

        let edits = try await fixture.planner.parentEdits()

        #expect(edits.isEmpty)
        #expect(!fixture.context.hasChanges)
    }

    @Test("Changed, missing, self and cyclic parent links produce only relationship edits")
    func parentChanges() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let root = fixture.task("root")
        let old = fixture.task("old")
        let changed = fixture.task("changed", parent: old, rawParent: "root")
        let missing = fixture.task("missing", parent: old, rawParent: "unknown")
        let selfParent = fixture.task("self", parent: old, rawParent: "self")
        let a = fixture.task("a", parent: old, rawParent: "b")
        let b = fixture.task("b", parent: old, rawParent: "a")
        let intoCycle = fixture.task("into-cycle", rawParent: "a")
        fixture.task("unchanged", parent: root, rawParent: "root")
        fixture.task("already-missing", rawParent: "unknown")
        try fixture.context.save()

        let edits = try await fixture.planner.parentEdits()
        let byUID = Dictionary(uniqueKeysWithValues: edits.map { ($0.uid, $0) })

        #expect(Set(byUID.keys) == ["changed", "missing", "self", "a", "b", "into-cycle"])
        #expect(byUID["changed"] == SyncInboundPlanner.ParentEdit(taskID: changed.id, uid: changed.uid,
            expectedRawParentUID: "root", expectedParentID: old.id, parentID: root.id))
        for task in [missing, selfParent, a, b] {
            let edit = try #require(byUID[task.uid])
            #expect(edit.taskID == task.id)
            #expect(edit.expectedRawParentUID == task.parentUID)
            #expect(edit.expectedParentID == old.id)
            #expect(edit.parentID == nil)
            #expect(task.parentTask?.id == old.id)
        }
        #expect(byUID["into-cycle"]?.parentID == a.id)
        #expect(byUID["into-cycle"]?.taskID == intoCycle.id)
        #expect(changed.parentTask?.id == old.id)
        #expect(missing.parentUID == "unknown")
        #expect(!fixture.context.hasChanges)
    }

    @Test("Dirty and locally deleted tasks do not receive parent edits")
    func pendingParentsAreSkipped() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let root = fixture.task("root")
        let dirty = fixture.task("dirty", rawParent: "root")
        dirty.isDirty = true
        let deleted = fixture.task("deleted", rawParent: "root")
        deleted.isDeletedLocally = true
        let orphan = fixture.task("orphan", parent: root, rawParent: "deleted")
        try fixture.context.save()

        let edits = try await fixture.planner.parentEdits()

        #expect(edits.map(\.uid) == ["orphan"])
        #expect(edits.first?.taskID == orphan.id)
        #expect(edits.first?.parentID == nil)
    }

    @Test("A protected grandchild protects every ancestor", arguments: ["dirty", "local-only", "deleted", "overlay", "no-href"])
    func ancestorProtection(reason: String) async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let root = fixture.task("root")
        let middle = fixture.task("middle", parent: root)
        let leaf = fixture.task("leaf", parent: middle)
        let sibling = fixture.task("sibling", parent: root)
        let survivor = fixture.task("survivor")
        switch reason {
        case "dirty": leaf.isDirty = true
        case "local-only": leaf.isLocalOnly = true
        case "deleted": leaf.isDeletedLocally = true
        case "no-href": leaf.remoteHref = nil
        default: break
        }
        try fixture.context.save()
        let protected: Set<String> = reason == "overlay" ? [leaf.uid] : []

        let candidates = try await fixture.planner.deletionCandidates(
            manifest: [resource(survivor.remoteHref!)], explicitHrefs: nil, protectedUIDs: protected)

        #expect(candidates.map(\.taskID) == [sibling.id])
        #expect(root.modelContext != nil)
        #expect(middle.modelContext != nil)
        #expect(leaf.modelContext != nil)
        #expect(!fixture.context.hasChanges)
    }

    @Test("Explicit tombstones also protect ancestors of a pending grandchild")
    func explicitAncestorProtection() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let root = fixture.task("root")
        let middle = fixture.task("middle", parent: root)
        let leaf = fixture.task("leaf", parent: middle)
        let sibling = fixture.task("sibling", parent: root)
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: [root, middle, leaf, sibling].compactMap(\.remoteHref), protectedUIDs: [leaf.uid])

        #expect(candidates.map(\.taskID) == [sibling.id])
    }

    @Test("Explicit deletion can remove the final uploaded leaf")
    func explicitFinalLeaf() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let leaf = fixture.task("last")
        #expect(!leaf.isLocalOnly)
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: [leaf.remoteHref!], protectedUIDs: [])

        #expect(candidates == [SyncInboundPlanner.DeleteCandidate(taskID: leaf.id, uid: leaf.uid,
            expectedHref: leaf.remoteHref, expectedListID: fixture.list.id)])
        #expect(leaf.modelContext != nil)
        #expect(!fixture.context.hasChanges)
    }

    @Test("Legacy local-only flags do not protect server-confirmed rows", arguments: ["explicit", "manifest"])
    func serverConfirmedLegacyRow(accounting: String) async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let legacy = fixture.task("legacy")
        legacy.isLocalOnly = true
        legacy.etag = "known-server-etag"
        let survivor = fixture.task("survivor")
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(
            manifest: accounting == "manifest" ? [resource(survivor.remoteHref!)] : nil,
            explicitHrefs: accounting == "explicit" ? [legacy.remoteHref!] : nil,
            protectedUIDs: [])

        #expect(candidates.map(\.taskID) == [legacy.id])
    }

    @Test("An empty complete manifest cannot delete the final leaf")
    func emptyManifestIsConservative() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.task("last")
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(manifest: [],
            explicitHrefs: nil, protectedUIDs: [])

        #expect(candidates.isEmpty)
    }

    @Test("Empty manifests do not suppress authenticated explicit tombstones")
    func emptyManifestWithExplicitTombstone() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let leaf = fixture.task("last")
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(manifest: [],
            explicitHrefs: [leaf.remoteHref!], protectedUIDs: [])

        #expect(candidates.map(\.taskID) == [leaf.id])
    }

    @Test("A nonempty manifest with no local href match preserves all absent tasks")
    func unknownManifestIsConservative() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.task("one")
        fixture.task("two")
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(
            manifest: [resource("/list/event.ics"), resource("/list/journal.ics")],
            explicitHrefs: nil, protectedUIDs: [])

        #expect(candidates.isEmpty)
    }

    @Test("Mixed component manifests use matching local hrefs rather than filename UIDs")
    func mixedManifest() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let kept = fixture.task("actual-uid")
        kept.remoteHref = "/list/opaque-name.ics"
        let absent = fixture.task("absent")
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(
            manifest: [resource(kept.remoteHref!), resource("/list/event.ics")],
            explicitHrefs: nil, protectedUIDs: [])

        #expect(candidates.map(\.taskID) == [absent.id])
    }

    @Test("Deletion plans are deepest first and retain parents of surviving children")
    func deepestFirst() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let root = fixture.task("root")
        let middle = fixture.task("middle", parent: root)
        let leaf = fixture.task("leaf", parent: middle)
        let liveRoot = fixture.task("live-root")
        let liveLeaf = fixture.task("live-leaf", parent: liveRoot)
        try fixture.context.save()

        let candidates = try await fixture.planner.deletionCandidates(
            manifest: [resource(liveLeaf.remoteHref!)], explicitHrefs: nil, protectedUIDs: [])

        #expect(candidates.map(\.taskID) == [leaf.id, middle.id, root.id])
    }

    @Test("Planning fetches only its list and does not resolve a parent in another list")
    func scopedToList() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let otherList = TaskList(id: "other", serverURL: "/other/", name: "Other", colorHex: "#007AFF")
        fixture.context.insert(otherList)
        let other = TaskItem(id: "foreign-id", uid: "foreign", title: "Foreign")
        other.taskList = otherList
        other.remoteHref = "/other/foreign.ics"
        other.isLocalOnly = false
        fixture.context.insert(other)
        let root = fixture.task("root")
        let child = fixture.task("child", parent: root, rawParent: "foreign")
        try fixture.context.save()

        let edits = try await fixture.planner.parentEdits()
        let deletions = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: [other.remoteHref!, child.remoteHref!], protectedUIDs: [])

        #expect(edits.map(\.taskID) == [child.id])
        #expect(edits.first?.parentID == nil)
        #expect(deletions.map(\.taskID) == [child.id])
    }

    @Test("Each plan reads newly saved state instead of cached models")
    func freshReads() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        let parent = fixture.task("parent")
        let child = fixture.task("child", rawParent: "parent")
        try fixture.context.save()
        let first = try await fixture.planner.parentEdits()
        #expect(first.first?.parentID == parent.id)
        child.parentTask = parent
        child.isDirty = true
        try fixture.context.save()

        let second = try await fixture.planner.parentEdits()
        let deletions = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: [parent.remoteHref!, child.remoteHref!], protectedUIDs: [])

        #expect(second.isEmpty)
        #expect(deletions.isEmpty)
    }

    @Test("No accounting and unknown explicit hrefs produce no deletions")
    func noDeletionEvidence() async throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture.container) {} }
        fixture.task("kept")
        try fixture.context.save()

        let noAccounting = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: nil, protectedUIDs: [])
        let unknown = try await fixture.planner.deletionCandidates(manifest: nil,
            explicitHrefs: ["/list/unknown.ics"], protectedUIDs: [])

        #expect(noAccounting.isEmpty)
        #expect(unknown.isEmpty)
    }

    @Test("Fifty thousand hierarchy depths are memoized iteratively")
    func deepHierarchyDepths() {
        let count = 50_000
        let ids = (0..<count).map { "node-\($0)" }
        var parents: [String: String] = [:]
        for index in 1..<count { parents[ids[index]] = ids[index - 1] }

        let depths = SyncInboundPlanner.deletionDepths(parentIDs: parents, taskIDs: ids.reversed())

        #expect(depths.count == count)
        #expect(depths["node-0"] == 0)
        #expect(depths["node-49999"] == 49_999)
        #expect(depths["node-25000"] == 25_000)
    }

    @Test("Depth computation terminates on cycles and unknown parents")
    func cycleSafeDepths() {
        let depths = SyncInboundPlanner.deletionDepths(
            parentIDs: ["a": "b", "b": "a", "tail": "a", "self": "self", "unknown": "outside"],
            taskIDs: ["tail", "a", "b", "self", "unknown", "root"])

        #expect(depths == ["a": 0, "b": 0, "tail": 1, "self": 0, "unknown": 0, "root": 0])
    }

    private func resource(_ href: String) -> CalDAVClient.RemoteResource {
        CalDAVClient.RemoteResource(href: href, etag: "etag")
    }

    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let list: TaskList
        let planner: SyncInboundPlanner

        init() throws {
            let schema = Schema([TaskItem.self, TaskList.self, ServerAccount.self, Tag.self, JournalEntry.self])
            container = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            context = ModelContext(container)
            context.autosaveEnabled = false
            list = TaskList(id: "list", serverURL: "/list/", name: "Fixture", colorHex: "#007AFF")
            context.insert(list)
            planner = SyncInboundPlanner(container: container, listID: list.id)
        }

        @discardableResult
        func task(_ uid: String, parent: TaskItem? = nil, rawParent: String? = nil) -> TaskItem {
            let task = TaskItem(id: "id-" + uid, uid: uid, title: uid)
            context.insert(task)
            task.taskList = list
            task.remoteHref = "/list/" + uid + ".ics"
            task.isLocalOnly = false
            task.isDirty = false
            task.parentTask = parent
            task.parentUID = rawParent
            return task
        }
    }
}
