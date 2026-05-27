import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SoulACP

struct ComposerView: View {
    @Binding var prompt: String
    let projectName: String
    var projectPath: String? = nil
    var commands: [SlashCommand] = []
    /// Two-arg send: (display, agent). Display is what shows in the user
    /// bubble (typically the bare `/cmd`); agent is the expanded prompt
    /// shipped over ACP. For free-text turns they're identical.
    var onSend: (_ display: String, _ agent: String, _ extraBlocks: [ContentBlock]) -> Bool = { _, _, _ in false }
    var supportsImageAttachments: Bool = false
    var onCancel: () -> Void = {}
    var isWorking: Bool = false
    /// Number of prompts queued behind the in-flight turn. Surfaced as a chip
    /// above the composer so the user can see what'll fire next and clear it
    /// if they change their mind.
    var queuedCount: Int = 0
    /// Most-recently-queued prompt for ↑-recall editing. ComposerView lets
    /// the user press ↑ (when the field is empty) to load this text back
    /// into the field and edit it; ⏎ then replaces the queued entry via
    /// `onEditQueued` instead of appending a new one. SOUL-199.
    var queuedTail: (id: UUID, text: String)? = nil
    var onEditQueued: (UUID, String) -> Bool = { _, _ in false }
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
    /// Terminal toggle, surfaced in the composer footer alongside the
    /// project/branch chips. SOUL-200.
    var terminalActive: Bool = false
    var onToggleTerminal: () -> Void = {}
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
    /// Set when the user pressed ↑ to recall a queued prompt. While non-nil,
    /// the next submit replaces that QueuedPrompt in the controller instead
    /// of appending a new entry.
    @State private var editingQueuedItemId: UUID? = nil
    /// True while the NSOpenPanel triggered by + is on-screen. Drives the
    /// button's active-state tint so the affordance reads as engaged
    /// while the modal is up.
    @State private var filePickerOpen: Bool = false
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
    /// True while AppShell's branch-seed background LLM is composing the
    /// pre-fill text for a freshly-spawned cross-provider draft. Drives
    /// the "Summarizing previous chat…" placeholder until the seed lands
    /// in `prompt`.
    var branchSeedLoading: Bool = false
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
        var agentLinks: [String] = []
        var displayLinks: [String] = []
        var extraBlocks: [ContentBlock] = []

