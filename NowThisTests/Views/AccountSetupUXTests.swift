import Testing
@testable import NowThis

@Suite("AccountSetup UX — Section Visibility")
struct AccountSetupUXTests {

    @Test("Login sections hidden when server URL is empty")
    func loginSectionsHiddenWhenEmpty() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "")
        #expect(result == false)
    }

    @Test("Login sections hidden when server URL is whitespace only")
    func loginSectionsHiddenWhenWhitespace() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "   ")
        #expect(result == false)
    }

    @Test("Login sections hidden when server URL is invalid")
    func loginSectionsHiddenWhenInvalid() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "not a url !!!")
        #expect(result == false)
    }

    @Test("Login sections hidden when server URL is HTTP (not HTTPS)")
    func loginSectionsHiddenWhenHTTP() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "http://cloud.example.com")
        #expect(result == false)
    }

    @Test("Login sections shown when server URL is valid HTTPS")
    func loginSectionsShownWhenValid() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "https://cloud.example.com")
        #expect(result == true)
    }

    @Test("Login sections shown when server URL has no scheme (auto-HTTPS)")
    func loginSectionsShownWhenNoScheme() {
        let result = AccountSetupHelper.shouldShowLoginSections(serverURL: "cloud.example.com")
        #expect(result == true)
    }
}
