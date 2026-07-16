import Testing
import Foundation

@testable import NowThis

@Suite("Sync Preferences Defaults")
struct SyncPreferencesTests {

    /// Returns a clean, isolated UserDefaults suite for a single test.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "SyncPreferencesTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Window months defaults to 3 when the key was never set")
    func defaultsToThreeMonths() {
        let defaults = makeDefaults("unset")
        #expect(SyncPreferences.windowMonths(defaults) == 3)
    }

    @Test("Explicitly choosing All (0) is preserved, not overridden by the default")
    func explicitAllIsPreserved() {
        let defaults = makeDefaults("all")
        defaults.set(0, forKey: SyncPreferences.windowMonthsKey)
        #expect(SyncPreferences.windowMonths(defaults) == 0)
    }

    @Test("An explicitly chosen window is returned unchanged")
    func explicitValueIsReturned() {
        let defaults = makeDefaults("six")
        defaults.set(6, forKey: SyncPreferences.windowMonthsKey)
        #expect(SyncPreferences.windowMonths(defaults) == 6)
    }
}
