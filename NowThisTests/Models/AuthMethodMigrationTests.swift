import Testing
import Foundation

@testable import NowThis

// MARK: - AuthMethod Migration Safety Tests

@Suite("AuthMethod Migration Safety")
struct AuthMethodMigrationTests {

    @Test("AuthMethod raw values are correct")
    func rawValues() {
        #expect(AuthMethod.manual.rawValue == "manual")
        #expect(AuthMethod.loginFlow.rawValue == "loginFlow")
    }

    @Test("New account defaults to manual auth method")
    func newAccountDefaultsToManual() {
        let account = ServerAccount(
            displayName: "Test",
            serverBaseURL: "https://example.com",
            username: "user",
            mode: .nextcloud
        )

        #expect(account.resolvedAuthMethod == .manual)
    }

    @Test("resolvedAuthMethod returns manual when storedAuthMethod is nil (pre-migration)")
    func resolvedAuthMethodNilFallback() {
        let account = ServerAccount(
            displayName: "Legacy",
            serverBaseURL: "https://old.server.com",
            username: "olduser",
            mode: .nextcloud
        )
        // Simulate pre-migration state: stored value is nil
        account.storedAuthMethod = nil

        #expect(account.resolvedAuthMethod == .manual)
    }

    @Test("resolvedAuthMethod returns loginFlow when explicitly set")
    func resolvedAuthMethodLoginFlow() {
        let account = ServerAccount(
            displayName: "Flow",
            serverBaseURL: "https://nc.example.com",
            username: "flowuser",
            mode: .nextcloud
        )
        account.storedAuthMethod = .loginFlow

        #expect(account.resolvedAuthMethod == .loginFlow)
    }

    @Test("Vault accounts have manual auth method by default")
    func vaultDefaultsToManual() {
        let vault = ServerAccount(vaultDisplayName: "Vault")

        #expect(vault.resolvedAuthMethod == .manual)
    }
}
