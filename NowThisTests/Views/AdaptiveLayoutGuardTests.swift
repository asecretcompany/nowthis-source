import Foundation
import Testing

@Suite("Adaptive layout API guard")
struct AdaptiveLayoutGuardTests {
    @Test("The scanner detects each forbidden API, including wrapped member access", arguments: [
        "UIScreen.main.bounds", "UIScreen.screens", "traits.userInterfaceIdiom",
        "scene.interfaceOrientation", "scene.effectiveGeometry.interfaceOrientation",
        "UIApplication.shared.statusBarOrientation", "UIDevice.current.orientation",
        "UIApplication.shared.windows", "UIApplication.shared.keyWindow", "application.keyWindow",
        "UIScreen\n . main.bounds", "UIDevice . current\n . orientation"
    ])
    func detectsForbiddenAPI(source: String) {
        #expect(!Self.forbiddenAPIs(in: source).isEmpty, "Missed forbidden layout API: \(source)")
    }

    @Test("Comments, literals, valid local window properties and similar names are not APIs")
    func ignoresNonCodeAndAllowedNames() {
        let source = #"""
        // UIScreen.main.bounds
        /* UIDevice.current.orientation /* scene.interfaceOrientation */ */
        let explanation = "UIApplication.shared.windows"
        let raw = #"UIScreen.screens"#
        let selected = windows.first(where: \.isKeyWindow)
        let interfaceOrientationDescription = "portrait"
        let userInterfaceIdiomDescription = "example"
        let keyWindowDescription = "window"
        let mainScreen = view.window?.windowScene?.screen
        let scale = traits.displayScale
        """#
        #expect(Self.forbiddenAPIs(in: source).isEmpty)
    }

    @Test("App and widget source stay free of screen, idiom and orientation layout APIs")
    func shippingSourcesAreAdaptive() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let files = try LocalizationCatalogFixture.swiftSourceFiles()
        for sourceRoot in ["NowThis/", "NowThisWidget/"] {
            let examined = files.filter { $0.hasPrefix(sourceRoot) }
            #expect(!examined.isEmpty, "The guard must examine files in \(sourceRoot)")
            for file in examined {
                let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                #expect(Self.forbiddenAPIs(in: source).isEmpty, "Forbidden layout API in \(file)")
            }
        }
    }

    private static func forbiddenAPIs(in source: String) -> [String] {
        let code = SwiftSourceScanner.redactedForStructure(source)
        let patterns = [
            #"\bUIScreen\s*\.\s*(?:main|screens)\b"#,
            #"\buserInterfaceIdiom\b"#,
            #"\b(?:interfaceOrientation|statusBarOrientation)\b"#,
            #"\bUIDevice\s*\.\s*current\s*\.\s*orientation\b"#,
            #"\bUIApplication\s*\.\s*shared\s*\.\s*windows\b"#,
            #"\.\s*keyWindow\b"#
        ]
        return patterns.filter { code.range(of: $0, options: .regularExpression) != nil }
    }
}
