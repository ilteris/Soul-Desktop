import Foundation
import SoulACP
import SoulCore

/// Codex-provider event/RPC handling lifted out of ThreadController. The
/// methods stay private to the extension so existing call sites in
/// `ThreadController` resolve through normal Swift member lookup —
/// `self.spawnAndInitializeCodex()`, `self.sendCodex(...)`,
/// `self.handleCodex(event)` etc. — without any forwarding shim.
///
/// Pure file shuffle, no behavior change. Refactor 5/N — agent
/// ergonomics: shrink ThreadController.swift below the threshold where
/// a coding agent can hold it in context.
extension ThreadController {

    func spawnAndInitializeCodex() async throws {
        if codexClient != nil { return }
        guard let spawn = ACPProviderSpawn.resolve(.codex) else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex binary not found on PATH"])
        }
        var enriched = spawn
        var codexEnv = enriched.environment ?? [:]
        // SOUL_PROJECT contract — see ACP spawn path above. Same rationale
        // for codex: kernel hooks should write to the desktop-selected
        // project bucket, not a cwd-derived one.
        codexEnv["SOUL_PROJECT"] = project.id
        // SOUL-FINALIZE-PARITY-001: same SOUL_SESSION_ID export as the ACP
        // path so `soul finalize` from a codex bash tool call writes a JSON
        // tagged with the desktop's session id. Codex resume isn't wired yet,
        // so `sessionId` is nil at spawn — the env stays out and the composer
        // expansion below carries the sid at /finalize time.
        if let sid = sessionId {
            codexEnv["SOUL_SESSION_ID"] = sid
        }
        enriched.environment = codexEnv
        enriched.cwd = project.path

        let client = try CodexClient(spawn: enriched)
        self.codexClient = client
        try await client.start()

