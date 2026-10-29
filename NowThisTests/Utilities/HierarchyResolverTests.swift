import Foundation
import Testing

@testable import NowThis

@Suite("HierarchyResolver")
struct HierarchyResolverTests {
    @Test("Nil parent values are omitted")
    func nilParentsAreOmitted() {
        let resolved = HierarchyResolver.resolvedParents(["child": nil])

        #expect(resolved.isEmpty)
    }

    @Test("A parent missing from the raw mapping is omitted")
    func missingParentIsOmitted() {
        let resolved = HierarchyResolver.resolvedParents(["child": "missing"])

        #expect(resolved.isEmpty)
    }

    @Test("A child whose parent became missing is omitted")
    func changedMissingParentIsOmitted() {
        let initiallyPresent: [String: String?] = [
            "child": "parent",
            "parent": nil
        ]
        let parentWasRemoved: [String: String?] = ["child": "parent"]

        #expect(HierarchyResolver.resolvedParents(initiallyPresent) == ["child": "parent"])
        #expect(HierarchyResolver.resolvedParents(parentWasRemoved).isEmpty)
    }

    @Test("Self-parent edges are omitted")
    func selfParentIsOmitted() {
        let resolved = HierarchyResolver.resolvedParents(["same": "same"])

        #expect(resolved.isEmpty)
    }

    @Test("Every edge in a two-node cycle is omitted")
    func twoNodeCycleIsOmitted() {
        let resolved = HierarchyResolver.resolvedParents([
            "a": "b",
            "b": "a"
        ])

        #expect(resolved.isEmpty)
    }

    @Test("Every edge in a three-node cycle is omitted")
    func threeNodeCycleIsOmitted() {
        let resolved = HierarchyResolver.resolvedParents([
            "a": "b",
            "b": "c",
            "c": "a"
        ])

        #expect(resolved.isEmpty)
    }

    @Test("Valid ancestors leading into a cycle are retained")
    func ancestorsLeadingIntoCycleAreRetained() {
        let resolved = HierarchyResolver.resolvedParents([
            "leaf": "branch",
            "branch": "a",
            "a": "b",
            "b": "a"
        ])

        #expect(resolved == ["leaf": "branch", "branch": "a"])
    }

    @Test("A chain resolves when children precede their parents")
    func childBeforeParentChainIsRetained() {
        let resolved = HierarchyResolver.resolvedParents([
            "leaf": "middle",
            "middle": "root",
            "root": nil
        ])

        #expect(resolved == ["leaf": "middle", "middle": "root"])
    }

    @Test("A deep chain is handled iteratively")
    func deepChainIsRetained() {
        let count = 50_000
        var rawParents: [String: String?] = [:]
        for index in 0..<count {
            rawParents.updateValue(
                index + 1 < count ? "node\(index + 1)" : nil,
                forKey: "node\(index)"
            )
        }

        let resolved = HierarchyResolver.resolvedParents(rawParents)

        #expect(resolved.count == count - 1)
        #expect(resolved["node0"] == "node1")
        #expect(resolved["node\(count - 2)"] == "node\(count - 1)")
    }

    @Test("Results do not depend on dictionary insertion order")
    func resultIsIndependentOfInsertionOrder() {
        let forward: [String: String?] = [
            "leaf": "branch",
            "branch": "a",
            "a": "b",
            "b": "a",
            "root": nil
        ]
        let reverse: [String: String?] = [
            "root": nil,
            "b": "a",
            "a": "b",
            "branch": "a",
            "leaf": "branch"
        ]

        #expect(
            HierarchyResolver.resolvedParents(forward)
                == HierarchyResolver.resolvedParents(reverse)
        )
    }
}
