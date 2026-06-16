import SwiftUI
@preconcurrency import EventKitUI
import SwiftData

/// Google Tasks-style "Add to Calendar" action for a task.
///
/// Shows a destination picker (Apple Calendar or Nextcloud Calendar),
/// then creates the event. On first use, prompts for calendar permission
/// via `CalendarPermissionManager`.
struct AddToCalendarButton: View {

    let task: TaskItem

    @StateObject private var permissionManager = CalendarPermissionManager()
    @State private var showingPicker = false
    @State private var showingEventEditor = false
    @State private var showingPermissionDenied = false
    @State private var selectedCalendarID: String?

    @Query(sort: \ServerAccount.displayName)
    private var allAccounts: [ServerAccount]

    @Environment(\.modelContext) private var modelContext

    /// Nextcloud accounts (non-vault) filtered locally.
    private var nextcloudAccounts: [ServerAccount] {
        allAccounts.filter { $0.mode != .vault }
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            Label("Add to Calendar", systemImage: "calendar.badge.plus")
        }
        .accessibilityHint("Add this task as a calendar event")
        .confirmationDialog("Add to Calendar", isPresented: $showingPicker) {
            // Apple Calendar options
            if permissionManager.hasAccess {
                let calendars = permissionManager.eventStore
                    .calendars(for: .event)
                    .filter { $0.allowsContentModifications }
                ForEach(calendars, id: \.calendarIdentifier) { calendar in
                    Button(calendar.title) {
                        addToAppleCalendar(calendarID: calendar.calendarIdentifier)
                    }
                }
            }

            // Nextcloud Calendar options
            ForEach(nextcloudAccounts) { account in
                Button("Nextcloud: \(account.displayName)") {
                    addToNextcloudCalendar(account: account)
                }
            }
        } message: {
            Text("Choose a calendar for \"\(task.title)\"")
        }
        .alert("Calendar Access Denied", isPresented: $showingPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("NowThis needs calendar access to add events. Please enable it in Settings.")
        }
        .sheet(isPresented: $showingEventEditor) {
            EventEditSheet(
                task: task,
                eventStore: permissionManager.eventStore,
                calendarID: selectedCalendarID
            )
        }
    }

    // MARK: - Actions

    private func handleTap() {
        Task {
            // Check or request permission on first use
            permissionManager.refreshStatus()

            switch permissionManager.authorizationStatus {
            case .notDetermined:
                let granted = await permissionManager.requestAccess()
                if granted {
                    showingPicker = true
                } else if !nextcloudAccounts.isEmpty {
                    // No Apple Calendar permission but Nextcloud available
                    showingPicker = true
                } else {
                    showingPermissionDenied = true
                }
            case .fullAccess, .writeOnly:
                showingPicker = true
            case .denied, .restricted:
                if nextcloudAccounts.isEmpty {
                    showingPermissionDenied = true
                } else {
                    showingPicker = true
                }
            @unknown default:
                showingPicker = true
            }
        }
    }

    private func addToAppleCalendar(calendarID: String) {
        selectedCalendarID = calendarID
        showingEventEditor = true
    }

    private func addToNextcloudCalendar(account: ServerAccount) {
        Task { @MainActor in
            let manager = NextcloudCalendarSyncManager()
            do {
                nonisolated(unsafe) let unsafeTask = task
                nonisolated(unsafe) let unsafeAccount = account
                try await manager.syncSingleTask(unsafeTask, account: unsafeAccount)
                try modelContext.save()
            } catch {
                // Silently fail — could add error toast later
            }
        }
    }
}

// MARK: - Event Edit Sheet (EKEventEditViewController wrapper)

/// Wraps `EKEventEditViewController` for Apple Calendar event creation.
///
/// Pre-fills the event with task data and lets the user customize
/// before saving (just like Google Tasks → Google Calendar).
struct EventEditSheet: UIViewControllerRepresentable {
    let task: TaskItem
    let eventStore: EKEventStore
    let calendarID: String?

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = eventStore
        controller.editViewDelegate = context.coordinator

        let event = EKEvent(eventStore: eventStore)
        event.title = task.title
        event.notes = task.descriptionText
        event.location = task.locationName

        if let dueDate = task.dueDate {
            let start = task.startDate ?? dueDate
            event.startDate = start
            event.endDate = Calendar.current.date(byAdding: .minute, value: 30, to: start) ?? start
        } else {
            event.startDate = Date()
            event.endDate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        }

        if let calID = calendarID,
           let calendar = eventStore.calendar(withIdentifier: calID) {
            event.calendar = calendar
        }

        if let urlString = task.url, let url = URL(string: urlString) {
            event.url = url
        }

        controller.event = event
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss, task: task)
    }

    class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        let task: TaskItem

        init(dismiss: DismissAction, task: TaskItem) {
            self.dismiss = dismiss
            self.task = task
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            nonisolated(unsafe) let theTask = task
            let theDismiss = dismiss
            MainActor.assumeIsolated {
                if action == .saved, let event = controller.event {
                    theTask.calendarEventID = event.eventIdentifier
                }
                theDismiss()
            }
        }
    }
}
