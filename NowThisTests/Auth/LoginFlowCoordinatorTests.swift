import Testing
import Foundation

@testable import NowThis

@Suite("LoginFlowCoordinator")
@MainActor
struct LoginFlowCoordinatorTests {

    @Test("Callback scheme must not match the app's registered URL scheme")
    func callbackSchemeDoesNotConflictWithDeepLinks() {
        // The app registers "nowthis" as its deep-link scheme in Info.plist.
        // ASWebAuthenticationSession's callbackURLScheme must differ,
        // otherwise iOS's URL handling intercepts the redirect and
        // immediately dismisses the auth sheet before the user can log in.
        let appDeepLinkScheme = "nowthis"
        #expect(LoginFlowCoordinator.callbackURLScheme != appDeepLinkScheme,
                "callbackURLScheme must not equal the app's deep link scheme or the auth sheet will be dismissed immediately")
    }

    @Test("Callback scheme is non-empty")
    func callbackSchemeIsNonEmpty() {
        #expect(!LoginFlowCoordinator.callbackURLScheme.isEmpty,
                "callbackURLScheme must be non-empty for ASWebAuthenticationSession")
    }
}
