import Foundation
import SwiftData
import Testing
@testable import NowThis

@Suite("Board grouped projections")
@MainActor
struct KanbanTaskProjectionTests {
    @Test("The Board's consumed descriptor scopes Status reads and keeps Lists reads global")
    func boardDescriptorScopesTheQueryBeforeProjection() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let lists = (0..<100).map { index in
            TaskList(serverURL: "https://board.invalid/\(index)", name: "List \(index)", colorHex: "#3478F6")
        }
        lists.forEach(context.insert)
        var rows: [TaskItem] = []
        for index in 0..<10_000 {
            let row = TaskItem(id: "task-\(index)", title: "Task \(index)")
            row.taskList = lists[index % lists.count]
            row.manualSortOrder = index
            context.insert(row)
            rows.append(row)
        }
        try context.save()

        let descriptor = KanbanBoardView.taskDescriptor(mode: .statusBoard, selectedListID: lists[37].id)
        let selectedRows = try context.fetch(descriptor)
        #expect(selectedRows.count == 100)
        let projected = KanbanTaskProjection(tasks: selectedRows)
        #expect(projected.column(.needsAction, listID: lists[37].id).map(\.id) ==
                rows.filter { $0.taskList?.id == lists[37].id }.sorted { $0.manualSortOrder < $1.manualSortOrder }.map(\.id))

        let listSwipeDescriptor = KanbanBoardView.taskDescriptor(mode: .listSwipe, selectedListID: lists[37].id)
        #expect(try context.fetch(listSwipeDescriptor).count == 10_000)
        let noSelection = KanbanBoardView.taskDescriptor(mode: .statusBoard, selectedListID: nil)
        #expect(try context.fetch(noSelection).isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test("Columns and pages preserve manual order, root scope and hidden-completed emptiness")
    func groupedRowsMatchExistingScope() throws {
        let container = try DAVSyncScenario.container()
        let context = container.mainContext
        let a = TaskList(serverURL: "https://board.invalid/a", name: "A", colorHex: "#3478F6")
        let b = TaskList(serverURL: "https://board.invalid/b", name: "B", colorHex: "#3478F6")
        let empty = TaskList(serverURL: "https://board.invalid/empty", name: "Empty", colorHex: "#3478F6")
        [a, b, empty].forEach { context.insert($0) }
        var rows: [TaskItem] = []
        for (id, status, order, list) in [
            ("late", TaskStatus.needsAction, 400, a),
            ("first", .needsAction, 100, a), ("done", .completed, 200, a),
            ("cancelled", .cancelled, 300, a), ("onlyDone", .completed, 100, b)
        ] {
            let row = TaskItem(id: id, title: id); row.status = status
            row.manualSortOrder = order; row.taskList = list
            context.insert(row); rows.append(row)
        }
        let child = TaskItem(id: "child", title: "child"); child.parentTask = rows[0]; child.taskList = a
        context.insert(child); rows.append(child)
        let deleted = TaskItem(id: "deleted", title: "deleted"); deleted.taskList = a; deleted.isDeletedLocally = true
        context.insert(deleted); rows.append(deleted)
        try context.save()
        let projection = KanbanTaskProjection(tasks: rows)
        #expect(projection.column(.needsAction, listID: a.id).map(\.id) == ["first", "late"])
        #expect(projection.page(listID: a.id, showCompleted: false).map(\.id) == ["first", "cancelled", "late"])
        #expect(projection.page(listID: a.id, showCompleted: true).map(\.id) == ["first", "done", "cancelled", "late"])
        #expect(projection.page(listID: b.id, showCompleted: false).isEmpty)
        #expect(!projection.isEmpty(listID: b.id))
        #expect(projection.isEmpty(listID: empty.id))
        #expect(projection.column(.needsAction, listID: nil).isEmpty)
        withExtendedLifetime(container) {}
    }
}
