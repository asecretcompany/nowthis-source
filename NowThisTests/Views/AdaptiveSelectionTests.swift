import SwiftUI
import Testing
@testable import NowThis

@Suite("Adaptive sidebar selection")
@MainActor
struct AdaptiveSelectionTests {
    @Test("Widening a nil selection restores the last list")
    func wideningRestoresLastList() {
        #expect(MainShellView.selectionAfterSizeClassChange(
            current: nil, storedKey: "list:last-list", newClass: .regular) == .taskList("last-list"))
    }

    @Test("Compact and unspecified width keep a nil selection at the sidebar root")
    func compactDoesNotPush() {
        #expect(MainShellView.selectionAfterSizeClassChange(
            current: nil, storedKey: "smart:Today", newClass: .compact) == nil)
        #expect(MainShellView.selectionAfterSizeClassChange(
            current: nil, storedKey: "smart:Today", newClass: nil) == nil)
    }

    @Test("A current user or deep-link selection remains authoritative in either width")
    func currentSelectionWins() {
        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            #expect(MainShellView.selectionAfterSizeClassChange(
                current: .tag("chosen"), storedKey: "smart:Today", newClass: sizeClass) == .tag("chosen"))
        }
    }

    @Test("A compact nil selection does not consume or replace the stored key")
    func roundTripKeepsStoredKey() {
        let key = "filter:last-filter"
        let compact = MainShellView.selectionAfterSizeClassChange(current: nil, storedKey: key, newClass: .compact)
        #expect(compact == nil)
        #expect(MainShellView.selectionAfterSizeClassChange(
            current: compact, storedKey: key, newClass: .regular) == .savedFilter("last-filter"))
    }

    @Test("Preserving a selection does not write its binding or disturb navigation")
    func unchangedSelectionDoesNotWrite() {
        let selections: [SidebarSelection?] = [nil, .smart(.today), .tag("chosen")]
        let sizeClasses: [UserInterfaceSizeClass?] = [nil, .compact, .regular]
        for initial in selections {
            for sizeClass in sizeClasses {
                if initial == nil && sizeClass == .regular { continue }
                var current = initial
                var writes = 0
                let selection = Binding<SidebarSelection?>(get: { current }, set: {
                    current = $0
                    writes += 1
                })
                MainShellView.restoreSelectionAfterSizeClassChange(
                    selection, storedKey: "list:last-list", newClass: sizeClass)
                #expect(current == initial)
                #expect(writes == 0, "Even an equal-value binding write can reset the split view's back navigation")
            }
        }
    }

    @Test("A nil regular-width selection is restored with one binding write")
    func restorationWritesOnce() {
        var current: SidebarSelection?
        var writes = 0
        let selection = Binding<SidebarSelection?>(get: { current }, set: {
            current = $0
            writes += 1
        })
        MainShellView.restoreSelectionAfterSizeClassChange(
            selection, storedKey: "list:last-list", newClass: .regular)
        #expect(current == .taskList("last-list"))
        #expect(writes == 1)
    }

    @Test("Restoration uses the existing malformed-key decoding fallback")
    func malformedKeyUsesExistingDecoder() {
        #expect(MainShellView.selectionAfterSizeClassChange(
            current: nil, storedKey: "invalid-key", newClass: .regular) == .smart(.today))
    }
}
