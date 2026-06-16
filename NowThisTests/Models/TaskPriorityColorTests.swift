import Testing
import SwiftUI

@testable import NowThis

// MARK: - TaskPriority Color Tests

@Suite("TaskPriority Color")
struct TaskPriorityColorTests {

    @Test("Each priority maps to its expected semantic color")
    func priorityColors() {
        // These mirror the colors previously duplicated across the task,
        // calendar, kanban, and widget views. System colors adapt to
        // Light/Dark automatically.
        #expect(TaskPriority.high.color == .red)
        #expect(TaskPriority.medium.color == .orange)
        #expect(TaskPriority.low.color == .blue)
        #expect(TaskPriority.none.color == .secondary)
    }
}
