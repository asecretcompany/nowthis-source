import SwiftUI

/// Observable error state for surfacing user-facing errors as banners.
///
/// Views attach `.errorBanner()` to show transient error messages.
/// Any component can publish errors via `ErrorState.shared.show(_:)`.
@MainActor
@Observable
final class ErrorState {

    static let shared = ErrorState()

    var currentError: String?
    var isPresented: Bool = false

    /// Shows an error message for a brief period.
    func show(_ message: String) {
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
    }
}

// MARK: - Error Banner View Modifier

/// Displays a transient error banner at the top of the view.
struct ErrorBannerModifier: ViewModifier {
    @State private var errorState = ErrorState.shared

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: $errorState.isPresented) {
                Button("OK") { errorState.dismiss() }
            } message: {
                Text(errorState.currentError ?? "An unknown error occurred.")
            }
    }
}

extension View {
    /// Attaches the global error banner to this view.
    func errorBanner() -> some View {
        modifier(ErrorBannerModifier())
    }
}
