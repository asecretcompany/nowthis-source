import Testing
import Foundation

@testable import NowThis

// MARK: - AuthFailureGate Tests

@Suite("AuthFailureGate")
struct AuthFailureGateTests {

    @Test("Skips an account whose recorded failing password is unchanged")
    func skipsSameCredentials() {
        var gate = AuthFailureGate()
        gate.recordFailure(accountID: "a1", password: "stale-pw")
        #expect(gate.shouldSkip(accountID: "a1", currentPassword: "stale-pw"))
    }

    @Test("Resumes (does not skip) once the password changes — i.e. after re-auth")
    func resumesAfterReauth() {
        var gate = AuthFailureGate()
        gate.recordFailure(accountID: "a1", password: "stale-pw")
        #expect(!gate.shouldSkip(accountID: "a1", currentPassword: "fresh-pw"))
    }

    @Test("Does not skip an account with no recorded failure")
    func noFailureNoSkip() {
        let gate = AuthFailureGate()
        #expect(!gate.shouldSkip(accountID: "a1", currentPassword: "pw"))
    }

    @Test("Failures are tracked independently per account")
    func perAccount() {
        var gate = AuthFailureGate()
        gate.recordFailure(accountID: "a1", password: "pw")
        #expect(gate.shouldSkip(accountID: "a1", currentPassword: "pw"))
        #expect(!gate.shouldSkip(accountID: "a2", currentPassword: "pw"))
    }

    @Test("Re-recording with a new password updates what is skipped")
    func reRecordUpdates() {
        var gate = AuthFailureGate()
        gate.recordFailure(accountID: "a1", password: "pw1")
        gate.recordFailure(accountID: "a1", password: "pw2")
        #expect(!gate.shouldSkip(accountID: "a1", currentPassword: "pw1"))
        #expect(gate.shouldSkip(accountID: "a1", currentPassword: "pw2"))
    }
}
