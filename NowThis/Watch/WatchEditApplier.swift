import Foundation
import SwiftData
import os

/// Stages watch edits in a caller-owned ModelContext, reusing the
/// same mutation semantics as in-app UI so recurrence, isDirty, and sync push
/// all behave identically. Entitlement is enforced here (defense in depth —
/// the watch UI also blocks writes when locked).
@MainActor
enum WatchEditApplier {
    enum Outcome: String, Equatable {
        case applied, rejectedLocked, unknownTask, invalid, unsupportedRecurrence, readOnlyList
    }
    private static let log = Logger(subsystem: "com.asecretcompany.nowthis", category: "WatchBridge")

    @discardableResult
    static func apply(_ edit: WatchEdit, modelContext: ModelContext,
                      isProUnlocked: Bool, now: Date = Date(),
                      calendar: Calendar = .current,
                      save: (() throws -> Void)? = nil) -> Outcome {
        var preferenceChange: NewTaskDefaults.PreferenceChange?
        let outcome = stage(edit, modelContext: modelContext, isProUnlocked: isProUnlocked,
                            now: now, calendar: calendar,
                            onPreferenceChange: { preferenceChange = $0 })
        if outcome == .readOnlyList { return .invalid }
        guard outcome == .applied else { return outcome }
        do {
            try ReminderSchedulingJournal.saveTaskChanges(in: modelContext, save: save)
        } catch {
            log.error("Watch edit save failed: \(error.localizedDescription, privacy: .private)")
            return .invalid
        }
        preferenceChange?.commit()
        ReminderScheduler.requestReconcile(modelContext: modelContext)
        return .applied
    }

    /// Mutates only the caller's owned transaction; no save or asynchronous side effects.
    static func stage(_ edit: WatchEdit, modelContext: ModelContext,
                      isProUnlocked: Bool, now: Date, calendar: Calendar = .current,
                      fetchTags: (ModelContext) throws -> [Tag] = Tag.fetchAll(in:),
                      onPreferenceChange: (NewTaskDefaults.PreferenceChange?) -> Void = { _ in }) -> Outcome {
        guard isProUnlocked else { return .rejectedLocked }
        guard edit.hasValidRawText else { return .invalid }
        switch edit {
        case .complete(let uid):
            guard let task = fetch(uid: uid, in: modelContext) else { return dropUnknown(uid) }
            do { try TaskWriteEligibility(writingIn: modelContext).tasks([task]) }
            catch let refusal as TaskWriteEligibility.Refusal where refusal == .readOnly { return .readOnlyList }
            catch { return .invalid }
            do { try TaskCompletionLogic.markCompleted(task, now: now) }
            catch { return .unsupportedRecurrence }
        case .uncomplete(let uid):
            guard let task = fetch(uid: uid, in: modelContext) else { return dropUnknown(uid) }
            do { try TaskWriteEligibility(writingIn: modelContext).tasks([task]) }
            catch let refusal as TaskWriteEligibility.Refusal where refusal == .readOnly { return .readOnlyList }
            catch { return .invalid }
            TaskCompletionLogic.markUncompleted(task, now: now)
        case .add(let rawText, let listID, let explicitDueDate, let explicitPriorityRaw):
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .invalid }

            let parsed = NaturalLanguageParser.parse(trimmed, now: now, calendar: calendar)
            let title = parsed.cleanTitle.isEmpty ? trimmed : parsed.cleanTitle
            guard let resolvedTitle = try? TaskTextValidation.title(title) else { return .invalid }

            // Resolve the target list: an explicit listID from the watch, else the
            // user's default list — the same rule every other creation surface uses.
            var explicitList: TaskList?
            if let listID {
                var descriptor = FetchDescriptor<TaskList>(predicate: #Predicate<TaskList> { $0.id == listID })
                descriptor.fetchLimit = 1
                explicitList = try? modelContext.fetch(descriptor).first
                guard explicitList != nil else { return .invalid }
            }
            let choice: NewTaskDefaults.CreationList
            do { choice = try NewTaskDefaults.creationList(explicit: explicitList, in: modelContext) }
            catch { return .invalid }
            guard let list = choice.list else { return .invalid }
            do {
                _ = try TaskWriteEligibility(writingIn: modelContext).destination(
                    .list(id: list.id, expectedPersistentID: list.persistentModelID))
            } catch let refusal as TaskWriteEligibility.Refusal where refusal == .readOnly {
                return .readOnlyList
            } catch { return .invalid }
            let tags: [Tag]
            do { tags = try Tag.resolve(parsed.tagNames, in: modelContext, fetch: fetchTags) }
            catch {
                log.error("Watch add could not resolve tags: \(String(describing: error), privacy: .private)")
                return .invalid
            }

            // Build the task exactly as QuickAddTaskIntent.performWithContainer does,
            // so a watch-dictated add lands identically to a Siri quick-add.

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

            task.tags = tags
            modelContext.insert(task)
            onPreferenceChange(choice.preferenceChange)
        }
        return .applied
    }

    private static func fetch(uid: String, in context: ModelContext) -> TaskItem? {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.uid == uid && !$0.isDeletedLocally }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private static func dropUnknown(_ uid: String) -> Outcome {
        log.warning("Watch edit for unknown uid \(uid, privacy: .private) dropped")
        return .unknownTask
    }
}
