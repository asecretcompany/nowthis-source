import Foundation
import Observation

@MainActor
@Observable
final class TaskTextDraft {
    var title: String
    var notes: String
    private var originalTitle: String
    private var originalNotes: String

    convenience init(_ task: TaskItem) {
        self.init(title: task.title, notes: task.descriptionText ?? "")
    }

    init(title: String = "", notes: String = "") {
        self.title = title
        self.notes = notes
        originalTitle = title
        originalNotes = notes
    }
    var hasChanges: Bool { title != originalTitle || notes != originalNotes }
    func discard() { title = originalTitle; notes = originalNotes }
    /// Sync may update an open editor. Refresh only fields the user hasn't edited.
    func refresh(from task: TaskItem) {
        if title == originalTitle { title = task.title; originalTitle = task.title }
        if notes == originalNotes { notes = task.descriptionText ?? ""; originalNotes = notes }
    }

    func commit(to task: TaskItem, save: () throws -> Void) throws {
        let changedTitle = title != originalTitle
        let changedNotes = notes != originalNotes
        // Validate both before changing either: other controls can save the context.
        let validatedTitle = changedTitle ? try TaskTextValidation.title(title) : task.title
        if changedNotes { try TaskTextValidation.notes(notes) }
        let previousTitle = task.title
        let previousNotes = task.descriptionText
        if changedTitle { task.title = validatedTitle }
        if changedNotes { task.descriptionText = notes.isEmpty ? nil : notes }
        do { try save() }
        catch {
            task.title = previousTitle
            task.descriptionText = previousNotes
            throw error
        }
        title = task.title
        notes = task.descriptionText ?? ""
        originalTitle = title
        originalNotes = notes
    }
}
