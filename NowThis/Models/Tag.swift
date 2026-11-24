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

    // MARK: - Identity

    /// The tag in `tags` that means the same thing as `name`, if there is one.
    ///
    /// One rule, in one place, because every path that can mint a tag has to
    /// agree — quick add, the intents, the watch, Task Detail, the sidebar, and
    /// now the sync engine applying inbound `CATEGORIES`. A path that disagrees
    /// creates a second tag for a name the user already has, and because tags
    /// serialize to `CATEGORIES`, the duplicate reaches the server.
    ///
    /// **Locale-aware case folding, not `lowercased()`.** Under a Turkish locale
    /// "I" and "ı" are different letters, so `lowercased()` makes `WORK` and
    /// `work` distinct and mints the duplicate this exists to prevent.
    ///
    /// **Deliberately not diacritic-insensitive.** "café" and "cafe" are
    /// different tags; merging them would silently retag the user's data. Search
    /// folds accents — identity does not.
    static func matching(_ name: String, in tags: [Tag]) -> Tag? {
        tags.first { namesMatch($0.name, name) }
    }

    /// Keeps the first spelling of each typed tag for the Quick Add preview.
    static func uniqueNames(_ names: [String]) -> [String] {
        var unique: [String] = []
        for name in names where !unique.contains(where: { namesMatch($0, name) }) {
            unique.append(name)
        }
        return unique
    }

    /// Resolves each identity once. New tags remain detached until the task is staged.
    static func resolve(_ names: [String], in context: ModelContext,
                        fetch: (ModelContext) throws -> [Tag] = fetchAll(in:)) throws -> [Tag] {
        guard !names.isEmpty else { return [] }
        var candidates = try fetch(context)
        var resolved: [Tag] = []
        var ids = Set<String>()
        for name in names {
            let tag: Tag
            if let existing = matching(name, in: candidates) {
                tag = existing
            } else {
                tag = Tag(name: name)
                candidates.append(tag)
            }
            if ids.insert(tag.id).inserted {
                resolved.append(tag)
            }
        }
        return resolved
    }

    static func fetchAll(in context: ModelContext) throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>())
    }

    private static func namesMatch(_ first: String, _ second: String) -> Bool {
        first.localizedCaseInsensitiveCompare(second) == .orderedSame
    }
}
