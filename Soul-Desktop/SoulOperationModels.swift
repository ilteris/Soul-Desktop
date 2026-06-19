import SwiftUI

struct SoulOperation: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case pulse
        case verify
        case delegate
        case task
        case finalize
        case compact
        case appServerDoctor

        var icon: String {
            switch self {
            case .pulse: return "waveform.path.ecg"
            case .verify: return "checkmark.shield"
            case .delegate: return "person.2.wave.2"
            case .task: return "checklist"
            case .finalize: return "seal"
            case .compact: return "rectangle.compress.vertical"
            case .appServerDoctor: return "stethoscope"
            }
        }
    }

    enum Status: Hashable {
        case running
        case succeeded
        case failed
        case cancelled

        var label: String {
            switch self {
            case .running: return "running"
            case .succeeded: return "done"
            case .failed: return "failed"
            case .cancelled: return "stopped"
            }
        }

        var tint: Color {
            switch self {
            case .running: return SoulColor.accent
            case .succeeded: return .green
            case .failed: return .red
            case .cancelled: return SoulColor.fgMuted
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var project: String?
    var provider: Provider?
    var status: Status
    var startedAt: Date
    var lastUpdatedAt: Date
    var processID: Int32?
    var endedAt: Date?
    var durableRunID: String?
    var durableStepID: String?
    var durableStepOwnedByDesktop: Bool
    var summary: String
    var logs: String
}

struct SoulOperationEvent: Identifiable, Hashable {
    enum Kind: Hashable {
        case command
        case subagent
        case toolStart
        case toolEnd
        case output
        case error
        case raw
    }

    let id: String
    var kind: Kind
    var title: String
    var detail: String
    var badge: String?

    var icon: String {
        switch kind {
        case .command: return "terminal"
        case .subagent: return "person.2.wave.2"
        case .toolStart: return "wrench.and.screwdriver"
        case .toolEnd: return "checkmark.circle"
        case .output: return "text.alignleft"
        case .error: return "exclamationmark.triangle"
        case .raw: return "curlybraces"
        }
    }

    var tint: Color {
        switch kind {
        case .command: return SoulColor.fgMuted
        case .subagent: return SoulColor.accent
        case .toolStart: return SoulColor.accent
        case .toolEnd: return .green
        case .output: return SoulColor.fgMuted
        case .error: return .red
        case .raw: return SoulColor.fgSubtle
        }
    }

    static func parse(_ logs: String) -> [SoulOperationEvent] {
        logs
            .split(whereSeparator: \.isNewline)
            .enumerated()
            .compactMap { index, rawLine in
                parseLine(String(rawLine), index: index)
            }
    }

    private static func parseLine(_ rawLine: String, index: Int) -> SoulOperationEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("$ ") {
            return SoulOperationEvent(
                id: "command-\(index)",
                kind: .command,
                title: "Command",
                detail: line,
                badge: nil
            )
        }

        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return SoulOperationEvent(
                id: "output-\(index)",
                kind: line.lowercased().contains("error") ? .error : .output,
                title: line.lowercased().contains("error") ? "Error" : "Output",
                detail: line,
                badge: nil
            )
        }

        let event = object["event"] as? String ?? "event"
        switch event {
        case "subagent_started":
            let specialist = object["specialist"] as? String ?? "subagent"
            let provider = object["provider"] as? String
            let task = object["task"] as? String ?? ""
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .subagent,
                title: "Started @\(specialist)",
                detail: firstLine(task),
                badge: provider
            )
        case "tool_call_start":
            let name = object["name"] as? String ?? "tool"
            let args = readableArgs(object["args"])
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .toolStart,
                title: toolTitle(name),
                detail: args,
                badge: "start"
            )
        case "tool_call_end":
            let name = object["name"] as? String ?? "tool"
            let status = object["status"] as? String ?? "done"
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .toolEnd,
                title: toolTitle(name),
                detail: status,
                badge: status
            )
        case "subagent_timeout":
            let reason = object["reason"] as? String ?? "No provider stream output before timeout."
            let status = object["status"] as? String ?? "failed"
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .error,
                title: "Subagent Timeout",
                detail: reason,
                badge: status
            )
        case "subagent_failed":
            let detail = object["error"] as? String ?? object["reason"] as? String ?? readablePayload(object)
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .error,
                title: "Subagent Failed",
                detail: detail,
                badge: "failed"
            )
        case "subagent_completed":
            let summary = object["summary"] as? String ?? readablePayload(object)
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: .subagent,
                title: "Subagent Completed",
                detail: firstLine(summary),
                badge: "done"
            )
        default:
            return SoulOperationEvent(
                id: "event-\(index)",
                kind: event.lowercased().contains("error") ? .error : .raw,
                title: event.replacingOccurrences(of: "_", with: " ").capitalized,
                detail: readablePayload(object),
                badge: nil
            )
        }
    }

    private static func firstLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? text
    }

    private static func toolTitle(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func readableArgs(_ value: Any?) -> String {
        if let string = value as? String {
            if
                let data = string.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return readablePayload(object)
            }
            return string
        }
        if let value {
            return "\(value)"
        }
        return ""
    }

    private static func readablePayload(_ object: [String: Any]) -> String {
        let preferredKeys = ["description", "command", "file_path", "displayName", "delegation_id", "live_log", "status"]
        let parts = preferredKeys.compactMap { key -> String? in
            guard let value = object[key] else { return nil }
            return "\(key): \(value)"
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }
}

struct SoulTimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case run
        case operation
        case task
        case session
    }

    let id = UUID()
    var kind: Kind
    var icon: String
    var tint: Color
    var title: String
    var detail: String
    var timestamp: Date?
    var badge: String
    var operationID: UUID?
    var taskID: String?
    var runID: String?
}

struct SoulTaskRecord: Identifiable, Hashable, Sendable {
    var id: String
    var project: String
    var subject: String
    var status: String
    var priority: String
    var updatedAt: String?
    var doneCriteria: [String]
    var completedCriteriaCount: Int

    static func fileURL(project: String, id: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("soul_registry")
            .appendingPathComponent("tasks")
            .appendingPathComponent(project)
            .appendingPathComponent("\(id).json")
    }

    var operatorSummary: String {
        guard !doneCriteria.isEmpty else { return "No acceptance criteria recorded." }
        let remaining = max(doneCriteria.count - completedCriteriaCount, 0)
        if remaining == 0 { return "All \(doneCriteria.count) criteria are marked complete." }
        let nextIndex = min(max(completedCriteriaCount, 0), doneCriteria.count - 1)
        return "\(remaining) criteria left. Next check: \(doneCriteria[nextIndex])"
    }
}

struct SoulAssistantMessage: Identifiable, Hashable {
    let id = UUID()
    var isUser: Bool
    var text: String
}
