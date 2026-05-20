import Foundation

enum ThreadItemGrouper {
    static func group(_ items: [ThreadItem]) -> [ThreadItem] {
        var result: [ThreadItem] = []
        var fileGroupMap: [String: Int] = [:]
        var kindGroupMap: [String: Int] = [:]
        var turnHasFileChanges = false

        for item in items {
            guard case .toolCall(let id, let kind, let title, _, let loc, _) = item else {
                result.append(item)
                if case .userMessage = item {
                    fileGroupMap.removeAll()
                    kindGroupMap.removeAll()
                    turnHasFileChanges = false
                } else if case .branchSummary = item {
                    fileGroupMap.removeAll()
                    kindGroupMap.removeAll()
                    turnHasFileChanges = false
                }
                continue
            }

            let isFileChange = kind == "edit" || kind == "write"
            let isVerification = kind == "read" || kind == "execute" || kind == "search"
            let fileKey = loc ?? title

            if isFileChange {
                turnHasFileChanges = true
                append(item, id: id, kind: kind, title: title, locationHint: loc, key: fileKey, map: &fileGroupMap, result: &result)
            } else if isVerification && turnHasFileChanges {
                continue
            } else {
                append(item, id: id, kind: kind, title: title, locationHint: loc, key: kind, map: &kindGroupMap, result: &result)
            }
        }

        return result.map { entry in
            if case .toolCallGroup(_, _, _, _, let inner) = entry, inner.count == 1 {
                return inner[0]
            }
            return entry
        }
    }

    private static func append(
        _ item: ThreadItem,
        id: UUID,
        kind: String,
        title: String,
        locationHint: String?,
        key: String,
        map: inout [String: Int],
        result: inout [ThreadItem]
    ) {
        if let idx = map[key] {
            if case .toolCallGroup(let gId, let gKind, let gTitle, let gLoc, var gItems) = result[idx] {
                gItems.append(item)
                result[idx] = .toolCallGroup(id: gId, kind: gKind, title: gTitle, locationHint: gLoc, items: gItems)
            }
        } else {
            map[key] = result.count
            result.append(.toolCallGroup(id: id, kind: kind, title: title, locationHint: locationHint, items: [item]))
        }
    }
}
