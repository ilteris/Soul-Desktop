import Foundation

/// ACP `SessionUpdate` dispatch + per-update helpers, lifted out of
/// ThreadController. The big `apply(_:)` switch and its accompanying
/// `insertToolCall` / `appendAgentChunk` / `insertPlan` / etc. all live
/// here so the controller proper isn't carrying ~600 lines of stream-
/// handling logic.
///
/// Pure file shuffle, no behavior change. Refactor 6/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
extension ThreadController {

    func apply(_ update: SessionUpdate) {
        let _applyStart = DispatchTime.now()
        let _applyKind = Self.kindLabel(update)
        defer {
            let elapsedNs = DispatchTime.now().uptimeNanoseconds &- _applyStart.uptimeNanoseconds
            applyTiming.record(
                kind: _applyKind,
                elapsedNs: elapsedNs,
                provider: provider,
                sessionId: sessionId,
                itemsCount: items.count
            )
        }
        // ACP trace: when the `soul.acp.trace` UserDefault is on, every
        // session/update lands as a one-line entry in the agent log
        // (kind name + a tiny size hint). Lets you see end-to-end whether
        // ACP frames are arriving during a turn — separate from the
        // unknown-kind logging which only fires on decoder gaps.
        if UserDefaults.standard.bool(forKey: "soul.acp.trace") {
            appendTraceLog("[acp ←] \(Self.kindLabel(update)) \(Self.sizeHint(update))")
        }
        // SOUL-SOUL_DESKTOP-043: during a session/load that follows a disk
        // hydrate, the agent streams every prior turn back through
        // user/agent_message_chunk + toolCall notifications. We already
        // rendered those items from the on-disk transcript, so re-applying
        // them here would double everything. Let only non-content updates
        // (availableCommandsUpdate populates the slash picker) through.
        if suppressLoadReplay {
            if case .availableCommandsUpdate(let payload) = update {
                updateCommands(payload)
            }
            return
        }
        switch update {
        case .agentMessageChunk(let block):
            if case .text(let chunk) = block {
                // SOUL-SOUL_DESKTOP-108: skip empty-text chunks so they don't
                // ghost-append a bubble with no body. Most empty chunks come
                // from non-text ACP content types the old decoder collapsed
                // to "" — the new decoder produces visible surrogates, but
                // legacy hooks.jsonl entries can still replay empty strings.
                guard !chunk.isEmpty else { break }
                if silentCapture != nil {
                    silentCapture? += chunk
                } else {
                    appendAgentChunk(chunk)
                }
            }
        case .agentThoughtChunk(let block):
            // Render the agent's reasoning stream so the user sees what's
            // happening during long turns instead of staring at a spinner.
            // Same coalescing pattern as agentMessageChunk: append to the
            // open thought bubble, or open a new one. A subsequent
            // agentMessageChunk (or tool call) closes the bubble by
            // resetting `openAgentThoughtId`.
            if silentCapture != nil { break }
            if case .text(let text) = block,
               !text.isEmpty {
                appendAgentThoughtChunk(text)
            }
        case .toolCall(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: false)
        case .toolCallUpdate(let payload):
            if silentCapture != nil { break }
            insertToolCall(payload, isUpdate: true)
        case .plan(let payload):
            insertPlan(payload)
        case .availableCommandsUpdate(let payload):
            updateCommands(payload)
        case .userMessageChunk(let block):
            // The agent replays prior user turns through this stream during
            // `session/load`. Each chunk is the full text of one turn (not a
            // partial stream). Closing the open agent bubble ensures turn
            // boundaries paint cleanly when several turns replay in sequence.
            if case .text(let text) = block,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                openAgentMessageId = nil
                // Claude Code wraps locally-executed slash command output in
                // `<local-command-*>` scaffolding tags before injecting them
                // back into the chat stream. Without filtering, those tags
                // would render verbatim as user bubbles. Strip / re-route.
                let classified = classifyLocalCommand(text)
                switch classified {
                case .skip:
                    break
                case .status(let inner):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    items.append(.status(id: id, text: inner))
                case .message(let cleaned):
                    let id = UUID()
                    if isReplayingLoad { historicalIDs.insert(id) }
                    // Strip Gemini-CLI's `--- Content from referenced files ---`
                    // auto-expansion block (same as the off-disk path in
                    // GeminiTranscriptReader). Defensive for non-Gemini
                    // streams too — the marker is unique enough not to false
                    // positive on legitimate prose.
                    let stripped = GeminiTranscriptReader.stripGeminiReferencedFileBlock(cleaned)
                    items.append(.userMessage(id: id, text: stripped, timestamp: Date()))
                }
            }
        case .currentModeUpdate:
            break
        case .unknown(let kind, let payload):
            // pi-acp emits `session_info_update` as queue/running telemetry
            // on every turn (depth + running flag). Useful diagnostic data
            // but emitted at high frequency — silently drop so the agent
            // log doesn't fill up with one entry per pi event. When Pi says
            // it is idle, also drain any stale per-tool watchdog entries left
            // behind by replay/noisy status bursts so they cannot cancel the
            // next live turn.
            if kind == "session_info_update" {
                clearPiToolTimeoutsIfIdle(payload)
                break
            }
            let preview = String(describing: payload).prefix(240)
            appendAgentLog("[unknown sessionUpdate] kind=\(kind) payload=\(preview)")
        }
    }

    private func clearPiToolTimeoutsIfIdle(_ payload: JSONValue) {
        guard provider == .pi else { return }
        guard case .bool(false)? = payload["_meta"]?["piAcp"]?["running"] else { return }
        let queueDepth: Int
        if case .int(let depth)? = payload["_meta"]?["piAcp"]?["queueDepth"] {
            queueDepth = depth
        } else {
            queueDepth = 0
        }
        guard queueDepth == 0 else { return }
        toolCallStartedAt.removeAll()
        toolCallLastActivityAt.removeAll()
        toolCallTimedOut.removeAll()
        toolCallPreviousLineCount.removeAll()
    }

    private typealias LocalCommandShape = LocalCommandClassifier.Shape

    private func classifyLocalCommand(_ raw: String) -> LocalCommandShape {
        return LocalCommandClassifier.classify(raw)
    }

    private func appendAgentChunk(_ chunk: String) {
        // A new message bubble ends any open thought bubble. The thought
        // chunks always precede the visible reply in Claude's stream, so
        // closing here keeps narrative order: thought → message.
        openAgentThoughtId = nil
        let bubbleId: UUID
        if let openId = openAgentMessageId,
           let idx = items.firstIndex(where: { $0.id == openId }),
           case .agentMessage(let id, let existing, _, let ts) = items[idx] {
            items[idx] = .agentMessage(id: id, text: existing + chunk, complete: false, timestamp: ts)
            bubbleId = id
        } else {
            let id = UUID()
            openAgentMessageId = id
            items.append(.agentMessage(id: id, text: chunk, complete: false, timestamp: Date()))
            bubbleId = id
        }
        // SOUL-SOUL_DESKTOP-065: persist each chunk to disk so the reply
        // text survives an abrupt child teardown (manual quit / force-quit
        // / OS sleep) that would otherwise lose everything written between
        // the last completed turn and the next AfterAgent. Retired at
        // end-of-turn when AfterAgent has been written authoritatively.
        if let sid = sessionId {
            SoulRegistry.appendAgentChunk(
                projectKey: project.id,
                sessionId: sid,
                bubbleId: bubbleId,
                chunk: chunk
            )
        }
    }

    /// Inject a paragraph break when a reasoning chunk begins with a bold
    /// span (`**Header**`) and the prior buffer ends in sentence-terminating
    /// punctuation. Gemini (and sometimes Pi/Codex) emit reasoning as one
    /// long run with no linebreaks between section headers, so the renderer's
    /// inline-only markdown parser ends up gluing headers onto the end of
    /// the previous sentence. Patching the buffer here is cheaper than
    /// rewriting the renderer (block-level markdown caused exponential
    /// SwiftUI layout recursion — see comment in AgentThoughtRow).
    private func normalizeThoughtJoin(prior: String, incoming: String) -> String {
        let trimmedIncoming = incoming.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmedIncoming.hasPrefix("**") else { return prior + incoming }
        let lastNonSpace = prior.reversed().drop(while: { $0 == " " || $0 == "\t" }).first
        guard let last = lastNonSpace, last == "." || last == "!" || last == "?" else {
            return prior + incoming
        }
        // Already separated by a newline? Don't double up.
        let tailNewlines = prior.reversed().prefix(while: { $0 == " " || $0 == "\t" || $0 == "\n" })
        if tailNewlines.contains("\n") { return prior + incoming }
        return prior + "\n\n" + incoming
    }

    private func appendAgentThoughtChunk(_ chunk: String) {
        if let openId = openAgentThoughtId,
           let idx = items.firstIndex(where: { $0.id == openId }),
           case .agentThought(let id, let existing, _, let ts) = items[idx] {
            let combined = normalizeThoughtJoin(prior: existing, incoming: chunk)
            items[idx] = .agentThought(id: id, text: combined, complete: false, timestamp: ts)
        } else {
            // Symmetric to appendAgentChunk: opening a thought bubble closes
            // any open message bubble. Without this, a stream of shape
            // message-chunk → thought-chunks → message-chunks (observed on
            // Pi) appends the second batch of message chunks back into the
            // first bubble — which sits ABOVE the thought bubble in items[],
            // so the reply text visually grows above the thinking card and
            // pushes it down. SOUL-SOUL_DESKTOP-070.
            openAgentMessageId = nil
            let id = UUID()
            openAgentThoughtId = id
            items.append(.agentThought(id: id, text: chunk, complete: false, timestamp: Date()))
        }
    }

    private func insertToolCall(_ payload: JSONValue, isUpdate: Bool) {
        let toolId: String = {
            if let tid = payload["toolCallId"]?.stringValue { return tid }
            // pi-acp legacy/load support: try to derive an ID from the payload
            // if toolCallId is missing, to avoid duplication during session/load.
            if let kind = payload["kind"]?.stringValue,
               let title = payload["title"]?.stringValue {
                return "legacy-\(kind)-\(title)"
            }
            return UUID().uuidString
        }()
        let rawKind = payload["kind"]?.stringValue ?? "tool"
        let rawTitle = payload["title"]?.stringValue ?? ""
        // Normalize provider kind quirks: Pi sends kind="other"+title="bash"
        // for shell invocations; the rest of the codebase (icon, kindForTool,
        // play-button affordance, carousel grouping) keys off "execute" for
        // shell tools. Remap so Pi bash renders identically to Claude/Gemini
        // bash instead of through the generic ⚙️ "other" path.
        let kind: String = {
            if rawKind == "other" {
                let t = rawTitle.lowercased()
                if t == "bash" || t == "shell" || t == "sh" || t == "command" {
                    return "execute"
                }
            }
            return rawKind
        }()
        let status = payload["status"]?.stringValue ?? "pending"

        // Claude (and most ACP agents) attach a human-readable description to
        // every tool call's rawInput — "Search for X", "List dotfiles". For
        // Bash calls especially, the title field is the raw command, which is
        // useless as a chip headline. Prefer description when present, and
        // surface the command underneath as location.
        let rawInput = payload["rawInput"]
        let description = rawInput?["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Provider variance: command can land in rawInput.command (Claude),
        // rawInput.cmd, or older Gemini-CLI variants stash it in
        // rawInput.shell_command / .args. Check all known spellings so the
        // chip never falls back to a generic "Shell" label with no command.
        let command: String = {
            for key in ["command", "cmd", "shell_command", "args"] {
                if let s = rawInput?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !s.isEmpty {
                    return s
                }
            }
            return ""
        }()

        // Treat generic placeholder titles ("Shell", "Bash", "Execute") as
        // unset so the command takes over the headline. Gemini-CLI sometimes
        // ships these literal placeholders when the rawTitle should have
        // been the command itself.
        let genericTitles: Set<String> = ["Shell", "Bash", "Execute", "execute", "Run", "run"]
        let titleIsGeneric = genericTitles.contains(rawTitle)

        let title: String = {
            if !description.isEmpty { return description }
            if kind == "execute", !command.isEmpty, (rawTitle.isEmpty || titleIsGeneric) {
                return command
            }
            return rawTitle
        }()

        let location: String? = {
            // Surface the command underneath as location only when title
            // already holds something else (description). Otherwise we'd
            // duplicate the command on both lines.
            if kind == "execute", !command.isEmpty, title != command {
                return command
            }
            return firstLocation(payload)
        }()

        if status == "failed" {
            ToolFailureLog.dump(payload: payload, provider: provider, sessionId: sessionId)
        }

        // Try structured extraction from rawInput first. ACP `tool_call_update`
        // notifications often re-send the same toolCallId with only the
        // status/output changing, so rawInput is empty on later updates.
        // We must NOT overwrite a previously-captured structured payload
        // with the JSON fallback when an update arrives empty-handed.
        let startLine: Int? = {
            guard case .array(let locs)? = payload["locations"], let first = locs.first,
                  let line = first["line"], case .int(let l) = line else { return nil }
            return l
        }()
        let structuredDetails: ToolCallDetails? = {
            // SOUL-SOUL_DESKTOP-111: delegate_to_specialist tool calls carry a
            // structured payload that the SubagentCard renders against. Match
            // on the literal tool name from rawTitle / payload["name"]. The
            // toolCallId doubles as the subagent dir name (kernel contract).
            let toolName = payload["name"]?.stringValue ?? rawTitle
            if toolName == "delegate_to_specialist" || rawKind == "delegate_to_specialist" {
                let specialist = rawInput?["specialist"]?.stringValue
                    ?? payload["specialist"]?.stringValue
                    ?? "specialist"
                let objective = rawInput?["task"]?.stringValue
                    ?? rawInput?["objective"]?.stringValue
                    ?? payload["task"]?.stringValue
                    ?? ""
                // Server-resolved color from agent frontmatter — parsed as a hex
                // string ("#RRGGBB" or "RRGGBB") from the tool metadata. Optional;
                // SpecialistPalette falls back to the built-in roster otherwise.
                let colorHex: UInt32? = {
                    let raw = (payload["color"]?.stringValue
                        ?? rawInput?["color"]?.stringValue
                        ?? payload["metadata"]?["color"]?.stringValue) ?? ""
                    let cleaned = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
                    return UInt32(cleaned, radix: 16)
                }()
                let findingPath: String? = (payload["finding_path"]?.stringValue
                    ?? payload["metadata"]?["finding_path"]?.stringValue)
                return ToolCallDetails(
                    kind: .subagent(
                        specialist: specialist,
                        objective: objective,
                        subagentId: toolId,
                        colorHex: colorHex,
                        findingPath: findingPath
                    ),
                    startLine: nil
                )
            }
            // SOUL-SOUL_DESKTOP-101: ACP DiffContent fallback. Gemini-CLI
            // write_file omits rawInput entirely; the diff lives in the
            // top-level content[] as { type:"diff", path, oldText, newText }.
            if case .array(let blocks)? = payload["content"] {
                for block in blocks {
                    guard block["type"]?.stringValue == "diff" else { continue }
                    let oldT = block["oldText"]?.stringValue ?? block["old_string"]?.stringValue
                    let newT = block["newText"]?.stringValue ?? block["new_string"]?.stringValue
                    guard let newT else { continue }
                    if let oldT, !oldT.isEmpty {
                        return ToolCallDetails(kind: .edit(oldString: oldT, newString: newT), startLine: startLine)
                    }
                    if toolCallPreviousLineCount[toolId] == nil,
                       let path = block["path"]?.stringValue {
                        let abs = path.hasPrefix("/") ? path : (project.path as NSString).appendingPathComponent(path)
                        toolCallPreviousLineCount[toolId] = previousLineCount(atPath: abs)
                    }
                    let prev = toolCallPreviousLineCount[toolId]
                    return ToolCallDetails(
                        kind: .write(content: newT),
                        startLine: startLine,
                        previousLineCount: (prev ?? 0) > 0 ? prev : nil
                    )
                }
            }
            if let rawInput {
                let oldS = rawInput["old_string"]?.stringValue ?? rawInput["oldString"]?.stringValue
                let newS = rawInput["new_string"]?.stringValue ?? rawInput["newString"]?.stringValue
                if let oldS, let newS {
                    return ToolCallDetails(kind: .edit(oldString: oldS, newString: newS), startLine: startLine)
                }
                // SOUL-SOUL_DESKTOP-080: Pi's edit shape — `edits: [{oldText, newText}]`
                // wrapped in an array, camelCase keys. Without this branch every Pi
                // edit fell through to nil details → no +/- counts, no diff card.
                // For now we render the first edit; multi-edit grouping is a
                // follow-up (Pi sometimes batches several edits into one tool call).
                if case .array(let edits)? = rawInput["edits"],
                   let first = edits.first {
                    let oldT = first["oldText"]?.stringValue ?? first["old_string"]?.stringValue
                    let newT = first["newText"]?.stringValue ?? first["new_string"]?.stringValue
                    if let oldT, let newT {
                        return ToolCallDetails(kind: .edit(oldString: oldT, newString: newT), startLine: startLine)
                    }
                }
                // Write-body field name varies by provider: Claude uses `content`
                // or `new_str`, Gemini-CLI's write_file uses `file_text`, and some
                // ACP servers use plain `text`. Check all four so the diff card
                // renders the actual file content instead of falling through to
                // the JSON-envelope fallback (SOUL-SOUL_DESKTOP-032).
                let writeBody = rawInput["content"]?.stringValue
                    ?? rawInput["new_str"]?.stringValue
                    ?? rawInput["file_text"]?.stringValue
                    ?? rawInput["text"]?.stringValue
                if let writeBody {
                    // Capture line count of the file on disk the first time we
                    // see this toolCallId, before the agent's write lands. Reads
                    // are cheap (single stat + read) and gated by the cache so
                    // later update events don't see the post-write content.
                    if toolCallPreviousLineCount[toolId] == nil,
                       let path = writeTargetPath(payload: payload, rawInput: rawInput) {
                        toolCallPreviousLineCount[toolId] = previousLineCount(atPath: path)
                    }
                    let prev = toolCallPreviousLineCount[toolId]
                    return ToolCallDetails(
                        kind: .write(content: writeBody),
                        startLine: startLine,
                        previousLineCount: (prev ?? 0) > 0 ? prev : nil
                    )
                }
            }
            // Fallback: capture tool output (stdout/stderr) for non-edit tools.
            // Surfaced when the row is expanded; helps diagnose grep/shell failures.
            if let out = payload["output"]?.stringValue, !out.isEmpty {
                return ToolCallDetails(kind: .output(text: out))
            }
            return nil
        }()

        // SOUL-SOUL_DESKTOP-033 + -079: per-tool-call timeout bookkeeping.
        // Record start AND refresh lastActivityAt on every non-terminal
        // update; the watchdog keys off lastActivityAt.
        let isTerminal = (status == "completed" || status == "failed" || status == "stopped")
        if isTerminal {
            toolCallStartedAt.removeValue(forKey: toolId)
            toolCallLastActivityAt.removeValue(forKey: toolId)
            toolCallTimedOut.remove(toolId)
            toolCallPreviousLineCount.removeValue(forKey: toolId)
        } else if !isReplayingLoad {
            if toolCallStartedAt[toolId] == nil {
                toolCallStartedAt[toolId] = Date()
            }
            toolCallLastActivityAt[toolId] = Date()
        }

        if let existingId = seenToolCallIds[toolId],
           let idx = items.firstIndex(where: { $0.id == existingId }),
           case .toolCall(let id, let oldKind, let oldTitle, _, let oldLoc, let oldDetails) = items[idx] {
            items[idx] = .toolCall(
                id: id,
                kind: oldKind,
                title: title.isEmpty ? oldTitle : title,
                status: status,
                locationHint: location ?? oldLoc,
                details: structuredDetails ?? oldDetails
            )
            return
        }

        // Closing the open agent message AND thought when a tool call arrives
        // keeps subsequent chunks in a fresh bubble below the call. Without
        // closing the thought, a stream of thought → tool → thought re-appends
        // the second batch into the original thinking card *above* the tool
        // rows, since openAgentThoughtId still points at it.
        openAgentMessageId = nil
        openAgentThoughtId = nil

        // First time we're seeing this toolCallId. Use structured details
        // when we have them; otherwise leave details = nil and the row
        // renders without an expand chevron. The previous JSON-envelope
        // fallback (SOUL-SOUL_DESKTOP-032) dumped the wrapper payload —
        // toolCallId, sessionUpdate, locations, etc. — into the diff
        // card's "new content" column, which was actively misleading on
        // any write-tool whose rawInput field name we didn't recognize.
        // The tool_call_update notifications that follow will supply the
        // real rawInput once the agent finishes streaming the call.
        let firstSeenDetails: ToolCallDetails? = structuredDetails

        // SOUL-SOUL_DESKTOP-034: surface known-stuck shell commands (tail -f,
        // watch, interactive top, …) with a warning row above the tool-call
        // card so the user knows to Recover instead of waiting on a turn that
        // will never resolve. Pure detection — the command still runs.
        if kind == "execute", !command.isEmpty,
           let reason = StuckCommandPatterns.reason(forExecuteCommand: command) {
            items.append(.status(id: UUID(), text: "⚠ \(reason)"))
        }

        let uuid = UUID()
        seenToolCallIds[toolId] = uuid
        items.append(.toolCall(
            id: uuid,
            kind: kind,
            title: title.isEmpty ? kind : title,
            status: status,
            locationHint: location,
            details: firstSeenDetails
        ))

        // Per-provider rawInput shape log. One entry per first-seen toolCallId
        // for edit/write tools, recording whether `structuredDetails` landed
        // (== whether the diff card will appear). Tail
        // `~/Library/Logs/Soul-Desktop/tool-schema.jsonl` to see what each
        // provider sends; grow the extractor matrix in `structuredDetails`
        // above when new field names appear.
        if case .object(let obj) = payload {
            ToolSchemaLog.record(
                toolCallId: toolId,
                kind: kind,
                toolName: payload["title"]?.stringValue ?? kind,
                rawInput: rawInput,
                payloadKeys: Array(obj.keys),
                provider: provider,
                sessionId: sessionId,
                extractedDetails: firstSeenDetails != nil
            )
        }
    }

#if DEBUG
    func _testApplyUpdate(_ update: SessionUpdate) {
        apply(update)
    }

    var _testTrackedToolCallCount: Int {
        toolCallStartedAt.count
    }

    func _testSetReplayingLoad(_ value: Bool) {
        isReplayingLoad = value
    }
#endif

    private func updateCommands(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["availableCommands"] ?? payload["commands"] else { return }
        let cmds: [SlashCommand] = raw.compactMap { c in
            guard let name = c["name"]?.stringValue else { return nil }
            let hint = c["input"]?["hint"]?.stringValue
            return SlashCommand(
                name: name,
                description: c["description"]?.stringValue,
                inputHint: hint
            )
        }
        availableCommands = cmds.sorted { $0.name < $1.name }
    }

    private func insertPlan(_ payload: JSONValue) {
        guard case .array(let raw)? = payload["entries"] else { return }
        let entries: [PlanEntry] = raw.map { e in
            PlanEntry(
                content: e["content"]?.stringValue ?? "",
                priority: e["priority"]?.stringValue,
                status: e["status"]?.stringValue
            )
        }
        guard !entries.isEmpty else { return }

        if let idx = items.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
            if case .plan(let id, _) = items[idx] {
                items[idx] = .plan(id: id, entries: entries)
                return
            }
        }
        openAgentMessageId = nil
        items.append(.plan(id: UUID(), entries: entries))
    }

    /// Returns the absolute target path for a Write tool call. Tries the
    /// rawInput `file_path` / `path` field first (most providers), then
    /// `locations[0].path`. Relative paths resolve against the active
    /// project's working dir so disk reads land on the right file.
    private func writeTargetPath(payload: JSONValue, rawInput: JSONValue?) -> String? {
        var raw: String? =
            rawInput?["file_path"]?.stringValue
            ?? rawInput?["path"]?.stringValue
            ?? rawInput?["filePath"]?.stringValue
        if raw == nil, case .array(let locs)? = payload["locations"], let first = locs.first {
            raw = first["path"]?.stringValue
        }
        guard let p = raw, !p.isEmpty else { return nil }
        if p.hasPrefix("/") { return p }
        if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        return (project.path as NSString).appendingPathComponent(p)
    }

    /// Sync line count for a file. Returns 0 if missing — callers treat 0 as
    /// "no previous content," so a fresh write keeps the additions-only chip.
    private func previousLineCount(atPath path: String) -> Int {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        if data.isEmpty { return 0 }
        var n = data.components(separatedBy: "\n").count
        if data.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }

    private func firstLocation(_ payload: JSONValue) -> String? {
        guard case .array(let locs)? = payload["locations"], let first = locs.first else { return nil }
        let path = first["path"]?.stringValue ?? ""
        if let line = first["line"], case .int(let l) = line { return "\(path):\(l)" }
        return path.isEmpty ? nil : path
    }

    func handleACPRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        // By the time this reaches handleACPRequest, ACPClient has already
        // checked its own built-ins (fs/*, session/request_permission).
        // Anything here is an unknown provider request.
        // Respond with an error so the provider doesn't stall, and log it.
        await client?.respondError(id: id, code: -32601, message: "method not implemented: \(method)")

        let text = "■ ACP request ignored: \(method)"
        items.append(.status(id: UUID(), text: text))

        // Log to kernel hooks for -056 auditing
        if let sid = sessionId {
            var hook: [String: Any] = [
                "event": "ACPRequestIgnored",
                "method": method,
                "provider": provider.rawValue
            ]
            if let params {
                hook["params"] = compactJSONString(params)
            }
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: hook)
        }
    }

    private func compactJSONString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }
}
