import EventKit
import Combine

/// Manages Apple Calendar (EventKit) authorization state.
///
/// Prompts the user for calendar access on first use and exposes
/// the current authorization status as a published property.
/// Handles all EKAuthorizationStatus states gracefully.
@MainActor
final class CalendarPermissionManager: ObservableObject {

    /// Current EventKit authorization status.
    @Published var authorizationStatus: EKAuthorizationStatus

    /// The shared event store used for all EventKit operations.
    let eventStore: EKEventStore

    init() {
        self.eventStore = EKEventStore()
        self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// Whether the user has granted full calendar access.
    var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    /// Requests calendar access from the user.
    ///
    /// On iOS 17+, uses `requestFullAccessToEvents()`.
    /// Updates `authorizationStatus` after the request completes.
    ///
    /// - Returns: `true` if access was granted.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    /// Refreshes the cached authorization status.
    func refreshStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// User-facing description of the current authorization state.
    var statusDescription: String {
        switch authorizationStatus {
        case .notDetermined:
            return String(localized: "calendarAccess.notDetermined",
                          defaultValue: "Not configured",
                          comment: "Apple Calendar access state in Settings: the app has not asked for permission yet.")
        case .restricted:
            return String(localized: "calendarAccess.restricted",
                          defaultValue: "Restricted by device policy",
                          comment: "Apple Calendar access state in Settings: blocked by Screen Time or a mobile device management profile, so the user cannot grant it here.")
        case .denied:
            return String(localized: "calendarAccess.denied",
                          defaultValue: "Denied in iOS Settings",
                          comment: "Apple Calendar access state: the user refused. iOS Settings is the system app's own name.")
        case .fullAccess:
            return String(localized: "calendarAccess.full",
                          defaultValue: "Full access granted",
                          comment: "Apple Calendar access state in Settings: the app can read and write events.")
        case .writeOnly:
            return String(localized: "calendarAccess.writeOnly",
                          defaultValue: "Write-only access",
                          comment: "Apple Calendar access state in Settings: the app can add events but cannot read existing ones.")
        @unknown default:
            return String(localized: "calendarAccess.unknown",
                          defaultValue: "Unknown",
                          comment: "Apple Calendar access state in Settings for a permission state this version of the app does not recognise.")
        }
    }
}
