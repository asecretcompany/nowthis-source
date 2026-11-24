import Testing
import Foundation

@testable import NowThis

// MARK: - AuthFailureGate Tests

@Suite("AuthFailureGate")
struct AuthFailureGateTests {
    private func scope(accountID: String = "a1", baseURL: String = "https://cloud.invalid",
                       username: String = "fixture", password: String = "pw") -> AuthFailureGate.Scope {
        .init(accountID: accountID, baseURL: baseURL, username: username, password: password)
    }

    @Test("Skips an account whose recorded failing password is unchanged")
    func skipsSameCredentials() {
        var gate = AuthFailureGate()
        let rejected = scope(password: "stale-pw")
        gate.recordFailure(rejected)
        #expect(gate.shouldSkip(rejected))
    }

    @Test("Resumes (does not skip) once the password changes — i.e. after re-auth")
    func resumesAfterReauth() {
        var gate = AuthFailureGate()
        gate.recordFailure(scope(password: "stale-pw"))
        #expect(!gate.shouldSkip(scope(password: "fresh-pw")))
    }

    @Test("Does not skip an account with no recorded failure")
    func noFailureNoSkip() {
        let gate = AuthFailureGate()
        #expect(!gate.shouldSkip(scope()))
    }

    @Test("Failures are tracked independently per account")
    func perAccount() {
        var gate = AuthFailureGate()
        gate.recordFailure(scope())
        #expect(gate.shouldSkip(scope()))
        #expect(!gate.shouldSkip(scope(accountID: "a2")))
    }

    @Test("Equivalent HTTPS installation addresses share a rejection")
    func equivalentInstallationAddress() {
        var gate = AuthFailureGate()
        gate.recordFailure(scope(baseURL: "HTTPS://CLOUD.INVALID:443/next%20cloud///"))
        #expect(gate.shouldSkip(scope(baseURL: "https://cloud.invalid/next%20cloud")))
        #expect(!gate.shouldSkip(scope(baseURL: "https://cloud.invalid:8443/next%20cloud")))
        #expect(!gate.shouldSkip(scope(baseURL: "https://cloud.invalid/Next%20cloud")))
        #expect(!gate.shouldSkip(scope(baseURL: "https://other.invalid/next%20cloud")))
    }

    @Test("Different username bytes are independent even when the spelling looks identical")
    func exactUsernameBytes() {
        var gate = AuthFailureGate()
        let rejected = scope(username: "caf\u{00e9}")
        let distinct = scope(username: "cafe\u{0301}")
        gate.recordFailure(rejected)
        #expect(!gate.shouldSkip(distinct))
        gate.recordFailure(distinct)
        #expect(gate.shouldSkip(rejected))
        #expect(gate.shouldSkip(distinct))
    }

    @Test("Re-recording with a new password updates what is skipped")
    func reRecordUpdates() {
        var gate = AuthFailureGate()
        gate.recordFailure(scope(password: "pw1"))
        gate.recordFailure(scope(password: "pw2"))
        #expect(!gate.shouldSkip(scope(password: "pw1")))
        #expect(gate.shouldSkip(scope(password: "pw2")))
    }
}
