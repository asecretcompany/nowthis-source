import Testing
import Foundation
@testable import NowThis

@Suite("AccountSetup UX — Section Visibility")
struct AccountSetupUXTests {
    private enum SaveFailure: LocalizedError {
        case database
        var errorDescription: String? { "Injected account save failure" }
    }

    @Test("The form receives success only after credentials have been saved", arguments: [false, true])
    @MainActor
    func loginSaveReportsTheCommitResult(fails: Bool) async {
        var committed = false
        var successCount = 0
        var failureMessage: String?
        await AccountLoginSave.perform(save: {
            if fails { throw SaveFailure.database }
            committed = true
        }, onSuccess: {
            #expect(committed)
            successCount += 1
        }, onFailure: { failureMessage = $0 })

        #expect(successCount == (fails ? 0 : 1))
        #expect(failureMessage == (fails ? SaveFailure.database.localizedDescription : nil))
    }

    @Test("A completed write cannot update a form after it has disappeared", arguments: [false, true])
    @MainActor
    func dismissedFormIgnoresLateSaveCompletion(fails: Bool) async {
        let entered = AsyncStream<Void>.makeStream()
        var completeSave: CheckedContinuation<Void, Never>?
        var completionCount = 0
        let save = Task {
            await AccountLoginSave.perform(save: {
                await withCheckedContinuation {
                    completeSave = $0
                    entered.continuation.yield()
                    entered.continuation.finish()
                }
                if fails { throw SaveFailure.database }
            }, onSuccess: { completionCount += 1 }, onFailure: { _ in completionCount += 1 })
        }
        for await _ in entered.stream { break }
        save.cancel()
        completeSave?.resume()
        await save.value

        #expect(completionCount == 0)
    }

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
