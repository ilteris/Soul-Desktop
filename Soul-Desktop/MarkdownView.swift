import SwiftUI

struct MarkdownView: View {
    let text: String
    var codeFont: Font = SoulType.code
    var bodyFont: Font = SoulType.body
    var headerColor: Color = SoulColor.fg
    var bodyColor: Color = SoulColor.fg
    var codeColor: Color = SoulColor.fg
    var codeBackground: Color = SoulColor.surface

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    private var blocks: [Block] { parse(text) }

    @ViewBuilder
    private func render(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let line):
            VStack(alignment: .leading, spacing: 4) {
                inline(line)
                    .font(headingFont(level))
                    .foregroundStyle(headerColor)
                if level == 1 {
                    Rectangle()
                        .fill(SoulColor.border.opacity(0.6))
                        .frame(height: 1)
                        .padding(.top, 2)
                }
            }
            .padding(.top, level == 1 ? 14 : level == 2 ? 10 : 6)
            .padding(.bottom, level == 1 ? 2 : 0)
        case .paragraph(let line):
            if let code = MarkdownView.bareInlineCode(line) {
                CopyableInlineCodeRow(code: code, font: codeFont)
            } else {
                inline(line)
                    .font(bodyFont)
                    .foregroundStyle(bodyColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bullet(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(bodyFont)
                            .foregroundStyle(SoulColor.fgSubtle)
                        if let code = MarkdownView.bareInlineCode(item) {
                            CopyableInlineCodeRow(code: code, font: codeFont)
                        } else {
                            inline(item)
                                .font(bodyFont)
                                .foregroundStyle(bodyColor)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .codeBlock(let code, let lang):
            CodeBlockView(code: code, lang: lang, font: codeFont, fg: codeColor, bg: codeBackground)
        case .table(let header, let rows):
            TableView(header: header, rows: rows, headerFont: bodyFont, bodyFont: bodyFont)
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    private func inline(_ s: String) -> Text { MarkdownView.inline(s) }

    /// Public so children (TableView cells, anyone else rendering markdown
    /// chunks) can produce the same bold/italic/code styling that paragraph
    /// rows get. Without this, `**bold**` and `` `code` `` leak through as
    /// raw asterisks/backticks in table cells.
    static func inline(_ s: String) -> Text {
        guard var attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return Text(s)
        }
        // Walk inlinePresentationIntent runs and apply the right PostScript
        // face explicitly. `.weight(.bold)` on `.custom()` Nerd Font is a
        // no-op — bold falls back to system-bold and breaks visual unity.
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            let isBold = intent.contains(.stronglyEmphasized)
            let isCode = intent.contains(.code)
            let isItalic = intent.contains(.emphasized)
            if isCode {
                attr[run.range].font = SoulType.code
            } else if isBold && isItalic {
                attr[run.range].font = SoulType.bodyBoldItalic
            } else if isBold {
                attr[run.range].font = SoulType.bodyBold
            } else if isItalic {
                attr[run.range].font = SoulType.bodyItalic
            }
        }
        return Text(attr)
    }

    /// If `s` (after trimming) is exactly one inline-code span — i.e.
    /// `` `something` `` with no other prose — return the unwrapped content.
    /// Used by paragraph and bullet rendering to swap a styled-Text for a
    /// click-to-copy row, so one-liners like an `open …` command can be
    /// copied with a single click instead of triple-clicking + cmd-C.
    static func bareInlineCode(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("`"), trimmed.hasSuffix("`"), trimmed.count >= 2 else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        // Reject if the inner content itself contains a backtick — that means
        // multiple spans or escaped tick, which our copy semantics would
        // mangle. Better to fall through to the styled-text path.
        guard !inner.contains("`") else { return nil }
        let cleaned = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return SoulType.h1
        case 2: return SoulType.h2
        case 3: return SoulType.h3
        default: return SoulType.h4
        }
    }
}

private struct TableView: View {
    let header: [String]
    let rows: [[String]]
    let headerFont: Font
    let bodyFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(cells: header, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Rectangle()
                    .fill(SoulColor.border.opacity(0.4))
                    .frame(height: 0.5)
                row(cells: cells, isHeader: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func row(cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                // Run cell text through the same markdown pass as paragraphs
                // so **bold** and `code` render styled instead of literal.
                MarkdownView.inline(cell)
                    .font(isHeader ? headerFont.weight(.semibold) : bodyFont)
                    .foregroundStyle(SoulColor.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                if idx < cells.count - 1 {
                    Rectangle()
                        .fill(SoulColor.border.opacity(0.4))
                        .frame(width: 0.5)
                }
            }
        }
        .background(isHeader ? SoulColor.surface.opacity(0.7) : Color.clear)
    }
}

private struct CodeBlockView: View {
    let code: String
    let lang: String?
    let font: Font
    let fg: Color
    let bg: Color
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(lang ?? "text")
                    .font(SoulFont.code(10, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .regular))
                        Text(copied ? "copied" : "copy")
                            .font(SoulFont.code(10))
                    }
                    .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.surface.opacity(0.7))
            .overlay(alignment: .bottom) {
                Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
            }

