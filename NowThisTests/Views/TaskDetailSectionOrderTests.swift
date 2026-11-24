import Testing
@testable import NowThis

struct TaskDetailSectionOrderTests {
    @Test(arguments: ["", "[]", "malformed"])
    func missingOrInvalidOrderUsesTheOriginalLayout(_ stored: String) {
        #expect(TaskDetailSection.decodeOrder(from: stored) == [
            .title, .status, .dates, .details, .tags, .notes, .photos, .subtasks, .linkedJournals
        ])
    }

    @Test func storedOrderKeepsKnownSectionsAndAppendsMissingOnes() {
        let stored = #"["notes","unknown","title","notes","subtasks"]"#
        #expect(TaskDetailSection.decodeOrder(from: stored) == [
            .notes, .title, .subtasks, .status, .dates, .details, .tags, .photos, .linkedJournals
        ])
    }

    @Test func savedOrderSurvivesARoundTrip() {
        let chosen: [TaskDetailSection] = [
            .notes, .title, .subtasks, .dates, .status, .details, .photos, .tags, .linkedJournals
        ]
        #expect(TaskDetailSection.decodeOrder(from: TaskDetailSection.encodeOrder(chosen)) == chosen)
    }
}
