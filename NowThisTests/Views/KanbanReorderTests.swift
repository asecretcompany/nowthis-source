import Testing
import Foundation

@testable import NowThis

// MARK: - KanbanReorder Tests
//
// Regression coverage for "drag and drop doesn't work well on the board". The
// board could only change a card's status: dropping a card inside its own
// column was an explicit no-op, the columns ignored `manualSortOrder` and
// showed newest first by creation date, and VoiceOver had no way to reorder
// at all.
//
// These tests pin the pure rules — the order a column shows, where a drop
// lands, and which sort values a move writes. The SwiftUI wiring (card
// frames, the drop location, the menu) is verified in the simulator.

@Suite("Kanban Reorder")
struct KanbanReorderTests {

    /// A task with a known sort value and a clean sync flag, so a test can
    /// tell exactly which cards a move marked for upload.
    private func card(_ title: String, order: Int) -> TaskItem {
        let task = TaskItem(title: title)
        task.manualSortOrder = order
        task.isDirty = false
        return task
    }

    private func titles(_ tasks: [TaskItem]) -> [String] {
        KanbanReorder.columnOrder(tasks).map(\.title)
    }

    // MARK: - Column order

    @Test("A column shows the list's manual order, lowest first")
    func columnFollowsManualOrder() {
        let a = card("A", order: 1_000)
        let b = card("B", order: 2_000)
        let c = card("C", order: 3_000)

        #expect(titles([c, a, b]) == ["A", "B", "C"])
    }

    /// `effectiveSortOrder` is what a push writes as `X-APPLE-SORT-ORDER`, so
    /// the board orders by it rather than by the raw stored value.
    @Test("A task with no stored order sits where its creation time puts it")
    func legacyZeroSortsByEffectiveOrder() {
        let early = card("Early", order: 5)
        let legacy = card("Legacy", order: 0) // effective value: creation seconds
        let late = card("Late", order: Int.max / 2)

        #expect(titles([late, legacy, early]) == ["Early", "Legacy", "Late"])
    }

    /// Tasks that arrive in one sync without an `X-APPLE-SORT-ORDER` share a
    /// seeded value. Without a tiebreak they could swap places between renders.
    @Test("Cards sharing a sort value keep one order whatever order they arrive in")
    func tiesAreDeterministic() {
        let first = card("First", order: 500)
        let second = card("Second", order: 500)
        second.createdDate = first.createdDate.addingTimeInterval(1)

        #expect(titles([second, first]) == ["First", "Second"])
        #expect(titles([first, second]) == ["First", "Second"])
    }

    // MARK: - Drop position

    @Test("A drop lands before the first card whose middle is below it")
    func dropLandsBeforeFirstCardBelow() {
        let midYs: [CGFloat?] = [100, 200, 300]

        #expect(KanbanReorder.insertionIndex(forDropAtY: 50, cardMidYs: midYs) == 0)
        #expect(KanbanReorder.insertionIndex(forDropAtY: 150, cardMidYs: midYs) == 1)
        #expect(KanbanReorder.insertionIndex(forDropAtY: 250, cardMidYs: midYs) == 2)
        #expect(KanbanReorder.insertionIndex(forDropAtY: 350, cardMidYs: midYs) == 3)
        #expect(KanbanReorder.insertionIndex(forDropAtY: 80, cardMidYs: []) == 0)
    }

    /// The column is a lazy stack, so a card scrolled out of view reports no
    /// position. Counting it as "not above the drop" would send every drop in
    /// a scrolled column to the top.
    @Test("Cards scrolled off the top don't pull a drop to the top of the column")
    func unmeasuredCardsAboveAreSkipped() {
        let midYs: [CGFloat?] = [nil, nil, 300, 400]

        #expect(KanbanReorder.insertionIndex(forDropAtY: 250, cardMidYs: midYs) == 2)
        #expect(KanbanReorder.insertionIndex(forDropAtY: 350, cardMidYs: midYs) == 3)
    }

    @Test("A drop below the last visible card lands above the ones not yet laid out")
    func unmeasuredCardsBelowStayBelow() {
        let midYs: [CGFloat?] = [100, 200, nil, nil]

        #expect(KanbanReorder.insertionIndex(forDropAtY: 250, cardMidYs: midYs) == 2)
    }

    // MARK: - Sort values

    @Test("A card moved between two neighbours takes a value between them")
    func valueBetweenNeighbours() {
        #expect(KanbanReorder.sortOrders(count: 1, between: 1_000, and: 2_000) == [1_500])
    }

    @Test("Several cards moved together get distinct values, in order")
    func severalValuesBetween() {
        #expect(KanbanReorder.sortOrders(count: 3, between: 0, and: 8) == [2, 4, 6])
    }

