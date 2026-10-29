import Foundation
import SwiftData
import os

/// Applies edits received from the watch on the MAIN ModelContext, reusing the
/// same mutation semantics as in-app UI so recurrence, isDirty, and sync push
/// all behave identically. Entitlement is enforced here (defense in depth —
/// the watch UI also blocks writes when locked).
@MainActor
enum WatchEditApplier {
    enum Outcome: String, Equatable { case applied, rejectedLocked, unknownTask, invalid }
    private static let log = Logger(subsystem: "com.asecretcompany.nowthis", category: "WatchBridge")

    @discardableResult
    static func apply(_ edit: WatchEdit, modelContext: ModelContext,
                      isProUnlocked: Bool, now: Date = Date(),
                      save: (() throws -> Void)? = nil) -> Outcome {
        guard isProUnlocked else { return .rejectedLocked }
        switch edit {
        case .complete(let uid):
            guard let task = fetch(uid: uid, in: modelContext) else { return dropUnknown(uid) }
            TaskCompletionLogic.markCompleted(task, now: now)
        case .uncomplete(let uid):
            guard let task = fetch(uid: uid, in: modelContext) else { return dropUnknown(uid) }
            TaskCompletionLogic.markUncompleted(task, now: now)
        case .add(let rawText, let listID, let explicitDueDate, let explicitPriorityRaw):
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .invalid }

            // Resolve the target list: an explicit listID from the watch, else the
            // user's default list — the same rule every other creation surface uses.
            var explicitList: TaskList?
            if let listID {
                var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate<TaskList> { $0.id == listID })
                descriptor.fetchLimit = 1
                explicitList = try? modelContext.fetch(descriptor).first
            }
            guard let list = NewTaskDefaults.resolveListAdopting(
                explicit: explicitList, in: modelContext
            ) else { return .invalid }

            // Build the task exactly as QuickAddTaskIntent.performWithContainer does,
            // so a watch-dictated add lands identically to a Siri quick-add.
            let parsed = NaturalLanguageParser.parse(trimmed)
            let title = parsed.cleanTitle.isEmpty ? trimmed : parsed.cleanTitle
            let resolvedTitle = title.isEmpty ? "New Task" : title

            // Precedence: a token the user typed or dictated outranks the add screen's
            // pickers, which is the rule `QuickAddView` already applies on iOS — so
            // "buy milk tomorrow" means the same thing wherever it is entered.
            let explicitPriority = explicitPriorityRaw.map(TaskPriority.fromRFC5545)
            let task = TaskItem(title: resolvedTitle,
                                priority: parsed.priority ?? explicitPriority ?? .none)
            task.taskList = list
            if let parsedDate = parsed.dueDate {
                // A parsed date with no explicit clock time is an all-day (date-only) due date.
                task.dueDate = parsedDate
                task.isDueDateOnly = !parsed.dueHasTime
            } else if let explicitDueDate {
                // The add screen offers whole-day presets only, so it never carries a time.
                task.dueDate = explicitDueDate
                task.isDueDateOnly = true
            }
            task.isDirty = true

            // Resolve tags (create-or-find), matching QuickAddTaskIntent.
            if !parsed.tagNames.isEmpty {
                let allTags = (try? modelContext.fetch(FetchDescriptor<Tag>())) ?? []
                for tagName in parsed.tagNames {
                    // Locale-aware case folding, not diacritic folding — see CreateTaskIntent.
                    if let existing = allTags.first(where: {
                        $0.name.localizedCaseInsensitiveCompare(tagName) == .orderedSame
                    }) {
                        task.tags.append(existing)
                    } else {
                        let newTag = Tag(name: tagName)
                        modelContext.insert(newTag)
                        task.tags.append(newTag)
                    }
                }
            }

            modelContext.insert(task)
        }
        do {
            try ReminderSchedulingJournal.saveTaskChanges(in: modelContext, save: save)
        } catch {
            log.error("Watch edit save failed: \(error.localizedDescription, privacy: .public)")
            return .invalid
        }
        // A watch-dictated add can carry a parsed due date; it reached no scheduler before.
        ReminderScheduler.requestReconcile(modelContext: modelContext)
        return .applied
    }

    private static func fetch(uid: String, in context: ModelContext) -> TaskItem? {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.uid == uid && !$0.isDeletedLocally }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private static func dropUnknown(_ uid: String) -> Outcome {
        log.warning("Watch edit for unknown uid \(uid, privacy: .public) dropped")
        return .unknownTask
    }
}
