import Foundation

public func readClaudeTranscriptTurns(sessionId: String, cwd: String) -> LedgerTranscriptReadResult? {
    let encoded = encodeClaudeCwd(cwd)
    let path = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sessionId).jsonl"
    guard FileManager.default.fileExists(atPath: path) else { return nil }

    var turns: [LedgerTranscriptTurn] = []
    var pendingAgentText: (text: String, ts: Date)? = nil

    let stats = enumerateJSONLines(atPath: path) { data in
        guard let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = rec["type"] as? String
        let ts = parseLedgerTimestamp(rec["timestamp"] as? String) ?? Date.distantPast

        switch type {
        case "user":
            flushAgentText(&turns, pending: &pendingAgentText)
            let msg = rec["message"] as? [String: Any]
            let contentRaw: String = {
                if let string = msg?["content"] as? String { return string }
                if let blocks = msg?["content"] as? [[String: Any]] {
                    return blocks.compactMap { $0["text"] as? String }.joined()
                }
                return ""
            }()
            if !contentRaw.isEmpty {
                turns.append(LedgerTranscriptTurn(content: .message(role: .user, text: contentRaw, timestamp: ts)))
            }

        case "assistant":
            let msg = rec["message"] as? [String: Any]
            guard let blocks = msg?["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    let text = block["text"] as? String ?? ""
                    guard !text.isEmpty else { continue }
                    if pendingAgentText == nil {
                        pendingAgentText = (text, ts)
                    } else {
                        pendingAgentText?.text += text
                    }
                case "tool_use":
                    flushAgentText(&turns, pending: &pendingAgentText)
                    let name = block["name"] as? String ?? "tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    turns.append(LedgerTranscriptTurn(
                        content: .tool(LedgerToolRecord(name: name, arguments: input.mapValues(LedgerJSONValue.init(any:))), timestamp: ts)
                    ))
                default:
                    continue
                }
            }

        default:
            return
        }
    }

    flushAgentText(&turns, pending: &pendingAgentText)
    return turns.isEmpty ? nil : LedgerTranscriptReadResult(turns: turns, stats: stats)
}

public func readGeminiTranscriptTurns(sessionId: String, projectKey: String) -> LedgerTranscriptReadResult? {
    guard let url = locateGeminiTranscript(sessionId: sessionId, projectKey: projectKey) else { return nil }

    var turns: [LedgerTranscriptTurn] = []
    let stats = enumerateJSONLines(atPath: url.path) { data in
        guard let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = rec["type"] as? String else { return }
        let ts = parseLedgerTimestamp(rec["timestamp"] as? String) ?? Date.distantPast

        switch type {
        case "user":
            let blocks = rec["content"] as? [[String: Any]] ?? []
            let raw = blocks
                .compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = stripLedgerGeminiReferencedFileBlock(raw)
            if !text.isEmpty {
                turns.append(LedgerTranscriptTurn(content: .message(role: .user, text: text, timestamp: ts)))
            }

        case "gemini":
            if let content = rec["content"] as? String {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    turns.append(LedgerTranscriptTurn(content: .message(role: .assistant, text: trimmed, timestamp: ts)))
                }
            }
            if let toolCalls = rec["toolCalls"] as? [[String: Any]] {
                for call in toolCalls {
                    let name = call["name"] as? String ?? "tool"
                    let args = call["args"] as? [String: Any] ?? [:]
                    turns.append(LedgerTranscriptTurn(
                        content: .tool(LedgerToolRecord(name: name, arguments: args.mapValues(LedgerJSONValue.init(any:))), timestamp: ts)
                    ))
                }
            }

        default:
            return
        }
    }

    if stats.warnedCount > 0 || stats.skippedCount > 0 {
        let mb = Double(stats.largestLineBytes) / 1_048_576.0
        let mbStr = String(format: "%.1f", mb)
        let parts: [String] = [
            stats.skippedCount > 0
                ? "\(stats.skippedCount) line\(stats.skippedCount == 1 ? "" : "s") skipped (too large to parse)"
                : nil,
            stats.warnedCount > 0
                ? "\(stats.warnedCount) line\(stats.warnedCount == 1 ? "" : "s") over 5MB"
                : nil,
            "largest \(mbStr) MB",
        ].compactMap { $0 }
        let text = "⚠ chat file bloat — " + parts.joined(separator: ", ")
        turns.insert(LedgerTranscriptTurn(content: .status(text: text)), at: 0)
    }

    return turns.isEmpty ? nil : LedgerTranscriptReadResult(turns: turns, stats: stats)
}

