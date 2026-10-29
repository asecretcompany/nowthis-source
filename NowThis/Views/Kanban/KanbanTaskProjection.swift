import Foundation

/// Groups live roots once. Columns and pages share the same manual ordering.
struct KanbanTaskProjection {
    private var lists: [String: [TaskItem]] = [:]
    private var columns: [String: [TaskStatus: [TaskItem]]] = [:]

    init(tasks: [TaskItem]) {
        let trace = PerformanceTrace.begin("BoardProjection", count: tasks.count)
        defer { PerformanceTrace.end("BoardProjection", trace) }
        let roots = tasks.filter {
            $0.modelContext != nil && !$0.isDeletedLocally && $0.parentTask == nil
        }
        for task in KanbanReorder.columnOrder(roots) {
            guard let listID = task.taskList?.id else { continue }
            lists[listID, default: []].append(task)
            columns[listID, default: [:]][task.status, default: []].append(task)
        }
    }

    func column(_ status: TaskStatus, listID: String?) -> [TaskItem] {
        guard let listID else { return [] }
        return columns[listID]?[status] ?? []
    }

    func page(listID: String?, showCompleted: Bool) -> [TaskItem] {
        guard let listID else { return [] }
        let rows = lists[listID] ?? []
        return showCompleted ? rows : rows.filter { $0.status != .completed }
    }

    func isEmpty(listID: String?) -> Bool {
        guard let listID else { return true }
        return lists[listID]?.isEmpty ?? true
    }
}
