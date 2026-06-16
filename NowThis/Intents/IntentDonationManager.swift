import AppIntents
import Intents

/// Centralized manager for donating user interactions to Siri for proactive suggestions.
///
/// Call these methods after the user performs actions in the UI so Siri can learn
/// usage patterns and suggest shortcuts at relevant times.
enum IntentDonationManager {

    /// Donate a "create task" interaction after the user creates a task.
    static func donateCreateTask(title: String, listName: String?) {
        let intent = CreateTaskIntent()
        intent.donate()
    }

    /// Donate a "complete task" interaction after the user completes a task.
    static func donateCompleteTask(title: String) {
        let intent = CompleteTaskIntent()
        intent.donate()
    }
}
