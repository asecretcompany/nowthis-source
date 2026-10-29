import Testing
import Foundation
import SwiftData

@testable import NowThis

// MARK: - List Metadata Round Trip

/// Covers the rule that keeps a user's list colour: a locally edited name or colour is
/// not replaced by the server's copy until that edit has actually been pushed.
///
/// Calendar discovery adopted the remote name and colour unconditionally, on every sync,
/// before the CTag delta-skip even ran — and nothing ever sent a colour change back, since
/// the client had no PROPPATCH at all. So recolouring a list was a local change that the
/// next sync (about two seconds later) reverted. That is the "colours all return back to
/// blue" report, and the blue itself came from the `?? .blue` fallback at the render sites.
@Suite("Sync — List Metadata")
@MainActor
struct SyncListMetadataTests {

    /// Held by the caller for the test's lifetime — returning `.mainContext` from a factory
    /// deallocates the container out from under the context and SIGTRAPs the test process.
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TaskItem.self, TaskList.self, JournalEntry.self,
                 Tag.self, ServerAccount.self, SyncMetadata.self, SavedFilter.self,
            configurations: config
        )
    }

    @Test("A list with an unpushed colour edit keeps it when the server says otherwise")
    func dirtyListKeepsLocalColor() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#FF3B30")
        list.isMetadataDirty = true
        context.insert(list)

        list.applyRemoteMetadata(name: "Work", colorHex: "#007AFFFF")

        #expect(list.colorHex == "#FF3B30",
                "an unpushed colour edit must survive the discovery pass that follows it")
    }

    @Test("A list with no local edit adopts the server's colour")
    func cleanListAdoptsRemoteColor() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#007AFF")
        context.insert(list)

        list.applyRemoteMetadata(name: "Work Renamed", colorHex: "#34C759FF")

        #expect(list.colorHex == "#34C759FF", "a colour set on another device must still arrive")
        #expect(list.name == "Work Renamed", "so must a rename")
    }

    @Test("An empty remote colour never blanks the local one")
    func emptyRemoteColorIgnored() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let list = TaskList(serverURL: "/calendars/x/", name: "Work", colorHex: "#FF3B30")
        context.insert(list)

        list.applyRemoteMetadata(name: "Work", colorHex: "")

        #expect(list.colorHex == "#FF3B30", "a server with no colour set says nothing, not 'none'")
    }

    @Test("The PROPPATCH body carries the display name and an 8-digit colour")
    func propPatchBodyIsWellFormed() {
        let body = CalDAVClient.calendarPropertyPatchBody(name: "Work", colorHex: "#FF3B30")

        #expect(body.contains("<d:displayname>Work</d:displayname>"))
        #expect(body.contains("#FF3B30FF"),
                "calendar-color is Apple's extension and its convention carries the alpha byte")
        #expect(body.contains("propertyupdate"), "a PROPPATCH body is a propertyupdate document")
    }

    @Test("A colour that already carries alpha is not given a second one")
    func propPatchBodyDoesNotDoubleAlpha() {
        let body = CalDAVClient.calendarPropertyPatchBody(name: "Work", colorHex: "#FF3B30FF")

        #expect(body.contains("#FF3B30FF"))
        #expect(!body.contains("#FF3B30FFFF"), "appending alpha blindly is what corrupted it")
    }
}
