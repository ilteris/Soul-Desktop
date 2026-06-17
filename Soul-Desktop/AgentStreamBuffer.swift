import Foundation

final class AgentStreamBuffer {
    enum SegmentKind {
        case message
        case thought
    }

    struct CompletedSegment {
        let id: UUID
        let kind: SegmentKind
        let text: String
        let timestamp: Date
    }

    private struct Segment {
        let id: UUID
        let kind: SegmentKind
        var text: String
        let timestamp: Date
    }

    private let queue = DispatchQueue(label: "soul.desktop.agent-stream-buffer", qos: .userInitiated)
    private var completedPreviewText = ""
    private var segments: [Segment] = []
    private var codexIdsByItemId: [String: UUID] = [:]
    private var codexKindsByItemId: [String: SegmentKind] = [:]

    @discardableResult
    func appendACPMessage(_ text: String) -> UUID {
        append(text, kind: .message, itemId: nil)
    }

    @discardableResult
    func appendACPThought(_ text: String, normalize: (String, String) -> String) -> UUID {
        queue.sync {
            if let index = segments.indices.last, segments[index].kind == .thought {
                let existing = segments[index].text
                segments[index].text = normalize(existing, text)
                return segments[index].id
            }
            let id = UUID()
            segments.append(Segment(id: id, kind: .thought, text: text, timestamp: Date()))
            return id
        }
    }

    func registerCodexItem(itemId: String, id: UUID, kind: SegmentKind, initialText: String) {
        queue.sync {
            codexIdsByItemId[itemId] = id
            codexKindsByItemId[itemId] = kind
            if !initialText.isEmpty {
                segments.append(Segment(id: id, kind: kind, text: initialText, timestamp: Date()))
            }
        }
    }

    func appendCodex(itemId: String, text: String, kind: SegmentKind) {
        append(text, kind: kind, itemId: itemId)
    }

    func drainCodexItem(itemId: String, finalText: String?) -> CompletedSegment? {
        queue.sync {
            guard let id = codexIdsByItemId.removeValue(forKey: itemId) else { return nil }
            let kind = codexKindsByItemId.removeValue(forKey: itemId) ?? .message
            if let index = segments.firstIndex(where: { $0.id == id }) {
                if let finalText, finalText.count > segments[index].text.count {
                    segments[index].text = finalText
                }
                let completed = removeCompletedSegment(at: index)
                appendCompletedPreview(completed)
                return completed
            }
            guard let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let completed = CompletedSegment(id: id, kind: kind, text: finalText, timestamp: Date())
            appendCompletedPreview(completed)
            return completed
        }
    }

    func drainAll(sanitizeMessage: ((String) -> String)? = nil) -> [CompletedSegment] {
        queue.sync {
            let completed = segments.compactMap { completedSegment($0, sanitizeMessage: sanitizeMessage) }
            completed.forEach(appendCompletedPreview)
            segments.removeAll(keepingCapacity: true)
            codexIdsByItemId.removeAll(keepingCapacity: true)
            codexKindsByItemId.removeAll(keepingCapacity: true)
            return completed
        }
    }

    func preview(sanitizeMessage: ((String) -> String)? = nil) -> String? {
        queue.sync {
            let liveTexts = segments.compactMap { segment -> String? in
                let text: String
                if segment.kind == .message, let sanitizeMessage {
                    text = sanitizeMessage(segment.text)
                } else {
                    text = segment.text
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : text
            }
            let text = ([completedPreviewText] + liveTexts)
                .joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text
        }
    }

    func clear() {
        queue.sync {
            completedPreviewText = ""
            segments.removeAll(keepingCapacity: true)
            codexIdsByItemId.removeAll(keepingCapacity: true)
            codexKindsByItemId.removeAll(keepingCapacity: true)
        }
    }

    @discardableResult
    private func append(_ text: String, kind: SegmentKind, itemId: String?) -> UUID {
        queue.sync {
            let id: UUID
            if let itemId {
                id = codexIdsByItemId[itemId] ?? UUID()
                codexIdsByItemId[itemId] = id
                codexKindsByItemId[itemId] = kind
            } else if let last = segments.last, last.kind == kind {
                id = last.id
            } else {
                id = UUID()
            }

            if let index = segments.firstIndex(where: { $0.id == id }) {
                segments[index].text += text
            } else {
                segments.append(Segment(id: id, kind: kind, text: text, timestamp: Date()))
            }
            return id
        }
    }

    private func removeCompletedSegment(at index: Int) -> CompletedSegment? {
        let segment = segments.remove(at: index)
        return completedSegment(segment)
    }

    private func appendCompletedPreview(_ completed: CompletedSegment?) {
        guard let text = completed?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }
        if !completedPreviewText.isEmpty {
            completedPreviewText += "\n\n"
        }
        completedPreviewText += text
    }

    private func completedSegment(_ segment: Segment, sanitizeMessage: ((String) -> String)? = nil) -> CompletedSegment? {
        let text: String
        if segment.kind == .message, let sanitizeMessage {
            text = sanitizeMessage(segment.text)
        } else {
            text = segment.text
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CompletedSegment(
            id: segment.id,
            kind: segment.kind,
            text: text,
            timestamp: segment.timestamp
        )
    }
}
