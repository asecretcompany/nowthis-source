import Foundation

/// Renders a journal entry's Markdown for the preview pane.
///
/// ## Why this exists rather than `Text(LocalizedStringKey(content))`
///
/// `LocalizedStringKey` performs a **string catalog lookup**. Passing the user's own writing
/// through it means a journal entry whose text happens to match a catalog key is silently
/// replaced by a translation of that key — the user opens their journal and finds different
/// words than the ones they wrote. Before this project there were no catalogs, so the lookup
/// always missed and the bug was invisible; there are 587 keys now.
///
/// `LocalizedStringKey` also only ever supported a small Markdown subset, so this is not a
/// downgrade: `AttributedString(markdown:)` handles the same inline syntax and does not treat
/// the input as a key.
enum JournalMarkdown {

    /// Parses `content` as Markdown, falling back to the text verbatim.
    ///
    /// `.inlineOnlyPreservingWhitespace` is deliberate. The default parsing options collapse
    /// newlines, which is wrong for prose the user typed line by line — a journal entry is not
    /// a label. Block syntax (headings, lists) is not interpreted, matching what the previous
    /// `LocalizedStringKey` rendering did.
    static func render(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let parsed = try? AttributedString(markdown: content, options: options) {
            return parsed
        }
        return AttributedString(content)
    }
}
