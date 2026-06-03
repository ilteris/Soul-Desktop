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
                return removeCompletedSegment(at: index)
            }
            guard let finalText, !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return CompletedSegment(id: id, kind: kind, text: finalText, timestamp: Date())
        }
    }

    func drainAll() -> [CompletedSegment] {
        queue.sync {
            let completed = segments.compactMap(completedSegment)
            segments.removeAll(keepingCapacity: true)
            codexIdsByItemId.removeAll(keepingCapacity: true)
            codexKindsByItemId.removeAll(keepingCapacity: true)
            return completed
        }
    }

    func clear() {
        queue.sync {
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

    private func completedSegment(_ segment: Segment) -> CompletedSegment? {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CompletedSegment(
            id: segment.id,
            kind: segment.kind,
            text: segment.text,
            timestamp: segment.timestamp
        )
    }
}
