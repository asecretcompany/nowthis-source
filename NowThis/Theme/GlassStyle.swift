import SwiftUI

extension View {

    /// Applies a Liquid Glass background on iOS 26+, falling back to an ultra-thin
    /// material on iOS 18–25.
    ///
    /// Use for floating controls — capsule buttons, chips, the quick-add field —
    /// so they read as Liquid Glass where the system supports it while staying
    /// legible on earlier deployment targets. Standard chrome (navigation bars,
    /// tab bars, toolbars, sheets) already adopts Liquid Glass automatically when
    /// built against the iOS 26 SDK, so this is only needed for custom surfaces.
    ///
    /// - Parameters:
    ///   - shape: The shape that clips the glass / material.
    ///   - interactive: Adds the system's touch-lensing effect. Only pass `true`
    ///     when this view is NOT already inside a `Button`/`Menu` — interactive
    ///     glass installs its own touch handling and will swallow an enclosing
    ///     control's tap (this caused the onboarding cards to stop responding).
    @ViewBuilder
    func glassBackground(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// A card surface: Liquid Glass on iOS 26+, falling back to an ultra-thin
    /// material with a hairline `.quaternary` border on iOS 18–25.
    ///
    /// The fallback border keeps material cards legible; Liquid Glass provides its
    /// own edge highlight, so the explicit border is dropped where glass is used.
    ///
    /// Defaults to non-interactive because cards are typically wrapped in a
    /// `Button`; interactive glass would intercept the button's tap. Only pass
    /// `interactive: true` for a standalone card that handles its own gesture.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }
}
