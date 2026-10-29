import Foundation
import SwiftData
import Testing
@testable import NowThis

/// Covers `WatchBridge.isWatchPairedAndInstalled`, the pure seam the Settings
/// paywall's contextual upsell reads to decide whether to show "You have an
/// Apple Watch — unlock NowThis Pro". Mirrors the `SpySession` pattern from
/// `WatchBridgeSnapshotTriggerTests.swift`.
@Suite("WatchBridge isWatchPairedAndInstalled")
@MainActor
struct WatchBridgeIsWatchPairedAndInstalledTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func trueWhenPairedAndInstalled() throws {
        let spy = SpySession()
        spy.isPaired = true
        spy.isWatchAppInstalled = true
        let bridge = WatchBridge(
            session: spy,
            entitlement: ProEntitlement(),
            syncScheduler: SyncScheduler(),
            modelContainer: try makeContainer()
        )

        #expect(bridge.isWatchPairedAndInstalled == true)
    }

    @Test func falseWhenNotPaired() throws {
        let spy = SpySession()
        spy.isPaired = false
        spy.isWatchAppInstalled = true
        let bridge = WatchBridge(
            session: spy,
            entitlement: ProEntitlement(),
            syncScheduler: SyncScheduler(),
            modelContainer: try makeContainer()
        )

        #expect(bridge.isWatchPairedAndInstalled == false)
    }

    @Test func falseWhenAppNotInstalled() throws {
        let spy = SpySession()
        spy.isPaired = true
        spy.isWatchAppInstalled = false
        let bridge = WatchBridge(
            session: spy,
            entitlement: ProEntitlement(),
            syncScheduler: SyncScheduler(),
            modelContainer: try makeContainer()
        )

        #expect(bridge.isWatchPairedAndInstalled == false)
    }

    @Test func falseWhenSessionIsNil() throws {
        let bridge = WatchBridge(
            session: nil,
            entitlement: ProEntitlement(),
            syncScheduler: SyncScheduler(),
            modelContainer: try makeContainer()
        )

        #expect(bridge.isWatchPairedAndInstalled == false)
    }
}
