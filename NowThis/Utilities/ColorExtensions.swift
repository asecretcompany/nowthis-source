import SwiftUI

extension Color {
    /// Creates a Color from a hex string (e.g., "#FF0000" or "FF0000").
    ///
    /// Supports 6-character `RRGGBB` and 8-character `RRGGBBAA` hex strings, each with an
    /// optional `#` prefix. Returns `nil` if the hex string is invalid.
    ///
    /// The 8-character form is not a nicety: `calendar-color` is Apple's iCal extension and
    /// its convention carries the alpha byte, which is what `CalDAVClient.createCalendar`
    /// writes and what a CalDAV server echoes back on the next PROPFIND. Rejecting it sent
    /// every list colour that made the server round trip to the `?? .blue` fallback at the
    /// render sites — the "colours all return back to blue" report.
    init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanHex = cleanHex.replacingOccurrences(of: "#", with: "")

        guard cleanHex.count == 6 || cleanHex.count == 8 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&rgbValue) else { return nil }

        // Shift the 6-digit form up by a fully opaque alpha byte so both widths share
        // one set of masks.
        let rgba = cleanHex.count == 8 ? rgbValue : (rgbValue << 8) | 0xFF

        let red = Double((rgba & 0xFF00_0000) >> 24) / 255.0
        let green = Double((rgba & 0x00FF_0000) >> 16) / 255.0
        let blue = Double((rgba & 0x0000_FF00) >> 8) / 255.0
        let alpha = Double(rgba & 0x0000_00FF) / 255.0

        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}
