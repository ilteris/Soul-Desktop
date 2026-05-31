import SwiftUI
import AppKit

/// Parses Claude Code's `Agent` tool result trailer out of the rendered body.
///
/// The ACP wrapper (`@agentclientprotocol/claude-agent-acp`) concatenates the
/// subagent's reply text with two trailing blocks before shipping it as the
/// tool-call result content:
///
///   ```
///   <…body…>
///   agentId: <hex> (use SendMessage with to: '<hex>' to continue this agent)
///   <usage>total_tokens: <int>
///   tool_uses: <int>
///   duration_ms: <int></usage>
///   ```
///
/// Left raw, those trailers leak into the bubble. We pull them out and surface
/// the structured fields on the card header/footer instead.
enum ClaudeAgentResultParser {
    struct Parsed: Hashable {
        var body: String
        var agentId: String?
        var totalTokens: Int?
        var toolUses: Int?
        var durationMs: Int?
    }

    static func parse(_ raw: String) -> Parsed {
        var working = raw
        var agentId: String?
        var totalTokens: Int?
        var toolUses: Int?
        var durationMs: Int?

        // Strip the `<usage>…</usage>` block (multiline). NSRegularExpression
        // with `.dotMatchesLineSeparators` so `.` crosses newlines.
        if let usageRegex = try? NSRegularExpression(
            pattern: #"<usage>([\s\S]*?)</usage>"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            if let match = usageRegex.firstMatch(in: working, options: [], range: range),
               let innerRange = Range(match.range(at: 1), in: working),
               let fullRange = Range(match.range, in: working) {
                let inner = String(working[innerRange])
                // Token key varies by wrapper: Claude's Agent tool emits
                // `total_tokens`, the Soul kernel's subagent trailer emits
                // `subagent_tokens`. Accept either so the footer chip fills in
                // for both surfaces instead of dropping to nil.
                totalTokens = firstInt(in: inner, key: "subagent_tokens")
                    ?? firstInt(in: inner, key: "total_tokens")
                toolUses = firstInt(in: inner, key: "tool_uses")
                durationMs = firstInt(in: inner, key: "duration_ms")
                working.replaceSubrange(fullRange, with: "")
            }
        }

        // Strip the `agentId: <hex> (use SendMessage with to: '<hex>' to continue this agent)` line.
        // The parenthetical is optional — guard against future wording shifts.
        if let idRegex = try? NSRegularExpression(
            pattern: #"agentId:\s*([a-zA-Z0-9_-]+)(?:\s*\([^)]*\))?\s*"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            if let match = idRegex.firstMatch(in: working, options: [], range: range),
               let idRange = Range(match.range(at: 1), in: working),
               let fullRange = Range(match.range, in: working) {
                agentId = String(working[idRange])
                working.replaceSubrange(fullRange, with: "")
            }
        }

        let body = working.trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(
            body: body,
            agentId: agentId,
            totalTokens: totalTokens,
            toolUses: toolUses,
            durationMs: durationMs
        )
    }

    private static func firstInt(in text: String, key: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: key))\\s*:\\s*(\\d+)",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let g = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[g])
    }
}

/// Inline card for Claude Code's `Agent` tool calls (a.k.a. `Task`).
///
/// Mirrors `SubagentCard`'s look so both surfaces read as "this is a
/// specialist run" — but doesn't tail a live.log (Claude's Agent tool has no
/// kernel subagent dir). Header shows `@<subagentType>` + status; body
/// renders the parsed reply (markdown) collapsed to a preview by default;
/// footer surfaces `agentId` + token/tool-use/duration when present.
struct ClaudeAgentCard: View {
    let subagentType: String
    let description: String
    let status: String
    let agentId: String?
    let replyBody: String
    let totalTokens: Int?
    let toolUses: Int?
    let durationMs: Int?
    var isHistorical: Bool = false

    @State private var expanded: Bool = false

    private var specialistColor: Color {
        SpecialistPalette.color(for: subagentType, serverHex: nil)
    }

