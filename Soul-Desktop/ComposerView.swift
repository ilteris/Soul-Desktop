import SwiftUI
import AppKit

struct ComposerView: View {
    @Binding var prompt: String
    let projectName: String
    var projectPath: String? = nil
    var commands: [SlashCommand] = []
    var onSend: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var isWorking: Bool = false
    var currentProjectID: String = ""
    var onSelectProject: (String) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    var devCommand: String? = nil
    var devURL: String? = nil
    var devRunning: Bool = false
    var onRunLocal: (String, String?) -> Void = { _, _ in }

    @State private var showingCommandPalette = false
    @State private var activeCommand: SlashCommand? = nil
    @State private var branchName: String? = nil
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    private func submit() {
        let trimmedArgs = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if let cmd = activeCommand {
            payload = trimmedArgs.isEmpty ? "/\(cmd.name)" : "/\(cmd.name) \(trimmedArgs)"
        } else {
            payload = trimmedArgs
        }
        guard !payload.isEmpty else { return }
        onSend(payload)
        prompt = ""
        activeCommand = nil
        showingCommandPalette = false
    }

    private var slashQuery: String? {
        guard activeCommand == nil else { return nil }
        let trimmed = prompt
        guard trimmed.hasPrefix("/") else { return nil }
        let after = trimmed.dropFirst()
        if after.contains(" ") { return nil }
        return String(after)
    }

    private var matchedCommands: [SlashCommand] {
        guard let q = slashQuery else { return [] }
        if q.isEmpty { return commands }
        return commands.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func selectCommand(_ cmd: SlashCommand) {
        activeCommand = cmd
        prompt = ""
        showingCommandPalette = false
    }

    private func clearCommand() {
        activeCommand = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    if let cmd = activeCommand {
                        CommandChip(command: cmd, onClear: clearCommand)
                            .padding(.top, 11)
                    }
                    ComposerTextField(
                        text: $prompt,
                        placeholder: activeCommand?.inputHint ?? "Ask Soul anything. @ to use plugins or mention files",
                        onSubmit: submit,
                        onBackspaceWhenEmpty: {
                            if activeCommand != nil { clearCommand() }
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .onChange(of: prompt) { _, _ in
                        showingCommandPalette = !matchedCommands.isEmpty
                    }
                    .popover(
                        isPresented: $showingCommandPalette,
                        attachmentAnchor: .point(.topLeading),
                        arrowEdge: .bottom
                    ) {
                        SlashCommandPalette(
                            commands: matchedCommands,
                            onSelect: selectCommand
                        )
                    }
                }
                .padding(.horizontal, 14)

                HStack(spacing: 10) {
                    ToolbarChip(icon: "plus", label: nil)
                    Spacer()
                    SoulIcon(name: "mic", color: SoulColor.fgMuted)
                    if isWorking {
                        Button(action: onCancel) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.accent, in: Circle())
                        }.buttonStyle(.plain)
                    } else {
                        Button(action: submit) {
                            SoulIcon(name: "arrow.up", size: 12, color: SoulColor.fg)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.surface, in: Circle())
                        }.buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: SoulMetric.radiusL))
            .overlay(
                RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                    .strokeBorder(SoulColor.border, lineWidth: 0.5)
            )

            HStack(spacing: 14) {
                ProjectChip(
                    currentName: projectName,
                    projects: SoulRegistry.activeProjects(),
                    currentID: currentProjectID,
                    onSelect: onSelectProject,
                    onCreate: onNewProject
                )
                if let branch = branchName {
                    BranchChip(
                        currentBranch: branch,
                        projectPath: projectPath,
                        onSwitched: { branchName = $0 }
                    )
                }
                if let cmd = devCommand {
                    RunLocalChip(isRunning: devRunning) {
                        onRunLocal(cmd, devURL)
                    }
                }
            }
            .padding(.horizontal, 4)
            .task(id: projectPath ?? "") { branchName = await GitInfo.currentBranch(at: projectPath) }
        }
    }
}

enum GitInfo {
    static func currentBranch(at path: String?) async -> String? {
        guard let path, !path.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty || s == "HEAD" ? nil : s
        }.value
    }

    static func localBranches(at path: String?) async -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads/"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            do { try p.run() } catch { return [] }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    /// Returns nil on success, or stderr message on failure.
    static func checkout(branch: String, at path: String?) async -> String? {
        guard let path, !path.isEmpty else { return "no project path" }
        return await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", path, "checkout", branch]
            let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let data = err.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(p.terminationStatus)"
        }.value
    }
}

private struct ToolbarChip: View {
    let icon: String
    let label: String?
    var trailingChevron: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            SoulIcon(name: icon, color: SoulColor.fgMuted)
            if let label {
                Text(label)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            if trailingChevron {
                SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgSubtle)
            }
        }
        .padding(.horizontal, label == nil ? 4 : 8)
        .padding(.vertical, 4)
        .background(label == nil ? Color.clear : SoulColor.surface.opacity(0.6), in: Capsule())
    }
}

private struct ProviderPicker: View {
    @Binding var selection: Provider

