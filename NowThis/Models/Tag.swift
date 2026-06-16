import Foundation
import SwiftData

/// Represents a category/label applied to tasks.
///
/// Maps to the iCalendar CATEGORIES property (RFC-5545 §3.8.1.2).
/// Multiple tags can be applied to a single task, and a single tag
/// can be shared across multiple tasks (many-to-many).
@Model
final class Tag {

    // MARK: - Identity

    /// Local unique identifier.
    @Attribute(.unique) var id: String

    /// User-facing tag name. Maps to individual CATEGORIES values.
    var name: String

    /// Optional hex color for visual differentiation in the UI.
    var color: String?

    // MARK: - Relationships

    /// All tasks tagged with this label.
    var tasks: [TaskItem] = []

    // MARK: - Initializer

    init(
        id: String = UUID().uuidString,
        name: String,
        color: String? = nil
    ) {
        self.id = id
        self.name = name
        self.color = color
    }
}
