import SwiftUI

/// Bottom-right toast shown when the active session's provider has no
/// native compact command (Codex / Pi) and its context window is
/// filling. Offers one-click branches to Claude or Gemini.
///
/// Distinct from the top-center repair toast because the two can
/// theoretically coexist (a repair-completed message while context is
/// also full). Bottom-right also keeps it out of the way of the
/// composer's "Compacting…" banner.
struct AutoCompactToastView: View {
    let toast: AutoCompactController.Toast
    let onPick: (Provider) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 16)
                Text(toast.message)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            if !toast.actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(toast.actions, id: \.self) { action in
                        Button(action.label) {
                            onPick(action.provider)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(SoulColor.accent)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 340, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 4)
    }
}
