import SwiftUI

private enum DiffRow {
    case unchanged(leftNum: Int, rightNum: Int, text: String)
    case removed(num: Int, text: String)
    case added(num: Int, text: String)
}

struct DiffView: View {
    let details: ToolCallDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch details.kind {
            case .edit(let oldString, let newString):
                diffRows(old: oldString, new: newString, startLine: details.startLine ?? 1)
            case .write(let content):
                // Pure addition: every line is `.added`. Same renderer; the
                // left column shows blank for each row.
                diffRows(old: "", new: content, startLine: details.startLine ?? 1)
            case .output(let text):
                Text(text)
                    .font(SoulFont.code(12))
                    .foregroundStyle(SoulColor.fg)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .subagent:
                // Subagent calls render via SubagentCard at the ThreadItemRow
                // level — they don't reach DiffView. Defensive empty case to
                // keep the switch exhaustive.
                EmptyView()
            }
        }
        .padding(.vertical, details.kind.isOutput ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Single text-selection scope for the whole diff card. Without this
        // each per-line Text would become its own NSTextView; with N lines
        // that's N selection participants in every drag-tick layout pass —
        // the bug that pegged the main thread to 100% during selection. One
        // scope at this level lets AppKit treat the diff as a single
        // selectable block.
        .textSelection(.enabled)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(SoulColor.border, lineWidth: 1)
        )
    }

    /// Compute aligned diff rows via Swift's `CollectionDifference` so
    /// unchanged lines render once across both columns (no tint) instead of
    /// once per column (full red + full green wash). Drops the wholesale-
    /// rewrite case from 600+ noisy rows to ~the actual change count.
    @ViewBuilder
    private func diffRows(old: String, new: String, startLine: Int) -> some View {
        let rows = Self.computeRows(old: old, new: new, startLine: startLine)
        let gutter = Self.gutterWidth(for: rows)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                diffRowView(row, gutterWidth: gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// SOUL-SOUL_DESKTOP-169: unified inline diff layout. The old two-column
    /// side-by-side split removed/added pairs across the row, which wasted
    /// horizontal space and made cmd-F scanning awkward. New layout mirrors
    /// `git diff --unified` / GitHub's inline view: two narrow gutters
    /// (old | new line nums), then one full-width text body with a 2pt
    /// colored left bar on changed rows.
    @ViewBuilder
    private func diffRowView(_ row: DiffRow, gutterWidth: CGFloat) -> some View {
        switch row {
        case .unchanged(let lNum, let rNum, let text):
            inlineRow(oldNum: lNum, newNum: rNum, sign: " ", text: text, tint: nil, gutterWidth: gutterWidth)
        case .removed(let num, let text):
            inlineRow(oldNum: num, newNum: nil, sign: "-", text: text, tint: .red, gutterWidth: gutterWidth)
        case .added(let num, let text):
            inlineRow(oldNum: nil, newNum: num, sign: "+", text: text, tint: .green, gutterWidth: gutterWidth)
        }
    }

    /// Inline row: `oldNum | newNum | ±  text`. `tint == nil` means unchanged
    /// (no left bar, no background); tinted rows get a 2pt colored left bar
    /// + a very faint background wash — enough signal at scroll-skim
    /// distance, light enough that hundred-line diffs don't read as a stripe
    /// pattern.
    private func inlineRow(oldNum: Int?, newNum: Int?, sign: String, text: String,
                           tint: Color?, gutterWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(oldNum.map(String.init) ?? "")
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fgSubtle.opacity(0.6))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text(newNum.map(String.init) ?? "")
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fgSubtle.opacity(0.6))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Text(sign)
                .font(SoulFont.code(12, weight: .bold))
                .foregroundStyle((tint ?? SoulColor.fgSubtle).opacity(0.85))
                .frame(width: 10, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .font(SoulFont.code(12))
                .foregroundStyle(SoulColor.fg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .background(tint?.opacity(0.06) ?? Color.clear)
        .overlay(alignment: .leading) {
            if let tint {
                Rectangle()
                    .fill(tint.opacity(0.65))
                    .frame(width: 2)
            }
        }
    }

    /// Walk `oldLines` and `newLines` in tandem using the diff's
    /// removed/added offset sets as an oracle. Unchanged lines emit a single
    /// aligned row; removed and added lines emit one-sided rows.
    private static func computeRows(old: String, new: String, startLine: Int) -> [DiffRow] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)
        // CollectionDifference.removals/insertions are arrays of `Change`
        // enum cases — pattern-match to extract the offset.
        var removedOffsets: Set<Int> = []
        for change in diff.removals {
            if case let .remove(offset, _, _) = change { removedOffsets.insert(offset) }
        }
        var addedOffsets: Set<Int> = []
        for change in diff.insertions {
            if case let .insert(offset, _, _) = change { addedOffsets.insert(offset) }
        }

        var rows: [DiffRow] = []
        var i = 0  // oldLines cursor
        var j = 0  // newLines cursor
        let lBase = startLine
        let rBase = startLine

        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedOffsets.contains(i) {
                rows.append(.removed(num: lBase + i, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, addedOffsets.contains(j) {
                rows.append(.added(num: rBase + j, text: newLines[j]))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                // Both cursors on common (unchanged) content.
                rows.append(.unchanged(leftNum: lBase + i, rightNum: rBase + j, text: oldLines[i]))
                i += 1
                j += 1
            } else if i < oldLines.count {
                // Defensive: trailing old past the diff's known removals.
                rows.append(.removed(num: lBase + i, text: oldLines[i]))
                i += 1
            } else {
                rows.append(.added(num: rBase + j, text: newLines[j]))
                j += 1
            }
        }
        return rows
    }

    /// Gutter wide enough for the largest line number that appears in any
    /// row. Each char ~7pt in 12pt monospace, plus 4pt of breathing room.
    private static func gutterWidth(for rows: [DiffRow]) -> CGFloat {
        var maxNum = 1
        for row in rows {
            switch row {
            case .unchanged(let l, let r, _): maxNum = max(maxNum, l, r)
            case .removed(let n, _): maxNum = max(maxNum, n)
            case .added(let n, _): maxNum = max(maxNum, n)
            }
        }
        let chars = max(3, String(maxNum).count)
        return CGFloat(chars) * 7 + 4
    }
}
