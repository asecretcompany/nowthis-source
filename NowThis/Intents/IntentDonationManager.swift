import AppIntents
import Foundation

/// Centralized manager for donating successful in-app actions to Siri.
enum IntentDonationManager {

    /// Build replayable parameters without contacting the system donation service.
    static func makeCreateTaskIntent(title: String, list: TaskListEntity?) -> CreateTaskIntent? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let intent = CreateTaskIntent()
        intent.taskTitle = title
        intent.list = list
        return intent
    }

    static func makeCompleteTaskIntent(task: TaskEntity) -> CompleteTaskIntent? {
        guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CompleteTaskIntent(task: task)
    }

    /// Donate after the task creation has committed.
    static func donateCreateTask(title: String, list: TaskListEntity?) {
        makeCreateTaskIntent(title: title, list: list)?.donate()
    }

    /// Receive a value snapshot, never reconstruct an identity from its display title.
    static func donateCompleteTask(task: TaskEntity) {
        makeCompleteTaskIntent(task: task)?.donate()
    }
}
