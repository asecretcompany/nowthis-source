import Foundation
import Testing
@testable import NowThis

@Suite("TaskList flattened hierarchy")
struct TaskListHierarchyProjectionTests {
    private func project(_ roots: [Int] = [0], children: [Int: [Int]],
                         collapsed: Set<Int> = [], hidden: Set<Int> = [])
        -> TaskListHierarchyProjection<Int, Int> {
        TaskListHierarchyProjection(roots: roots, collapsedIDs: collapsed,
            isVisible: { !hidden.contains($0) }, id: { $0 },
            orderedChildren: { children[$0, default: []] })
    }

    @Test("A 4096-level expanded chain retains every row and depth without recursion")
    func deepExpandedChain() {
        let children = Dictionary(uniqueKeysWithValues: (0..<4095).map { ($0, [$0 + 1]) })
        let projection = project(children: children)
        #expect(projection.rows.count == 4096)
        #expect(projection.rows.first?.depth == 0)
        #expect(projection.rows.last?.id == 4095)
        #expect(projection.rows.last?.depth == 4095)
        #expect(projection.rows.last?.parentID == 4094)
    }

    @Test("Cycles, self-links and repeated roots render each identity once")
    func cyclesAndRepeatedRoots() {
        let projection = project([0, 2, 0], children: [0: [1], 1: [2, 1], 2: [0]])
        #expect(projection.rows.map(\.id) == [0, 1, 2])
        #expect(projection.rows.map(\.depth) == [0, 1, 2])
    }