public func readPiTranscriptTurns(sessionId: String, cwd: String) -> LedgerTranscriptReadResult? {
    guard let path = locatePiTranscript(sessionId: sessionId, cwd: cwd) else { return nil }

    var turns: [LedgerTranscriptTurn] = []
    var pendingAgentText: (text: String, ts: Date)? = nil
    let stats = enumerateJSONLines(atPath: path) { data in
        guard let rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (rec["type"] as? String) == "message",
              let msg = rec["message"] as? [String: Any],
              let roleRaw = msg["role"] as? String,
              let blocks = msg["content"] as? [[String: Any]]
        else { return }

        let ts = parseLedgerTimestamp(rec["timestamp"] as? String) ?? Date.distantPast
        let role: LedgerTranscriptRole = roleRaw == "user" ? .user : .assistant

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                if role == .user {
                    flushAgentText(&turns, pending: &pendingAgentText)
                    turns.append(LedgerTranscriptTurn(content: .message(role: .user, text: text, timestamp: ts)))
                } else {
                    if pendingAgentText == nil {
                        pendingAgentText = (text, ts)
                    } else {
                        pendingAgentText?.text += text
                    }
                }
            case "toolCall":
                flushAgentText(&turns, pending: &pendingAgentText)
                let name = block["name"] as? String ?? "tool"
                let args = block["arguments"] as? [String: Any] ?? [:]
                turns.append(LedgerTranscriptTurn(
                    content: .tool(LedgerToolRecord(name: name, arguments: args.mapValues(LedgerJSONValue.init(any:))), timestamp: ts)
                ))
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                if !text.isEmpty {
                    flushAgentText(&turns, pending: &pendingAgentText)
                    turns.append(LedgerTranscriptTurn(content: .thought(text: text, timestamp: ts)))
                }
            default:
                continue
            }
        }
    }

    flushAgentText(&turns, pending: &pendingAgentText)
    return turns.isEmpty ? nil : LedgerTranscriptReadResult(turns: turns, stats: stats)
}

public func stripLedgerGeminiReferencedFileBlock(_ value: String) -> String {
    let marker = "--- Content from referenced files ---"
    guard let range = value.range(of: marker) else { return value }
    var cut = range.lowerBound
    while cut > value.startIndex {
        let previous = value.index(before: cut)
        let character = value[previous]
        if character == "\n" || character == " " || character == "\t" {
            cut = previous
        } else {
            break
        }
    }
    return String(value[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func flushAgentText(
    _ turns: inout [LedgerTranscriptTurn],
    pending: inout (text: String, ts: Date)?
) {
    guard let value = pending else { return }
    turns.append(LedgerTranscriptTurn(content: .message(role: .assistant, text: value.text, timestamp: value.ts)))
    pending = nil
}

private func encodeClaudeCwd(_ cwd: String) -> String {
    let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
    return trimmed.replacingOccurrences(of: "/", with: "-")
}

private func locateGeminiTranscript(sessionId sid: String, projectKey: String) -> URL? {
    let geminiBase = (("~/.gemini/tmp" as NSString)).expandingTildeInPath
    let fileManager = FileManager.default
    guard let topEntries = try? fileManager.contentsOfDirectory(atPath: geminiBase) else { return nil }
    let lowerKey = projectKey.lowercased()
    let candidateDirs = topEntries.filter {
        let lower = $0.lowercased()
        return lower == lowerKey || lower.hasPrefix("\(lowerKey)-")
    }

    func isChatFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasSuffix(".jsonl") || name.hasSuffix(".json") { return true }
        if name.contains(".jsonl.bak-") || name.contains(".jsonl.corrupt-") { return true }
        return false
    }

    var allCandidates: [URL] = []
    for dir in candidateDirs {
        let dirURL = URL(fileURLWithPath: "\(geminiBase)/\(dir)/chats")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { continue }
        allCandidates.append(contentsOf: entries.filter(isChatFile))
    }

    let shortId = String(sid.prefix(8))
    let prefixMatches = allCandidates.filter { $0.lastPathComponent.contains(shortId) }
    let largestByPrefix = prefixMatches.max(by: { first, second in
        let firstSize = (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let secondSize = (try? second.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return firstSize < secondSize
    })
    if let hit = largestByPrefix, firstLineSessionId(at: hit) == sid {
        return hit
    }
    return allCandidates.first(where: { firstLineSessionId(at: $0) == sid })
}

private func firstLineSessionId(at url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let head = handle.readData(ofLength: 512)
    guard let string = String(data: head, encoding: .utf8),
          let newline = string.range(of: "\n") else { return nil }
    let firstLine = String(string[..<newline.lowerBound])
    guard let data = firstLine.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["sessionId"] as? String
}

private func locatePiTranscript(sessionId sid: String, cwd: String) -> String? {
    let encoded = piEncode(cwd: cwd)
    guard !encoded.isEmpty else { return nil }
    let dir = "\(NSHomeDirectory())/.pi/agent/sessions/\(encoded)"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    for name in entries where name.hasSuffix("_\(sid).jsonl") {
        return "\(dir)/\(name)"
    }
    return nil
}

private func piEncode(cwd: String) -> String {
    let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
    guard !parts.isEmpty else { return "" }
    return "--" + parts.joined(separator: "-") + "--"
}
