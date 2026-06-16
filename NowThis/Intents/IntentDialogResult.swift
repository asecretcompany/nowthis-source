import Foundation

/// Simple result type for testable intent entry points.
/// Allows tests to inspect dialog text and optional values without dealing with opaque IntentResult types.
struct IntentDialogResult {
    let dialog: String
    var value: Int?

    init(dialog: String, value: Int? = nil) {
        self.dialog = dialog
        self.value = value
    }
}
