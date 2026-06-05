import SwiftUI
import AppKit

enum SoulFont {
    static let family = "JetBrainsMono Nerd Font"

    /// SwiftUI's `.weight()` modifier on custom (non-system) font families is
    /// unreliable — it often silently no-ops on Nerd Font builds because the
    /// face axis isn't exposed the way system fonts expose it. Select the
    /// explicit PostScript face name instead.
    private static func face(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin:        return "JetBrainsMonoNF-Thin"
        case .light:                    return "JetBrainsMonoNF-Light"
        case .regular:                  return "JetBrainsMonoNF-Regular"
        case .medium:                   return "JetBrainsMonoNF-Medium"
        case .semibold:                 return "JetBrainsMonoNF-SemiBold"
        case .bold:                     return "JetBrainsMonoNF-Bold"
        case .heavy, .black:            return "JetBrainsMonoNF-ExtraBold"
        default:                        return "JetBrainsMonoNF-Medium"
        }
    }

    static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .custom(face(for: weight), size: size)
    }
    static func code(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .custom(face(for: weight), size: size)
    }
    static func hero(_ size: CGFloat = 28) -> Font {
        .custom(face(for: .regular), size: size)
    }

    /// AppKit equivalent of `ui(_:weight:)`. Use this for any NSFont consumer
    /// (NSTextView, SwiftTerm) so the rendered weight matches SwiftUI views.
    /// Falls back to the system monospaced face if the PostScript name fails
    /// to load (e.g. font not installed).
    static func nsFont(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: face(for: weight), size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum SoulColor {
    // SOUL-215: cream → neutral gray off-white. Same luminance, much
    // less yellow saturation — the NavigationSplitView divider shadow
    // reads as a soft tonal step instead of a warm/dark gradient bleed.
    static let bg            = dynamic(light: 0xEFEEEC, dark: 0x181818)
    static let bgElevated    = dynamic(light: 0xF8F8F6, dark: 0x222222)
    static let sidebar       = dynamic(light: 0xE6E5E2, dark: 0x1F1F1F, alpha: 0.6)
    static let surface       = dynamic(light: 0xE6E5E2, dark: 0x2A2A2A)
    static let border        = dynamic(light: 0xD2D1CD, dark: 0x333333)
    static let fg            = dynamic(light: 0x1E1E2E, dark: 0xE6E6E6)
    static let fgMuted       = dynamic(light: 0x5C5F77, dark: 0xA6A6A6)
    static let fgSubtle      = dynamic(light: 0x8C8FA1, dark: 0x6E6E6E)

    /// Default Catppuccin purple — used when the user hasn't picked one.
    static let defaultAccentHex: UInt32 = 0x8839EF
    static let accentStorageKey = "soul.accent.hex"

    static var accent: Color {
        let stored = UInt32(UserDefaults.standard.integer(forKey: accentStorageKey))
        return Color(hex: stored == 0 ? defaultAccentHex : stored)
    }
    static var accentMuted: Color { accent.opacity(0.12) }
    /// Soft green tint used for "active project" selection in the sidebar.
    static let success       = Color(hex: 0x40A02B)
    static let successMuted  = Color(hex: 0x40A02B).opacity(0.18)

    /// Returns a SwiftUI Color that resolves to `light` or `dark` based on
    /// the system appearance. Driven by NSColor's dynamicProvider so it
    /// flips live when the user toggles system appearance — no app restart.
    private static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1.0) -> Color {
        let lightNS = NSColor(hex: light, alpha: alpha)
        let darkNS = NSColor(hex: dark, alpha: alpha)
        let ns = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return isDark ? darkNS : lightNS
        }
        return Color(nsColor: ns)
    }
}

enum SoulMetric {
    static let sidebarWidth: CGFloat = 320
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14
    static let pad: CGFloat = 12
    static let padTight: CGFloat = 8

    // SOUL-207: single source of truth for icon sizing. Tune here, not
    // at call sites. Three tiers — `iconHint` for decorative micro-glyphs
    // (chevron-down on menus, status dots), `icon` for standard inline
    // affordances (toolbar buttons, chip leading glyphs), `iconLarge`
    // for emphasis (send/stop circles, working indicator).
    static let iconHint: CGFloat = 10
    static let icon: CGFloat = 13
    static let iconLarge: CGFloat = 15
}

/// Named typography roles. Tune sizes here, not in views. New code should
/// reference these tokens; old call sites still using `SoulFont.ui(N)`
/// directly will be migrated incrementally. Sizes intentionally cluster
/// around the 15pt body to keep vertical rhythm coherent.
enum SoulType {
    // Body — chat messages, sidebar rows, paragraph text.
    static let body          = SoulFont.ui(16, weight: .regular)
    static let bodyBold      = SoulFont.ui(16, weight: .bold)
    static let bodyItalic    = SoulFont.ui(16, weight: .regular).italic()
    static let bodyBoldItalic = SoulFont.ui(16, weight: .bold).italic()

    // Inline code spans — slightly smaller than body so the mono face
    // doesn't overpower; same face though (composer/sidebar are all mono).
    static let code          = SoulFont.code(15, weight: .regular)

    // Headings — semibold, descending. SOUL-SOUL_DESKTOP-168: every
    // heading sits above body (15pt). Pre-fix h3/h4 were 14/13pt and
    // rendered VISUALLY SMALLER than the body they were supposed to
    // introduce — agent "## Section" headers looked like they belonged
    // below their own content. New ladder: 22 / 19 / 17 / 16 keeps a
    // clear step between each level and never drops below body.
    static let h1            = SoulFont.ui(22, weight: .semibold)
    static let h2            = SoulFont.ui(20, weight: .semibold)
    static let h3            = SoulFont.ui(18, weight: .semibold)
    static let h4            = SoulFont.ui(17, weight: .semibold)

    // Meta — timestamps, footers, badges, sub-headers.
    static let caption       = SoulFont.ui(13, weight: .regular)
    static let micro         = SoulFont.ui(11, weight: .regular)

    // Composer text field. AppKit-side so we expose NSFont too.
    static let composerSize: CGFloat = 15
    static let composer      = SoulFont.ui(composerSize, weight: .regular)
    static var composerNS: NSFont { SoulFont.nsFont(composerSize, weight: .regular) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: CGFloat(alpha))
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    static func toHex(_ color: Color) -> UInt32 {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.purple
        let r = UInt32(round(ns.redComponent * 255)) & 0xFF
        let g = UInt32(round(ns.greenComponent * 255)) & 0xFF
        let b = UInt32(round(ns.blueComponent * 255)) & 0xFF
        return (r << 16) | (g << 8) | b
    }
}

/// Reaches up to the hosting NSWindow once the view is in a window. Used at
/// app startup to flip the window to non-opaque + clear background so the
/// `NSVisualEffectView` sidebar can actually show behind-window content
/// (desktop wallpaper, other apps) instead of blending into an opaque pane.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Native macOS vibrancy backdrop. Wraps `NSVisualEffectView` so the sidebar
/// can opt into the true `.sidebar` material — picks up window-behind colors
/// (desktop wallpaper, other app chrome) the way Finder / Mail / Xcode do.
/// SwiftUI's `.ultraThinMaterial` is a close approximation but doesn't blend
/// behind-window content; use this anywhere the real sidebar look is needed.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct SoulIcon: View {
    let name: String
    var size: CGFloat = SoulMetric.icon
    var color: Color = SoulColor.fgMuted
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
}
