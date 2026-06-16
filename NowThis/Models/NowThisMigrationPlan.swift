import Foundation
import SwiftData

// MARK: - Schema V1

/// Original schema before Build 34 relationship and auth changes.
///
/// This represents the database shape prior to the Tag↔TaskItem inverse
/// annotation fix and the addition of `storedAuthMethod` on ServerAccount.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TaskItem.self,
            TaskList.self,
            JournalEntry.self,
            Tag.self,
            ServerAccount.self,
            SyncMetadata.self,
            SavedFilter.self
        ]
    }
}

// MARK: - Schema V2

/// Current schema: explicit Tag↔TaskItem inverse, optional storedAuthMethod.
enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TaskItem.self,
            TaskList.self,
            JournalEntry.self,
            Tag.self,
            ServerAccount.self,
            SyncMetadata.self,
            SavedFilter.self
        ]
    }
}

// MARK: - Migration Plan

/// Deprecated — no longer used by ModelContainer.
///
/// The V1 → V2 migration plan has been disabled because SchemaV1 and SchemaV2
/// both reference the same compiled `@Model` types, which makes SwiftData produce
/// identical version checksums. On devices with an existing V1 store this causes
/// an unrecoverable `NSException` inside `NSLightweightMigrationStage.init`.
///
/// The V1→V2 changes (adding an optional column + annotation metadata) are
/// inherently lightweight and SwiftData handles them automatically without an
/// explicit migration plan.
enum NowThisMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [] }
    static var stages: [MigrationStage] { [] }
}
