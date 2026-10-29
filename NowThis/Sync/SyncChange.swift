import Foundation

/// Values describing durable changes. Model instances never leave their context owner.
struct SyncChange: Sendable, Equatable {
    enum Kind: Sendable { case tasks, lists, journals }
    let revision: UInt64
    let accountIDs: Set<String>
    let listIDs: Set<String>
    let changedIDs: Set<String>
    let deletedIDs: Set<String>
    let kind: Kind
}
