import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposerView: View {
    @Binding var prompt: String
    let projectName: String
    var projectPath: String? = nil
    var commands: [SlashCommand] = []
    /// Two-arg send: (display, agent). Display is what shows in the user
    /// bubble (typically the bare `/cmd`); agent is the expanded prompt
    /// shipped over ACP. For free-text turns they're identical.
    var onSend: (_ display: String, _ agent: String) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    var isWorking: Bool = false
    /// Number of prompts queued behind the in-flight turn. Surfaced as a chip
    /// above the composer so the user can see what'll fire next and clear it
    /// if they change their mind.
    var queuedCount: Int = 0
    var onClearQueue: () -> Void = {}
    /// Cancel the in-flight ACP turn and dispatch the next queued prompt as
    /// a fresh turn. Surfaced as a "Steer" button on the queue chip alongside
    /// the clear-X. Shares the underlying `cancelActiveProviderTurn()` path
    /// with the composer's Stop button (`onCancel`) — Stop drops the queue,
    /// Steer flushes it.
    var onSteer: () -> Void = {}
    var currentProjectID: String = ""
    var onSelectProject: (String) -> Void = { _ in }
    var onNewProject: () -> Void = {}
    var devCommand: String? = nil
    var devURL: String? = nil
    var devRunning: Bool = false
    var onRunLocal: (String, String?) -> Void = { _, _ in }
    @Binding var permissionMode: PermissionMode
    /// Provider this composer feeds. Claude reads `~/.claude/skills/<name>/SKILL.md`
    /// natively when it sees `/cmd`, so we skip client-side expansion for
    /// Claude to avoid double-instruction confusion. Pi/gemini-cli need the
    /// expansion because their TUI command system isn't exposed over ACP.
    var provider: Provider = .geminiCLI
    /// Called when the user changes harness from the inline picker. Routes
    /// through AppShell which handles new-chat-on-switch semantics.
    var onPickHarness: (Provider) -> Void = { _ in }

    @State private var showingCommandPalette = false
    @State private var activeCommand: SlashCommand? = nil
    @State private var branchName: String? = nil
    /// True while a drag with at least one image URL is hovering the
    /// composer. Drives the dashed accent overlay so the user knows the
    /// drop will be accepted before they release.
    @State private var isImageDropTargeted = false
    /// Files dropped onto the composer. Rendered as a row of chips above the
    /// text field; converted to markdown links at submit time. Storing them
    /// out-of-band keeps the textarea clean (no inline `[name](file://…)`
    /// noise the user has to scroll past) and lets the user remove a single
    /// attachment without surgical text editing.
    @State private var droppedAttachments: [String] = []
    /// Last submitted prompt, persisted across launches. Up-arrow recalls it
    /// when the field is empty (shell-history convention; single-entry).
    @AppStorage("soul.composer.lastSent") private var lastSent: String = ""
    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    private func submit() {
        let trimmedArgs = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let display: String
        let agent: String
        if let cmd = activeCommand {
            display = trimmedArgs.isEmpty ? "/\(cmd.name)" : "/\(cmd.name) \(trimmedArgs)"
            // Claude reads ~/.claude/skills/<name>/SKILL.md natively when it
            // sees the bare `/cmd` literal — don't double-inject.
            if provider == .claude {
                agent = display
            } else if let body = SkillsRegistry.instructions(forCommand: cmd.name) {
                var enriched = """
                <slash-command name="\(cmd.name)">
                \(body)
                </slash-command>

                The user invoked /\(cmd.name).
                """
                if !trimmedArgs.isEmpty {
                    enriched += "\nArguments: \(trimmedArgs)"
                }
                agent = enriched
            } else {
                agent = display
            }
        } else {
            display = trimmedArgs
            agent = trimmedArgs
        }
        let attachmentSuffix: String = {
            guard !droppedAttachments.isEmpty else { return "" }
            let links = droppedAttachments.map { Self.markdownLink(forPath: $0) }
            return (display.isEmpty ? "" : "\n\n") + links.joined(separator: " ")
        }()
        let finalDisplay = display + attachmentSuffix
        let finalAgent = agent + attachmentSuffix
        guard !finalDisplay.isEmpty else { return }
        onSend(finalDisplay, finalAgent)
        lastSent = finalDisplay
        prompt = ""
        droppedAttachments = []
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

    /// Handle a drop of one or more file URLs onto the composer. Copies any
    /// image files into `<projectPath>/.soul/attachments/` (created on
    /// demand) and appends a markdown link `[name](file:///abs/path)` for
    /// each dropped file. Images get copied into the per-project
    /// `.soul/attachments` dir so they survive if the source moves; other
    /// files are referenced in place. The MarkdownView in the user bubble
    /// renders the inserted tokens as clickable links.
    private func handleFileDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var attachmentsDir: String? = nil
        if let project = projectPath, !project.isEmpty,
           urls.contains(where: { Self.isImageURL($0) }) {
            let dir = "\(project)/.soul/attachments"
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            attachmentsDir = dir
        }
        var added = 0
        for (i, src) in urls.enumerated() {
            let finalPath: String
            if Self.isImageURL(src), let dir = attachmentsDir {
                let dst = "\(dir)/\(stamp)-\(i)-\(src.lastPathComponent)"
                do {
                    try FileManager.default.copyItem(atPath: src.path, toPath: dst)
                    finalPath = dst
                } catch {
                    finalPath = src.path
                }
            } else {
                finalPath = src.path
            }
            if !droppedAttachments.contains(finalPath) {
                droppedAttachments.append(finalPath)
                added += 1
            }
        }
        return added > 0
    }

    /// `[file.ext](file:///abs/path)` — file URLs need percent-encoding for
    /// spaces and other path characters or the markdown link will only
    /// capture up to the first space.
    private static func markdownLink(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let url = URL(fileURLWithPath: path).absoluteString
        return "[\(name)](\(url))"
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        return exts.contains(url.pathExtension.lowercased())
    }

    /// Handle a mixed-payload drop. Each provider may carry a file URL
    /// (Finder, Cmd-Shift-4 to disk) or raw image bytes (Messages, Mail,
    /// browser drag-from-page, screenshot drag-from-Preview). File URLs go
    /// through the existing path; raw image bytes are written into the
    /// per-project attachments dir then appended as an attachment chip.
    private func handleProviderDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        let group = DispatchGroup()
        var fileURLs: [URL] = []
        var dataDrops: [(Data, String?)] = []
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url, u.isFileURL { fileURLs.append(u) }
                    group.leave()
                }
                continue
            }
            // Probe image type identifiers in order of fidelity (PNG → JPEG
            // → TIFF → GIF → generic). Whichever responds first wins; we
            // stop after one to avoid loading the same bytes twice.
            let imageTypes = ["public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.image"]
            for type in imageTypes where provider.hasItemConformingToTypeIdentifier(type) {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data { dataDrops.append((data, Self.extHint(forType: type))) }
                    group.leave()
                }
                break
            }
        }
        // The drop callback is called on the main thread; we need to wait
        // for the async provider loads before mutating state. Caller cares
        // about the return Bool so we synchronously wait — bounded by the
        // OS's drop timeout anyway.
        _ = group.wait(timeout: .now() + 2.0)
        if !fileURLs.isEmpty {
            accepted = handleFileDrop(fileURLs) || accepted
        }
        for (data, hint) in dataDrops {
            if let path = writeImageDataAsAttachment(data, hint: hint),
               !droppedAttachments.contains(path) {
                droppedAttachments.append(path)
                accepted = true
            }
        }
        return accepted
    }

    private static func extHint(forType uti: String) -> String? {
        switch uti {
        case "public.png":          return "png"
        case "public.jpeg":         return "jpg"
        case "public.tiff":         return "tiff"
        case "com.compuserve.gif":  return "gif"
        default:                    return nil
        }
    }

    /// Persist raw image bytes (from a non-file drag — Messages, Mail, web
    /// browsers all flatten an image to a Transferable image payload, not a
    /// file URL) into the project's attachments dir and return the on-disk
    /// path. Returns nil if the bytes couldn't be decoded or there's no
    /// project to write into.
    private func writeImageDataAsAttachment(_ data: Data, hint: String?) -> String? {
        guard let project = projectPath, !project.isEmpty else { return nil }
        let dir = "\(project)/.soul/attachments"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let ext: String = {
            if let h = hint?.lowercased(), !h.isEmpty,
               ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "bmp"].contains(h) {
                return h
            }
            // Sniff by magic header — cheaper than NSImage round-trip, and
            // we keep the original encoding so the agent sees the original
            // bytes rather than a re-encoded PNG.
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
            if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
            return "png"
        }()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dst = "\(dir)/\(stamp)-drag.\(ext)"
        do {
            try data.write(to: URL(fileURLWithPath: dst))
            return dst
        } catch {
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if queuedCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(SoulColor.fgMuted)
                    Text("\(queuedCount) message\(queuedCount == 1 ? "" : "s") queued")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                    Spacer(minLength: 0)
                    Button(action: onSteer) {
                        HStack(spacing: 3) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Steer")
                                .font(SoulFont.ui(10, weight: .semibold))
                        }
                        .foregroundStyle(SoulColor.fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SoulColor.fg.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel the current turn and send the next queued prompt now")
                    Button(action: onClearQueue) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear queued messages")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 10) {
                if !droppedAttachments.isEmpty {
                    AttachmentChipRow(
                        paths: droppedAttachments,
                        onRemove: { p in droppedAttachments.removeAll { $0 == p } }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                }
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
                        },
                        onTab: {
                            // Commit the top-matched slash command when the
                            // popover is open. Returns true to swallow Tab so
                            // focus doesn't leave the field; false otherwise
                            // (default tab traversal continues).
                            guard activeCommand == nil,
                                  let match = matchedCommands.first
                            else { return false }
                            selectCommand(match)
                            return true
                        },
                        onUpArrowWhenEmpty: {
                            // Shell-style: recall the last submitted prompt
                            // when the field is empty. No-op if there's no
                            // history yet. Caret will land at end via
                            // text-change reflow.
                            guard !lastSent.isEmpty else { return false }
                            prompt = lastSent
                            return true
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .onChange(of: prompt) { _, new in
                        // Auto-commit: typing space after an exact command name
                        // ("/pulse ") drops the chip and clears the slash text,
                        // matching what clicking the popover row already does.
                        if activeCommand == nil,
                           new.hasPrefix("/"),
                           let spaceIdx = new.firstIndex(of: " ") {
                            let head = String(new[new.index(after: new.startIndex)..<spaceIdx])
                            if let match = commands.first(where: { $0.name.caseInsensitiveCompare(head) == .orderedSame }) {
                                let tail = String(new[new.index(after: spaceIdx)...])
                                activeCommand = match
                                prompt = tail
                                showingCommandPalette = false
                                return
                            }
                        }
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
                    HarnessPicker(selection: provider, onSelect: onPickHarness)
                    PermissionModePicker(mode: $permissionMode)
                    Spacer()
                    SoulIcon(name: "mic", color: SoulColor.fgMuted)
                    if isWorking {
                        // Both buttons visible while a turn is in flight:
                        // stop ends the current turn; send queues the next.
                        Button(action: onCancel) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Stop the current turn")

                        Button(action: submit) {
                            SoulIcon(name: "arrow.up.to.line", size: 12, color: SoulColor.fg)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.surface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Queue this message — will send when the current turn finishes")
                    } else {
                        Button(action: submit) {
                            SoulIcon(name: "arrow.up", size: 12, color: SoulColor.fg)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.surface, in: Circle())
                        }
                        .buttonStyle(.plain)
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
            .overlay(
                RoundedRectangle(cornerRadius: SoulMetric.radiusL)
                    .strokeBorder(
                        SoulColor.accent,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .opacity(isImageDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: isImageDropTargeted)
            )
            .onDrop(
                of: [.fileURL, .image, .png, .jpeg, .tiff, .gif],
                isTargeted: $isImageDropTargeted
            ) { providers in
                handleProviderDrop(providers)
            }

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
    var onTab: (() -> Bool)? = nil
    /// Fires on Up-arrow when the field is empty. Returns true to consume
    /// the event (caret-up motion suppressed), false to fall through to
    /// the default cursor-move behavior.
    var onUpArrowWhenEmpty: (() -> Bool)? = nil

    func makeNSView(context: Context) -> BackspaceInterceptingTextView {
        let tv = BackspaceInterceptingTextView()
        tv.delegate = context.coordinator
        tv.onBackspaceWhenEmpty = onBackspaceWhenEmpty
        tv.onCommit = onSubmit
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = SoulType.composerNS
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
        tv.onTab = onTab
        tv.onUpArrowWhenEmpty = onUpArrowWhenEmpty
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
    /// Fired on plain Tab key. Returns true to consume the event, false to
    /// let the default focus-traversal behavior run. Used to commit the
    /// slash command popover's top match without forcing a Space keystroke.
    var onTab: (() -> Bool)?
    var onUpArrowWhenEmpty: (() -> Bool)?
    var placeholderString: String = "" { didSet { needsDisplay = true } }

    private let lineHeight: CGFloat = 20
    private let minLines: CGFloat = 3
    private let maxLines: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minLines * lineHeight)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let height = min(maxLines * lineHeight, max(minLines * lineHeight, ceil(used) + 2))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    /// Refuse image-file drops at the NSTextView level so SwiftUI's outer
    /// `.dropDestination` on the composer container gets a chance to claim
    /// them and copy into `.soul/attachments/`. Default NSTextView behavior
    /// is to drop file URLs in as plain text, which produced the "tmp path
    /// in the prompt" bug — we override draggingEntered/draggingUpdated to
    /// return no-op for image drags. Non-image drags (text, other files)
    /// keep default behavior.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingHasImageURL(sender) { return [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingHasImageURL(sender) { return [] }
        return super.draggingUpdated(sender)
    }

    private static func draggingHasImageURL(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty
        else { return false }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        return urls.contains { imageExts.contains($0.pathExtension.lowercased()) }
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete (backspace), 36 = return, 76 = numpad enter,
        // 48 = tab, 126 = up arrow
        if event.keyCode == 51, string.isEmpty {
            onBackspaceWhenEmpty?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.shift) {
            onCommit?()
            return
        }
        if event.keyCode == 48, onTab?() == true {
            return
        }
        if event.keyCode == 126, string.isEmpty,
           onUpArrowWhenEmpty?() == true {
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

private struct AttachmentChipRow: View {
    let paths: [String]
    let onRemove: (String) -> Void
    @Environment(\.openFilePreview) private var openFilePreview

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    AttachmentChip(path: path,
                                   onOpen: { openFilePreview(path) },
                                   onRemove: { onRemove(path) })
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let path: String
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var name: String { (path as NSString).lastPathComponent }
    private var icon: String {
        let ext = (path as NSString).pathExtension.lowercased()
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        if images.contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(SoulColor.accent)
            Button(action: onOpen) {
                Text(name)
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.5)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SoulColor.accentMuted, in: Capsule())
        .overlay(
            Capsule().strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .help(path)
    }
}

private struct CommandChip: View {
    let command: SlashCommand
    let onClear: () -> Void

    var body: some View {
        Text("/\(command.name)")
            .font(SoulFont.code(12, weight: .regular))
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
                            .font(SoulFont.code(12, weight: .regular))
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

/// Composer-row chip exposing the umbrella permission mode for the active
/// thread. Tap to open a menu of `PermissionMode` choices; selection writes
/// straight through to the bound state and (via ThreadController didSet) to
/// the live ACP client policy.
private struct PermissionModePicker: View {
    @Binding var mode: PermissionMode

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { m in
                Button {
                    mode = m
                } label: {
                    HStack {
                        Image(systemName: m.sfSymbol)
                        VStack(alignment: .leading) {
                            Text(m.label)
                            Text(m.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        if mode == m { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.sfSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(mode.label)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SoulIcon(name: "chevron.down", size: 9, color: SoulColor.fgSubtle)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SoulColor.surface.opacity(0.6), in: Capsule())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.subtitle)
    }
}