    @Test("Neighbours with no free integer between them leave no room")
    func noRoomBetweenNeighbours() {
        #expect(KanbanReorder.sortOrders(count: 1, between: 7, and: 8) == nil)
        #expect(KanbanReorder.sortOrders(count: 1, between: 7, and: 7) == nil)
        #expect(KanbanReorder.sortOrders(count: 2, between: 7, and: 9) == nil)
    }

    @Test("The top and bottom of a column always have room")
    func endsAlwaysHaveRoom() {
        let spacing = TaskListHelpers.manualSortSpacing

        #expect(KanbanReorder.sortOrders(count: 1, between: nil, and: 5_000) == [5_000 - spacing])
        #expect(KanbanReorder.sortOrders(count: 1, between: 5_000, and: nil) == [5_000 + spacing])
        #expect(KanbanReorder.sortOrders(count: 2, between: 5_000, and: nil)
                == [5_000 + spacing, 5_000 + 2 * spacing])
    }

    // MARK: - Placing a card

    /// `manualSortOrder` is one sequence per list, shared with the task list's
    /// Manually sort. Renumbering the column would reshuffle that order and
    /// upload every card in the column for a single drag.
    @Test("Moving a card writes that card and no other")
    func moveTouchesOneCard() {
        let a = card("A", order: 1_000)
        let b = card("B", order: 2_000)
        let c = card("C", order: 3_000)

        KanbanReorder.place([c], at: 1, among: [a, b])

        #expect(titles([a, b, c]) == ["A", "C", "B"])
        #expect(c.isDirty)
        #expect(!a.isDirty)
        #expect(!b.isDirty)
        #expect(a.manualSortOrder == 1_000)
        #expect(b.manualSortOrder == 2_000)
    }

    @Test("A card dropped back where it was is left alone and not uploaded")
    func dropInPlaceIsANoOp() {
        let a = card("A", order: 1_000)
        let b = card("B", order: 2_000)
        let c = card("C", order: 3_000)

        KanbanReorder.place([b], at: 1, among: [a, c])

        #expect(b.manualSortOrder == 2_000)
        #expect(!b.isDirty)
    }

    @Test("With no room between the neighbours, the column is renumbered")
    func noRoomRenumbersTheColumn() {
        // Two tasks that arrived in one sync share a sort value.
        let a = card("A", order: 1_000)
        let b = card("B", order: 1_000)
        let c = card("C", order: 5_000)

        KanbanReorder.place([c], at: 1, among: [a, b])

        #expect(titles([a, b, c]) == ["A", "C", "B"])
        #expect(!a.isDirty) // already at the anchor
        #expect(b.isDirty)
        #expect(c.isDirty)
    }

    @Test("A card moved to the top of its column goes above the first card")
    func moveToTop() {
        let a = card("A", order: 1_000)
        let b = card("B", order: 2_000)

        KanbanReorder.place([b], at: 0, among: [a])

        #expect(titles([a, b]) == ["B", "A"])
        #expect(!a.isDirty)
    }

    // MARK: - Move actions

    @Test("Move actions target the right slot among the column's other cards")
    func moveTargets() {
        // The card at position 2 of 5.
        #expect(KanbanReorder.targetIndex(for: .top, from: 2, count: 5) == 0)
        #expect(KanbanReorder.targetIndex(for: .up, from: 2, count: 5) == 1)
        #expect(KanbanReorder.targetIndex(for: .down, from: 2, count: 5) == 3)
        #expect(KanbanReorder.targetIndex(for: .bottom, from: 2, count: 5) == 4)
    }

    @Test("A card already at an end is offered no move past it")
    func noMovePastTheEnds() {
        #expect(KanbanReorder.targetIndex(for: .top, from: 0, count: 3) == nil)
        #expect(KanbanReorder.targetIndex(for: .up, from: 0, count: 3) == nil)
        #expect(KanbanReorder.targetIndex(for: .down, from: 2, count: 3) == nil)
        #expect(KanbanReorder.targetIndex(for: .bottom, from: 2, count: 3) == nil)
        #expect(KanbanReorder.targetIndex(for: .up, from: 0, count: 1) == nil)
    }

    /// The Move actions and `place` must agree on what an index counts — the
    /// column's other cards, not including the one being moved.
    @Test("Move Down puts the card after the one that was below it")
    func moveDownThroughPlace() throws {
        let a = card("A", order: 1_000)
        let b = card("B", order: 2_000)
        let c = card("C", order: 3_000)

        let target = try #require(KanbanReorder.targetIndex(for: .down, from: 0, count: 3))
        KanbanReorder.place([a], at: target, among: [b, c])

        #expect(titles([a, b, c]) == ["B", "A", "C"])
    }
}
