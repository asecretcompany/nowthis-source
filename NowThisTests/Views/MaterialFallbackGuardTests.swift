import Foundation
import Testing

@testable import NowThis

/// **A material is not glass, and iOS 27's Tint Amount slider can tell the difference.**
///
/// iOS 27 adds Settings → Appearance → Liquid Glass → Tint Amount. Measured on the iOS 27.0
/// simulator over a black backdrop, `.glassEffect(.regular)` follows it the way system chrome does
/// — mean luma 133 → 179 from the default to fully tinted, beside a toolbar button's 131 → 176 —
/// while `.regularMaterial` and `.ultraThinMaterial` render byte-identical at both settings. A
/// surface drawn with a material stays put while every glass surface around it moves.
///
/// So on iOS 26 and later a surface is glass, and a material appears only as the iOS 18–25
/// fallback, in the `else` of an `#available(iOS 26.0, *)` check.
@Suite("Material backgrounds are pre-iOS 26 fallbacks")
struct MaterialFallbackGuardTests {

    private static let materialBackground =
        #"background\(\s*\.(ultraThin|thin|regular|thick|ultraThick)Material\b"#

    @Test("Every material background sits in the else of an iOS 26 availability check")
    func everyMaterialIsAFallback() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var unconditional: [String] = []

        for file in try LocalizationCatalogFixture.swiftSourceFiles() where file.hasPrefix("NowThis/") {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let lines = SwiftSourceScanner.strippingComments(source).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.range(of: Self.materialBackground, options: .regularExpression) != nil {
                examined += 1
                let before = lines[max(0, index - 6)..<index]
                let elseAt = before.lastIndex { $0.contains("} else {") }
                let availableAt = before.lastIndex { $0.contains("#available(iOS 26") }
                if let elseAt, let availableAt, availableAt < elseAt { continue }
                unconditional.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(examined >= 4, """
            Found \(examined) material backgrounds in NowThis/; there were 4 when this guard was \
            written (two in GlassStyle, one each in FilterChipView and InlineAddBar). Fewer means \
            the scan stopped seeing them, not that they went away.
            """)
        #expect(unconditional.isEmpty, """
            These material backgrounds also draw on iOS 26 and later, where they ignore the Liquid \
            Glass Tint Amount setting that every glass surface around them follows: \
            \(unconditional). Use `.glassEffect(.regular, in:)` on iOS 26+ and keep the material \
            in the `else` of an `#available(iOS 26.0, *)` check.
            """)
    }
}