    var body: some View {
        Menu {
            ForEach(Provider.allCases) { p in
                Button { selection = p } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            Image(systemName: p.icon)
                            Text(p.label)
                            if selection == p { Image(systemName: "checkmark") }
                        }
                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selection.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(selection.label)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
                SoulIcon(name: "chevron.down", size: 10, color: SoulColor.fgMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct ComposerTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onBackspaceWhenEmpty: () -> Void

    func makeNSView(context: Context) -> BackspaceInterceptingTextView {
        let tv = BackspaceInterceptingTextView()
        tv.delegate = context.coordinator
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = NSFont(name: SoulFont.family, size: 14) ?? NSFont.systemFont(ofSize: 14)
        tv.textColor = NSColor(SoulColor.fg)
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.placeholderString = placeholder
        tv.string = text
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        return tv
    }

    func updateNSView(_ tv: BackspaceInterceptingTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.placeholderString = placeholder
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextField
        init(_ p: ComposerTextField) { parent = p }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? BackspaceInterceptingTextView else { return }
            parent.text = tv.string
            tv.invalidateIntrinsicContentSize()
        }
    }
}

private final class BackspaceInterceptingTextView: NSTextView {
    var onBackspaceWhenEmpty: (() -> Void)?
    var onCommit: (() -> Void)?
    var placeholderString: String = "" { didSet { needsDisplay = true } }

    private let lineHeight: CGFloat = 20
    private let maxLines: CGFloat = 6

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: lineHeight)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let height = min(maxLines * lineHeight, max(lineHeight, ceil(used) + 2))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete (backspace), 36 = return, 76 = numpad enter
        if event.keyCode == 51, string.isEmpty {
            onBackspaceWhenEmpty?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.shift) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(SoulColor.fgSubtle)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width, y: inset.height)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}

private struct CommandChip: View {
    let command: SlashCommand
    let onClear: () -> Void

    var body: some View {
        Text("/\(command.name)")
            .font(SoulFont.code(12, weight: .medium))
            .foregroundStyle(SoulColor.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.accentMuted, in: Capsule())
            .overlay(
                Capsule().strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 0.5)
            )
            .help(command.description ?? "/\(command.name)")
    }
}

private struct SlashCommandPalette: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(commands) { cmd in
                Button {
                    onSelect(cmd)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(cmd.name)")
                            .font(SoulFont.code(12, weight: .medium))
                            .foregroundStyle(SoulColor.fg)
                        if let hint = cmd.inputHint {
                            Text(hint)
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer(minLength: 12)
                        if let desc = cmd.description {
                            Text(desc)
                                .font(SoulFont.ui(11))
                                .foregroundStyle(SoulColor.fgMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 420)
    }
}

private struct RunLocalChip: View {
    let isRunning: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SoulIcon(
                    name: isRunning ? "stop.fill" : "play.fill",
                    size: 10,
                    color: isRunning ? .red : SoulColor.accent
                )
                Text(isRunning ? "Stop" : "Run locally")
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (isRunning ? Color.red.opacity(0.12) : SoulColor.accentMuted),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BranchChip: View {
    let currentBranch: String
    let projectPath: String?
    var onSwitched: (String) -> Void
    @State private var branches: [String] = []
    @State private var checkoutError: String? = nil

    var body: some View {
        Menu {
            if branches.isEmpty {
                Text("Loading…")
            } else {
                ForEach(branches, id: \.self) { b in
                    Button {
                        switchTo(b)
                    } label: {
                        HStack {
                            if b == currentBranch { Image(systemName: "checkmark") }
                            Text(b)
                        }
                    }
                    .disabled(b == currentBranch)
                }
            }
            if let err = checkoutError {
                Divider()
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } label: {
            HStack(spacing: 4) {
                SoulIcon(name: "arrow.triangle.branch", size: 11, color: SoulColor.fgMuted)
                Text(currentBranch).font(SoulFont.ui(12)).foregroundStyle(SoulColor.fgMuted)
                SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .task(id: projectPath ?? "") {
            branches = await GitInfo.localBranches(at: projectPath)
        }
    }

    private func switchTo(_ b: String) {
        Task {
            checkoutError = nil
            if let err = await GitInfo.checkout(branch: b, at: projectPath) {
                checkoutError = err.split(separator: "\n").first.map(String.init) ?? err
                return
            }
            onSwitched(b)
            branches = await GitInfo.localBranches(at: projectPath)
        }
    }
}

private struct ContextChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            SoulIcon(name: icon, size: 11, color: SoulColor.fgMuted)
            Text(label).font(SoulFont.ui(12)).foregroundStyle(SoulColor.fgMuted)
            SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgSubtle)
        }
    }
}

private struct ProjectChip: View {
    let currentName: String
    let projects: [SoulProject]
    let currentID: String
    let onSelect: (String) -> Void
    let onCreate: () -> Void

    var body: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    onSelect(p.id)
                } label: {
                    HStack {
                        if p.id == currentID { Image(systemName: "checkmark") }
                        Text(p.name)
                    }
                }
            }
            Divider()
            Button("New project…", action: onCreate)
        } label: {
            HStack(spacing: 4) {
                SoulIcon(name: "folder", size: 11, color: SoulColor.fgMuted)
                Text(currentName).font(SoulFont.ui(12)).foregroundStyle(SoulColor.fgMuted)
                SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
