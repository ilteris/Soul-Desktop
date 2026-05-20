import SwiftUI
import AppKit

// MARK: - Reusable rows

struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SoulFont.hero(20))
                .foregroundStyle(SoulColor.fg)
            if let subtitle {
                Text(subtitle)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SoulFont.ui(13, weight: .regular))
                .foregroundStyle(SoulColor.fg)
            if let subtitle {
                Text(subtitle)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
        .padding(.bottom, 2)
    }
}

struct WorkModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                SoulIcon(name: icon, size: SoulMetric.iconLarge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SoulFont.ui(13, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                    Text(subtitle)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Circle()
                    .strokeBorder(selected ? SoulColor.accent : SoulColor.border, lineWidth: selected ? 5 : 1)
                    .frame(width: 12, height: 12)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? SoulColor.accent.opacity(0.5) : SoulColor.border.opacity(0.4), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulChip)
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                if let description {
                    Text(description)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct ToggleRow: View {
    let title: String
    let description: String
    @Binding var value: Bool
    var danger: Bool = false

    var body: some View {
        SettingRow(title: title, description: description) {
            Toggle("", isOn: $value)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(danger ? .orange : SoulColor.accent)
        }
    }
}

struct MenuRow: View {
    let title: String
    let description: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SettingRow(title: title, description: description) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { (key, label) in
                    Text(label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
        }
    }
}

struct SegmentedRow: View {
    let title: String
    let description: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { (key, label) in
                    Button { selection = key } label: {
                        Text(label)
                            .font(SoulFont.ui(11, weight: .regular))
                            .foregroundStyle(selection == key ? SoulColor.fg : SoulColor.fgMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selection == key
                                    ? AnyShapeStyle(SoulColor.surface)
                                    : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.soulChip)
                }
            }
            .padding(2)
            .background(SoulColor.bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

struct StepperRow: View {
    let title: String
    let description: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 4) {
                Stepper(value: $value, in: range) {
                    Text("\(value)")
                        .font(SoulFont.code(12))
                        .frame(width: 28, alignment: .trailing)
                }
                .labelsHidden()
                Text(suffix)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
    }
}

struct StaticActionRow: View {
    let title: String
    let description: String
    let actionLabel: String?
    let actionButton: String
    let disabled: Bool

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 8) {
                if let actionLabel {
                    Text(actionLabel)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                Button(actionButton) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(disabled)
            }
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: "tray", size: SoulMetric.icon)
            Text(text)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
    }
}
