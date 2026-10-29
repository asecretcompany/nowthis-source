import Testing
import Foundation

@testable import NowThis

// MARK: - KanbanAutoScroll Tests
//
// On a phone a board column is 280pt of a ~400pt screen, so only the edge of
// the next column shows and a dragged card could reach no column beyond it.
// A drag that rests on a column only partly on screen now scrolls the board to
// it. These tests pin which way: far enough to show that column whole, lined up
// so the next column in the direction of travel peeks in for the drag to carry
// on into. The scrolling itself is verified in the simulator.

@Suite("Kanban Auto-Scroll")
struct KanbanAutoScrollTests {

    /// iPhone 17's width, and a column's 294pt drop area.
    private let width: CGFloat = 402

    @Test("A column cut off on the right is lined up on the left, so the next one peeks")
    func cutOffOnTheRight() {
        #expect(KanbanAutoScroll.alignment(forColumnFrom: 303, to: 597, inViewportOfWidth: width)
                == .leading)
    }

    @Test("A column cut off on the left is lined up on the right, so the previous one peeks")
    func cutOffOnTheLeft() {
        #expect(KanbanAutoScroll.alignment(forColumnFrom: -55, to: 239, inViewportOfWidth: width)
                == .trailing)
    }

    /// The column a card is picked up from is on screen already, as is every
    /// column on an iPad. Scrolling to one of those would throw the board
    /// sideways under a drag that is only passing over.
    @Test("A column already whole on screen does not scroll the board")
    func wholeColumnStaysPut() {
        #expect(KanbanAutoScroll.alignment(forColumnFrom: 9, to: 303, inViewportOfWidth: width) == nil)
        #expect(KanbanAutoScroll.alignment(forColumnFrom: 0, to: 294, inViewportOfWidth: width) == nil)
        #expect(KanbanAutoScroll.alignment(forColumnFrom: 108, to: 402, inViewportOfWidth: width) == nil)
    }

    /// Layout lands on fractional points, so a column that is whole to the eye
    /// can measure a hair past the edge.
    @Test("Less than a point past the edge counts as whole")
    func subPointOverhangIsWhole() {
        #expect(KanbanAutoScroll.alignment(forColumnFrom: -0.4, to: 293.6, inViewportOfWidth: width) == nil)
        #expect(KanbanAutoScroll.alignment(forColumnFrom: 108.3, to: 402.3, inViewportOfWidth: width) == nil)
    }
}
