import Testing
import SwiftUI

@testable import NowThis

// MARK: - Hex Colour Parsing

/// Covers ``SwiftUI/Color/init(hex:)`` — specifically the 8-digit `RRGGBBAA` form.
///
/// CalDAV's `calendar-color` is Apple's own iCal extension, and its convention is
/// `#RRGGBBAA`: `CalDAVClient.createCalendar` appends the opaque alpha byte when it
/// creates a calendar, and a server echoes that same 8-digit value back on the next
/// PROPFIND. The parser only ever accepted 6, so every colour that made the round trip
/// came back `nil` and every list render site fell through to its `?? .blue` default —
/// which is what a user sees as "the colours all return back to blue".
@Suite("Hex Colour Parsing")
struct ColorHexTests {

    @Test("An 8-digit RRGGBBAA hex parses as its RGB colour")
    func eightDigitHexParses() {
        let withAlpha = Color(hex: "#FF3B30FF")
        #expect(withAlpha != nil, "#RRGGBBAA is the calendar-color convention and must parse")
        #expect(withAlpha == Color(hex: "#FF3B30"),
                "the alpha byte must not change which colour this is")
    }

    @Test("A hex of any other length is still rejected")
    func otherLengthsRejected() {
        #expect(Color(hex: "#FF3B3") == nil, "5 digits is not a colour")
        #expect(Color(hex: "#FF3B30F") == nil, "7 digits is not a colour")
        #expect(Color(hex: "#FF3B30FFF") == nil, "9 digits is not a colour")
        #expect(Color(hex: "") == nil, "empty is not a colour")
    }
}
