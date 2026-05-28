import SwiftUI
import AppKit

/// Inline card that renders a `delegate_to_specialist` tool call (SOUL-SOUL_DESKTOP-111).
///
/// Replaces the generic `ToolCallRow` for these calls so a backgrounded specialist run
/// reads as "@<specialist> is working" with its own color, expandable log, and finding
/// link, instead of as a stuck shell row.
///
/// Lifecycle:
///   - `.onAppear`  → start log tailer
///   - status flips to terminal (completed / failed / stopped) → stop tailer, drain final bytes
///   - `.onDisappear` → stop tailer (defensive — view scrolled out of view)
///
/// Path contract (kernel side, SPEC-055):
///   `~/soul_registry/sessions/<project>/subagents/<subagentId>/live.log`
struct SubagentCard: View {
    let specialist: String
    let objective: String
    let status: String
    let subagentId: String
    let projectKey: String
    let colorHex: UInt32?
    let findingPath: String?
    var isHistorical: Bool = false

    @State private var tailer: SubagentLogTailer?
    @State private var expanded: Bool = false

    private var logPath: String {
        "\(SoulRegistry.primarySessionsRoot)/\(projectKey)/subagents/\(subagentId)/live.log"
    }

    private var specialistColor: Color {
        SpecialistPalette.color(for: specialist, serverHex: colorHex)
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

    /// Inline-defined danger color; DesignSystem doesn't carry a canonical one yet.
    /// Hex picked to read against both light and dark canvas backgrounds.
    private static let dangerColor = Color(hex: 0xD20F39)

    private var statusColor: Color {
        switch status {
        case "completed":      return SoulColor.success
        case "failed", "error": return Self.dangerColor
        case "stopped":        return SoulColor.fgSubtle
        default:               return specialistColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8).opacity(0.4)
            logBody
            if let path = findingPath, isTerminal {
                Divider().padding(.vertical, 8).opacity(0.4)
                findingRow(path: path)
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
            // Left edge accent stripe — gives the card an immediately-readable
            // "this is a specialist" signal without dominating the layout.
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
        .onAppear {
            // Skip live tailing for historical rows — replay reads from hooks.jsonl,
            // not the live.log (which may not even exist for old sessions).
            guard !isHistorical else { return }
            if tailer == nil {
                tailer = SubagentLogTailer(path: logPath)
            }
            if !isTerminal {
                tailer?.start()
            }
        }
        .onDisappear {
            tailer?.stop()
            tailer = nil
        }
        .onChange(of: status) { _, newStatus in
            if newStatus == "completed" || newStatus == "failed" || newStatus == "error" || newStatus == "stopped" {
                tailer?.stop()
                tailer = nil
            }
        }
        .onChange(of: subagentId) { _, _ in
            // The kernel prints `ID: <hex>` to stdout at the start of a
            // delegation, but the first tool_call notification may arrive
            // BEFORE that line streams through. In that window the parent's
            // `parseDelegationId` returns nil and the SubagentCard is born
            // with `subagentId = toolId` (the ACP call id, which doesn't
            // match the kernel's subagents/<hex>/ path) → we tail nothing.
            // Once the streaming content lands and a tool_call_update lifts
            // the structured `.subagent` details to the real id, restart
            // the tailer against the corrected path so live output starts
            // flowing inside the card.
            tailer?.stop()
            tailer = SubagentLogTailer(path: logPath)
            if !isTerminal {
                tailer?.start()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(specialistColor)
                    .frame(width: 8, height: 8)
                Text("@\(specialist)")
                    .font(SoulFont.ui(13, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
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
            if !objective.isEmpty {
                Text(objective)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg.opacity(0.78))
                    .italic()
                    .lineLimit(2)
                    .padding(.leading, 16) // align past the color dot
            }
        }
    }

    @ViewBuilder
    private var logBody: some View {
        let content = tailer?.content ?? ""
        let prose = Self.extractProse(from: content)
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            HStack(spacing: 6) {
                Text(isHistorical ? "(log not tailed for archived run)" : "Waiting for first output…")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .italic()
            }
            .padding(.leading, 16)
        } else if expanded {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: trimmed)
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                collapseControl
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview(trimmed, maxChars: 280))
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg.opacity(0.78))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                expandControl(charCount: trimmed.count)
            }
        }
    }

    private func expandControl(charCount: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { expanded = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                Text("Expand reply")
                Text("(\(charCount) chars)")
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .font(SoulFont.ui(10, weight: .medium))
            .foregroundStyle(SoulColor.fgSubtle)
        }
        .buttonStyle(.soulHover)
        .padding(.leading, 16)
        .padding(.top, 2)
    }

    /// Show the first chars of `s` as a single-paragraph preview. Newlines
    /// inside the window collapse to spaces so the truncation doesn't dump
    /// the user mid-line.
    private func preview(_ s: String, maxChars: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= maxChars { return flat }
        return String(flat.prefix(maxChars)) + "…"
    }

    /// Parse the live.log stream into readable prose. Gemini/Claude/Codex
    /// stream JSON lines that bury the assistant text inside structured
    /// envelopes (claude-sdk message frames, gemini stream-json events);
    /// raw JSON in the card body reads as noise. Extract only the text
    /// payload and concatenate, falling back to the raw line if it's not
    /// a recognized JSON shape (preamble lines, plain prose).
    static func extractProse(from raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var out: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // JSON-line? Try to extract assistant text.
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let extracted = extractTextFromEvent(obj), !extracted.isEmpty {
                    out.append(extracted)
                }
                continue
            }
            // Plain prose (header lines like "--- Subagent @X (ID: ...) Started ---",
            // warnings, etc.) — keep verbatim.
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    /// Walk a few known envelope shapes and return any visible assistant text.
    /// Recognizes:
    ///   • Claude SDK: `{type:"assistant", message:{content:[{type:"text", text}]}}`
    ///   • Gemini stream-json: `{type:"content", content:"…"}` or
    ///     `{response:{candidates:[{content:{parts:[{text:"…"}]}}]}}`
    ///   • Generic: any top-level `text` / `content` / `output` string.
    private static func extractTextFromEvent(_ obj: [String: Any]) -> String? {
        // Claude SDK assistant frames
        if (obj["type"] as? String) == "assistant",
           let message = obj["message"] as? [String: Any],
           let content = message["content"] {
            if let arr = content as? [[String: Any]] {
                let pieces = arr.compactMap { $0["text"] as? String }
                if !pieces.isEmpty { return pieces.joined(separator: "\n") }
            }
            if let s = content as? String, !s.isEmpty { return s }
        }
        // Gemini stream-json: direct content event
        if (obj["type"] as? String) == "content", let s = obj["content"] as? String {
            return s
        }
        // Gemini response wrapper
        if let response = obj["response"] as? [String: Any],
           let candidates = response["candidates"] as? [[String: Any]] {
            var pieces: [String] = []
            for c in candidates {
                guard let content = c["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { continue }
                for p in parts {
                    if let t = p["text"] as? String, !t.isEmpty { pieces.append(t) }
                }
            }
            if !pieces.isEmpty { return pieces.joined() }
        }
        // Generic fallbacks (some adapters flatten to top-level fields)
        if let s = obj["text"] as? String { return s }
        if let s = obj["output"] as? String { return s }
        return nil
    }

    private var collapseControl: some View {
        Button {
            expanded = false
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

    private func findingRow(path: String) -> some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(SoulFont.ui(11, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .foregroundStyle(specialistColor)
        }
        .buttonStyle(.soulHover)
        .padding(.leading, 16)
        .help("Open finding: \(path)")
    }

    private func lastLines(_ text: String, count: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [] }
        return Array(lines.suffix(count)).map(String.init)
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.1f MB", Double(n) / (1024.0 * 1024.0))
    }
}
