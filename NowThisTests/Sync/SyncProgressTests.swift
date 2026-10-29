import Testing
@testable import NowThis

@Suite("Sync progress state")
struct SyncProgressTests {
    @MainActor
    @Test("Applying progress clamps counts and deduplicates equivalent updates")
    func applyClampsAndDeduplicates() {
        let state = SyncProgressState()

        #expect(state.apply(.init(accountID: "account", listID: nil, stage: .downloading,
                                  completed: -4, total: 3)))
        #expect(state.current?.completed == 0)
        #expect(state.current?.total == 3)

        #expect(!state.apply(.init(accountID: "account", listID: nil, stage: .downloading,
                                   completed: 0, total: 3)))
        #expect(state.current?.completed == 0)

        #expect(state.apply(.init(accountID: "account", listID: nil, stage: .downloading,
                                  completed: 8, total: 3)))
        #expect(state.current?.completed == 3)

        #expect(state.apply(.init(accountID: "account", listID: nil, stage: .downloading,
                                  completed: -2, total: -1)))
        #expect(state.current?.completed == 0)
        #expect(state.current?.total == 0)
    }

    @MainActor
    @Test("Clearing progress removes the current update")
    func clearRemovesProgress() {
        let state = SyncProgressState()
        #expect(state.apply(.init(accountID: "account", listID: "list", stage: .applying,
                                  completed: 8, total: 5)))

        state.clear()

        #expect(state.current == nil)
    }
}
