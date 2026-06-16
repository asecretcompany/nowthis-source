import Testing
import Foundation

@testable import NowThis

// MARK: - TaskStatus Tests

@Suite("TaskStatus Enum")
struct TaskStatusTests {

    @Test("Raw values match RFC-5545 STATUS property values")
    func rawValuesMatchRFC5545() {
        #expect(TaskStatus.needsAction.rawValue == "NEEDS-ACTION")
        #expect(TaskStatus.inProcess.rawValue == "IN-PROCESS")
        #expect(TaskStatus.completed.rawValue == "COMPLETED")
        #expect(TaskStatus.cancelled.rawValue == "CANCELLED")
    }

    @Test("All cases are present")
    func allCasesPresent() {
        #expect(TaskStatus.allCases.count == 4)
    }

    @Test("Init from raw value round-trips")
    func initFromRawValue() {
        let status = TaskStatus(rawValue: "NEEDS-ACTION")
        #expect(status == .needsAction)

        let invalid = TaskStatus(rawValue: "INVALID")
        #expect(invalid == nil)
    }

    @Test("Display names are non-empty localized strings")
    func displayNames() {
        for status in TaskStatus.allCases {
            #expect(!status.displayName.isEmpty)
        }
    }

    @Test("System image names are valid SF Symbol identifiers")
    func systemImageNames() {
        for status in TaskStatus.allCases {
            #expect(!status.systemImageName.isEmpty)
        }
    }
}

// MARK: - TaskPriority Tests

@Suite("TaskPriority Enum")
struct TaskPriorityTests {

    @Test("Raw values match RFC-5545 PRIORITY mapping")
    func rawValuesMatchMapping() {
        #expect(TaskPriority.none.rawValue == 0)
        #expect(TaskPriority.high.rawValue == 1)
        #expect(TaskPriority.medium.rawValue == 5)
        #expect(TaskPriority.low.rawValue == 9)
    }

    @Test("fromRFC5545 maps 0 to none")
    func fromRFC5545Zero() {
        #expect(TaskPriority.fromRFC5545(0) == .none)
    }

    @Test("fromRFC5545 maps 1-4 to high")
    func fromRFC5545High() {
        for value in 1...4 {
            #expect(TaskPriority.fromRFC5545(value) == .high)
        }
    }

    @Test("fromRFC5545 maps 5 to medium")
    func fromRFC5545Medium() {
        #expect(TaskPriority.fromRFC5545(5) == .medium)
    }

    @Test("fromRFC5545 maps 6-9 to low")
    func fromRFC5545Low() {
        for value in 6...9 {
            #expect(TaskPriority.fromRFC5545(value) == .low)
        }
    }

    @Test("fromRFC5545 maps out-of-range values to none (defensive)")
    func fromRFC5545OutOfRange() {
        #expect(TaskPriority.fromRFC5545(-1) == .none)
        #expect(TaskPriority.fromRFC5545(10) == .none)
        #expect(TaskPriority.fromRFC5545(100) == .none)
    }

    @Test("Comparable: high < medium < low (lower rawValue = higher priority)")
    func comparableOrdering() {
        #expect(TaskPriority.none < TaskPriority.high)
        #expect(TaskPriority.high < TaskPriority.medium)
        #expect(TaskPriority.medium < TaskPriority.low)
    }

    @Test("Sorting by priority puts highest first")
    func sortingByPriority() {
        let priorities: [TaskPriority] = [.low, .none, .high, .medium]
        let sorted = priorities.sorted()
        #expect(sorted == [.none, .high, .medium, .low])
    }

    @Test("All cases are present")
    func allCasesPresent() {
        #expect(TaskPriority.allCases.count == 4)
    }

    @Test("Display names are non-empty")
    func displayNames() {
        for priority in TaskPriority.allCases {
            #expect(!priority.displayName.isEmpty)
        }
    }
}

// MARK: - AccountMode Tests

@Suite("AccountMode Enum")
struct AccountModeTests {

    @Test("Raw values are correct")
    func rawValues() {
        #expect(AccountMode.vault.rawValue == "vault")
        #expect(AccountMode.nextcloud.rawValue == "nextcloud")
    }

    @Test("Init from raw value round-trips")
    func initFromRawValue() {
        #expect(AccountMode(rawValue: "vault") == .vault)
        #expect(AccountMode(rawValue: "nextcloud") == .nextcloud)
        #expect(AccountMode(rawValue: "invalid") == nil)
    }
}

// MARK: - ServerAccount Vault Mode Tests

@Suite("ServerAccount Vault Mode")
struct ServerAccountVaultTests {

    @Test("Vault convenience initializer sets correct defaults")
    func vaultInitializer() {
        let vault = ServerAccount(vaultDisplayName: "My Vault")

        #expect(vault.displayName == "My Vault")
        #expect(vault.serverBaseURL.isEmpty)
        #expect(vault.username.isEmpty)
        #expect(vault.mode == .vault)
        #expect(!vault.id.isEmpty)
    }

    @Test("Vault with default name")
    func vaultDefaultName() {
        let vault = ServerAccount(vaultDisplayName: "Vault")

        #expect(vault.displayName == "Vault")
        #expect(vault.mode == .vault)
    }

    @Test("Nextcloud account has populated server fields")
    func nextcloudAccount() {
        let account = ServerAccount(
            displayName: "Work",
            serverBaseURL: "https://cloud.example.com",
            username: "alice",
            mode: .nextcloud
        )

        #expect(account.mode == .nextcloud)
        #expect(account.serverBaseURL == "https://cloud.example.com")
        #expect(account.username == "alice")
    }
}