            Text(code)
                .font(font)
                .foregroundStyle(fg)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1)
        )
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

/// One-line click-to-copy chip for paragraphs/bullets whose entire content is
/// a single inline-code span. Less chrome than `CodeBlockView` (no header bar,
/// no language tag), more affordance than a styled `Text` (cursor changes,
/// hover reveals "copy", click writes the unwrapped content to the pasteboard).
private struct CopyableInlineCodeRow: View {
    let code: String
    let font: Font
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Disable text-selection on the label itself: an I-beam cursor
            // and the row's "click anywhere to copy" intent fight each
            // other. We let `onTapGesture` own the click; selection can
            // happen via cmd-A in the chat or by dragging across multiple
            // rows (still works at the canvas level).
            Text(code)
                .font(font)
                .foregroundStyle(SoulColor.fg)
            if hovering || copied {
                HStack(spacing: 3) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .regular))
                    if copied {
                        Text("copied")
                            .font(.system(size: 10, weight: .regular))
                    }
                }
                .foregroundStyle(copied ? SoulColor.accent : SoulColor.fgMuted)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SoulColor.border.opacity(hovering ? 0.6 : 0.3), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: copy)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { hovering = h }
            // Pointing-hand cursor so the row reads as a clickable button,
            // not a text input. AppKit's cursor stack needs push/pop —
            // SwiftUI's `.pointerStyle(.link)` is macOS 15-only.
            if h {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click to copy")
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeIn(duration: 0.15)) { copied = false }
        }
    }
}

private enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case codeBlock(text: String, lang: String?)
    case table(header: [String], rows: [[String]])
    case blank
}

private func parse(_ markdown: String) -> [Block] {
    var blocks: [Block] = []
    let lines = markdown.components(separatedBy: "\n")

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            let lang = String(trimmed.dropFirst(3))
            var code: [String] = []
            i += 1
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                code.append(l)
                i += 1
            }
            blocks.append(.codeBlock(text: code.joined(separator: "\n"), lang: lang.isEmpty ? nil : lang))
            i += 1
            continue
        }

        if let level = headingLevel(trimmed) {
            let stripped = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(level: level, text: stripped))
            i += 1
            continue
        }

        if isTableHeader(trimmed),
           i + 1 < lines.count,
           isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
            let header = parseTableRow(trimmed)
            i += 2
            var rows: [[String]] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard isTableHeader(t) else { break }
                rows.append(parseTableRow(t))
                i += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            var items: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") || t.hasPrefix("* ") {
                    items.append(String(t.dropFirst(2)))
                    i += 1
                } else { break }
            }
            blocks.append(.bullet(items))
            continue
        }

        if trimmed.isEmpty {
            blocks.append(.blank)
            i += 1
            continue
        }

        blocks.append(.paragraph(line))
        i += 1
    }
    return blocks
}

private func isTableHeader(_ line: String) -> Bool {
    line.contains("|") && line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 3
}

private func isTableSeparator(_ line: String) -> Bool {
    guard isTableHeader(line) else { return false }
    let cells = parseTableRow(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
        let s = cell.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" }
    }
}

private func parseTableRow(_ line: String) -> [String] {
    var trimmed = line
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    return trimmed
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func headingLevel(_ line: String) -> Int? {
    var count = 0
    for ch in line {
        if ch == "#" { count += 1 } else { break }
    }
    guard count >= 1, count <= 6 else { return nil }
    let after = line.dropFirst(count)
    return after.first == " " ? count : nil
}
