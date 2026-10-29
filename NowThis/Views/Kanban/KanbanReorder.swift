import Foundation

/// Where a card goes when it is dropped on, or moved within, a board column.
///
/// `manualSortOrder` is one sequence per list — the one the task list sorts by when
/// set to Manually, and the one that syncs as `X-APPLE-SORT-ORDER` — but a column
/// shows only one status's slice of it. Renumbering a column to fit a moved card
/// would push its values past other columns' and reshuffle the list's own manual
/// order, and would mark every card in the column for upload over a single drag.
/// So a moved card takes a value between its two new neighbours and nothing else
/// is written. The column is renumbered only when those neighbours leave no
/// integer between them, which happens when several tasks share a seeded value.
///
/// An index here always counts the column's *other* cards — the column without
/// the ones being moved. The drop position and the Move actions both measure it
/// that way, and ``place(_:at:among:)`` reads it that way.
enum KanbanReorder {

    /// The moves a card's menu and its VoiceOver actions offer.
    enum Move: CaseIterable {
        case top, up, down, bottom
    }

    /// A column's cards in board order: the list's manual order, lowest first.
    ///
    /// Ordered by `effectiveSortOrder` rather than the raw stored value, because
    /// that is what a push writes to the server. Ties — tasks that arrived in one
    /// sync without a sort order share their seeded value — fall back to creation
    /// date and then id, so two cards cannot swap places from one render to the
    /// next. Each value is read once per task rather than once per comparison.
    static func columnOrder(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks
            .map { (order: $0.effectiveSortOrder, created: $0.createdDate, id: $0.id, task: $0) }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                if lhs.created != rhs.created { return lhs.created < rhs.created }
                return lhs.id < rhs.id
            }
            .map { $0.task }
    }

    /// Where a drop lands among the column's other cards.
    ///
    /// The column is a lazy stack, so a card scrolled out of view has no position
    /// to report. Those are skipped rather than counted: the drop goes in front of
    /// the first laid-out card whose middle is below it, or after the last one
    /// above it. A card the stack has not reached is never between the two.
    ///
    /// - Parameters:
    ///   - y: The drop's vertical position in the column's coordinate space.
    ///   - midYs: Each other card's vertical middle in the same space, in board
    ///     order, or `nil` for a card that is not laid out.
    static func insertionIndex(forDropAtY y: CGFloat, cardMidYs midYs: [CGFloat?]) -> Int {
        var afterLastAbove: Int?
        for (index, midY) in midYs.enumerated() {
            guard let midY else { continue }
            if y < midY { return index }
            afterLastAbove = index + 1
        }
        return afterLastAbove ?? midYs.count
    }

    /// Sort values for `count` cards placed, in order, between two neighbours, or
    /// `nil` when there are not enough free integers between them.
    ///
    /// The ends of a column always have room. They step by
    /// `TaskListHelpers.manualSortSpacing` rather than by one, so the next card
    /// dropped beside this one finds a gap waiting.
    ///
    /// - Parameters:
    ///   - above: The sort value of the card that will sit above, or `nil` at the top.
    ///   - below: The sort value of the card that will sit below, or `nil` at the bottom.
    static func sortOrders(count: Int, between above: Int?, and below: Int?) -> [Int]? {
        guard count > 0 else { return [] }
        let spacing = TaskListHelpers.manualSortSpacing
        switch (above, below) {
        case (nil, nil):
            return nil
        case (nil, let below?):
            return (0..<count).map { below - (count - $0) * spacing }
        case (let above?, nil):
            return (1...count).map { above + $0 * spacing }
        case (let above?, let below?):
            let gap = below - above
            guard gap > count else { return nil }
            return (1...count).map { above + gap * $0 / (count + 1) }
        }
    }

    /// Places `moving` at `index` among `others`, writing as few sort values as it can.
    ///
    /// A card whose value already sits between its new neighbours — one dropped
    /// back where it was, or one arriving from another column at the place its
    /// value already implies — is left alone and not marked for upload.
    ///
    /// - Parameters:
    ///   - moving: The cards being placed. They keep their order relative to each other.
    ///   - index: Where they go, counted among `others`. Clamped to the column.
    ///   - others: The destination column's other cards, in ``columnOrder(_:)``.
    static func place(_ moving: [TaskItem], at index: Int, among others: [TaskItem]) {
        guard !moving.isEmpty else { return }
        let moving = columnOrder(moving)
        let index = min(max(index, 0), others.count)
        let above = index > 0 ? others[index - 1].effectiveSortOrder : nil
        let below = index < others.count ? others[index].effectiveSortOrder : nil

        let current = moving.map(\.effectiveSortOrder)
        let ascending = zip(current, current.dropFirst()).allSatisfy { $0 < $1 }
        let clearsAbove = above.map { $0 < current[0] } ?? true
        let clearsBelow = below.map { current[current.count - 1] < $0 } ?? true
        if ascending && clearsAbove && clearsBelow { return }

        if let values = sortOrders(count: moving.count, between: above, and: below) {
            for (task, value) in zip(moving, values) {
                task.manualSortOrder = value
                task.isDirty = true
                task.lastModifiedDate = Date()
            }
        } else {
            var column = others
            column.insert(contentsOf: moving, at: index)
            TaskListHelpers.assignManualOrder(column)
        }
    }

    /// The index `move` sends the card at `position` to, counted among the
    /// column's other cards, or `nil` when the card is already at that end.
    ///
    /// - Parameters:
    ///   - position: The card's place in the whole column.
    ///   - count: How many cards the whole column holds, this one included.
    static func targetIndex(for move: Move, from position: Int, count: Int) -> Int? {
        let isFirst = position <= 0
        let isLast = position >= count - 1
        switch move {
        case .top: return isFirst ? nil : 0
        case .up: return isFirst ? nil : position - 1
        case .down: return isLast ? nil : position + 1
        case .bottom: return isLast ? nil : count - 1
        }
    }
}