    @Test("Collapsed descendants keep their expansion choice after their ancestor reopens")
    func independentExpansionSurvivesAncestorCollapse() {
        let children = [0: [1, 4], 1: [2], 2: [3]]
        let childCollapsed = project(children: children, collapsed: [1])
        #expect(childCollapsed.rows.map(\.id) == [0, 1, 4])
        #expect(childCollapsed.rows.first(where: { $0.id == 1 })?.hasChildren == true)
        #expect(project(children: children, collapsed: [0, 1]).rows.map(\.id) == [0])
        #expect(project(children: children, collapsed: [1]).rows.map(\.id) == [0, 1, 4])
        #expect(project(children: children).rows.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test("A collapsed branch never queries descendants' children")
    func collapsedBranchIsNotTraversed() {
        var queried: [Int] = []
        let projection = TaskListHierarchyProjection(roots: [0], collapsedIDs: [0],
            isVisible: { _ in true }, id: { $0 }, orderedChildren: { node in
                queried.append(node)
                return [node + 1]
            })
        #expect(projection.rows.map(\.id) == [0])
        #expect(projection.rows.first?.hasChildren == true)
        #expect(queried == [0])
    }

    @Test("Hidden or detached branches are excluded before identity or child reads")
    func visibilityGuardsModelReads() {
        var identityReads: [Int] = []
        var childReads: [Int] = []
        let children = [0: [1, 4], 1: [2]]
        let projection = TaskListHierarchyProjection(roots: [9, 0],
            isVisible: { ![9, 1].contains($0) }, id: { node in
                identityReads.append(node)
                return node
            }, orderedChildren: { node in
                childReads.append(node)
                return children[node, default: []]
            })
        #expect(projection.rows.map(\.id) == [0, 4])
        #expect(!identityReads.contains(9))
        #expect(!identityReads.contains(1))
        #expect(childReads == [0, 4])
    }

    @Test("The supplied sibling order and each original sibling offset survive flattening")
    func siblingOrderAndOffsets() {
        let projection = project([0, 40], children: [0: [20, 10, 30], 20: [21]])
        #expect(projection.rows.map(\.id) == [0, 20, 21, 10, 30, 40])
        #expect(projection.rows.map(\.depth) == [0, 1, 2, 1, 1, 0])
        #expect(projection.rows.map(\.siblingIndex) == [0, 0, 0, 1, 2, 1])
        #expect(projection.rows.map(\.parentID) == [nil, 0, 20, 0, 0, nil])
    }

    @Test("Root moves use root offsets even when expanded descendants occupy rows")
    func rootMoveMapping() throws {
        let projection = project([0, 10, 20], children: [0: [1], 1: [2], 10: [11]])
        let upward = try #require(projection.move(from: IndexSet(integer: 5), to: 0))
        #expect(upward.parentID == nil)
        #expect(upward.source == IndexSet(integer: 2))
        #expect(upward.destination == 0)
        let downward = try #require(projection.move(from: IndexSet(integer: 0), to: 6))
        #expect(downward.source == IndexSet(integer: 0))
        #expect(downward.destination == 3)
        let insideOtherRoot = try #require(projection.move(from: IndexSet(integer: 5), to: 2))
        #expect(insideOtherRoot.destination == 1)
    }

    @Test("Sibling moves skip grandchildren and clamp to their original parent's group")
    func siblingMoveMapping() throws {
        let projection = project([0, 10], children: [0: [1, 4, 5], 1: [2], 2: [3], 10: [11]])
        // Visible rows: 0, 1, 2, 3, 4, 5, 10, 11.
        let upward = try #require(projection.move(from: IndexSet(integer: 5), to: 1))
        #expect(upward.parentID == 0)
        #expect(upward.parent == 0)
        #expect(upward.source == IndexSet(integer: 2))
        #expect(upward.destination == 0)
        let downward = try #require(projection.move(from: IndexSet(integer: 1), to: 8))
        #expect(downward.parentID == 0)
        #expect(downward.source == IndexSet(integer: 0))
        #expect(downward.destination == 3)
        let insideSibling = try #require(projection.move(from: IndexSet(integer: 5), to: 3))
        #expect(insideSibling.destination == 1)
    }

    @Test("Multiple sibling sources retain their offsets; mixed parents cannot reorder")
    func multipleSourcesAndMixedParents() throws {
        let projection = project([0, 10], children: [0: [1, 4, 5], 1: [2]])
        let move = try #require(projection.move(from: IndexSet([1, 4]), to: 5))
        #expect(move.parentID == 0)
        #expect(move.source == IndexSet([0, 2]))
        #expect(move.destination == 3)
        #expect(projection.move(from: IndexSet([0, 1]), to: 5) == nil)
        #expect(projection.move(from: IndexSet([1, 2]), to: 5) == nil)
    }

    @Test("Collapsed sibling subtrees do not change manual sibling offsets")
    func collapsedMoveMapping() throws {
        let projection = project(children: [0: [1, 4], 1: [2], 2: [3]], collapsed: [1])
        #expect(projection.rows.map(\.id) == [0, 1, 4])
        let move = try #require(projection.move(from: IndexSet(integer: 2), to: 1))
        #expect(move.parentID == 0)
        #expect(move.source == IndexSet(integer: 1))
        #expect(move.destination == 0)
    }

    @Test("Skipped cycle edges retain offsets into the original ordered siblings")
    func cycleEdgeMoveMapping() throws {
        let projection = project(children: [0: [0, 1, 2]])
        #expect(projection.rows.map(\.id) == [0, 1, 2])
        let move = try #require(projection.move(from: IndexSet(integer: 2), to: 1))
        #expect(move.source == IndexSet(integer: 2))
        #expect(move.destination == 1)
    }

    @Test("Stale, empty and out-of-range offsets cannot produce a reorder")
    func invalidMoveOffsets() {
        let projection = project(children: [0: [1]])
        #expect(projection.move(from: [], to: 0) == nil)
        #expect(projection.move(from: IndexSet(integer: 2), to: 0) == nil)
        #expect(projection.move(from: IndexSet(integer: 0), to: -1) == nil)
        #expect(projection.move(from: IndexSet(integer: 0), to: 3) == nil)
        #expect(project([], children: [:]).move(from: IndexSet(integer: 0), to: 0) == nil)
    }

    @Test("Ten thousand unloaded roots read children only for the roots activated on screen")
    func rootsAreActivatedLazily() {
        var states = Array(repeating: TaskListRootHierarchyState<Int, Int>(), count: 10_000)
        var childReads: [Int] = []
        let build: (Int) -> TaskListHierarchyProjection<Int, Int> = { root in
            TaskListHierarchyProjection(roots: [root], isVisible: { _ in true },
                id: { $0 }, orderedChildren: { node in
                    childReads.append(node)
                    return []
                })
        }
        #expect(childReads.isEmpty)
        #expect(states.allSatisfy { $0.projection == nil })
        states[0].activate { build(0) }
        states[9999].activate { build(9999) }
        states[0].activate { build(0) }
        #expect(childReads == [0, 9999])
        #expect(states[0].projection?.rows.map(\.id) == [0])
        #expect(states[9999].projection?.rows.map(\.id) == [9999])
        #expect(states[5000].projection == nil)
    }

    @Test("An offscreen root invalidates its cache without reading relationships")
    func offscreenInvalidationDefersProjection() {
        var state = TaskListRootHierarchyState<Int, Int>()
        var builds = 0
        var children = [0: [1]]
        let build: () -> TaskListHierarchyProjection<Int, Int> = {
            builds += 1
            return project(children: children)
        }
        state.activate(build)
        #expect(builds == 1)
        #expect(state.projection?.rows.map(\.id) == [0, 1])
        children = [0: [2]]
        state.invalidate()
        #expect(builds == 1)
        #expect(state.needsRefresh)
        #expect(state.projection?.rows.map(\.id) == [0, 1])
        state.activate(build)
        #expect(builds == 2)
        #expect(!state.needsRefresh)
        #expect(state.projection?.rows.map(\.id) == [0, 2])
    }

    @Test("Deep rows keep readable widths while retaining their real hierarchy depth")
    func indentationIsBounded() {
        #expect(TaskListHierarchyLayout.visualDepth(0) == 0)
        #expect(TaskListHierarchyLayout.visualDepth(1) == 1)
        #expect(TaskListHierarchyLayout.visualDepth(4) == 4)
        #expect(TaskListHierarchyLayout.visualDepth(2000) == 4)
        #expect(TaskListHierarchyLayout.visualDepth(4095) == 4)
        let projection = project(children: Dictionary(uniqueKeysWithValues:
            (0..<4095).map { ($0, [$0 + 1]) }))
        #expect(projection.rows.last?.depth == 4095)
    }
    @Test("Committed query revisions refresh a cached tree without resetting expansion")
    func inboundRevisionInvalidatesCachedTree() {
        var state = TaskListRootHierarchyState<Int, Int>()
        var children = [1]
        func build() -> TaskListHierarchyProjection<Int, Int> {
            TaskListHierarchyProjection(roots: [0], isVisible: { _ in true }, id: { $0 },
                orderedChildren: { $0 == 0 ? children : [] })
        }
        state.activate(build)
        #expect(state.projection?.rows.map(\.id) == [0, 1])
        children = [2]
        state.receiveRevision(1)
        #expect(state.needsRefresh)
        state.activate(build)
        #expect(state.projection?.rows.map(\.id) == [0, 2])
        state.receiveRevision(1)
        #expect(!state.needsRefresh)
        state.receiveRevision(2)
        #expect(state.needsRefresh)
    }

}
