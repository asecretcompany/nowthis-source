import Foundation

/// Which way the board scrolls when a drag rests on a column only partly on screen.
///
/// On a phone a column is 280pt of a ~400pt screen, so only the edge of the next
/// column shows and a dragged card could reach no column beyond it: moving one
/// from To Do to Done took a drop in In Progress and a second drag. The board now
/// scrolls just far enough to show the column whole, lined up against the edge
/// it was cut off by — so the column after it, in the direction the drag is
/// travelling, peeks in for the drag to carry on into.
enum KanbanAutoScroll {

    /// The edge of the screen the column is lined up against.
    enum Alignment: Equatable {
        case leading, trailing
    }

    /// Layout lands on fractional points, so a column that is whole to the eye can
    /// measure a hair past the edge. Less than this still counts as whole.
    private static let tolerance: CGFloat = 1

    /// How to scroll a column into view, or `nil` when it is on screen already —
    /// the column a card was picked up from, or any column on an iPad, where the
    /// board would otherwise lurch sideways under a drag only passing over it.
    ///
    /// - Parameters:
    ///   - minX: The column's leading edge, in the board's visible coordinates.
    ///   - maxX: The column's trailing edge, in the same coordinates.
    ///   - width: The width of the board's visible area.
    static func alignment(forColumnFrom minX: CGFloat, to maxX: CGFloat,
                          inViewportOfWidth width: CGFloat) -> Alignment? {
        if maxX > width + tolerance { return .leading }
        if minX < -tolerance { return .trailing }
        return nil
    }
}
