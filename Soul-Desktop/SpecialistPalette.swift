import SwiftUI

/// Canonical color mapping for `delegate_to_specialist` subagents (SOUL-SOUL_DESKTOP-111).
///
/// Source of truth is the `color` frontmatter field on `~/dotfiles/soul/agents/<name>.md`,
/// resolved server-side by the App Server and shipped down as a hex string in the
/// `delegate_to_specialist` tool metadata. This palette is the local FALLBACK for two
/// cases:
///   1. The kernel hasn't shipped the color enrichment yet (development boot-strap).
///   2. A "custom" specialist that doesn't carry a color field returns nil from the
///      server, and we still want a deterministic color across renders.
///
/// Update this table only when adding a new built-in specialist to the roster; per-user
/// custom specialists rely on the hash-derived fallback at the bottom.
enum SpecialistPalette {
    static let knownColors: [String: UInt32] = [
        "information_retriever":  0x007AFF, // system blue
        "code_archaeologist":     0xA2845E, // brown
        "systems_architect":      0x5856D6, // indigo
        "registry_guardian":      0xAF52DE, // purple
        "creative_technologist":  0xFF2D55, // pink
    ]

    static func isKnownSpecialist(_ name: String) -> Bool {
        knownColors.keys.contains(name.lowercased())
    }

    /// Resolve a color for a specialist. Server-provided hex always wins. Falls back to
    /// the built-in palette, then to a deterministic hash-derived hue for unknown names.
    static func color(for specialist: String, serverHex: UInt32? = nil) -> Color {
        if let hex = serverHex { return Color(hex: hex) }
        let key = specialist.lowercased()
        if let hex = knownColors[key] { return Color(hex: hex) }
        return derivedColor(for: key)
    }

    /// Stable hue derived from the specialist name so the same custom specialist always
    /// gets the same color across launches. Saturation/brightness are pinned so the
    /// generated colors stay readable against the canvas background.
    private static func derivedColor(for key: String) -> Color {
        var hasher = Hasher()
        hasher.combine(key)
        let h = abs(hasher.finalize())
        // Quantize to 12 steps around the wheel; avoids two near-identical hues
        // for adjacent specialists.
        let hue = Double(h % 12) / 12.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.72)
    }
}