        for path in droppedAttachments {
            let link = Self.markdownLink(forPath: path)
            displayLinks.append(link)

            let isImg = DropAttachmentHandler.isImageURL(URL(fileURLWithPath: path))
            if isImg && supportsImageAttachments {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                    let mimeType: String
                    switch ext {
                    case "png": mimeType = "image/png"
                    case "jpeg", "jpg": mimeType = "image/jpeg"
                    case "gif": mimeType = "image/gif"
                    case "webp": mimeType = "image/webp"
                    default: mimeType = "image/jpeg"
                    }
                    extraBlocks.append(.image(mimeType: mimeType, base64: data.base64EncodedString()))
                } else {
                    agentLinks.append(link)
                }
            } else {
                agentLinks.append(link)
            }
        }

        let finalDisplay = display + (displayLinks.isEmpty ? "" : (display.isEmpty ? "" : "\n\n") + displayLinks.joined(separator: " "))
        let finalAgent = agent + (agentLinks.isEmpty ? "" : (agent.isEmpty ? "" : "\n\n") + agentLinks.joined(separator: " "))

        guard !finalDisplay.isEmpty else { return }
        // SOUL-199: in edit-queued mode, replace the queued entry in place
        // instead of appending a new prompt. The agent sees the new text
        // when the queue drains; the visible bubble redraws too.
        let accepted: Bool
        if let editingId = editingQueuedItemId {
            accepted = onEditQueued(editingId, finalDisplay)
            if accepted {
                editingQueuedItemId = nil
            }
        } else {
            accepted = onSend(finalDisplay, finalAgent, extraBlocks)
        }
        // Contract: the composer is allowed to clear only after the owner
        // has synchronously accepted the prompt. "Accepted" means the app
        // has either painted/persisted the user bubble or updated an
        // existing queued bubble. Provider spawn/dispatch may still fail
        // later, but the user's text is already represented in app state.
        guard accepted else { return }
        lastSent = finalDisplay
        prompt = ""
        droppedAttachments = []
        // SOUL-217: don't clear the chip on send — keep it visible while
        // the agent is processing so the user retains the "/pulse"
        // context. Cleared automatically when isWorking flips false
        // (see .onChange below).
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
    ///
    /// SOUL-SOUL_DESKTOP-158: switched to async `panel.begin` so we can
    /// flip `filePickerOpen` on entry and off on close — the button paints
    /// its active state while the modal is up. `runModal()` would block
    /// the main thread and SwiftUI couldn't repaint.
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to attach"
        filePickerOpen = true
        panel.begin { response in
            DispatchQueue.main.async {
                filePickerOpen = false
                guard response == .OK else { return }
                let providers = panel.urls.map { url in
                    NSItemProvider(object: url as NSURL)
                }
                _ = handleProviderDrop(providers)
            }
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
                        HStack(spacing: 4) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Steer")
                                .font(SoulFont.ui(10, weight: .semibold))
                        }
                        .foregroundStyle(SoulColor.fg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SoulColor.fg.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.soulChip)
                    .help("Cancel the current turn and send the next queued prompt now")
                    Button(action: onClearQueue) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SoulColor.fgMuted)
                    }
                    .buttonStyle(.soulHover)
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
                        placeholder: activeCommand == nil ? "Ask Soul anything. @ to use plugins or mention files" : "",
                        onSubmit: submit,
                        onBackspaceWhenEmpty: {
                            if activeCommand != nil { clearCommand() }
                        },
                        preservesFocusedDraft: activeCommand == nil,
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
                            // SOUL-199: if a prompt is currently queued
                            // (turn in flight), ↑ pulls the queued text
                            // back into the field for editing. Submitting
                            // then replaces that queued entry in place
                            // rather than appending a new one. Falls back
                            // to shell-style lastSent recall otherwise.
                            if let tail = queuedTail {
                                prompt = tail.text
                                editingQueuedItemId = tail.id
                                return true
                            }
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
                    HoverableToolbarButton(
                        icon: "plus",
                        help: "Attach a file — routes through the same drop pipeline as drag-and-drop",
                        isActive: filePickerOpen,
                        action: openFilePicker
                    )
                    HarnessPicker(selection: provider, onSelect: onPickHarness)
                    PermissionModePicker(mode: $permissionMode)
                    Spacer()
                    SoulIcon(name: "mic", size: SoulMetric.iconLarge, color: SoulColor.fgMuted)
                    if isWorking {
                        // Both buttons visible while a turn is in flight:
                        // stop ends the current turn; send queues the next.
                        StopButton(onCancel: onCancel)

                        Button(action: submit) {
                            SoulIcon(name: "arrow.up.to.line", size: SoulMetric.icon, color: SoulColor.fg)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.surface, in: Circle())
                        }
                        .buttonStyle(.soulChip)
                        .help("Queue this message — will send when the current turn finishes")
                    } else {
                        Button(action: submit) {
                            SoulIcon(name: "arrow.up", size: SoulMetric.icon, color: SoulColor.fg)
                                .frame(width: 22, height: 22)
                                .background(SoulColor.surface, in: Circle())
                        }
                        .buttonStyle(.soulChip)
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
                    // SOUL-SOUL_DESKTOP-161: read from the @Observable
                    // cache instead of calling SoulRegistry.activeProjects()
                    // here. The previous inline call triggered a disk-stat
                    // sweep on every ComposerView re-render — during hydrate
                    // that meant one stat-per-project per appended item.
                    projects: LiveSoulRegistryStore.shared.cachedActive,
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
                Spacer(minLength: 0)
                Button(action: onToggleTerminal) {
                    Image(systemName: "terminal")
                        .font(.system(size: SoulMetric.icon, weight: .regular))
                        .foregroundStyle(terminalActive ? SoulColor.accent : SoulColor.fgMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.soulHover)
                .help(terminalActive ? "Hide terminal" : "Show terminal")
            }
            .padding(.horizontal, 4)
            .task(id: projectPath ?? "") { branchName = await GitInfo.currentBranch(at: projectPath) }
        }
        // SOUL-217: clear the active command chip once the agent's turn
        // completes, not at send time. Keeps the "/pulse" context
        // visible to the user during processing.
        .onChange(of: isWorking) { _, nowWorking in
            if !nowWorking { activeCommand = nil }
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

/// SOUL-211: dedicated Stop button with instant visual feedback. Flips to a
/// darker shade on press AND latches to a "cancelling…" disabled state on
/// release so the user gets unambiguous confirmation that the click registered
/// even before the async teardown completes downstream. The latched state
/// auto-clears after 1.5s in case isWorking doesn't flip (transport stuck).
private struct StopButton: View {
    let onCancel: () -> Void
    @State private var clicked = false

    var body: some View {
        Image(systemName: clicked ? "hourglass" : "stop.fill")
            .font(.system(size: SoulMetric.iconHint, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(clicked ? Color.red : SoulColor.accent))
            .scaleEffect(clicked ? 0.85 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: clicked)
            // SOUL-211: contentShape pins the hit region to the visible
            // circle; bare Image otherwise hit-tests against its bounding
            // box which can be eaten by sibling layouts.
            .contentShape(Circle())
            .onTapGesture {
                guard !clicked else { return }
                clicked = true
                let ts = ISO8601DateFormatter().string(from: Date())
                let line = "\(ts) composer Stop tap fired\n"
                let path = NSHomeDirectory() + "/Library/Logs/Soul-Desktop/cancel.log"
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if let data = line.data(using: .utf8) {
                    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                        try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close()
                    } else { try? data.write(to: URL(fileURLWithPath: path)) }
                }
                onCancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    clicked = false
                }
            }
            .help(clicked ? "Cancelling…" : "Stop the current turn")
    }
}
