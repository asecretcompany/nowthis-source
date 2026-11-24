import SwiftUI
import SwiftData
import os

/// Observable error state for surfacing user-facing errors as alerts.
///
/// Views attach `.errorBanner()` to show transient error messages.
/// Any component can publish errors via `ErrorState.shared.show(_:)`.
@MainActor
@Observable
final class ErrorState {

    static let shared = ErrorState()

    var currentError: String?
    var isPresented: Bool = false
    var retryAction: (() -> Void)?

    /// Shows an error message until dismissed.
    func show(_ message: String) {
        retryAction = nil
        currentError = message
        isPresented = true
    }

    /// Shows an error with a standard message for the given Error.
    func show(_ error: Error) {
        show(error.localizedDescription)
    }

    func dismiss() {
        isPresented = false
        currentError = nil
        retryAction = nil
    }
}

// MARK: - Error Banner View Modifier

/// Ordinary errors use an alert. Retryable errors keep their presentation while an
/// attempt runs: alert actions dismiss automatically and can swallow a synchronous
/// second failure before SwiftUI finishes dismissing the first alert.
struct ErrorBannerModifier: ViewModifier {
    @Bindable var errorState: ErrorState

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: Binding(
                get: { errorState.isPresented && errorState.retryAction == nil },
                set: { if !$0 { errorState.dismiss() } }
            )) {
                Button("OK") { errorState.dismiss() }
            } message: {
                ErrorMessage(errorState: errorState)
            }
            .sheet(isPresented: Binding(
                get: { errorState.isPresented && errorState.retryAction != nil },
                set: { if !$0 { errorState.dismiss() } }
            )) {
                RetryErrorSheet(errorState: errorState)
            }
    }
}

private struct ErrorMessage: View {
    let errorState: ErrorState

    var body: some View {
        Text(errorState.currentError ?? String(
            localized: "error.unknown",
            defaultValue: "An unknown error occurred.",
            comment: "Message body of the global error alert shown when no more specific error message is available."))
    }
}

private struct RetryErrorSheet: View {
    let errorState: ErrorState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ErrorMessage(errorState: errorState)
                    Button("Retry") { errorState.retryAction?() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Error")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { errorState.dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// Attaches the global error banner to this view.
    func errorBanner(_ errorState: ErrorState = .shared) -> some View {
        modifier(ErrorBannerModifier(errorState: errorState))
    }
}

// App-only save boundary; the journal remains available to extensions without UI dependencies.
@MainActor
enum ViewPersistence {
    private static let logger = Logger(subsystem: "com.nowthis", category: "view-persistence")

    static func report(_ error: Error, to errorState: ErrorState? = nil) {
        logger.error("View save failed: \(String(describing: error), privacy: .private)")
        (errorState ?? .shared).show(String(localized: "persistence.saveFailed", defaultValue: "Couldn't save your change",
            comment: "Generic persistence failure alert. The editor keeps the user's draft so they can retry; never include private task or server details."))
    }

    static func reportTaskWriteRefusal(_ error: Error, to errorState: ErrorState? = nil,
                                       creating: Bool = false) {
        let message: LocalizedStringResource
        switch error as? TaskWriteEligibility.Refusal {
        case .readOnly:
            message = creating ? TaskWriteEligibility.readOnlyCreationMessage : TaskWriteEligibility.readOnlyEditMessage
        case .targetChanged:
            message = IntentError.taskChanged.localizedStringResource
        default:
            report(error, to: errorState)
            return
        }
        (errorState ?? .shared).show(String(localized: message))
    }

    static func reportCalendarFailure(_ detail: String, to errorState: ErrorState? = nil) {
        logger.error("Calendar sync failed: \(detail, privacy: .private)")
        (errorState ?? .shared).show(String(localized: "calendar.syncFailed", defaultValue: "Couldn't sync your calendars",
            comment: "Generic alert after a manual calendar sync fails. Details are logged privately; the user can retry the sync."))
    }

    /// The task mutation is already durable. Retain only reminder recovery for Retry.
    static func recoverRemindersAfterCommit(errorState: ErrorState? = nil,
                                           requestReconcile: @escaping @MainActor () throws -> Void) {
        ReminderRecoveryAttempt(errorState: errorState ?? .shared, requestReconcile: requestReconcile).run()
    }

    @MainActor
    private final class ReminderRecoveryAttempt {
        private weak var errorState: ErrorState?
        private let requestReconcile: @MainActor () throws -> Void
        private var finished = false
        private var hasFailed = false

        init(errorState: ErrorState, requestReconcile: @escaping @MainActor () throws -> Void) {
            self.errorState = errorState
            self.requestReconcile = requestReconcile
        }

        func run() {
            guard !finished else { return }
            do {
                try requestReconcile()
                finished = true
                if hasFailed { errorState?.dismiss() }
            } catch {
                hasFailed = true
                ViewPersistence.logger.error("Reminder recovery failed after committed change: \(String(describing: error), privacy: .private)")
                errorState?.show(String(localized: "persistence.reminderRecoveryFailed",
                    defaultValue: "Your change was saved, but reminders couldn't be updated. Retry to update reminders.",
                    comment: "Partial-success alert: the task change is already saved. Retry repeats only reminder recovery and never repeats completion, reopening, or recurrence advancement."))
                // The alert owns the attempt; the attempt weakly references its presenter.
                errorState?.retryAction = { self.run() }
            }
        }
    }

