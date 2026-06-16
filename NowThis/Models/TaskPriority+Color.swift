import SwiftUI

extension TaskPriority {

    /// The semantic color used to represent this priority across the app and widget.
    ///
    /// These are system colors, so they automatically adapt to Light and Dark mode.
    /// In the widget's `.accented` rendering mode (the Home Screen "Tinted" setting),
    /// the system desaturates accentable elements to the user's tint — see the widget's
    /// use of `widgetAccentable()`.
    ///
    /// Centralizes the priority→color mapping that was previously duplicated across
    /// the task list, calendar, kanban, quick-add, and widget views.
    var color: Color {
        switch self {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        case .none:   return .secondary
        }
    }
}
