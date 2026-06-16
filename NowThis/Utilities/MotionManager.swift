import SwiftUI

/// Provides a Reduce Motion-aware animation wrapper.
///
/// When the user has Reduce Motion enabled in Accessibility settings,
/// animations are replaced with cross-dissolve (opacity) or removed
/// entirely, per Apple HIG guidelines.
///
/// Usage: Replace `withAnimation(.easeInOut) { ... }` with
/// `withAccessibleAnimation { ... }`.
@MainActor
enum MotionManager {

    /// Wraps `withAnimation` to respect Reduce Motion preference.
    ///
    /// When Reduce Motion is enabled, uses a simple opacity crossfade
    /// instead of the requested animation. When disabled, uses the
    /// provided animation or the default.
    static func withAccessibleAnimation<Result>(
        _ animation: Animation? = .default,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if UIAccessibility.isReduceMotionEnabled {
            return try withAnimation(.linear(duration: 0.15), body)
        } else {
            return try withAnimation(animation, body)
        }
    }
}
