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
    struct DelegateCommand: Hashable {
        let specialist: String
        let objective: String
    }

    static let knownColors: [String: UInt32] = [
        "information_retriever":  0x007AFF, // system blue
        "code_archaeologist":     0xA2845E, // brown
        "systems_architect":      0x5856D6, // indigo
        "registry_guardian":      0xAF52DE, // purple
        "creative_technologist":  0xFF2D55, // pink
        "adversarial_judge":      0xFF9500, // orange
        "cloud_architect":        0x34C759, // green
        "monorepo_architect":     0x5AC8FA, // cyan
        "narrative_taxonomist":   0xBF5AF2, // violet
        "product_shaper":         0xFF375F, // red
        "terrain_mapper":         0x64D2FF, // light blue
        "visual_auditor":         0xFFCC00, // yellow
    ]

    static func isKnownSpecialist(_ name: String) -> Bool {
        knownColors.keys.contains(normalizedSpecialistName(name))
    }

    /// Gemini direct-delegation tool rows arrive as titles like
    /// `Delegating to agent 'adversarial_judge'` rather than as Soul's
    /// canonical `delegate_to_specialist` tool name. Normalize both the raw
    /// specialist name and that title shape before checking the built-in roster.
    static func normalizedSpecialistName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\""))
        let lower = trimmed.lowercased()
        let marker = "delegating to agent '"
        if let range = lower.range(of: marker) {
            let tail = lower[range.upperBound...]
            if let end = tail.firstIndex(of: "'") {
                return String(tail[..<end])
            }
        }
        return lower
    }

    /// Gemini-CLI exposes `soul delegate ...` as a normal shell execute row.
    /// Parse that command shape so Desktop can still render the native Soul
    /// subagent card when Gemini is the selected provider.
    static func parseDelegateCommand(_ raw: String) -> DelegateCommand? {
        let tokens = shellTokens(raw)
        guard let delegateIndex = tokens.firstIndex(of: "delegate"),
              delegateIndex > 0,
              delegateIndex + 1 < tokens.count,
              tokens[delegateIndex - 1].hasSuffix("soul") else {
            return nil
        }

        let specialist = normalizedSpecialistName(tokens[delegateIndex + 1])
        guard !specialist.isEmpty else { return nil }

        var objectiveParts: [String] = []
        var index = delegateIndex + 2
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") { break }
            objectiveParts.append(token)
            index += 1
        }

        return DelegateCommand(
            specialist: specialist,
            objective: objectiveParts.joined(separator: " ")
        )
    }

    static func parseDelegationId(from output: String?) -> String? {
        guard let output else { return nil }
        // Two shapes accepted:
        //   • `ID: <hex>` — emitted by soul_subagent.py to stderr / live.log header
        //   • `"delegation_id":"<hex>"` — JSON key in soul delegate's stdout block
        // The kernel's JSON output is the canonical handoff to Soul-Desktop;
        // the `ID:` form is kept for backward compatibility with old findings.
        let patterns = [
            #""delegation_id"\s*:\s*"([A-Za-z0-9_-]+)""#,
            #"\bID:\s*([A-Za-z0-9_-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: output,
                      range: NSRange(output.startIndex..<output.endIndex, in: output)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: output) else {
                continue
            }
            return String(output[range])
        }
        return nil
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

    private static func shellTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for ch in raw {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" {
                escaping = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                continue
            }
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
