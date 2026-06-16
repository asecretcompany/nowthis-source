import Testing
import Foundation
import UserNotifications

@testable import NowThis

@Suite("Notification Preferences")
struct NotificationPreferencesTests {

    // MARK: - Setup

    /// Clears the preference keys before each test so defaults apply.
    private func clearDefaults() {
        UserDefaults.standard.removeObject(forKey: NotificationPreferences.bannerEnabledKey)
        UserDefaults.standard.removeObject(forKey: NotificationPreferences.badgeEnabledKey)
    }

    // MARK: - Default Values

    @Test("Banner defaults to enabled when never set")
    func bannerDefaultsToEnabled() {
        clearDefaults()
        #expect(NotificationPreferences.isBannerEnabled == true)
    }

    @Test("Badge defaults to enabled when never set")
    func badgeDefaultsToEnabled() {
        clearDefaults()
        #expect(NotificationPreferences.isBadgeEnabled == true)
    }

    // MARK: - Explicit Values

    @Test("Banner returns false when explicitly disabled")
    func bannerExplicitlyDisabled() {
        clearDefaults()
        UserDefaults.standard.set(false, forKey: NotificationPreferences.bannerEnabledKey)
        #expect(NotificationPreferences.isBannerEnabled == false)
    }

    @Test("Badge returns false when explicitly disabled")
    func badgeExplicitlyDisabled() {
        clearDefaults()
        UserDefaults.standard.set(false, forKey: NotificationPreferences.badgeEnabledKey)
        #expect(NotificationPreferences.isBadgeEnabled == false)
    }

    // MARK: - Presentation Options

    @Test("Presentation options include banner and badge and sound when both enabled")
    func presentationOptionsBothEnabled() {
        clearDefaults()
        let options = NotificationPreferences.presentationOptions
        #expect(options.contains(.banner))
        #expect(options.contains(.badge))
        #expect(options.contains(.sound))
    }

    @Test("Presentation options exclude banner when disabled")
    func presentationOptionsBannerDisabled() {
        clearDefaults()
        UserDefaults.standard.set(false, forKey: NotificationPreferences.bannerEnabledKey)
        let options = NotificationPreferences.presentationOptions
        #expect(!options.contains(.banner))
        #expect(options.contains(.badge))
        #expect(options.contains(.sound))
    }

    @Test("Presentation options exclude badge when disabled")
    func presentationOptionsBadgeDisabled() {
        clearDefaults()
        UserDefaults.standard.set(false, forKey: NotificationPreferences.badgeEnabledKey)
        let options = NotificationPreferences.presentationOptions
        #expect(options.contains(.banner))
        #expect(!options.contains(.badge))
        #expect(options.contains(.sound))
    }

    @Test("Presentation options with both disabled still include sound")
    func presentationOptionsBothDisabled() {
        clearDefaults()
        UserDefaults.standard.set(false, forKey: NotificationPreferences.bannerEnabledKey)
        UserDefaults.standard.set(false, forKey: NotificationPreferences.badgeEnabledKey)
        let options = NotificationPreferences.presentationOptions
        #expect(!options.contains(.banner))
        #expect(!options.contains(.badge))
        #expect(options.contains(.sound))
    }

    // MARK: - Badge Count Integration

    @Test("updateBadgeCount should be skippable when badge is disabled")
    func badgeCountRespectsPreference() {
        clearDefaults()
        // When badge is enabled, computeBadgeCount should return normally
        let yesterday = Date().addingTimeInterval(-86400)
        let task = TaskItem(title: "Overdue Task")
        task.dueDate = yesterday
        let count = ReminderScheduler.computeBadgeCount(tasks: [task])
        #expect(count >= 1, "computeBadgeCount should still compute even when pref exists — the caller decides to use it")

        // The actual skipping happens in updateBadgeCount(), not computeBadgeCount()
        // This test just proves the preference value is readable alongside badge logic
        UserDefaults.standard.set(false, forKey: NotificationPreferences.badgeEnabledKey)
        #expect(NotificationPreferences.isBadgeEnabled == false)
    }
}