    private var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "stopped" || status == "error"
    }

    private var statusLabel: String {
        switch status {
        case "in_progress", "pending": return "working"
        case "completed":              return "completed"
        case "failed", "error":        return "failed"
        case "stopped":                return "stopped"
        default:                       return status
        }
    }

    private static let dangerColor = Color(hex: 0xD20F39)

    private var statusColor: Color {
        switch status {
        case "completed":       return SoulColor.success
        case "failed", "error": return Self.dangerColor
        case "stopped":         return SoulColor.fgSubtle
        default:                return specialistColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !replyBody.isEmpty {
                Divider().padding(.vertical, 8).opacity(0.4)
                bodyView
            }
            if isTerminal, hasFooterStats {
                Divider().padding(.vertical, 8).opacity(0.4)
                footerStats
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SoulColor.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(specialistColor.opacity(0.35), lineWidth: 1)
                )
        )
        .overlay(
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(specialistColor)
                    .frame(width: 3)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.leading, 1)
        )
        .opacity(isHistorical ? 0.75 : 1.0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(specialistColor)
                    .frame(width: 8, height: 8)
                Text("@\(subagentType)")
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Text("· Claude subagent")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                if !isTerminal && !isHistorical {
                    SparkleSpinner(tint: SoulColor.fgMuted, size: 10)
                }
                Text(statusLabel)
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
            if !description.isEmpty {
                Text(description)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg.opacity(0.78))
                    .italic()
                    .lineLimit(2)
                    .padding(.leading, 16)
            }
        }
    }

    /// Split the reply into visible prose + the trailing `<soul_trace>` block.
    /// The trace is rendered as a chip; the raw envelope never leaks into text.
    private var split: (visible: String, trace: SoulTrace?) {
        SoulTrace.extract(from: replyBody)
    }

    @ViewBuilder
    private var bodyView: some View {
        let parts = split
        let visible = parts.visible
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    MarkdownView(text: visible)
                        .padding(.leading, 16)
                        .padding(.trailing, 4)
                    collapseControl
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview(visible, maxChars: 280))
                        .font(SoulFont.ui(12))
                        .foregroundStyle(SoulColor.fg.opacity(0.78))
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .padding(.leading, 16)
                        .padding(.trailing, 4)
                    expandControl
                }
            }
            if let trace = parts.trace {
                SoulTraceChip(trace: trace)
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
            }
        }
    }

    private var expandControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { expanded = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                Text("Expand reply")
                Text("(\(replyBody.count) chars)")
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .font(SoulFont.ui(10, weight: .medium))
            .foregroundStyle(SoulColor.fgSubtle)
        }
        .buttonStyle(.soulHover)
        .padding(.leading, 16)
        .padding(.top, 2)
    }

    private var collapseControl: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { expanded = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                Text("Collapse")
            }
            .font(SoulFont.ui(10, weight: .medium))
            .foregroundStyle(SoulColor.fgSubtle)
        }
        .buttonStyle(.soulHover)
        .padding(.leading, 16)
        .padding(.top, 4)
    }

    private var hasFooterStats: Bool {
        agentId != nil || totalTokens != nil || toolUses != nil || durationMs != nil
    }

    private var footerStats: some View {
        HStack(spacing: 10) {
            if let id = agentId {
                statChip(icon: "number", label: id, monospaced: true)
            }
            if let t = totalTokens {
                statChip(icon: "circle.hexagongrid", label: "\(formatNumber(t)) tok")
            }
            if let n = toolUses {
                statChip(icon: "wrench.and.screwdriver", label: "\(n) tool\(n == 1 ? "" : "s")")
            }
            if let ms = durationMs {
                statChip(icon: "clock", label: formatDuration(ms: ms))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
    }

    private func statChip(icon: String, label: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(monospaced ? .system(size: 10, design: .monospaced) : SoulFont.ui(10, weight: .medium))
        }
        .foregroundStyle(SoulColor.fgSubtle)
    }

    private func preview(_ text: String, maxChars: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<idx]) + "…"
    }

    private func formatNumber(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000.0) }
        return String(format: "%.1fM", Double(n) / 1_000_000.0)
    }

    private func formatDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s / 60)
        let rem = Int(s) % 60
        return "\(m)m \(rem)s"
    }
}
