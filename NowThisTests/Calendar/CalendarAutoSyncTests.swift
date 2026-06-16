import Testing
import Foundation

@testable import NowThis

@Suite("CalendarAutoSync")
struct CalendarAutoSyncTests {

    @Test("Syncs task to Apple Calendar when enabled and task has dueDate")
    @MainActor
    func syncsWhenEnabledAndHasDueDate() async throws {
        // Given: Apple Calendar sync is enabled
        UserDefaults.standard.set(true, forKey: "appleCalendarSyncEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "appleCalendarSyncEnabled") }

        let task = TaskItem(title: "Test task")
        task.dueDate = Date()

        // When
        let result = CalendarAutoSync.shouldSyncToAppleCalendar(task)

        // Then
        #expect(result == true, "Should sync when enabled and task has dueDate")
    }

    @Test("Does NOT sync when Apple Calendar sync is disabled")
    @MainActor
    func doesNotSyncWhenDisabled() async throws {
        // Given: Apple Calendar sync is disabled
        UserDefaults.standard.set(false, forKey: "appleCalendarSyncEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "appleCalendarSyncEnabled") }

        let task = TaskItem(title: "Test task")
        task.dueDate = Date()

        // When
        let result = CalendarAutoSync.shouldSyncToAppleCalendar(task)

        // Then
        #expect(result == false, "Should NOT sync when disabled")
    }

    @Test("Does NOT sync when task has no dueDate")
    @MainActor
    func doesNotSyncWithoutDueDate() async throws {
        // Given: Apple Calendar sync is enabled but task has no due date
        UserDefaults.standard.set(true, forKey: "appleCalendarSyncEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "appleCalendarSyncEnabled") }

        let task = TaskItem(title: "Test task")
        task.dueDate = nil

        // When
        let result = CalendarAutoSync.shouldSyncToAppleCalendar(task)

        // Then
        #expect(result == false, "Should NOT sync when task has no dueDate")
    }

    @Test("Syncs task to Nextcloud Calendar when enabled and task has dueDate")
    @MainActor
    func syncsToNextcloudWhenEnabled() async throws {
        // Given
        UserDefaults.standard.set(true, forKey: "nextcloudCalendarSyncEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "nextcloudCalendarSyncEnabled") }

        let task = TaskItem(title: "Test task")
        task.dueDate = Date()

        // When
        let result = CalendarAutoSync.shouldSyncToNextcloudCalendar(task)

        // Then
        #expect(result == true, "Should sync to Nextcloud when enabled and task has dueDate")
    }

    @Test("Does NOT sync to Nextcloud when disabled")
    @MainActor
    func doesNotSyncToNextcloudWhenDisabled() async throws {
        // Given
        UserDefaults.standard.set(false, forKey: "nextcloudCalendarSyncEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "nextcloudCalendarSyncEnabled") }

        let task = TaskItem(title: "Test task")
        task.dueDate = Date()

        // When
        let result = CalendarAutoSync.shouldSyncToNextcloudCalendar(task)

        // Then
        #expect(result == false, "Should NOT sync to Nextcloud when disabled")
    }
}
