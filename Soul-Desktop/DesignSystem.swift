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
    static let bg            = Color(hex: 0xEFF1F5)
    static let bgElevated    = Color(hex: 0xFFFFFF)
    static let sidebar       = Color(hex: 0xE6E9EF).opacity(0.6)
    static let surface       = Color(hex: 0xE6E9EF)
    static let border        = Color(hex: 0xCCD0DA)
    static let fg            = Color(hex: 0x1E1E2E)
    static let fgMuted       = Color(hex: 0x5C5F77)
    static let fgSubtle      = Color(hex: 0x8C8FA1)

    /// Default Catppuccin purple — used when the user hasn't picked one.
    static let defaultAccentHex: UInt32 = 0x8839EF
    static let accentStorageKey = "soul.accent.hex"

    static var accent: Color {
        let stored = UInt32(UserDefaults.standard.integer(forKey: accentStorageKey))
        return Color(hex: stored == 0 ? defaultAccentHex : stored)
    }
    static var accentMuted: Color { accent.opacity(0.12) }

    enum Dark {
        static let bg          = Color(hex: 0x181818)
        static let bgElevated  = Color(hex: 0x222222)
        static let sidebar     = Color(hex: 0x1F1F1F).opacity(0.6)
        static let surface     = Color(hex: 0x2A2A2A)
        static let border      = Color(hex: 0x333333)
        static let fg          = Color(hex: 0xFFFFFF)
        static let fgMuted     = Color(hex: 0xA6A6A6)
        static let fgSubtle    = Color(hex: 0x6E6E6E)
        static let accent      = Color(hex: 0x339CFF)
        static let accentMuted = Color(hex: 0x339CFF).opacity(0.18)
    }
}

enum SoulMetric {
    static let sidebarWidth: CGFloat = 240
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14
    static let pad: CGFloat = 12
    static let padTight: CGFloat = 8
}

/// Named typography roles. Tune sizes here, not in views. New code should
/// reference these tokens; old call sites still using `SoulFont.ui(N)`
/// directly will be migrated incrementally. Sizes intentionally cluster
/// around the 15pt body to keep vertical rhythm coherent.
enum SoulType {
    // Body — chat messages, sidebar rows, paragraph text.
    static let body          = SoulFont.ui(15, weight: .regular)
    static let bodyBold      = SoulFont.ui(15, weight: .bold)
    static let bodyItalic    = SoulFont.ui(15, weight: .regular).italic()
    static let bodyBoldItalic = SoulFont.ui(15, weight: .bold).italic()

    // Inline code spans — slightly smaller than body so the mono face
    // doesn't overpower; same face though (composer/sidebar are all mono).
    static let code          = SoulFont.code(14, weight: .regular)

    // Headings — semibold, descending.
    static let h1            = SoulFont.ui(24, weight: .semibold)
    static let h2            = SoulFont.ui(19, weight: .semibold)
    static let h3            = SoulFont.ui(16, weight: .semibold)
    static let h4            = SoulFont.ui(14, weight: .semibold)

    // Meta — timestamps, footers, badges, sub-headers.
    static let caption       = SoulFont.ui(12, weight: .regular)
    static let micro         = SoulFont.ui(10, weight: .regular)

    // Composer text field. AppKit-side so we expose NSFont too.
    static let composerSize: CGFloat = 14
    static let composer      = SoulFont.ui(composerSize, weight: .regular)
    static var composerNS: NSFont { SoulFont.nsFont(composerSize, weight: .regular) }
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

struct SoulIcon: View {
    let name: String
    var size: CGFloat = 13
    var color: Color = SoulColor.fgMuted
    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
    }
}
