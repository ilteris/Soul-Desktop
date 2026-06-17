import Foundation

public enum UnifiedDiffParser {
    public static func details(from diff: String, changeKind: String) -> ToolCallDetails? {
        let startLine = firstHunkStartLine(in: diff)
        if changeKind == "add" {
            let content = addedContent(in: diff)
            return ToolCallDetails(kind: .write(content: content.isEmpty ? diff : content), startLine: startLine)
        }

        let lines = changedLines(in: diff)
        if !lines.isEmpty {
            return ToolCallDetails(kind: .patch(lines: lines), startLine: startLine)
        }

        guard !diff.isEmpty else { return nil }
        return ToolCallDetails(kind: .edit(oldString: "", newString: diff), startLine: startLine)
    }

    public static func firstHunkStartLine(in diff: String) -> Int? {
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("@@") else { continue }
            guard let range = parseHunkRange(line) else { continue }
            return range.newStart
        }
        return nil
    }

    public static func changedLines(in diff: String) -> [ToolCallDetails.DiffLine] {
        var rows: [ToolCallDetails.DiffLine] = []
        walkHunks(in: diff) { line, oldLine, newLine in
            if line.hasPrefix("-"), !line.hasPrefix("---") {
                rows.append(ToolCallDetails.DiffLine(
                    kind: .removed,
                    oldLine: oldLine,
                    newLine: nil,
                    text: String(line.dropFirst())
                ))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                rows.append(ToolCallDetails.DiffLine(
                    kind: .added,
                    oldLine: nil,
                    newLine: newLine,
                    text: String(line.dropFirst())
                ))
            }
        }
        return rows
    }

    private static func addedContent(in diff: String) -> String {
        var lines: [String] = []
        walkHunks(in: diff) { line, _, _ in
            guard line.hasPrefix("+"), !line.hasPrefix("+++") else { return }
            lines.append(String(line.dropFirst()))
        }
        return lines.joined(separator: "\n")
    }

    private static func walkHunks(
        in diff: String,
        visit: (_ line: String, _ oldLine: Int?, _ newLine: Int?) -> Void
    ) {
        var currentOld: Int?
        var currentNew: Int?

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                if let range = parseHunkRange(rawLine) {
                    currentOld = range.oldStart
                    currentNew = range.newStart
                } else {
                    currentOld = nil
                    currentNew = nil
                }
                continue
            }

            guard let oldLine = currentOld, let newLine = currentNew else { continue }
            if line.hasPrefix("\\") { continue }

            if line.hasPrefix("-"), !line.hasPrefix("---") {
                visit(line, oldLine, nil)
                currentOld = oldLine + 1
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                visit(line, nil, newLine)
                currentNew = newLine + 1
            } else {
                visit(line, oldLine, newLine)
                currentOld = oldLine + 1
                currentNew = newLine + 1
            }
        }
    }

    private static func parseHunkRange(_ line: Substring) -> (oldStart: Int, newStart: Int)? {
        guard let oldMarker = line.firstIndex(of: "-"),
              let newMarker = line.firstIndex(of: "+")
        else { return nil }

        let oldDigits = line[line.index(after: oldMarker)...].prefix { $0.isNumber }
        let newDigits = line[line.index(after: newMarker)...].prefix { $0.isNumber }
        guard let oldStart = Int(oldDigits), let newStart = Int(newDigits) else { return nil }
        return (oldStart, newStart)
    }
}