    static func savePendingDeletion(in context: ModelContext, errorState: ErrorState? = nil,
                                    needsRecovery: Bool = false, save: (() throws -> Void)? = nil,
                                    onSaved: @escaping () -> Void = {}) {
        let owner = errorState ?? .shared
        if saveOrReport(in: context, errorState: owner, needsRecovery: needsRecovery, save: save) {
            owner.dismiss()
            onSaved()
        } else {
            // The row may already be hidden. Retry only its pending save, never the deletion preparation.
            owner.retryAction = { [weak owner] in
                guard let owner else { return }
                savePendingDeletion(in: context, errorState: owner, needsRecovery: needsRecovery,
                                    save: save, onSaved: onSaved)
            }
        }
    }

    @discardableResult
    static func saveOrReport(in context: ModelContext, errorState: ErrorState? = nil,
                             needsRecovery: Bool = false, save: (() throws -> Void)? = nil) -> Bool {
        do {
            try ReminderSchedulingJournal.saveTaskChanges(in: context, needsRecovery: needsRecovery, save: save)
            return true
        } catch {
            report(error, to: errorState)
            return false
        }
    }
}

@MainActor
struct TaskDeletionPersistence {
    static func admit(_ task: TaskItem, in context: ModelContext,
                      confirmed: TaskWriteEligibility.DeletionScope? = nil) throws
        -> TaskWriteEligibility.DeletionAdmission {
        guard task.modelContext === context, !task.isDeletedLocally else {
            throw TaskWriteEligibility.Refusal.taskUnavailable
        }
        let proposed = TaskListHelpers.deletionSubtree(of: task)
        return try TaskWriteEligibility(writingIn: context).deletionSubtree(
            root: task, proposed: proposed, confirmed: confirmed)
    }

    static func perform(_ task: TaskItem, in context: ModelContext, errorState: ErrorState? = nil,
                        confirmed: TaskWriteEligibility.DeletionScope? = nil,
                        save: (() throws -> Void)? = nil) -> [String]? {
        let admission: TaskWriteEligibility.DeletionAdmission
        do {
            admission = try admit(task, in: context, confirmed: confirmed)
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return nil
        }
        let snapshots = admission.rows.map {
            (task: $0, deleted: $0.isDeletedLocally, dirty: $0.isDirty, modified: $0.lastModifiedDate)
        }
        let ids = TaskListHelpers.markDeleted(admission.rows)
        guard ViewPersistence.saveOrReport(in: context, errorState: errorState, save: save) else {
            // This synchronous operation owns only these three fields. Never roll back the context.
            for snapshot in snapshots where snapshot.task.modelContext != nil {
                snapshot.task.isDeletedLocally = snapshot.deleted
                snapshot.task.isDirty = snapshot.dirty
                snapshot.task.lastModifiedDate = snapshot.modified
            }
            return nil
        }
        return ids
    }
}

@MainActor
@Observable
final class TaskCreationDraft {
    private var pending: TaskItem?
    private var ownedContext: ModelContext?
    /// A failed inline save must finish before another editor can commit that context.
    var hasPendingTask: Bool { pending?.modelContext != nil }

    /// Explicit cancellation on a shared inline context must not roll back other edits.
    /// A primary save may already have succeeded before reminder recovery failed.
    func cancelInlineAddition(in context: ModelContext) throws {
        guard ownedContext == nil else { discardOwnedChanges(); return }
        if let task = pending, task.modelContext != nil {
            let id = task.id
            let saved = ModelContext(context.container)
            let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
            if try saved.fetchCount(descriptor) == 0 { context.delete(task) }
        }
        didSave()
    }

    func context(in container: ModelContainer) -> ModelContext {
        if let ownedContext { return ownedContext }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        ownedContext = context
        return context
    }

    /// Only sheets that acquired their own context can discard here. Other creation
    /// surfaces keep their existing save boundary and unrelated edits are never touched.
    func discardOwnedChanges() {
        guard let ownedContext else { return }
        pending = nil
        ownedContext.rollback()
        self.ownedContext = nil
    }

    @discardableResult
    func saveOwnedChanges(errorState: ErrorState, save: (() throws -> Void)? = nil) -> Bool {
        guard let ownedContext else { return false }
        guard ViewPersistence.saveOrReport(in: ownedContext, errorState: errorState, save: save) else { return false }
        // Release ownership at the primary commit, before fallible reminder recovery.
        didSave()
        return true
    }


    func task(title: String, priority: TaskPriority = .none) throws -> TaskItem {
        let title = try TaskTextValidation.title(title)
        // A genuine account/task deletion invalidates a draft; never mutate that model on retry.
        let task = pending.flatMap { $0.modelContext != nil ? $0 : nil }
            ?? TaskItem(title: title, priority: priority)
        task.title = title
        task.priority = priority
        pending = task
        return task
    }

    func subtask(title: String, parent: TaskItem, in container: ModelContainer) throws -> TaskItem? {
        guard parent.modelContext != nil, !parent.isDeleted, !parent.isDeletedLocally else { return nil }
        let context = context(in: container)
        let parentID = parent.id
        let persistentID = parent.persistentModelID
        if let source = parent.modelContext {
            try TaskWriteEligibility(writingIn: source).tasks([parent])
        }
        let committedParent = try TaskWriteEligibility(writingIn: context).task(.id(parentID))
        guard committedParent.persistentModelID == persistentID,
              committedParent.taskList?.persistentModelID == parent.taskList?.persistentModelID else {
            throw TaskWriteEligibility.Refusal.targetChanged
        }
        let child = try task(title: title)
        child.parentTask = committedParent
        child.taskList = committedParent.taskList
        child.parentUID = committedParent.uid
        child.isDirty = true
        context.insert(child)
        return child
    }

    func didSave() {
        pending = nil
        ownedContext = nil
    }
}

// Each editor supplies its own alert owner to nested sections; the main screen uses shared.
extension EnvironmentValues {
    @Entry var saveErrorState: ErrorState? = nil
}
