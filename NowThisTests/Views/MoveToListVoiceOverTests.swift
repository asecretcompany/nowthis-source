import Foundation
import Testing

@testable import NowThis

/// **Move to List… reaches VoiceOver wherever the menu offers it.**
///
/// A task row and a board card each combine their children into one element and speak their
/// menu's actions as named VoiceOver actions. A menu item with no matching action is one a
/// VoiceOver user can reach only by going somewhere else — here, the task's details.
@Suite("Move to List… as a VoiceOver action")
struct MoveToListVoiceOverTests {

    static let surfaces = [
        "NowThis/Views/Tasks/TaskRowView.swift",
        "NowThis/Views/Kanban/KanbanColumnView.swift",
    ]

    @Test("A task row and a board card both offer Move to List… as a VoiceOver action")
    func everyMenuThatMovesAlsoSpeaksIt() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        var examined = 0
        var missing: [String] = []

        for file in Self.surfaces {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let code = SwiftSourceScanner.strippingComments(source)
            examined += 1
            // The body of each `.accessibilityActions { … }` block, up to the next modifier.
            let blocks = code.components(separatedBy: ".accessibilityActions {").dropFirst()
                .map { $0.components(separatedBy: "\n        .").first ?? $0 }
            let speaksMove = blocks.contains {
                $0.contains("Move to List…") || $0.contains("moveToListButton(")
            }
            if !speaksMove { missing.append(file) }
        }

        #expect(examined == Self.surfaces.count, "Examined \(examined) of \(Self.surfaces.count) files.")
        #expect(missing.isEmpty, """
            These views offer Move to List… in a menu but not as a VoiceOver action: \(missing). \
            Add it inside `.accessibilityActions { }`, shown only when `MoveDestinations.canMove` is true.
            """)
    }
}
