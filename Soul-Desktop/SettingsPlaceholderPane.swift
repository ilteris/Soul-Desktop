import SwiftUI
import AppKit

// MARK: - Coming soon

struct ComingSoonPane: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: title)
            HStack(spacing: 10) {
                SoulIcon(name: "hourglass", size: SoulMetric.iconLarge)
                Text(note)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

