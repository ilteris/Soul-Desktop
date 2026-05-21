import SwiftUI
import AppKit
import Foundation

/// SPEC-061 §5 envelope payload — minimal subset that SubagentCard cares
/// about. Provider + model are reliable as of soul-side SOUL-SOUL-044
/// (2026-05-20). Envelopes from earlier runs may omit both, in which
/// case `resolve` returns nil and the header subline is hidden.
struct SubagentEnvelopeMeta {
    let provider: String
    let model: String

    private struct EnvelopeJSON: Decodable {
        let provider: String?
        let model: String?
        let specialist: String?
    }

    /// Find the envelope for this (projectKey, specialist) combo by
    /// scanning `~/soul_registry/sessions/<project>/del_<specialist>_*.json`
    /// and picking the most recent. Multi-delegation-per-turn corner case
    /// (same specialist invoked twice in close succession) picks the
    /// newer envelope; the older card may stay un-decorated. Worth a
    /// follow-up if it bites, but the common case is single-delegation.
    static func resolve(projectKey: String, specialist: String) -> SubagentEnvelopeMeta? {
        let dir = "\(NSHomeDirectory())/soul_registry/sessions/\(projectKey)"
        let prefix = "del_\(specialist)_"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let matches = entries
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted(by: >)  // lexicographic = reverse-chronological for ts-suffixed names
        for name in matches {
            let path = "\(dir)/\(name)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let env = try? JSONDecoder().decode(EnvelopeJSON.self, from: data)
            else { continue }
            let provider = (env.provider ?? "").trimmingCharacters(in: .whitespaces)
            guard !provider.isEmpty else { continue }
            return SubagentEnvelopeMeta(
                provider: provider,
                model: (env.model ?? "").trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }
}

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
    /// SOUL-SOUL_DESKTOP-242 / SPEC-061 §5 consumer. Provider + model from
    /// the envelope JSON, resolved on first render and refreshed when the
    /// subagent reaches a terminal state (the envelope is typically
    /// written at completion). Nil until resolved or when the envelope
    /// doesn't carry the fields (legacy run).
    @State private var envelopeMeta: SubagentEnvelopeMeta? = nil

    private var logPath: String {
        "\(NSHomeDirectory())/soul_registry/sessions/\(projectKey)/subagents/\(subagentId)/live.log"
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
            guard !isHistorical else {
                envelopeMeta = SubagentEnvelopeMeta.resolve(projectKey: projectKey, specialist: specialist)
                return
            }
            if tailer == nil {
                tailer = SubagentLogTailer(path: logPath)
            }
            if !isTerminal {
                tailer?.start()
            }
            // Try once on appear — for fast subagents the envelope may
            // already exist by render time. Else the status-change handler
            // below picks it up when the run completes.
            envelopeMeta = SubagentEnvelopeMeta.resolve(projectKey: projectKey, specialist: specialist)
        }
        .onDisappear {
            tailer?.stop()
        }
        .onChange(of: status) { _, newStatus in
            if newStatus == "completed" || newStatus == "failed" || newStatus == "error" || newStatus == "stopped" {
                tailer?.stop()
                envelopeMeta = SubagentEnvelopeMeta.resolve(projectKey: projectKey, specialist: specialist)
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
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
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
            // SOUL-SOUL_DESKTOP-242 / SPEC-061 §5 consumer: provider + model
            // surfaced from the envelope JSON. Hidden when neither is
            // present (legacy envelopes, in-flight rows before envelope
            // exists). Codex envelopes carry an empty model — we show just
            // the provider name in that case, no trailing separator.
            if let meta = envelopeMeta, !meta.provider.isEmpty {
                Text(meta.model.isEmpty ? meta.provider : "\(meta.provider) · \(meta.model)")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private var logBody: some View {
        let content = tailer?.content ?? ""
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            HStack(spacing: 6) {
                Text(isHistorical ? "(log not tailed for archived run)" : "Waiting for first output…")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .italic()
            }
            .padding(.leading, 16)
        } else if expanded {
            ScrollView {
                Text(trimmed)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SoulColor.fg.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 240)
            .background(SoulColor.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding(.leading, 16)
            .padding(.trailing, 4)
            collapseControl
        } else {
            let tail = lastLines(trimmed, count: 3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(SoulColor.fg.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            expandControl(byteCount: trimmed.utf8.count)
        }
    }

    private func expandControl(byteCount: Int) -> some View {
        Button {
            expanded = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                Text("Expand log")
                Text("(\(formatBytes(byteCount)))")
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            .font(SoulFont.ui(10, weight: .medium))
            .foregroundStyle(SoulColor.fgSubtle)
        }
        .buttonStyle(.soulHover)
        .padding(.leading, 16)
        .padding(.top, 4)
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
