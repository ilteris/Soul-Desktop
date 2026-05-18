import SwiftUI

// SoulTrace model + parser live in SoulTrace.swift (refactor step 1 —
// kept the view file focused on rendering, isolated the regex/JSON work).

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
                        .font(.system(size: 12, weight: .regular))
                    Text("trace")
                        .font(SoulFont.ui(12, weight: .regular))
                    if !expanded, !trace.intent.isEmpty {
                        Text("·")
                            .font(SoulFont.ui(12))
                            .foregroundStyle(SoulColor.fgSubtle)
                        Text(trace.intent)
                            .font(SoulFont.ui(12))
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
            .buttonStyle(.soulHover)
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
                    .font(SoulFont.ui(11, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .frame(width: 40, alignment: .leading)
                Text(value)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
                    .textSelection(.enabled)
            }
        }
    }
}
