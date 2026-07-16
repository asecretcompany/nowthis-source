import Testing
import Foundation

@testable import NowThis

/// The CTag delta check lets `SyncEngine` skip the inbound pull when the server
/// collection looks unchanged. Trusting CTag equality alone caused silent data
/// loss: a stale/cached `getctag` equal to the stored one suppressed every
/// server-side create/edit/reorder indefinitely. `shouldSkipPull` bounds the
/// optimization so an equal CTag can only skip a *recent* full pull.
@Suite("Sync pull-skip decision")
struct SyncPullSkipTests {

    private let interval: TimeInterval = 600 // 10 minutes
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("Different CTags always force a pull")
    func differentCTagsPull() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "ctag-A",
                remoteCTag: "ctag-B",
                lastFullPull: now.addingTimeInterval(-30),
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }

    @Test("Equal CTags still force a pull when no full pull has happened yet")
    func equalCTagsButNeverPulledPull() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "ctag-A",
                remoteCTag: "ctag-A",
                lastFullPull: nil,
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }

    @Test("Equal CTags force a pull once the last full pull is stale (safety override)")
    func equalCTagsButStalePull() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "ctag-A",
                remoteCTag: "ctag-A",
                lastFullPull: now.addingTimeInterval(-(interval + 60)),
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }

    @Test("A backward clock jump (last full pull in the future) forces a pull")
    func futureLastFullPullForcesPull() {
        // Device clock moved backward (NTP correction, manual change): the last
        // full pull now appears to be in the future. A negative elapsed interval
        // must not be treated as "recent" or server changes would be suppressed.
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "ctag-A",
                remoteCTag: "ctag-A",
                lastFullPull: now.addingTimeInterval(300),
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }

    @Test("Equal CTags skip the pull only when a full pull happened recently")
    func equalCTagsRecentSkips() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "ctag-A",
                remoteCTag: "ctag-A",
                lastFullPull: now.addingTimeInterval(-30),
                now: now,
                maxSkipInterval: interval
            ) == true
        )
    }

    @Test("A nil local CTag forces a pull")
    func nilLocalCTagPulls() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: nil,
                remoteCTag: "ctag-A",
                lastFullPull: now.addingTimeInterval(-30),
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }

    @Test("An empty local CTag forces a pull")
    func emptyLocalCTagPulls() {
        #expect(
            SyncEngine.shouldSkipPull(
                localCTag: "",
                remoteCTag: "",
                lastFullPull: now.addingTimeInterval(-30),
                now: now,
                maxSkipInterval: interval
            ) == false
        )
    }
}
