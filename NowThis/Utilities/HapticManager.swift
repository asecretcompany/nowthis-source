import SwiftUI

/// Generates UIKit haptic feedback in a SwiftUI-friendly API.
///
/// Uses `UIImpactFeedbackGenerator` and `UINotificationFeedbackGenerator`
/// for system-standard haptics on task interactions.
@MainActor
enum HapticManager {

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    /// Light impact for toggling checkboxes.
    static func checkbox() {
        lightGenerator.impactOccurred()
    }

    /// Medium impact for completing a task.
    static func taskComplete() {
        mediumGenerator.impactOccurred()
    }

    /// Success notification for sync complete.
    static func success() {
        notificationGenerator.notificationOccurred(.success)
    }

    /// Error notification for failed operations.
    static func error() {
        notificationGenerator.notificationOccurred(.error)
    }

    /// Soft impact for menu/sheet presentation.
    static func softImpact() {
        softGenerator.impactOccurred()
    }
}
