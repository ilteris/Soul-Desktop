import SwiftUI
import AppKit

struct ThreadView: View {
    @Bindable var controller: ThreadController
    @Binding var prompt: String
    var onCancel: () -> Void = {}
    var onNewChat: () -> Void = {}

    @State private var renaming = false
    @State private var renameDraft = ""
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                title: controller.displayTitle,
                onCopySessionId: copySessionId,
                onCopyMarkdown: copyMarkdown,
                onRename: startRename
            )

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear.frame(height: 8)
                        ForEach(controller.items) { item in
                            ThreadItemRow(
                                item: item,
                                isHistorical: controller.historicalIDs.contains(item.id)
                            )
                                .id(item.id)
                        }
                        if controller.isWorking {
                            WorkingIndicator()
                        }
                        Color.clear.frame(height: 44).id("__bottom__")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
                .onChange(of: controller.items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }

            VStack(spacing: 8) {
                ComposerView(
                    prompt: $prompt,
                    projectName: controller.project.name,
                    projectPath: controller.project.path,
                    commands: controller.availableCommands,
                    onSend: { text in
                        Task { await controller.send(text) }
                    },
                    onCancel: onCancel,
                    isWorking: controller.isWorking
                )
                .frame(maxWidth: 760)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Title", text: $renameDraft)
            Button("Save") { controller.customTitle = renameDraft.trimmingCharacters(in: .whitespaces) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startRename() {
        renameDraft = controller.customTitle ?? controller.displayTitle
        renaming = true
    }

    private func copySessionId() {
        // sessionId is private; store last via controller.id for now
        let value = controller.id
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copyMarkdown() {
        let md = controller.markdownTranscript()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }
}

private struct ThreadHeader: View {
    let title: String
    let onCopySessionId: () -> Void
    let onCopyMarkdown: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(SoulFont.ui(13, weight: .medium))
                .foregroundStyle(SoulColor.fg)
                .lineLimit(1)
                .truncationMode(.tail)

            Menu {
                Button("Rename chat", action: onRename)
                Divider()
                Button("Copy session ID", action: onCopySessionId)
                Button("Copy as Markdown", action: onCopyMarkdown)
                Divider()
                Section("Coming soon") {
                    Button("Fork into new worktree") {}.disabled(true)
                    Button("Open side chat") {}.disabled(true)
                    Button("Open in new window") {}.disabled(true)
                    Button("Copy deeplink") {}.disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(SoulColor.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SoulColor.border.opacity(0.4)).frame(height: 0.5)
        }
    }
}

struct ThreadItemRow: View {
    let item: ThreadItem
    var isHistorical: Bool = false

    var body: some View {
        Group {
            switch item {
            case .userMessage(_, let text, let ts):
                UserMessageRow(text: text, timestamp: ts)
            case .agentMessage(_, let text, _, let ts):
                AgentMessageRow(text: text, timestamp: ts, isHistorical: isHistorical)
            case .toolCall(_, let kind, let title, let status, let loc):
                ToolCallRow(kind: kind, title: title, status: status, location: loc)
            case .plan(_, let entries):
                PlanCard(entries: entries)
            case .status(_, let text):
                Text(text)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
            case .error(_, let text):
                Text(text)
                    .font(SoulFont.code(11))
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .opacity(isHistorical ? 0.62 : 1.0)
    }
}

private struct AgentMessageRow: View {
    let text: String
    let timestamp: Date
    var isHistorical: Bool = false
    @State private var isHovering = false
    @State private var feedback: Feedback = .none

    enum Feedback { case none, up, down }

    private var split: (visible: String, trace: SoulTrace?) { SoulTrace.extract(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownView(text: split.visible)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let trace = split.trace {
                SoulTraceChip(trace: trace)
            }

            if isHistorical {
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .help(MessageTimestamp.absolute(timestamp))
            } else {
            HStack(spacing: 4) {
                FooterButton(systemName: "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                FooterButton(
                    systemName: feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                    help: "Helpful",
                    active: feedback == .up
                ) {
                    feedback = feedback == .up ? .none : .up
                }
                FooterButton(
                    systemName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    help: "Not helpful",
                    active: feedback == .down
                ) {
                    feedback = feedback == .down ? .none : .down
                }
                FooterButton(systemName: "arrow.triangle.branch", help: "Fork (coming soon)") {
                    // TODO: SOUL-SOUL_DESKTOP-002 — fork into worktree
                }
                .disabled(true)
                Text(MessageTimestamp.format(timestamp))
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .help(MessageTimestamp.absolute(timestamp))
                Spacer()
            }
            .opacity(isHovering ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            }  // end !isHistorical else branch
        }
        .onHover { isHovering = $0 }
    }
}

enum MessageTimestamp {
    static func format(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: d)
    }
    static func absolute(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: d)
    }
}

private struct FooterButton: View {
    let systemName: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(active ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct UserMessageRow: View {
    let text: String
    let timestamp: Date

    private var parsed: (commandName: String?, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return (nil, text) }
        let body = trimmed.dropFirst()
        if let space = body.firstIndex(of: " ") {
            let cmd = String(body[..<space])
            let rest = String(body[body.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            return cmd.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                ? (cmd, rest)
                : (nil, text)
        }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            ? (String(body), "")
            : (nil, text)
    }

    var body: some View {
        let p = parsed
        VStack(alignment: .trailing, spacing: 2) {
            bubble(p)
            Text(MessageTimestamp.format(timestamp))
                .font(SoulFont.ui(10))
                .foregroundStyle(SoulColor.fgSubtle)
                .help(MessageTimestamp.absolute(timestamp))
                .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private func bubble(_ p: (commandName: String?, rest: String)) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 32)
            if let cmd = p.commandName {
                Text("/\(cmd)")
                    .font(SoulFont.code(12, weight: .medium))
                    .foregroundStyle(SoulColor.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SoulColor.accentMuted, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 0.5)
                    )
                if !p.rest.isEmpty {
                    Text(p.rest)
                        .font(SoulFont.ui(13))
                        .foregroundStyle(SoulColor.fg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            } else {
                Text(text)
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ToolCallRow: View {
    let kind: String
    let title: String
    let status: String
    let location: String?

    private var filePath: String? {
        if let loc = location, looksLikePath(loc) { return loc }
        if looksLikePath(title) { return title }
        return nil
    }

    var body: some View {
        if let path = filePath {
            FileChipRow(kind: kind, status: status, path: path, statusColor: statusColor, icon: icon)
        } else {
            DefaultToolRow(kind: kind, title: title, status: status, location: location, statusColor: statusColor, icon: icon)
        }
    }

    private var icon: String {
        switch kind {
        case "read": return "📖"
        case "edit": return "✎"
        case "delete": return "🗑"
        case "move": return "→"
        case "search": return "🔎"
        case "execute": return "▶"
        case "think": return "💭"
        case "fetch": return "🌐"
        default: return "⚙"
        }
    }

    private var statusColor: Color {
        switch status {
        case "completed": return .green
        case "failed", "error": return .red
        case "in_progress", "pending": return SoulColor.accent
        default: return SoulColor.fgMuted
        }
    }
}

private func looksLikePath(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.contains(" ") else { return false }
    if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") { return true }
    if t.contains("/") && t.contains(".") { return true }
    return false
}

private struct FileChipRow: View {
    let kind: String
    let status: String
    let path: String
    let statusColor: Color
    let icon: String

    private var basename: String {
        (path as NSString).lastPathComponent
    }
    private var ext: String {
        let e = (basename as NSString).pathExtension
        return e.isEmpty ? "file" : e.uppercased()
    }
    private var dir: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "" : parent
    }

    var body: some View {
        Button(action: openFile) {
            cardContent
        }
        .buttonStyle(.plain)
        .help("Open \(path)")
    }

    private func openFile() {
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    private var cardContent: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(SoulColor.bgElevated)
                    .frame(width: 32, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(SoulColor.border, lineWidth: 1)
                    )
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(SoulColor.fgMuted)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(basename)
                        .font(SoulFont.code(12, weight: .medium))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kind)
                        .font(SoulFont.ui(10, weight: .medium))
                        .foregroundStyle(SoulColor.fgMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SoulColor.surface, in: Capsule())
                }
                HStack(spacing: 6) {
                    Text(ext)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(SoulColor.fgSubtle)
                    if !dir.isEmpty {
                        Text("·")
                            .foregroundStyle(SoulColor.fgSubtle)
                        Text(dir)
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(status)
                .font(SoulFont.ui(10))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct DefaultToolRow: View {
    let kind: String
    let title: String
    let status: String
    let location: String?
    let statusColor: Color
    let icon: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(icon)
                .font(SoulFont.ui(12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind)
                        .font(SoulFont.ui(11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                    Text(title)
                        .font(SoulFont.code(12))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(status)
                        .font(SoulFont.ui(10))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                if let location {
                    Text(location)
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PlanCard: View {
    let entries: [PlanEntry]
    @State private var expanded = true

    private var summary: String {
        let done = entries.filter { $0.status == "completed" }.count
        return "\(done)/\(entries.count) complete"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("Plan")
                    .font(SoulFont.ui(12, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                Text(summary)
                    .font(SoulFont.ui(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                Spacer()
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(SoulColor.surface.opacity(0.7))
            .overlay(alignment: .bottom) {
                if expanded {
                    Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        PlanEntryRow(entry: entry)
                    }
                }
                .padding(12)
            }
        }
        .background(SoulColor.bgElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1)
        )
    }
}

private struct PlanEntryRow: View {
    let entry: PlanEntry

    private var symbol: String {
        switch entry.status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }
    private var symbolColor: Color {
        switch entry.status {
        case "completed": return .green
        case "in_progress": return SoulColor.accent
        default: return SoulColor.fgSubtle
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(symbolColor)
                .padding(.top, 2)
            Text(entry.content)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let p = entry.priority, p != "medium" {
                Text(p)
                    .font(SoulFont.ui(9, weight: .medium))
                    .foregroundStyle(SoulColor.fgMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SoulColor.surface, in: Capsule())
            }
        }
    }
}

private struct WorkingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(SoulColor.fgSubtle)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1 : 0.35)
            }
        }
        .onAppear {
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}
