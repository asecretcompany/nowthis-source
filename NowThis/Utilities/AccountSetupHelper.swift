import Foundation

/// Testable helper for AccountSetupView section visibility logic.
///
/// Extracts the "should we show the Login Flow / Manual Entry sections?"
/// decision out of the SwiftUI view so it can be unit tested.
enum AccountSetupHelper {

    /// Returns `true` when the server URL is valid enough to show login sections.
    static func shouldShowLoginSections(serverURL: String) -> Bool {
        ServerURLValidator.validate(serverURL).isValid
    }
}

/// Routes the completed account write to the owning form.
@MainActor
enum AccountLoginSave {
    static func perform(
        save: @MainActor () async throws -> Void,
        onSuccess: () -> Void,
        onFailure: (String) -> Void
    ) async {
        do {
            try Task.checkCancellation()
            try await save()
            guard !Task.isCancelled else { return }
            onSuccess()
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), !(error is AccountCredentialDeferral) else { return }
            onFailure(error.localizedDescription)
        }
    }
}
