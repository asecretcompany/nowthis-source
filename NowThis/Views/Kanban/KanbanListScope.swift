import Foundation
import SwiftData

/// Which list the Board is scoped to, resolved the same way for both board modes.
///
/// The Status columns and the Lists swipe pages used to hold their own, unconnected
/// selection, so a list chosen in one mode was invisible to the other and switching
/// modes dropped the user back on whichever list sorted first. Both modes now store
/// one id and resolve it here.
///
/// The stored id outlives the list it names — it is persisted across launches, and a
/// list can be deleted locally or by an inbound sync — so resolution always falls
/// back rather than returning nothing. Routing the toolbar label and the column
/// filter through the one rule is what stops them disagreeing: the label used to
/// fall back on "no match" while the filter fell back only on "nil", which showed a
/// real list's name above three empty columns.
enum KanbanListScope {

    /// The stored value before the user has picked a list. The board falls back
    /// to the first list until then.
    static let unset = ""

    /// The list the board is scoped to, or `nil` when there are no lists at all.
    ///
    /// - Parameters:
    ///   - id: The persisted `TaskList.id`, or ``unset``.
    ///   - lists: The board's lists, already ordered and known to be live.
    static func resolvedList(id: String, in lists: [TaskList]) -> TaskList? {
        lists.first { $0.id == id } ?? lists.first
    }

    /// The tasks the board shows for the scoped list, before either mode applies
    /// its own rule about status.
    ///
    /// Resolving the same *list* in both modes was only half the problem: each
    /// mode then decided for itself what that list contains. Status mode matched
    /// on the list alone, so a subtask appeared as a card of its own beside its
    /// parent, and the same list showed a different number of tasks depending on
    /// which mode you were in. Three clauses, in this order, each load-bearing:
    ///
    /// - **Liveness first**, so the two reads after it are safe. Deleting an
    ///   account cascades `ServerAccount` -> `TaskList` -> `TaskItem` on the main
    ///   context, and deleting a list cascades to its tasks; a board still on
    ///   screen then re-renders over the stale array. Reading `status` — a stored
    ///   attribute — on one of those traps in SwiftData rather than returning
    ///   nothing. `&&` short-circuits, which is the whole reason this clause is
    ///   written first rather than last.
    /// - **`parentTask == nil`**, because a subtask belongs to its parent's card,
    ///   not beside it. This is the clause the Lists pages already had.
    /// - **The list match**, `nil` included: with no list resolved there is
    ///   nothing to show, which is not the same as showing everything.
    ///
    /// What deliberately stays outside: completed tasks. Status mode has a Done
    /// column and always shows them; the Lists pages hide them behind
    /// `showCompletedTasks`. That difference is the feature, so each mode layers
    /// it on top rather than this function guessing.
    static func scopedTasks(_ tasks: [TaskItem], inListWithID listID: String?) -> [TaskItem] {
        tasks.filter { task in
            task.modelContext != nil
                && task.parentTask == nil
                && task.taskList?.id == listID
        }
    }

    /// Whether the list holds nothing at all, as opposed to holding only
    /// completed tasks that the current filter is hiding.
    ///
    /// A page with no rows has two quite different causes and the swipe view
    /// gave the user the wrong one, saying *"All tasks in X are completed."*
    /// whenever the page was empty — including for a list that has never held a
    /// task. A list showing `0 tasks` claimed every task in it was finished.
    ///
    /// The two are exactly distinguishable, and the completed filter is why:
    /// it is the only thing between these tasks and the visible ones. So if the
    /// scope holds something while the page shows nothing, what it holds is
    /// completed and hidden, and nothing else can produce that combination.
    static func listIsEmpty(_ tasks: [TaskItem], inListWithID listID: String?) -> Bool {
        scopedTasks(tasks, inListWithID: listID).isEmpty
    }

    /// A Lists page's rows, in the list's manual order.
    ///
    /// The pages used to keep the board's `@Query` order, newest first by
    /// creation date, while the Status columns follow the list's manual order —
    /// so a card moved to the top of To Do could sit anywhere on its page. Both
    /// now order through ``KanbanReorder/columnOrder(_:)``, which makes each
    /// status's rows on a page read in the order its Status column shows them.
    static func pageTasks(_ tasks: [TaskItem], inListWithID listID: String?,
                          showCompleted: Bool) -> [TaskItem] {
        KanbanReorder.columnOrder(
            scopedTasks(tasks, inListWithID: listID)
                .filter { showCompleted || $0.status != .completed }
        )
    }
}
