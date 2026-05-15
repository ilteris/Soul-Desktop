import SwiftUI

/// Shared component for rendering a slash command (e.g. `/decision [args]`)
/// as a pill-shaped chip. Matches the terminal CLI aesthetic.
/// 
/// SOUL-SOUL_DESKTOP-037: used in both `ThreadView` (live chat) and 
/// `ReplayView` (history).
struct SlashCommandChip: View {
    let command: String
    let args: String
    var isHistorical: Bool = false
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))
                // Drop the leading `/` from the rendered chip — the user
                // already typed the slash to invoke the command; the
                // terminal-style icon to the left signals "this is a
                // command" without echoing the punctuation.
                Text(command)
                    .font(SoulFont.code(12, weight: .bold))
            }
            .foregroundStyle(isHistorical ? SoulColor.accent.opacity(0.62) : SoulColor.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (isHistorical ? SoulColor.accentMuted.opacity(0.62) : SoulColor.accentMuted),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    SoulColor.accent.opacity(isHistorical ? 0.18 : 0.3),
                    lineWidth: 0.5
                )
            )

            if !args.isEmpty {
                Text(args)
                    .font(SoulFont.ui(13))
                    .foregroundStyle(isHistorical ? SoulColor.fgMuted.opacity(0.62) : SoulColor.fgMuted)
                    .lineLimit(lineLimit)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
    }
}
