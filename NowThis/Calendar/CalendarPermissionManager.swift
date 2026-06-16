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
            return "Not configured"
        case .restricted:
            return "Restricted by device policy"
        case .denied:
            return "Denied — tap to open Settings"
        case .fullAccess:
            return "Full access granted"
        case .writeOnly:
            return "Write-only access"
        @unknown default:
            return "Unknown"
        }
    }
}
