import Testing
import Foundation

@testable import NowThis

// MARK: - IntentDonationManager Tests

@Suite("IntentDonationManager")
struct IntentDonationTests {

    @Test("donateCreateTask does not throw")
    func donateCreateDoesNotThrow() {
        // Verify donation calls complete without error
        IntentDonationManager.donateCreateTask(title: "Test task", listName: "Work")
    }

    @Test("donateCompleteTask does not throw")
    func donateCompleteDoesNotThrow() {
        IntentDonationManager.donateCompleteTask(title: "Test task")
    }

    @Test("donateCreateTask with nil list does not throw")
    func donateCreateWithNilList() {
        IntentDonationManager.donateCreateTask(title: "Test", listName: nil)
    }
}
