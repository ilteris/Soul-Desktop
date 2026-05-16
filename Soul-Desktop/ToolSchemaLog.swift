import Foundation

/// One-entry-per-toolCallId log of the schema each provider's ACP tool-call
/// payload uses. Built to answer "why does this edit row show a diff and that
/// one doesn't?" — the answer is always whether `rawInput` contained one of
/// the field names Soul-Desktop's structured extractor recognizes
/// (`old_string`/`new_string` for edits; `content`/`new_str`/`file_text`/
/// `text` for writes). When an edit/write arrives whose keys we don't yet
/// recognize, this log captures the shape so we can grow the extractor's
/// matrix in `insertToolCall`.
///
/// Output: `~/Library/Logs/Soul-Desktop/tool-schema.jsonl`. One JSONL line
/// per first-seen `toolCallId`, deduped in-process so streaming
/// `tool_call_update` notifications don't spam.
enum ToolSchemaLog {
    private static let queue = DispatchQueue(label: "soul.tool-schema-log")
    nonisolated(unsafe) private static var seen: Set<String> = []
    private static let seenLock = NSLock()

    /// Record a tool-call's schema iff we haven't seen this `toolCallId` yet.
    /// Captures: the canonical Soul-Desktop tool `kind`, the agent-side tool
    /// `name`, every top-level key from `rawInput` plus a few one-line value
    /// previews (truncated to 80 chars, no full content — keeps the log
    /// readable when you `cat` it). Resolution-relevant: also captures
    /// whether `structuredDetails` would land non-nil.
    static func record(
        toolCallId: String,
        kind: String,
        toolName: String,
        rawInput: JSONValue?,
        payloadKeys: [String],
        provider: Provider,
        sessionId: String?,
        extractedDetails: Bool
    ) {
        guard kind == "edit" || kind == "write" else { return }

        seenLock.lock()
        let isNew = seen.insert(toolCallId).inserted
        seenLock.unlock()
        guard isNew else { return }

        var rawInputShape: [String: JSONValue] = [:]
        if case .object(let obj)? = rawInput {
            for (k, v) in obj {
                rawInputShape[k] = .string(Self.previewValue(v))
            }
        } else if let rawInput {
            // SOUL-SOUL_DESKTOP-080: previously this logged a bare
            // "non-object" string with no further detail, which masked the
            // fact that Pi's rawInput IS an object (just under different
            // keys than the extractor expected). Dump the actual JSONValue
            // case + a short preview so the trace is honest about shape.
            rawInputShape["__rawInput_type__"] = .string(Self.previewValue(rawInput))
        } else {
            rawInputShape["__rawInput__"] = .string("nil")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry: JSONValue = .object([
            "timestamp": .string(timestamp),
            "provider": .string(provider.label),
            "sessionId": .string(sessionId ?? "unknown"),
            "toolCallId": .string(toolCallId),
            "kind": .string(kind),
            "toolName": .string(toolName),
            "extractedDetails": .bool(extractedDetails),
            "payloadKeys": .array(payloadKeys.sorted().map { .string($0) }),
            "rawInputShape": .object(rawInputShape),
        ])

        queue.async {
            guard let url = logURL(),
                  let data = try? JSONEncoder().encode(entry) else { return }
            var line = data
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// One-line summary of a JSON value: type tag + first 80 chars of the
    /// string representation. Keeps the log human-readable without dumping
    /// full file contents (a single Write's `content` field can be MBs).
    private static func previewValue(_ v: JSONValue) -> String {
        switch v {
        case .string(let s):
            let preview = s.count > 80 ? String(s.prefix(80)) + "…" : s
            return "string(\(s.count)): \(preview.replacingOccurrences(of: "\n", with: "\\n"))"
        case .int(let n):    return "int: \(n)"
        case .double(let d): return "double: \(d)"
        case .bool(let b):   return "bool: \(b)"
        case .array(let a):  return "array[\(a.count)]"
        case .object(let o): return "object{\(o.keys.sorted().joined(separator: ","))}"
        case .null:          return "null"
        }
    }

    private static func logURL() -> URL? {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = library.appendingPathComponent("Logs/Soul-Desktop", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tool-schema.jsonl")
    }
}
