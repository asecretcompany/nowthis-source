import Foundation

struct SyncOutcome: Sendable, Equatable {
    enum Status: Sendable { case completed, partial, cancelled, alreadyRunning }
    var status: Status = .completed
    var changedListIDs: Set<String> = []
    var importedCount = 0
    var updatedCount = 0
    var deletedCount = 0
    var pendingOutboundCount = 0
    var failures: [SyncFailure] = []
}
