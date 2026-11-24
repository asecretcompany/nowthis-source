import Foundation
import os

/// Intervals contain aggregate counts only; never task contents, hrefs or credentials.
enum PerformanceTrace {
    /// A scoped observer for opt-in component measurements. No IDs or contents are recorded.
    @TaskLocal static var operationRecorder: OperationRecorder?

    enum Operation: String, Sendable {
        case matchingTaskInventory, receiptInventory, matchingTaskLookup, matchingReceiptLookup
        case shapeTasks, genericShapeRecords, retainedShapeCaptures
        case receiptWriteLookup, otherScopePrune, checkpointRead, checkpointCommit
        case hierarchyScan, deletionScan, pendingOutbound
        case reminderPlan
    }

    final class OperationRecorder: @unchecked Sendable {
        struct Count: Equatable, Sendable {
            var calls = 0
            var rows = 0
            var maxKeys = 0
        }

        private let lock = NSLock()
        private var counts: [Operation: Count] = [:]

        func record(_ operation: Operation, rows: Int, keys: Int) {
            lock.withLock {
                counts[operation, default: Count()].calls += 1
                counts[operation, default: Count()].rows += rows
                counts[operation, default: Count()].maxKeys =
                    max(counts[operation, default: Count()].maxKeys, keys)
            }
        }

        func count(_ operation: Operation) -> Count {
            lock.withLock { counts[operation] ?? Count() }
        }
    }

    static func record(_ operation: Operation, rows: Int, keys: Int = 0) {
        operationRecorder?.record(operation, rows: rows, keys: keys)
    }

    static let reminderPlanName: StaticString = "ReminderPlan"
    private static let signposter = OSSignposter(subsystem: "com.nowthis", category: "performance")

    static func begin(_ name: StaticString, count: Int = 0, bytes: Int = 0) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(),
                                 "count=\(count) bytes=\(bytes)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
