import Foundation

/// Trajectory signal emitted by agents at the end of substantive turns —
/// `<soul_trace>{"intent": "...", "next_step": "...", "rationale": "..."}</soul_trace>`.
/// The kernel parses this to score predictive alignment; the desktop renders
/// it as a small chip below the assistant bubble.
struct SoulTrace: Hashable {
    let intent: String
    let nextStep: String
    let rationale: String

    /// Pull a `<soul_trace>` block out of an agent reply. Returns the visible
    /// text (block stripped) plus the parsed trace when present and well-formed.
    /// Malformed JSON inside a valid block yields `(visible: stripped, trace: nil)`
    /// so the chip silently degrades to no-chip rather than crashing the row.
    static func extract(from raw: String) -> (visible: String, trace: SoulTrace?) {
        guard let range = raw.range(of: #"<soul_trace>([\s\S]*?)</soul_trace>"#, options: .regularExpression) else {
            return (raw, nil)
        }
        let block = String(raw[range])
        let inner = block
            .replacingOccurrences(of: "<soul_trace>", with: "")
            .replacingOccurrences(of: "</soul_trace>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parsed: SoulTrace? = {
            guard let data = inner.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return SoulTrace(
                intent:    obj["intent"]    as? String ?? "",
                nextStep:  obj["next_step"] as? String ?? "",
                rationale: obj["rationale"] as? String ?? ""
            )
        }()

        var stripped = raw
        stripped.replaceSubrange(range, with: "")
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), parsed)
    }
}
