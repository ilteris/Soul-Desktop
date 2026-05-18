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

    func makeBody(configuration: Configuration) -> some View {
        SoulHoverButtonContent(
            configuration: configuration,
            cornerRadius: cornerRadius,
            minSize: minSize,
            padding: padding
        )
    }
}

extension ButtonStyle where Self == SoulHoverButtonStyle {
    static var soulHover: SoulHoverButtonStyle { SoulHoverButtonStyle() }
}

private struct SoulHoverButtonContent: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let minSize: CGFloat
    let padding: CGFloat
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(padding)
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .background(
                background(),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private func background() -> Color {
        if configuration.isPressed { return SoulColor.accent.opacity(0.25) }
        if hovering { return SoulColor.accentMuted }
        return .clear
    }
}
