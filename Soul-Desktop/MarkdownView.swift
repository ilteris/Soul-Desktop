import SwiftUI

struct MarkdownView: View {
    let text: String
    var codeFont: Font = .custom(SoulFont.family, size: 12)
    var bodyFont: Font = .custom(SoulFont.family, size: 13)
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
            inline(line)
                .font(bodyFont)
                .foregroundStyle(bodyColor)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(bodyFont)
                            .foregroundStyle(SoulColor.fgSubtle)
                        inline(item)
                            .font(bodyFont)
                            .foregroundStyle(bodyColor)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
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

    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attr)
        }
        return Text(s)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .custom(SoulFont.family, size: 24).weight(.semibold)
        case 2: return .custom(SoulFont.family, size: 19).weight(.semibold)
        case 3: return .custom(SoulFont.family, size: 16).weight(.semibold)
        default: return .custom(SoulFont.family, size: 14).weight(.semibold)
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
                Text(cell)
                    .font(isHeader ? headerFont.weight(.semibold) : bodyFont)
                    .foregroundStyle(isHeader ? SoulColor.fg : SoulColor.fg)
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
                    .font(SoulFont.code(10, weight: .medium))
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
