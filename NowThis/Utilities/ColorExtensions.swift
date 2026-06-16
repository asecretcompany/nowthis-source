import SwiftUI

extension Color {
    /// Creates a Color from a hex string (e.g., "#FF0000" or "FF0000").
    ///
    /// Supports 6-character hex strings with optional `#` prefix.
    /// Returns `nil` if the hex string is invalid.
    init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanHex = cleanHex.replacingOccurrences(of: "#", with: "")

        guard cleanHex.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&rgbValue) else { return nil }

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}
