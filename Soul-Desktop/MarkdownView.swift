import SwiftUI

struct MarkdownView: View {
    let text: String
    var codeFont: Font = SoulType.code
    var bodyFont: Font = SoulType.body
    var headerColor: Color = SoulColor.fg
    var bodyColor: Color = SoulColor.fg
    var codeColor: Color = SoulColor.fg
    var codeBackground: Color = SoulColor.surface
    /// When true, lay out blocks in a LazyVStack so only visible paragraphs
    /// run AttributedString markdown parsing + path linkification. Use for
    /// large documents inside a ScrollView (FilePreviewPanel); leave false
    /// for small inline bubbles where eager layout is cheaper than the
    /// LazyVStack bookkeeping.
    var lazy: Bool = false

    @Environment(\.openFilePreview) private var openFilePreview

    var body: some View {
        // SOUL-SOUL_DESKTOP-099: scroll-perf telemetry. MarkdownView is
        // suspected to dominate AgentMessageRow's body cost during scroll.
        // Per-body event so we can quantify materialization rate.
        let _ = SoulSignposts.event("MarkdownView.body")
        return Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        render(block)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        render(block)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // Custom scheme that preserves the raw token (absolute or
            // relative). AppShell's handler resolves relative paths against
            // the active project.
            if url.scheme == "soulpath" {
                let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let p = comps?.queryItems?.first(where: { $0.name == "p" })?.value {
                    openFilePreview(p)
                    return .handled
                }
            }
            if url.isFileURL {
                openFilePreview(url.path)
                return .handled
            }
            // SOUL-SOUL_DESKTOP-066: when Apple's markdown parser sees
            // `[label](path.swift:1234)` it builds a URL where the colon
            // promotes `path.swift` to a scheme. The result fails every
            // check above and falls through to .systemAction, which macOS
            // routes to "no handler" — that's the "file not found" black
            // hole users hit on every line-numbered link. Anything that
            // isn't an actual web protocol gets routed back through the
            // preview resolver with the raw token intact.
            let webSchemes: Set<String> = ["http", "https", "ftp", "ftps", "mailto", "tel", "sms", "ssh", "x-apple-helpkit"]
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme.isEmpty || !webSchemes.contains(scheme) {
                let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
                openFilePreview(raw)
                return .handled
            }
            return .systemAction
        })
    }

    /// Memoized parse result. SwiftUI re-evaluates body on every animation
    /// frame (panel slides, scroll restoration, parent state thrash), and
    /// re-tokenizing 70KB of CLAUDE.md per frame across every visible bubble
    /// was the load-bearing cause of choppy panel-open animations.
    private var blocks: [Block] {
        if let hit = MarkdownView.parseCache[text] { return hit }
        let result = parse(text)
        if MarkdownView.parseCache.count > 256 {
            MarkdownView.parseCache.removeAll(keepingCapacity: true)
        }
        MarkdownView.parseCache[text] = result
        return result
    }

    /// Process-wide cache keyed by raw markdown. Bounded; reset wholesale at
    /// the cap so we never grow unbounded across long sessions.
    nonisolated(unsafe) private static var parseCache: [String: [Block]] = [:]

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
                    .modifier(LinkHoverCursor(active: MarkdownView.hasAnyLink(line)))
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
                                .modifier(LinkHoverCursor(active: MarkdownView.hasAnyLink(item)))
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
        linkifyPaths(&attr)
        stripLinkUnderlines(&attr)
        return Text(attr)
    }

    /// SwiftUI underlines `.link`-bearing runs by default. We want the system
    /// blue color but no underline. Walk every link run and explicitly clear
    /// the underline style — covers both our path linkifier and Apple's
    /// markdown parser's `[text](url)` output.
    private static func stripLinkUnderlines(_ attr: inout AttributedString) {
        for run in attr.runs where run.link != nil {
            attr[run.range].underlineStyle = nil
            attr[run.range].foregroundColor = SoulColor.accent
        }
    }

    /// SOUL-SOUL_DESKTOP-041: detect bare absolute paths in prose and tag
    /// them as file:// links. The host view's openURL handler turns those
    /// taps into in-app preview-pane opens. Conservative match: must start
    /// with `/` or `~/`, contain at least one extra slash OR a dotted
    /// extension, and use only path-safe characters.
    /// Compiled once at process startup. Recompiling per-paragraph during
    /// thread scroll/rerender was a measurable hot path. Matches absolute
    /// (`/Users/...`), home-rooted (`~/...`), and relative (`Config/foo.xcconfig`,
    /// `src/main.rs`) path tokens. The post-match filter in linkifyPaths
    /// rejects single-slash junk like "and/or" by requiring either 2+
    /// slashes OR a dotted file extension.
    private static let pathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._/~-])((?:~/|/)?[A-Za-z0-9_][A-Za-z0-9._-]*(?:/[A-Za-z0-9._-]+)+)"#)
    }()

    /// True if a paragraph contains either an Apple-autolinked markdown link
    /// (`[label](url)`) or one of our path/filename tokens. Used to decide
    /// whether to swap the hover cursor to pointing-hand. Cheap by design:
    /// runs on every paragraph render, gated by a contains-check first.
    static func hasAnyLink(_ s: String) -> Bool {
        if s.contains("](") && s.contains("[") { return true }
        return hasLinkifiablePath(s)
    }

    static func hasLinkifiablePath(_ s: String) -> Bool {
        guard s.contains("/") else { return false }
        guard let regex = pathRegex else { return false }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        var found = false
        regex.enumerateMatches(in: s, range: range) { m, _, stop in
            guard let m, let r = Range(m.range, in: s) else { return }
            var token = String(s[r])
            while let last = token.last, ".,;:)]}\"'".contains(last) { token.removeLast() }
            let slashes = token.filter({ $0 == "/" }).count
            let last = token.split(separator: "/").last.map(String.init) ?? ""
            let hasExt = last.contains(".") && !last.hasSuffix(".") && !last.hasPrefix(".")
            if slashes >= 2 || (slashes >= 1 && hasExt) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// Filename-with-extension matcher for bare tokens like `GEMINI.md`,
    /// `README.md`, `Package.swift`. Whitelisted extensions keep us from
    /// false-matching things like `Mr.Smith` or version numbers.
    private static let filenameRegex: NSRegularExpression? = {
        let exts = "md|markdown|swift|py|js|ts|tsx|jsx|rs|go|c|cpp|h|hpp|m|mm|sh|zsh|bash|fish|json|yaml|yml|toml|xml|html|css|scss|sql|txt|log|conf|config|xcconfig|plist|lock"
        return try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9._/~-])([A-Za-z][A-Za-z0-9_-]*\.(?:\#(exts)))(?![A-Za-z0-9])"#
        )
    }()

    static func linkifyPaths(_ attr: inout AttributedString) {
        let s = String(attr.characters)
        // Early-out: any linkifiable token needs at least one `/` or `.`.
        guard s.contains("/") || s.contains(".") else { return }
        applyLinkRegex(Self.pathRegex, on: &attr, fullString: s, requirePathish: true)
        applyLinkRegex(Self.filenameRegex, on: &attr, fullString: s, requirePathish: false)
    }

    /// Walks a regex over the attributed string and applies a soulpath://?p=<token>
    /// link to every accepted match. We use a custom scheme (not file://) so
    /// the original token survives URL parsing — that's how relative paths
    /// like `Config/foo.xcconfig` and bare filenames like `GEMINI.md` get
    /// passed verbatim to the host, which resolves them against the active
    /// project. Color is NOT overridden — SwiftUI's default link styling
    /// (system blue + underline) is what the user signed off on.
    private static func applyLinkRegex(
        _ regex: NSRegularExpression?,
        on attr: inout AttributedString,
        fullString s: String,
        requirePathish: Bool
    ) {
        guard let regex else { return }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            var token = String(s[r])
            while let last = token.last, ".,;:)]}\"'".contains(last) { token.removeLast() }
            guard token.count >= 3 else { continue }
            if requirePathish {
                let slashes = token.filter({ $0 == "/" }).count
                let lastSeg = token.split(separator: "/").last.map(String.init) ?? ""
                let hasExt = lastSeg.contains(".") && !lastSeg.hasSuffix(".") && !lastSeg.hasPrefix(".")
                guard slashes >= 2 || (slashes >= 1 && hasExt) else { continue }
            }
            // Skip if this range already has a link attribute — Apple's
            // markdown parser may have linkified `[label](url)` earlier, and
            // we don't want to clobber that.
            let tokenRange = s.range(of: token, range: r) ?? r
            guard let lower = AttributedString.Index(tokenRange.lowerBound, within: attr),
                  let upper = AttributedString.Index(tokenRange.upperBound, within: attr) else { continue }
            let attrRange = lower..<upper
            if attr[attrRange].link != nil { continue }
            var comps = URLComponents()
            comps.scheme = "soulpath"
            comps.queryItems = [URLQueryItem(name: "p", value: token)]
            guard let url = comps.url else { continue }
            attr[attrRange].link = url
        }
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

/// Pushes `NSCursor.pointingHand` while hovering a paragraph/bullet that
/// contains a link, pops on exit. SwiftUI Text doesn't expose per-substring
/// hover, so this applies to the whole paragraph — but only when at least
/// one link is present, so plain prose keeps the I-beam selection cursor.
private struct LinkHoverCursor: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard active else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
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
