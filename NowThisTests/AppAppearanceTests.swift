import Testing
import SwiftUI

@testable import NowThis

// MARK: - AppAppearance Tests

@Suite("AppAppearance")
struct AppAppearanceTests {

    @Test("colorScheme mapping: system follows the device (nil), light/dark are explicit")
    func colorSchemeMapping() {
        #expect(AppAppearance.system.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test("Raw values round-trip for @AppStorage persistence")
    func rawValueRoundTrip() {
        #expect(AppAppearance(rawValue: "system") == .system)
        #expect(AppAppearance(rawValue: "light") == .light)
        #expect(AppAppearance(rawValue: "dark") == .dark)
        #expect(AppAppearance(rawValue: "bogus") == nil)
    }

    @Test("All cases present with non-empty display names and SF Symbols")
    func casesAndLabels() {
        #expect(AppAppearance.allCases.count == 3)
        for appearance in AppAppearance.allCases {
            #expect(!appearance.displayName.isEmpty)
            #expect(!appearance.systemImageName.isEmpty)
        }
    }

    @Test("Default storage value resolves to system")
    func defaultResolvesToSystem() {
        let resolved = AppAppearance(rawValue: AppAppearance.system.rawValue) ?? .system
        #expect(resolved == .system)
        #expect(resolved.colorScheme == nil)
    }
}
