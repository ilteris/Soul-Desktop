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
    /// drop will be accepted before they release. Owned by the parent so
    /// the outer canvas drop target (ThreadView) can share the targeting
    /// state with the composer's own `.onDrop`.
    @Binding var isImageDropTargeted: Bool
    /// Files dropped onto the composer surface (or anywhere in the parent's
    /// drop area — see ThreadView.swift / HeroEmptyState.swift). Rendered
    /// as a row of chips above the text field; converted to markdown links
    /// at submit time. Owned by the parent so multiple drop surfaces share
    /// one attachment list.
    @Binding var droppedAttachments: [String]
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

    /// `[file.ext](file:///abs/path)` — file URLs need percent-encoding for
    /// spaces and other path characters or the markdown link will only
    /// capture up to the first space.
    private static func markdownLink(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let url = URL(fileURLWithPath: path).absoluteString
        return "[\(name)](\(url))"
    }

    /// Forward a drop to the shared DropAttachmentHandler and append any
    /// new paths to the parent-owned binding. Used by the composer's own
    /// inner `.onDrop` (drops directly on the composer); the same helper
    /// is also called from parents (ThreadView / HeroEmptyState) for the
    /// wider canvas drop area.
    private func handleProviderDrop(_ providers: [NSItemProvider]) -> Bool {
        let new = DropAttachmentHandler.process(
            providers: providers,
            projectPath: projectPath,
            existing: droppedAttachments
        )
        guard !new.isEmpty else { return false }
        droppedAttachments.append(contentsOf: new)
        return true
    }

    /// SOUL-SOUL_DESKTOP-154: + toolbar button companion to drag-and-drop.
    /// Opens an NSOpenPanel allowing multi-select, then wraps each chosen
    /// URL as an NSItemProvider and feeds the same pipeline drag drops
    /// go through. Images get copied into `<project>/.soul/attachments/`;
    /// non-image files reference in place — identical semantics to drag.
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to attach"
        guard panel.runModal() == .OK else { return }
        let providers = panel.urls.map { url in
            NSItemProvider(object: url as NSURL)
        }
        _ = handleProviderDrop(providers)
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
                    Button(action: openFilePicker) {
                        ToolbarChip(icon: "plus", label: nil)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach a file — routes through the same drop pipeline as drag-and-drop")
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
            // SOUL-SOUL_DESKTOP-147: the dashed drop-target affordance moved
            // to ThreadView so it traces the whole canvas (matching where
            // drops are actually accepted). Composer keeps its inner
            // `.onDrop` for direct-composer drops but no longer paints its
            // own border — the canvas-wide one covers it.
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

