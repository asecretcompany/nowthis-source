import Foundation

/// One parsed resource supplies import, history and deletion accounting metadata.
struct ParsedRemoteTask: Sendable {
    let href: String
    let etag: String
    let todo: ICalendarParser.VTODOData?
}
