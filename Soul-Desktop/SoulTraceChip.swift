import SwiftUI

struct SoulTrace {
    let intent: String
    let nextStep: String
    let rationale: String

    /// Returns (text with the trace block stripped, parsed trace if present).
    /// Trace blocks are: `<soul_trace>{...json...}</soul_trace>`. The JSON has
    /// `intent`, `next_step`, `rationale` keys.
    static func extract(from raw: String) -> (visible: String, trace: SoulTrace?) {
        guard let range = raw.range(of: #"<soul_trace>([\s\S]*?)</soul_trace>"#, options: .regularExpression) else {
            return (raw, nil)
        }
        let block = String(raw[range])
        let inner = block
            .replacingOccurrences(of: "<soul_trace>", with: "")
            .replacingOccurrences(of: "</soul_trace>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parsed: SoulTrace? = {
            guard let data = inner.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return SoulTrace(
                intent:    obj["intent"]    as? String ?? "",
                nextStep:  obj["next_step"] as? String ?? "",
                rationale: obj["rationale"] as? String ?? ""
            )
        }()

        var stripped = raw
        stripped.replaceSubrange(range, with: "")
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), parsed)
    }
}

struct SoulTraceChip: View {
    let trace: SoulTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 9, weight: .medium))
                    Text("trace")
                        .font(SoulFont.ui(10, weight: .medium))
                    if !expanded, !trace.intent.isEmpty {
                        Text("·")
                            .font(SoulFont.ui(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                        Text(trace.intent)
                            .font(SoulFont.ui(10))
                            .foregroundStyle(SoulColor.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .foregroundStyle(SoulColor.fgMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(SoulColor.surface.opacity(0.6), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Soul OS trajectory signal — kernel uses this to score predictive alignment")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    field("intent", trace.intent)
                    field("next", trace.nextStep)
                    field("why", trace.rationale)
                }
                .padding(8)
                .background(SoulColor.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(SoulFont.ui(10, weight: .medium))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .frame(width: 36, alignment: .leading)
                Text(value)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .textSelection(.enabled)
            }
        }
    }
}