        let stream = await client.events
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.handleCodex(event)
            }
        }

        _ = try await client.initializeAndAck()

        let threadId = try await client.threadStart(cwd: project.path)
        // Preserve the kernel sessionId when this thread was hydrated from
        // disk (sessionId already set to the original kernel UUID by
        // `hydrateFromDisk`). Without this guard, the freshly-minted codex
        // threadId would clobber the kernel UUID and every subsequent
        // appendHook would write to a new directory, orphaning the
        // ledger the user just opened.
        if sessionId == nil {
            // Same UUID-invariant as the ACP path — see SOUL-196 in
            // ThreadController+Lifecycle.swift. Codex threadIds may not
            // be strict UUIDs; mint our own kernel sid in that case.
            sessionId = Self.looksLikeUUID(threadId) ? threadId : UUID().uuidString.lowercased()
        }
        nativeSessionId = threadId
        hasInitialized = true

        // Record a NativeSessionID hook so future reopens can identify this
        // session as codex via `SoulRegistry.findProvider`. Without it
        // codex sessions have no provider marker in the kernel ledger and
        // AppShell falls back to the active harness on click, mis-routing
        // codex rows when the harness is gemini/claude.
        if let sid = sessionId {
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "NativeSessionID",
                "provider": Provider.codex.rawValue,
                "nativeId": threadId,
                "cwd": project.path,
            ])
        }
    }

    /// Drive a single codex turn: send `text` via turn/start, then await
    /// the turn/completed notification (resumed by `handleCodex`). The
    /// streaming agent/tool events update `items` as they arrive.
    func sendCodex(text: String) async throws {
        // Use `nativeSessionId` (the codex-minted thread id) for the actual
        // RPC. `sessionId` is the kernel UUID and is preserved as the hooks
        // directory key — see `spawnAndInitializeCodex`. Sending the kernel
        // UUID to codex produces "thread not found" because codex never
        // started a thread with that id.
        guard let client = codexClient, let tid = nativeSessionId ?? sessionId else {
            throw NSError(domain: "Soul-Desktop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codex client not initialized"])
        }
        codexItemMap.removeAll(keepingCapacity: true)
        let turnId = try await client.turnStart(threadId: tid, text: text)
        codexActiveTurnId = turnId
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            codexTurnContinuation = cont
        }
        codexActiveTurnId = nil
    }

    /// Translates codex notifications (item/started, item/agentMessage/delta,
    /// item/completed, turn/completed, etc.) into ThreadItem mutations. Kept
    /// intentionally narrow: handles agent text and turn lifecycle today;
    /// tool-call rendering is a follow-up.
    private func handleCodex(_ event: CodexClient.Event) {
        switch event {
        case .request(let id, let method, let params):
            CodexProtocolLog.record(method: method, params: params)
            lastActivityAt = Date()
            Task { [weak self] in
                await self?.handleCodexRequest(id: id, method: method, params: params)
            }
        case .notification(let method, let params):
            // Append-only protocol log so we can see EXACTLY what codex
            // sends on the wire. When extractors fail (empty Thought, bare
            // execute row), tail
            // `~/Library/Logs/Soul-Desktop/codex-protocol.jsonl` and the
            // mismatched shape is right there. No guessing.
            CodexProtocolLog.record(method: method, params: params)
            // Any notification = the agent is alive and emitting. Bump the
            // stall watchdog's clock so it doesn't trip on tool-call /
            // reasoning streams that we don't render yet but still indicate
            // forward motion.
            lastActivityAt = Date()
            switch method {
            case "item/started":
                guard case .object(let p)? = params,
                      case .object(let item)? = p["item"],
                      case .string(let itemType)? = item["type"],
                      case .string(let codexId)? = item["id"]
                else { return }
                appendCodexItem(itemType: itemType, codexId: codexId, item: item, terminal: false)
            case "item/agentMessage/delta":
                guard case .object(let p)? = params,
                      case .string(let itemId)? = p["itemId"],
                      case .string(let delta)? = p["delta"],
                      let uuid = codexItemMap[itemId]
                else { return }
                if let idx = items.firstIndex(where: { $0.id == uuid }),
                   case .agentMessage(let id, let prior, _, let ts) = items[idx] {
                    items[idx] = .agentMessage(id: id, text: prior + delta, complete: false, timestamp: ts)
                }
                lastActivityAt = Date()
            case "item/completed":
                guard case .object(let p)? = params,
                      case .object(let item)? = p["item"],
                      case .string(let itemType)? = item["type"],
                      case .string(let codexId)? = item["id"]
                else { return }
                completeCodexItem(itemType: itemType, codexId: codexId, item: item)
            case "turn/completed":
                guard case .object(let p)? = params,
                      case .object(let turn)? = p["turn"]
                else { return }
                let turnIdMatches: Bool = {
                    if case .string(let tid)? = turn["id"], let active = codexActiveTurnId {
                        return tid == active
                    }
                    return true
                }()
                guard turnIdMatches else { return }
                if let cont = codexTurnContinuation {
                    codexTurnContinuation = nil
                    if case .string(let status)? = turn["status"], status == "failed",
                       case .object(let err)? = turn["error"],
                       case .string(let msg)? = err["message"] {
                        cont.resume(throwing: NSError(domain: "Codex", code: 1,
                                                      userInfo: [NSLocalizedDescriptionKey: msg]))
                    } else {
                        cont.resume(returning: ())
                    }
                }
            case "item/reasoning/textDelta",
                 "item/reasoning/summaryTextDelta",
                 "item/reasoning/summaryPartAdded":
                // Codex's reasoning stream. Append each delta into the open
                // agent-thought bubble so the user sees what the agent is
                // reasoning through. Without this the `item/started` event
                // creates an empty `Thinking…` card and the deltas vanish.
                guard case .object(let p)? = params,
                      case .string(let itemId)? = p["itemId"],
                      let uuid = codexItemMap[itemId]
                else { return }
                // Codex reasoning streams come in three shapes:
                //   - summaryTextDelta / textDelta:  {"delta": "<string>"}
                //   - summaryPartAdded:              {"summaryPart": {"text": "<string>"}}
                //   - any: pick first nested string we find
                let delta: String = {
                    if case .string(let s)? = p["delta"] { return s }
                    if case .string(let s)? = p["text"] { return s }
                    if case .object(let part)? = p["summaryPart"] {
                        if case .string(let s)? = part["text"] { return s }
                    }
                    if case .object(let item)? = p["item"] {
                        if case .string(let s)? = item["text"] { return s }
                        if case .string(let s)? = item["content"] { return s }
                    }
                    return ""
                }()
                guard !delta.isEmpty else { return }
                if let idx = items.firstIndex(where: { $0.id == uuid }),
                   case .agentThought(let id, let prior, _, let ts) = items[idx] {
                    items[idx] = .agentThought(id: id, text: prior + delta, complete: false, timestamp: ts)
                }
            case "item/commandExecution/outputDelta",
                 "item/fileChange/outputDelta",
                 "item/plan/delta":
                // Stream-level deltas for other item types — keep
                // `lastActivityAt` fresh (already done above) and rely on
                // `item/completed` to render the final state. Wiring
                // per-row live streaming for these is a follow-up.
                break
            case "thread/tokenUsage/updated":
                guard case .object(let p)? = params,
                      case .object(let usage)? = p["tokenUsage"]
                else { return }
                if case .object(let last)? = usage["last"],
                   case .int(let total)? = last["totalTokens"] {
                    codexTokensUsed = total
                }
                if case .int(let window)? = usage["modelContextWindow"] {
                    codexContextWindow = window
                }
            default:
                break  // ignore lifecycle / mcp / remoteControl chatter
            }
        case .stderr(let line):
            print("[codex stderr] \(line)")
        case .terminated(let cause):
            items.append(.error(id: UUID(), text: "codex child terminated: \(cause)"))
            if let cont = codexTurnContinuation {
                codexTurnContinuation = nil
                cont.resume(throwing: NSError(domain: "Codex", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: cause]))
            }
        }
    }

    private func handleCodexRequest(id: JSONRPCID, method: String, params: JSONValue?) async {
        guard method == "item/commandExecution/requestApproval" else {
            try? await codexClient?.respond(id: id, result: .null)
            appendCodexRequestHook(
                method: method,
                params: params,
                decision: .string("ignored"),
                handled: false
            )
            items.append(.status(id: UUID(), text: "■ Codex request ignored: \(method)"))
            return
        }

        let result = CodexApprovalPolicy.responseResult(params: params, permissionMode: permissionMode)
        let decision: JSONValue = {
            if case .object(let obj) = result, let value = obj["decision"] { return value }
            return .null
        }()
        if case .object(let obj) = result,
           case .string("decline")? = obj["decision"] {
            try? await codexClient?.respond(id: id, result: result)
            appendCodexRequestHook(
                method: method,
                params: params,
                decision: decision,
                handled: true
            )
            items.append(.status(id: UUID(), text: "■ Codex command approval cancelled"))
            return
        }

        try? await codexClient?.respond(id: id, result: result)
        appendCodexRequestHook(
            method: method,
            params: params,
            decision: decision,
            handled: true
        )
        items.append(.status(id: UUID(), text: "✓ Codex command approval handled"))
    }

    private func appendCodexRequestHook(
        method: String,
        params: JSONValue?,
        decision: JSONValue,
        handled: Bool
    ) {
        guard let sid = sessionId else { return }
        let command = codexRequestCommand(from: params)
        let decisionText = compactJSONString(decision)
        let intent: String = {
            if !handled { return "Codex request ignored: \(method)" }
            if decisionText.contains("decline") || decisionText.contains("cancel") {
                return command.isEmpty
                    ? "Codex command approval cancelled"
                    : "Codex command approval cancelled: \(command)"
            }
            return command.isEmpty
                ? "Codex command approval handled"
                : "Codex command approval handled: \(command)"
        }()
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "CodexApproval",
            "op": handled ? "APPROVAL" : "REQUEST",
            "intent": intent,
            "provider": Provider.codex.rawValue,
            "method": method,
            "decision": decisionText,
            "command": command,
            "permission_mode": permissionMode.rawValue,
        ])
    }

    /// Phase 3: translate a codex `item/started` payload into a ThreadItem.
    /// Each branch handles one codex item type, choosing the closest
    /// existing ThreadItem shape so the canvas reads consistently across
    /// providers. Codex emits richer item types than ACP, so a few of them
    /// fall through to a `status` row (a one-liner with an emoji prefix)
    /// rather than a full toolCall card.
    private func appendCodexItem(itemType: String, codexId: String, item: [String: JSONValue], terminal: Bool) {
        let uuid = UUID()
        codexItemMap[codexId] = uuid
        let now = Date()
        switch itemType {
        case "agentMessage":
            let text = stringField(item, "text") ?? ""
            items.append(.agentMessage(id: uuid, text: text, complete: terminal, timestamp: now))
            openAgentMessageId = uuid
        case "commandExecution":
            // Build the title from command + argv so the row shows the FULL
            // command line, not just the bare executable. Codex sometimes
            // sends `command: "soul"` + `argv: ["soul", "task", "list"]`;
            // showing just `command` truncated rows to "execute soul" which
            // is useless for understanding what the agent ran.
            let cmd = codexCommandTitle(from: item) ?? "(command)"
            let cwd = stringField(item, "cwd")
            let status = stringField(item, "status") ?? "pending"
            items.append(.toolCall(
                id: uuid,
                kind: "execute",
                title: cmd,
                status: status,
                locationHint: cwd,
                details: nil
            ))
        case "fileChange":
            let details = codexFileChangeDetails(from: item)
            let title = codexFileChangeTitle(from: item)
            let status = stringField(item, "status") ?? "pending"
            let kindLabel: String = {
                if case .write = details?.kind { return "write" }
                return "edit"
            }()
            items.append(.toolCall(
                id: uuid,
                kind: kindLabel,
                title: title,
                status: status,
                locationHint: nil,
                details: details
            ))
        case "mcpToolCall":
            let server = stringField(item, "server") ?? "mcp"
            let tool = stringField(item, "tool") ?? "?"
            let status = stringField(item, "status") ?? "pending"
            items.append(.toolCall(
                id: uuid,
                kind: "mcp:\(server)",
                title: tool,
                status: status,
                locationHint: nil,
                details: nil
            ))
        case "webSearch":
            let query = stringField(item, "query") ?? ""
            items.append(.toolCall(
                id: uuid,
                kind: "search",
                title: query.isEmpty ? "(web search)" : query,
                status: "in_progress",
                locationHint: nil,
                details: nil
            ))
        case "imageView":
            let path = stringField(item, "path") ?? "(image)"
            items.append(.toolCall(
                id: uuid,
                kind: "view-image",
                title: (path as NSString).lastPathComponent,
                status: "completed",
                locationHint: path,
                details: nil
            ))
        case "reasoning":
            // Render reasoning as a proper agentThought bubble (muted
            // italic + collapsible). Pre-fill from any text on the
            // started event — `text`/`summary`/`content` as strings, or
            // a `summary` array of summary-part objects (the canonical
            // codex shape). Deltas streamed via
            // `item/reasoning/textDelta` etc. append to this bubble.
            let initial: String = {
                if let s = stringField(item, "text"), !s.isEmpty { return s }
                if let s = stringField(item, "summary"), !s.isEmpty { return s }
                if let s = stringField(item, "content"), !s.isEmpty { return s }
                if case .array(let parts)? = item["summary"] {
                    return parts.compactMap { p -> String? in
                        guard case .object(let o) = p,
                              case .string(let t)? = o["text"] else { return nil }
                        return t
                    }.joined(separator: "\n\n")
                }
                return ""
            }()
            // Only materialize the bubble when there's actually text on the
            // started event. Otherwise leave bubble creation to the first
            // non-empty delta (appendAgentThoughtChunk lazy-creates and
            // registers under openAgentThoughtId). Codex frequently emits
            // reasoning items that stay encrypted server-side and never
            // ship visible text — creating a bubble preemptively just to
            // delete it (or worse, leave a "reasoning hidden" placeholder)
            // is the wrong default.
            if !initial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.append(.agentThought(id: uuid, text: initial, complete: false, timestamp: now))
                openAgentThoughtId = uuid
            } else {
                // Drop the mapping so item/completed doesn't try to fill a
                // bubble that was never created.
                codexItemMap.removeValue(forKey: codexId)
            }
        case "plan":
            let entries = codexPlanEntries(from: item)
            if entries.isEmpty {
                let text = stringField(item, "text") ?? ""
                items.append(.status(id: uuid, text: "📋 plan: \(text.prefix(120))"))
            } else {
                items.append(.plan(id: uuid, entries: entries))
            }
        case "enteredReviewMode":
            let review = stringField(item, "review") ?? "review"
            items.append(.status(id: uuid, text: "🔍 entered review: \(review)"))
        case "exitedReviewMode":
            items.append(.status(id: uuid, text: "✓ exited review"))
        case "contextCompaction":
            items.append(.status(id: uuid, text: "⤵ context compacted"))
        default:
            // Unknown codex item types used to render as `· <itemType>`
            // status rows, leaking implementation names like `· userMessage`
            // into the canvas. Specifically skip `userMessage` (the user's
            // prompt is already rendered by `send()` — we don't need codex
            // echoing it back as a status), and silently swallow every other
            // unknown type. New first-class types can be added to the switch
            // when we want them visible.
            if itemType == "userMessage" { return }
            // Other unknowns: capture in the codexItemMap for completion
            // tracking but don't render. If we discover one matters we can
            // promote it to a real case.
            return
        }
        lastActivityAt = now
    }

    /// Build a readable command line from a codex `commandExecution` item.
    /// Codex sends this under various keys depending on protocol version;
    /// we try each known shape and fall back to the bare executable.
    ///
    /// Tail `~/Library/Logs/Soul-Desktop/codex-protocol.jsonl` to see what
    /// actually arrives in your session — if a new key shape appears,
    /// add it to this matrix.
    private func codexCommandTitle(from item: [String: JSONValue]) -> String? {
        // 1. A `command` string that already looks like a full line wins.
        if let cmd = stringField(item, "command")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cmd.isEmpty,
           cmd.contains(" ") {
            return cmd
        }
        // 2. Try every known array-of-args key. Codex has shipped at least
        //    `argv`, `args`, `arguments`, `commandArgs` in different builds.
        for key in ["argv", "args", "arguments", "commandArgs"] {
            if case .array(let arr)? = item[key] {
                let parts = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s }
                    return nil
                }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
        }
        // 3. A `command` array (some codex versions send the bare executable
        //    in `command` AND the args as siblings; others bundle both into
        //    `command` as an array).
        if case .array(let arr)? = item["command"] {
            let parts = arr.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        // 4. Some payloads expose the full pre-formatted line.
        for key in ["commandLine", "fullCommand", "aggregatedCommand", "displayCommand"] {
            if let s = stringField(item, key), !s.isEmpty { return s }
        }
        // 5. Bare `command` string (single executable). Last resort.
        return stringField(item, "command")
    }

    /// Finalize the row that `appendCodexItem` opened for `codexId`. Updates
    /// status (terminal completed/failed/etc.) and fills in any fields that
    /// were only known at end-of-call (e.g. agent message final text, file
    /// change diff, command output).
    private func completeCodexItem(itemType: String, codexId: String, item: [String: JSONValue]) {
        guard let uuid = codexItemMap[codexId],
              let idx = items.firstIndex(where: { $0.id == uuid })
        else { return }
        switch items[idx] {
        case .agentMessage(let id, let prior, _, let ts):
            let final = stringField(item, "text") ?? prior
            items[idx] = .agentMessage(id: id, text: final, complete: true, timestamp: ts)
        case .toolCall(let id, let kind, let title, _, let loc, let priorDetails):
            let status = stringField(item, "status") ?? "completed"
            // For fileChange items the final diff arrives at completion —
            // rebuild details from the finalized payload so the diff card
            // renders something useful.
            let details: ToolCallDetails?
            if itemType == "fileChange" {
                details = codexFileChangeDetails(from: item) ?? priorDetails
            } else {
                details = priorDetails
            }
            let finalTitle: String
            if itemType == "fileChange" {
                finalTitle = codexFileChangeTitle(from: item)
            } else if itemType == "commandExecution" {
                // Use the full argv-joined title at completion too. The
                // bare `command` field often contains just the executable
                // name (`soul`), which would clobber the started-event's
                // richer title (`soul task list`).
                finalTitle = codexCommandTitle(from: item) ?? title
            } else {
                finalTitle = title
            }
            items[idx] = .toolCall(
                id: id,
                kind: kind,
                title: finalTitle,
                status: status,
                locationHint: loc,
                details: details
            )
            appendCodexToolHook(
                itemType: itemType,
                item: item,
                kind: kind,
                title: finalTitle,
                status: status,
                locationHint: loc,
                details: details
            )
        case .plan(let id, _):
            let entries = codexPlanEntries(from: item)
            if !entries.isEmpty { items[idx] = .plan(id: id, entries: entries) }
        case .agentThought(let id, let prior, _, let ts):
            // Codex's reasoning completion comes in a few shapes — flat
            // `text`/`summary`/`content`, or a `summary` array of
            // summary-part objects (`{"text": "...", "type": "..."}`).
            // We try each. If the model didn't produce a human-readable
            // summary (codex sends `summary: []` and stashes the actual
            // chain in `encrypted_content` which we can't decode), the
            // final text stays empty — in which case REMOVE the bubble
            // entirely rather than leaving a hollow "Thought" card on
            // the canvas. This is the root cause of the empty cards: the
            // bubble was created at `item/started` time, then nothing
            // visible ever arrived to fill it.
            let final: String = {
                if let flat = stringField(item, "text"), !flat.isEmpty { return flat }
                if let flat = stringField(item, "summary"), !flat.isEmpty { return flat }
                if let flat = stringField(item, "content"), !flat.isEmpty { return flat }
                if case .array(let parts)? = item["summary"] {
                    let joined = parts.compactMap { part -> String? in
                        guard case .object(let o) = part,
                              case .string(let s)? = o["text"] else { return nil }
                        return s
                    }.joined(separator: "\n\n")
                    if !joined.isEmpty { return joined }
                }
                if case .array(let parts)? = item["content"] {
                    let joined = parts.compactMap { part -> String? in
                        guard case .object(let o) = part,
                              case .string(let s)? = o["text"] else { return nil }
                        return s
                    }.joined(separator: "\n\n")
                    if !joined.isEmpty { return joined }
                }
                return ""
            }()
            // NEVER remove the bubble on completion. If streaming put text
            // into `prior`, we keep it — even if the completion payload's
            // `summary` is an empty array (codex routinely sends `summary:
            // []` while stashing the real chain in `encrypted_content`).
            // The old "drop hollow bubble" path was nuking bubbles that had
            // already rendered text to the user — visible as a flicker.
            let chosen = final.count > prior.count ? final : prior
            let trimmed = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = trimmed.isEmpty ? "_(reasoning hidden by codex)_" : chosen
            items[idx] = .agentThought(id: id, text: finalText, complete: true, timestamp: ts)
            openAgentThoughtId = nil
        default:
            break  // status / error rows finalize themselves on append
        }
    }

    private func appendCodexToolHook(
        itemType: String,
        item: [String: JSONValue],
        kind: String,
        title: String,
        status: String,
        locationHint: String?,
        details: ToolCallDetails?
    ) {
        guard let sid = sessionId else { return }
        let tool: String
        let target: String
        switch itemType {
        case "commandExecution":
            tool = "Bash"
            target = codexCommandTitle(from: item) ?? title
        case "fileChange":
            if case .write = details?.kind {
                tool = "Write"
            } else {
                tool = "Edit"
            }
            target = codexFileChangePath(from: item) ?? title
        case "mcpToolCall":
            tool = "MCP"
            let server = stringField(item, "server") ?? "mcp"
            let call = stringField(item, "tool") ?? title
            target = "\(server).\(call)"
        case "webSearch":
            tool = "WebSearch"
            target = stringField(item, "query") ?? title
        case "imageView":
            tool = "Read"
            target = stringField(item, "path") ?? locationHint ?? title
        default:
            tool = kind
            target = title
        }
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
            "event": "AfterTool",
            "tool": tool,
            "target": target,
            "rationale": title,
            "provider": Provider.codex.rawValue,
            "codex_item_type": itemType,
            "status": status,
            "cwd": locationHint ?? project.path,
        ])
    }

    /// Pull `field` out of a codex item object when it's a string.
    private func stringField(_ obj: [String: JSONValue], _ field: String) -> String? {
        if case .string(let s)? = obj[field] { return s }
        return nil
    }

    /// Build a ToolCallDetails from codex's fileChange shape. Codex packs
    /// changes into `changes: [{path, kind, diff}]`; we render the first
    /// entry so the diff card has something concrete. `kind` is `"add"` /
    /// `"modify"` / `"delete"` — we collapse to write (add) or edit (modify).
    private func codexFileChangeDetails(from item: [String: JSONValue]) -> ToolCallDetails? {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first
        else { return nil }
        let kind = stringField(change, "kind") ?? "modify"
        let diff = stringField(change, "diff") ?? ""
        if kind == "add" {
            return ToolCallDetails(kind: .write(content: diff))
        }
        // For modify/delete we expose the raw diff in newString and leave
        // oldString empty — the side-by-side diff card still renders
        // something the user can scan; a richer hunk parser is a follow-up.
        return ToolCallDetails(kind: .edit(oldString: "", newString: diff))
    }

    /// Title for a fileChange row — first path's basename, falls back to a
    /// generic label if `changes` is empty.
    private func codexFileChangeTitle(from item: [String: JSONValue]) -> String {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first,
              let path = stringField(change, "path")
        else { return "(file change)" }
        return (path as NSString).lastPathComponent
    }

    private func codexFileChangePath(from item: [String: JSONValue]) -> String? {
        guard case .array(let changes)? = item["changes"],
              let first = changes.first,
              case .object(let change) = first
        else { return nil }
        return stringField(change, "path")
    }

    private func codexRequestCommand(from params: JSONValue?) -> String {
        guard case .object(let obj)? = params else { return "" }
        if let command = codexCommandTitle(from: obj) { return command }
        if case .object(let item)? = obj["item"],
           let command = codexCommandTitle(from: item) {
            return command
        }
        return ""
    }

    private func compactJSONString(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return text
    }

    /// Parse codex's plan into our PlanEntry shape. Codex plan items are
    /// proposed-action text; without a structured shape we wrap each line.
    private func codexPlanEntries(from item: [String: JSONValue]) -> [PlanEntry] {
        let text = stringField(item, "text") ?? ""
        return text
            .split(separator: "\n")
            .map { line in
                PlanEntry(
                    content: String(line).trimmingCharacters(in: .whitespaces),
                    priority: nil,
                    status: nil
                )
            }
            .filter { !$0.content.isEmpty }
    }

}
