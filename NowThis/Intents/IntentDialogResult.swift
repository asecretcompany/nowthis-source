import Foundation

/// Simple result type for testable intent entry points.
/// Allows tests to inspect dialog text and optional values without dealing with opaque IntentResult types.
///
/// ## Why `dialog` is a `LocalizedStringResource` and not a `String`
///
/// It was a `String`, and every intent handed it to Siri as `.result(dialog: "\(result.dialog)")`.
/// That interpolation *does* extract — it extracts the key `"%@"`, once, shared by all seven
/// intents — so not a single Siri sentence in the app ever reached a catalog. Siri answered in
/// English in every language, and no catalog guard could see it, because from the catalog's point
/// of view the sentences did not exist.
///
/// Building the resource at the literal instead means the sentence is extracted where it is
/// written, and `perform()` passes it through with `IntentDialog(result.dialog)` rather than
/// re-wrapping it in a fresh `"%@"`.
struct IntentDialogResult {
    let dialog: LocalizedStringResource
    var value: Int?

    init(dialog: LocalizedStringResource, value: Int? = nil) {
        self.dialog = dialog
        self.value = value
    }

    /// The dialog rendered in the current locale.
    ///
    /// Siri renders the resource itself; this exists so tests can assert on what the user
    /// actually hears without re-implementing the lookup.
    var spokenText: String {
        String(localized: dialog)
    }
}
