import SwiftUI

struct ReminderSheet: View {
    let context: SoulReminderContext
    let onSave: (SoulReminderDraft) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var dueAt: Date = Date().addingTimeInterval(3600)

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Add Reminder")
                    .font(SoulFont.ui(18, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Cancel")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Action")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                TextField("Follow up on...", text: $text, axis: .vertical)
                    .font(SoulType.composer)
                    .lineLimit(3...5)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(SoulColor.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.7), lineWidth: 0.5))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Date")
                    .font(SoulFont.ui(11, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                DatePicker("Due", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                HStack(spacing: 6) {
                    presetButton("1h", interval: 3600)
                    presetButton("Tomorrow", interval: 24 * 3600)
                    presetButton("Next week", interval: 7 * 24 * 3600)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(context.projectName)
                    .font(SoulFont.ui(12, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                if let title = context.threadTitle, !title.isEmpty {
                    Text(title)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                } else if context.threadId == nil {
                    Text("Project reminder")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoulColor.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                Button("Add") {
                    onSave(SoulReminderDraft(text: text, dueAt: dueAt, context: context))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(SoulColor.bg)
    }

    private func presetButton(_ label: String, interval: TimeInterval) -> some View {
        Button(label) {
            dueAt = Date().addingTimeInterval(interval)
        }
        .font(SoulFont.ui(11, weight: .medium))
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SoulColor.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DueReminderBanner: View {
    let reminders: [SoulReminder]
    let onComplete: (UUID) -> Void
    let onDismiss: (UUID) -> Void

    private var first: SoulReminder? { reminders.first }

    var body: some View {
        if let first {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SoulColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(first.text)
                        .font(SoulFont.ui(12, weight: .semibold))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(2)
                    Text(metadata(for: first))
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if reminders.count > 1 {
                    Text("+\(reminders.count - 1)")
                        .font(SoulFont.ui(10, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(SoulColor.surface, in: Capsule())
                }
                Button("Done") { onComplete(first.id) }
                    .font(SoulFont.ui(11, weight: .semibold))
                    .buttonStyle(.borderless)
                Button(action: { onDismiss(first.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SoulColor.border.opacity(0.6), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.14), radius: 12, x: 0, y: 6)
        }
    }

    private func metadata(for reminder: SoulReminder) -> String {
        if let title = reminder.threadTitle, !title.isEmpty {
            return "\(reminder.projectName) · \(title)"
        }
        return reminder.projectName
    }
}
