import Foundation
import SwiftData
import Testing
@testable import NowThis

@MainActor
final class SpySession: WatchSessionProtocol {
    var isPaired = true
    var isWatchAppInstalled = true
    var pushedContexts: [[String: Any]] = []
    func updateApplicationContext(_ context: [String: Any]) throws { pushedContexts.append(context) }
}

@Suite("WatchBridge triggers")
@MainActor
struct WatchBridgeSnapshotTriggerTests {
    @MainActor
    private final class EntitlementFixture {
        let suite = "NowThis.WatchBridgeEntitlement.\(UUID().uuidString)"
        let defaults: UserDefaults
        let entitlement: ProEntitlement

        init() {
            defaults = UserDefaults(suiteName: suite)!
            entitlement = ProEntitlement(client: ProStoreTestClient(),
                cache: ProEntitlementCache(defaults: defaults),
                testerBuild: { false }, forcePaywall: { false })
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(SchemaV2.models)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func waitForPush(_ spy: SpySession, count: Int = 1) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while spy.pushedContexts.count < count && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func accessChangesPushWithoutASyncAndSeparateTesterAccess() async throws {
        let container = try makeContainer()
        let spy = SpySession()
        let fixture = EntitlementFixture()
        defer { fixture.cleanUp() }
        let entitlement = fixture.entitlement
        let bridge = WatchBridge(session: spy, entitlement: entitlement, syncScheduler: SyncScheduler(), modelContainer: container)
        bridge.activate()
        entitlement.isTesterBuild = true
        await waitForPush(spy)
        let snapshot = try #require(spy.pushedContexts.last.flatMap(WatchSnapshot.init(contextDictionary:)))
        #expect(!snapshot.isProUnlocked)
        #expect(snapshot.testerProOverride == true)
        #expect(snapshot.canEditTasks(at: Date()))
    }

    @Test func pushSnapshotSendsDecodableSnapshotWithEntitlementFlag() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "https://example.com/cal/", name: "Inbox", colorHex: "#007AFF")
        context.insert(list)

        let task = TaskItem(title: "Due today")
        task.dueDate = Date()
        task.isDueDateOnly = false
        task.taskList = list
        context.insert(task)

        try context.save()

        let spy = SpySession()
        let fixture = EntitlementFixture()
        defer { fixture.cleanUp() }
        let bridge = WatchBridge(
            session: spy,
            entitlement: fixture.entitlement,
            syncScheduler: SyncScheduler(),
            modelContainer: container
        )

        bridge.pushSnapshot()
        await waitForPush(spy)

        #expect(spy.pushedContexts.count == 1)
        let snap = try #require(WatchSnapshot(contextDictionary: spy.pushedContexts[0]))
        #expect(snap.isProUnlocked == false)
        #expect(snap.tasks.count == 1)
    }

    /// Covers the data-refresh push path: `handleDataRefresh()` (the hook the
    /// `activate()` subscription invokes) triggers exactly one snapshot push, and
    /// `activate()` itself does NOT push on subscribe (the `.dropFirst()` guard).
    /// It does NOT cover "a `dataRefreshToken` change fires the sink": that token is
    /// `@Published private(set)` on `SyncScheduler`, bumped only inside a completed
    /// full sync, so the subscription's change-delivery is unreachable from a unit
    /// test — verified by inspection/integration instead. (Flagged for final review.)
    @Test func handleDataRefreshTriggersPush() async throws {
        let container = try makeContainer()
        let spy = SpySession()
        let scheduler = SyncScheduler()
        let fixture = EntitlementFixture()
        defer { fixture.cleanUp() }
        let bridge = WatchBridge(
            session: spy,
            entitlement: fixture.entitlement,
            syncScheduler: scheduler,
            modelContainer: container
        )
        bridge.activate()
        // `activate()` wires the `.dropFirst()` subscription but must not itself push.
        #expect(spy.pushedContexts.isEmpty)

        bridge.handleDataRefresh()
        await waitForPush(spy)

        #expect(spy.pushedContexts.count == 1)
    }
}
