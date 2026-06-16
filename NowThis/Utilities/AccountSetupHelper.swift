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
