import Foundation

public struct DelegationContentSanitizerContext: Equatable, Hashable, Sendable {
    public var specialist: String
    public var delegationId: String
    public var findingPath: String?

    public init(specialist: String, delegationId: String, findingPath: String? = nil) {
        self.specialist = specialist
        self.delegationId = delegationId
        self.findingPath = findingPath
    }

    var tokens: [String] {
        var out = [
            specialist,
            "@\(specialist)",
            delegationId
        ]
        if let findingPath, !findingPath.isEmpty {
            out.append(findingPath)
            out.append((findingPath as NSString).lastPathComponent)
        }
        return out.filter { !$0.isEmpty }
    }
}

/// Gemini/Soul delegation already has structured DelegationStarted /
/// DelegationCompleted records that render as SubagentCard. Some Gemini
/// streams also roll progress narration into assistant prose; prefer the card
/// and retain only the final human-facing summary when one is present.
public enum DelegationContentSanitizer {
    public static func sanitizeAgentText(
        _ raw: String,
        contexts: [DelegationContentSanitizerContext]
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !contexts.isEmpty else { return trimmed }
        guard mentionsDelegation(trimmed, contexts: contexts) else { return trimmed }

        if let suffix = delegationSummarySuffix(in: trimmed, contexts: contexts) {
            return suffix
        }

        if containsDelegationStatusMarker(trimmed, contexts: contexts) {
            let filtered = trimmed
                .components(separatedBy: .newlines)
                .filter { !isDelegationProgressLine($0, contexts: contexts) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return filtered == trimmed ? "" : filtered
        }

        return trimmed
    }

    private static func mentionsDelegation(
        _ text: String,
        contexts: [DelegationContentSanitizerContext]
    ) -> Bool {
        let lower = text.lowercased()
        if lower.contains("subagent") || lower.contains("delegate") || lower.contains("delegation") {
            return true
        }
        return contexts.contains { context in
            context.tokens.contains { token in
                lower.contains(token.lowercased())
            }
        }
    }

    private static func delegationSummarySuffix(
        in text: String,
        contexts: [DelegationContentSanitizerContext]
    ) -> String? {
        var starts: [String.Index] = []
        for context in contexts {
            let specialist = context.specialist
            let patterns = [
                "Our `@\(specialist)` subagent",
                "Our @\(specialist) subagent",
                "The `@\(specialist)` subagent",
                "The @\(specialist) subagent",
                "`@\(specialist)` subagent has completed",
                "@\(specialist) subagent has completed"
            ]
            for pattern in patterns {
                if let range = text.range(of: pattern, options: [.caseInsensitive]) {
                    starts.append(range.lowerBound)
                }
            }
        }
        if text.localizedCaseInsensitiveContains("subagent"),
           let heading = text.range(of: "\n# ") {
            starts.append(text.index(after: heading.lowerBound))
        }
        guard let start = starts.min(), start > text.startIndex else { return nil }
        let prefix = text[..<start].lowercased()
        guard prefix.contains("subagent") || prefix.contains("delegate") || prefix.contains("delegation") else {
            return nil
        }
        return text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsDelegationStatusMarker(
        _ text: String,
        contexts: [DelegationContentSanitizerContext]
    ) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "routing gemini native delegation",
            "soul delegate still running",
            "delegate still running",
            "started @",
            "delegationstarted",
            "delegationcompleted",
            "delegated subagent outputs",
            "subagent delegation report"
        ]
        if markers.contains(where: { lower.contains($0) }) {
            return true
        }
        guard lower.contains("running tool:") || lower.contains("completed tool:") else {
            return false
        }
        return mentionsDelegation(text, contexts: contexts)
    }

    private static func isDelegationProgressLine(
        _ line: String,
        contexts: [DelegationContentSanitizerContext]
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if containsDelegationStatusMarker(trimmed, contexts: contexts) { return true }
        let startsWithProgressVerb = [
            "i will invoke",
            "i will search",
            "i will read",
            "i will inspect",
            "i will list"
        ].contains { lower.hasPrefix($0) }
        guard startsWithProgressVerb else { return false }
        if lower.contains("subagent") || lower.contains("delegation") || lower.contains("session registry") {
            return true
        }
        return contexts.contains { context in
            context.tokens.contains { token in
                lower.contains(token.lowercased())
            }
        }
    }
}
