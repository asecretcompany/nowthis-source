import Foundation
import Testing

@Suite("Permanent free functional access")
struct FreeFeatureAccessGuardTests {
    private static func violations(_ source: String) -> [String] {
        let code = source.replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\n]*"#, with: "", options: .regularExpression)
        return ["ProEntitlement", "ProAccessSnapshot", "ProEntitlementCache", "ProProductCatalog", "isProUnlocked"].filter(code.contains)
    }

    @Test func productivityAndWidgetSourcesRemainUngated() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let directories = ["NowThis/Views", "NowThis/Models", "NowThis/Services", "NowThis/Sync", "NowThis/Parser", "NowThis/Intents", "NowThisWidget", "NowThisWatchWidget"]
        var count = 0
        var findings: [String] = []
        for directory in directories {
            let url = root.appendingPathComponent(directory)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                if file.path.contains("/Views/Settings/") { continue }
                count += 1
                let source = try String(contentsOf: file, encoding: .utf8)
                if !Self.violations(source).isEmpty { findings.append(file.lastPathComponent) }
            }
        }
        #expect(count > 0)
        #expect(findings.isEmpty, "Pro dependency in free functional sources: \(findings)")
    }

    @Test func guardCatchesPlantedGatesAndIgnoresComments() {
        #expect(Self.violations("if ProEntitlement.cachedUnlocked() { TaskEditor() }") == ["ProEntitlement"])
        #expect(Self.violations("// ProEntitlement must not gate viewing\nTaskEditor()").isEmpty)
        #expect(Self.violations("if isProUnlocked { renderWidget() }") == ["isProUnlocked"])
    }
}
