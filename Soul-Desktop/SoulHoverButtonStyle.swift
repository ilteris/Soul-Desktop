import SwiftUI

/// Global hover/active button treatment for the app. Behavior:
/// - Suppresses macOS's default button chrome (same as `.plain`).
/// - On hover, paints a `SoulColor.accentMuted` rounded-rect background
///   BEHIND the label. Buttons whose labels already have their own
///   background (Send-button circle, capsule pills, etc.) cover this
///   automatically — the hover bg only shows for icon/text-only buttons
///   without an existing background.
/// - On press, deepens to `SoulColor.accent.opacity(0.25)` and shrinks
///   slightly so click feedback is visible regardless of bg.
/// - Animated over 120ms (hover) / 80ms (press) — matches the existing
///   ToolbarChip / CommandChip / ReplayProgressChip motion.
///
/// Apply at the app root so every Button picks it up as default. Buttons
/// that need to stay truly chrome-less without hover (e.g. an inline
/// link) can still opt back to `.plain` explicitly.
///
/// Hit-area expansion (the SwiftUI trick): the label gets minimum 24x24
/// frame + `.contentShape(Rectangle())` so the whole rounded-rect region
/// claims clicks even when the icon glyph is tiny.
struct SoulHoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var minSize: CGFloat = 24
    var padding: CGFloat = 4
    /// When false, the style still removes macOS chrome and applies the
    /// press-scale feedback, but does NOT paint a hover background. Use
    /// for buttons whose labels already render their own background
    /// (capsule chips, circle send-buttons, pill toggles) — painting an
    /// additional bg underneath produces visible double-bg artifacts.
    var paintHoverBackground: Bool = true
    /// When true, paint the hover bg permanently — used for buttons whose
    /// associated UI is currently active (e.g. + while file picker open,
    /// dropdown chevron while menu visible). Driven by per-call-site
    /// @State; ButtonStyle's own isPressed only fires while the mouse is
    /// held down, which doesn't cover external-modal-open scenarios.
    var isActive: Bool = false
    /// SOUL-212: chip buttons paint their own bg and shouldn't have a
    /// rounded-rect contentShape stamped over their visible shape (the
    /// resulting hit region drifts off the painted circle/capsule and
    /// silently eats clicks — that was the unresponsive-Stop root cause).
    /// When true, makeBody returns the label as-is so each call site's
    /// own .background(Shape) defines the hit region.
    var chipMode: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        if chipMode {
            // Pure chrome-suppression. No contentShape, no scaleEffect, no
            // onHover. The call-site's own background shape IS the hit region.
            return AnyView(configuration.label)
        }
        return AnyView(SoulHoverButtonContent(
            configuration: configuration,
            cornerRadius: cornerRadius,
            minSize: minSize,
            padding: padding,
            paintHoverBackground: paintHoverBackground,
            isActive: isActive
        ))
    }
}

extension ButtonStyle where Self == SoulHoverButtonStyle {
    /// Default treatment: hit-area expansion + accent-muted hover bg +
    /// press-scale feedback. Use for icon-only / text-only buttons that
    /// don't have their own background.
    static var soulHover: SoulHoverButtonStyle { SoulHoverButtonStyle() }

    /// Chip-shaped buttons (capsule, circle, etc.) that paint their own
    /// background. Keeps the hit-area expansion + press feedback but
    /// suppresses the hover bg layer so the label's own bg is the only
    /// thing rendered.
    static var soulChip: SoulHoverButtonStyle {
        SoulHoverButtonStyle(minSize: 0, padding: 0, paintHoverBackground: false, chipMode: true)
    }
}

private struct SoulHoverButtonContent: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let minSize: CGFloat
    let padding: CGFloat
    let paintHoverBackground: Bool
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(padding)
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(
                paintHoverBackground ? background() : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isActive)
            .onHover { hovering = $0 }
    }

    private func background() -> Color {
        // Neutral muted gray for hover/active — NOT accent-tinted. Accent
        // tint belongs to the icon (set per call site), not the bg. Press
        // deepens to a stronger neutral so click feedback is visible.
        if configuration.isPressed { return SoulColor.fg.opacity(0.16) }
        if isActive || hovering { return SoulColor.fg.opacity(0.08) }
        return .clear
    }
}
