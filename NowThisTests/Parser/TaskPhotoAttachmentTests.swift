import Foundation
import Testing
@testable import NowThis

struct TaskPhotoAttachmentTests {
    private let photoID = "AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4"
    private let jpeg = TaskPhotoJPEGFixture.data

    @Test func inlinePhotoSurvivesRoundTrip() throws {
        // Dropping ATTACH from either parser or serializer loses a shared task photo.
        let photo = TaskPhotoAttachment(id: photoID, previewData: jpeg,
            originalFileID: "731", folderFileID: "730", originalRequested: true)
        let ics = ICalendarSerializer.serialize(uid: "task-photo", summary: "Snack inspection",
            photos: [photo])
        #expect(ics.contains("ATTACH;"))
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from: ics))
        #expect(parsed.photos == [photo])
    }

    @Test func unsupportedAttachmentSurvivesTitleEdit() throws {
        let original = "ATTACH;FMTTYPE=application/pdf:https://cloud.example.com/manual.pdf"
        let parsed = try #require(try ICalendarParser.parseSingleVTODO(from:
            "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:manual\r\nSUMMARY:Old\r\n" + original + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"))
        #expect(parsed.opaqueAttachments == [original])
        let rewritten = ICalendarSerializer.serialize(uid: parsed.uid, summary: "New",
            photos: parsed.photos, opaqueAttachments: parsed.opaqueAttachments)
        #expect(rewritten.contains(original))
    }
    @Test func malformedOwnedPhotoStopsImport() {
        let raw = "ATTACH;FMTTYPE=image/jpeg;ENCODING=BASE64;VALUE=BINARY;X-NOWTHIS-PHOTO-ID=AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4:invalid!"
        #expect(throws: (any Error).self) {
            try ICalendarParser.parseSingleVTODO(from: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:broken\r\n" + raw + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        }
    }
    @Test func oversizedOwnedPhotoStopsImport() {
        let bytes = Data([0xff, 0xd8, 0xff]) + Data(repeating: 0, count: 250_000)
        let raw = "ATTACH;FMTTYPE=image/jpeg;ENCODING=BASE64;VALUE=BINARY;X-NOWTHIS-PHOTO-ID=AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4:" + bytes.base64EncodedString()
        #expect(throws: (any Error).self) {
            try ICalendarParser.parseSingleVTODO(from: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:broken\r\n" + raw + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        }
    }
    @Test func opaqueAttachmentCannotInjectAnotherProperty() {
        let injected = "ATTACH:https://example.com/image\r\nSUMMARY:Injected"
        let ics = ICalendarSerializer.serialize(uid: "safe", summary: "Real", opaqueAttachments: [injected, "UID:evil"])
        #expect(!ics.contains("Injected"))
        #expect(!ics.contains("UID:evil"))
    }

    @Test func sixthIncomingPhotoIsRejectedBeforeItCanBlockTaskEdits() throws {
        let photos = (0..<6).map { _ in TaskPhotoAttachment(id: UUID().uuidString, previewData: jpeg) }
        let ics = ICalendarSerializer.serialize(uid: "over-limit", summary: "Shared", photos: photos)
        #expect(throws: TaskPhotoAttachmentError.self) { try ICalendarParser.parseSingleVTODO(from: ics) }
    }

    @Test func base64WithFakeJpegHeaderIsRejected() {
        let raw = "ATTACH;FMTTYPE=image/jpeg;ENCODING=BASE64;VALUE=BINARY;X-NOWTHIS-PHOTO-ID=AD2E616C-55C0-4F7C-A3C4-32AD464EC9E4:/9j/AAAA"
        #expect(throws: (any Error).self) {
            try ICalendarParser.parseSingleVTODO(from: "BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nUID:fake\r\n" + raw + "\r\nEND:VTODO\r\nEND:VCALENDAR\r\n")
        }
    }

}
