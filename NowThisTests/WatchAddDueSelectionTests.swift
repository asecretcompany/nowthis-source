import Foundation
import Testing
@testable import NowThis

struct WatchAddDueSelectionTests {
    private let original = ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z")!

    @Test func retainedDateIsSelectedInsteadOfNoneAndExplicitNoneRemovesIt() {
        var selection = WatchAddDueSelection(retainedDate: original)
        #expect(selection.selectedPreset == nil)
        #expect(selection.resolvedDate() == original)
        selection.select(.none)
        #expect(selection.selectedPreset == DefaultDueDateRule.none)
        #expect(selection.resolvedDate() == nil)
        #expect(selection.retainedDate == nil)
    }

    @Test func presetReplacesRetainedDateAndRemoveLeavesNoDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = ISO8601DateFormatter().date(from: "2026-10-24T02:00:00Z")!
        var selection = WatchAddDueSelection(retainedDate: original)
        selection.select(.nextWeek)
        #expect(selection.selectedPreset == .nextWeek)
        #expect(selection.retainedDate == nil)
        #expect(selection.resolvedDate(now: now, calendar: calendar) == ISO8601DateFormatter().date(from: "2026-10-30T00:00:00Z"))
        selection.removeDate()
        #expect(selection.selectedPreset == DefaultDueDateRule.none)
        #expect(selection.resolvedDate(now: now, calendar: calendar) == nil)
    }

    @Test(arguments: ["America/Los_Angeles", "Asia/Tokyo"])
    func retainedDateDisplaysItsCalendarDayWithoutChangingSubmission(zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let selection = WatchAddDueSelection(retainedDate: original)
        let display = try #require(selection.retainedDateForDisplay(calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: display)
        #expect(components.year == 2026)
        #expect(components.month == 10)
        #expect(components.day == 24)
        #expect(components.hour == 0)
        #expect(selection.resolvedDate(calendar: calendar) == original)
    }
}
