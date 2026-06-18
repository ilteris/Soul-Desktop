import SwiftUI

/// SOUL-SOUL_DESKTOP-162: `Equatable` conformance + a manual `==` over
/// the stored input lets `.equatable()` at the use site short-circuit
/// SwiftUI's body re-evals when none of the input changed. Without it,
/// every items.count change in a parent re-evaluates every visible
/// MarkdownView body and re-runs the markdown parse + linkify regex on
/// the full text — a profile (2026-05-20) showed this dominating CPU
/// after the registry-store cache landed. `@Environment` is intentionally
/// excluded from `==`: the openFilePreview action's identity changes
/// across container re-creates but its observable behavior is stable.
struct MarkdownView: View, Equatable {
    let text: String
    var codeFont: Font = SoulType.code
    var bodyFont: Font = SoulType.body
    var h1Font: Font = SoulType.h1
    var h2Font: Font = SoulType.h2
    var h3Font: Font = SoulType.h3
    var h4Font: Font = SoulType.h4
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

    static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.text == rhs.text
            && lhs.codeFont == rhs.codeFont
            && lhs.bodyFont == rhs.bodyFont
            && lhs.h1Font == rhs.h1Font
            && lhs.h2Font == rhs.h2Font
            && lhs.h3Font == rhs.h3Font
            && lhs.h4Font == rhs.h4Font
            && lhs.headerColor == rhs.headerColor
            && lhs.bodyColor == rhs.bodyColor
            && lhs.codeColor == rhs.codeColor
            && lhs.codeBackground == rhs.codeBackground
            && lhs.lazy == rhs.lazy
    }

    var body: some View {
        // SOUL-SOUL_DESKTOP-167: cross-paragraph selection. SwiftUI's
        // `.textSelection(.enabled)` lets you drag *within* a single `Text`
        // but not across sibling `Text`s in a VStack. The user's complaint
        // was that they couldn't cmd-drag from the middle of paragraph 1
        // through paragraph 3 to grab a multi-paragraph quote. Fix: group
        // consecutive prose blocks (paragraph/bullet/blank) into a single
        // merged AttributedString rendered as ONE `Text`, so the run is
        // natively selectable end-to-end. Headings, code blocks, and tables
        // remain selection boundaries — they have non-Text layout anyway.
        let groups = groupForSelection(blocks)
        return Group {
            if lazy {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        renderGroup(group)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        renderGroup(group)
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
        .textSelection(.enabled)
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
            // SOUL-SOUL_DESKTOP-167: drop the leading `•  ` glyph. The
            // VStack's tight 4pt spacing already visually distinguishes
            // bullet items from surrounding paragraphs (which get
            // `\n\n`), and the glyph wasn't carrying meaning beyond
            // "this is a list" — which the layout itself communicates.
            // Side benefit: copy now yields the item text verbatim,
            // without the `•  ` prefix that earlier paste flows had to
            // strip.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
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
        case .codeBlock(let code, let lang):
            CodeBlockView(code: code, lang: lang, font: codeFont, fg: codeColor, bg: codeBackground)
        case .table(let header, let rows):
            TableView(header: header, rows: rows, headerFont: bodyFont, bodyFont: bodyFont)
        case .blank:
            Spacer().frame(height: 4)
        case .blockquote(let lines):
            BlockquoteView(lines: lines, bodyFont: bodyFont, bodyColor: bodyColor)
        case .horizontalRule:
            Rectangle()
                .fill(SoulColor.border.opacity(0.5))
                .frame(height: 1)
                .padding(.vertical, 6)
        }
    }

    /// Selection groups: either a run of prose blocks (paragraph/bullet/
    /// blank) we can merge into one selectable `Text`, or a single
    /// "structural" block (heading/code/table/inline-code-row) rendered
    /// alone. Inline-code-row paragraphs stay alone too — they own their
    /// own click-to-copy affordance, which would be lost if we collapsed
    /// them into the prose stream.
    private enum SelectionGroup {
        case prose([Block])
        case standalone(Block)
    }

    private func groupForSelection(_ blocks: [Block]) -> [SelectionGroup] {
        var out: [SelectionGroup] = []
        var bucket: [Block] = []
        func flush() {
            if !bucket.isEmpty {
                // Drop a trailing blank — its only job was paragraph
                // separation inside the merged Text, but the merge already
                // inserts \n\n between paragraphs.
                while case .blank? = bucket.last { bucket.removeLast() }
                if !bucket.isEmpty { out.append(.prose(bucket)) }
                bucket.removeAll(keepingCapacity: true)
            }
        }
        for block in blocks {
            switch block {
            case .paragraph(let line) where MarkdownView.bareInlineCode(line) != nil:
                flush(); out.append(.standalone(block))
            case .paragraph, .blank:
                bucket.append(block)
            case .bullet:
                bucket.append(block)
            case .heading, .codeBlock, .table, .blockquote, .horizontalRule:
                // SOUL-SOUL_DESKTOP-160: blockquote and HR own their own
                // chrome (left rail / divider) — never collapse into a
                // sibling prose Text.
                flush(); out.append(.standalone(block))
            }
        }
        flush()
        return out
    }

    @ViewBuilder
    private func renderGroup(_ group: SelectionGroup) -> some View {
        switch group {
        case .standalone(let block):
            render(block)
        case .prose(let merged):
            mergedProse(merged)
        }
    }

    /// Builds one `Text` from the AttributedStrings of every block in the
    /// group. Paragraphs separated by `\n\n`; bullets get a leading
    /// "•  " marker. Path linkification runs on the merged string so cross-
    /// paragraph links keep working.
    @ViewBuilder
    private func mergedProse(_ blocks: [Block]) -> some View {
        // SOUL-SOUL_DESKTOP-186: skip LinkHoverCursor on merged prose
        // groups. The cursor modifier applies at the view level — for a
        // merged group of N paragraphs, even one link anywhere in the
        // group forced the entire stretch to show a pointing-hand cursor,
        // which read as wrong on the plain-prose paragraphs. Single
        // paragraphs and bullets still get the modifier (one paragraph =
        // tight enough granularity for the affordance to make sense).
        let attr = MarkdownView.mergedAttributed(for: blocks)
        Text(attr)
            .font(bodyFont)
            .foregroundStyle(bodyColor)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    fileprivate static func mergedAttributed(for blocks: [Block]) -> AttributedString {
        let key = mergedAttributedCacheKey(for: blocks)
        if let hit = mergedAttrCache[key] { return hit }

        var out = AttributedString()
        var first = true
        func appendBreak() {
            if first { first = false; return }
            out.append(AttributedString("\n\n"))
        }
        for block in blocks {
            switch block {
            case .paragraph(let line):
                appendBreak()
                out.append(attributedInline(line))
            case .bullet(let items):
                // SOUL-SOUL_DESKTOP-167: drop the leading `•  ` glyph
                // from the merged prose stream. Items still separate by
                // single `\n` (vs paragraphs' `\n\n`), so the list
                // grouping reads visually without the marker. Copy
                // yields verbatim item text.
                appendBreak()
                for (idx, item) in items.enumerated() {
                    if idx > 0 { out.append(AttributedString("\n")) }
                    out.append(attributedInline(item))
                }
            case .blank:
                // SOUL-SOUL_DESKTOP-197: skip — appendBreak() between
                // adjacent prose blocks already yields the paragraph
                // gap. Emitting "\n\n" for the blank too produced a
                // double-gap (4 newlines visible) between paragraphs
                // separated by a markdown blank line.
                continue
            case .heading, .codeBlock, .table, .blockquote, .horizontalRule:
                continue // grouping invariant — never present in a prose group
            }
        }
        if mergedAttrCache.count > 512 {
            mergedAttrCache.removeAll(keepingCapacity: true)
        }
        mergedAttrCache[key] = out
        return out
    }

    private static func mergedAttributedCacheKey(for blocks: [Block]) -> String {
        var key = ""
        key.reserveCapacity(blocks.reduce(0) { partial, block in
            switch block {
            case .paragraph(let line):
                return partial + line.count + 4
            case .bullet(let items):
                return partial + items.reduce(4) { $0 + $1.count + 1 }
            case .blank:
                return partial + 4
            case .heading, .codeBlock, .table, .blockquote, .horizontalRule:
                return partial + 4
            }
        })
        for block in blocks {
            switch block {
            case .paragraph(let line):
                key += "p:\(line)\u{1F}"
            case .bullet(let items):
                key += "b:\(items.joined(separator: "\u{1E}"))\u{1F}"
            case .blank:
                key += "n:\u{1F}"
            case .heading, .codeBlock, .table, .blockquote, .horizontalRule:
                continue
            }
        }
        return key
    }

    /// Same styling pipeline as `inline(_:)` but returns the raw
    /// AttributedString so callers can concatenate runs before rendering.
    ///
    /// SOUL-SOUL_DESKTOP-162: memoized by source string. The expensive
    /// portion is `linkifyPaths` (NSRegularExpression scan over the merged
    /// inline) which a profile (2026-05-20) showed firing per body
    /// re-eval per visible MarkdownView. Each line of agent prose is
    /// stable once received, so caching by `s` is a clean hit pattern
    /// during streaming — only the actively-growing last line misses.
    static func attributedInline(_ s: String) -> AttributedString {
        if let hit = inlineAttrCache[s] { return hit }
        let result = computeAttributedInline(s)
        if inlineAttrCache.count > 4096 {
            inlineAttrCache.removeAll(keepingCapacity: true)
        }
        inlineAttrCache[s] = result
        return result
    }

    /// Process-wide cache keyed by raw inline string. Bounded; reset
    /// wholesale at the cap so we never grow unbounded across long
    /// sessions. Mirrors the `parseCache` pattern.
    private static var inlineAttrCache: [String: AttributedString] = [:]
    private static var mergedAttrCache: [String: AttributedString] = [:]

    private static func computeAttributedInline(_ s: String) -> AttributedString {
        guard var attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return AttributedString(s)
        }
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
        // SOUL-SOUL_DESKTOP-160: Apple's AttributedString(markdown:) parser
        // silently leaves some `[label](url)` constructs un-linked — file://
        // URLs are the worst offender. Symptom from the bug report: the
        // bracket TEXT got auto-styled by linkifyPaths because it looked
        // path-shaped, while the literal `](url)` remained as ASCII text
        // after the styled run. Convert any `[label](url)` patterns still
        // present in the post-parser AttributedString to real link runs.
        applyMarkdownLinkFallback(&attr)
        applyInlineMathSymbolFallback(&attr)
        linkifyPaths(&attr)
        stripLinkUnderlines(&attr)
        return attr
    }

    /// SOUL-SOUL_DESKTOP-160: scan the AttributedString's plain text for
    /// surviving `[label](url)` patterns (i.e., the ones Apple's markdown
    /// parser didn't convert) and replace each with the label text carrying
    /// a `.link` attribute. Processes matches in reverse so the
    /// `attr.range(of:)` lookups don't get invalidated by earlier
    /// replacements.
    private static func applyMarkdownLinkFallback(_ attr: inout AttributedString) {
        let plain = String(attr.characters)
        guard plain.contains("](") else { return }
        guard let regex = markdownLinkRegex else { return }
        let nsPlain = plain as NSString
        let matches = regex.matches(in: plain, range: NSRange(location: 0, length: nsPlain.length))
        for m in matches.reversed() {
            guard m.numberOfRanges == 3 else { continue }
            let fullMatch = nsPlain.substring(with: m.range)
            let labelText = nsPlain.substring(with: m.range(at: 1))
            let urlText = nsPlain.substring(with: m.range(at: 2))
            // file:// URLs with spaces (rare but possible from agent
            // line-wraps that escaped collapseMultilineLinks) need percent
            // encoding before URL() will accept them.
            let encoded = urlText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlText
            guard let url = URL(string: urlText) ?? URL(string: encoded) else { continue }
            guard let attrRange = attr.range(of: fullMatch) else { continue }
            var replacement = AttributedString(labelText)
            replacement.link = url
            attr.replaceSubrange(attrRange, with: replacement)
        }
    }

    /// We do not run a math renderer, but agents occasionally emit small
    /// LaTeX inline symbols in prose (`$\rightarrow$`) where a literal glyph
    /// was intended. Swift's markdown parser leaves those spans untouched, so
    /// normalize a tiny allowlist before path linkification. Code spans are
    /// deliberately skipped so shell snippets and source examples stay exact.
    private static func applyInlineMathSymbolFallback(_ attr: inout AttributedString) {
        let replacements = [
            #"\rightarrow"#: "→",
            #"\to"#: "→",
            #"\leftarrow"#: "←",
            #"\Rightarrow"#: "⇒",
            #"\Leftarrow"#: "⇐",
            #"\leftrightarrow"#: "↔"
        ]
        let escapedAlternatives = replacements.keys
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: #"\$(\#(escapedAlternatives))\$"#) else {
            return
        }

        let plain = String(attr.characters)
        let nsPlain = plain as NSString
        let matches = regex.matches(in: plain, range: NSRange(location: 0, length: nsPlain.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: plain),
                  let tokenRange = Range(match.range(at: 1), in: plain),
                  let replacementText = replacements[String(plain[tokenRange])],
                  let lower = AttributedString.Index(fullRange.lowerBound, within: attr),
                  let upper = AttributedString.Index(fullRange.upperBound, within: attr)
            else {
                continue
            }
            let attrRange = lower..<upper
            guard !containsCodeRun(attrRange, in: attr) else { continue }
            attr.replaceSubrange(attrRange, with: AttributedString(replacementText))
        }
    }

    private static func containsCodeRun(
        _ range: Range<AttributedString.Index>,
        in attr: AttributedString
    ) -> Bool {
        attr.runs.contains { run in
            guard run.range.overlaps(range) else { return false }
            return run.inlinePresentationIntent?.contains(.code) == true
        }
    }

    /// `[label](url)` matcher. Label can contain any char except `]`; URL
    /// can contain any char except `)`. CommonMark allows nested parens via
    /// escaping but agent outputs effectively never use that.
    private static let markdownLinkRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#)
    }()

    private func inline(_ s: String) -> Text { MarkdownView.inline(s) }

    /// Public so children (TableView cells, anyone else rendering markdown
    /// chunks) can produce the same bold/italic/code styling that paragraph
    /// rows get. Without this, `**bold**` and `` `code` `` leak through as
    /// raw asterisks/backticks in table cells.
    static func inline(_ s: String) -> Text {
        // Single pipeline shared with mergedAttributed — both produce the
        // same styled run, only the wrapper (Text vs AttributedString)
        // differs. Keeps bold/italic/code/link behavior identical.
        Text(attributedInline(s))
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

    /// True if a paragraph contains either a markdown link
    /// (`[label](url)`), an auto-detected bare URL (http/https/mailto/file
    /// scheme that Apple's markdown parser auto-links), or one of our
    /// path/filename tokens. Used to decide whether to swap the hover
    /// cursor to pointing-hand. Cheap by design: runs on every paragraph
    /// render, gated by contains-checks first.
    static func hasAnyLink(_ s: String) -> Bool {
        if s.contains("](") && s.contains("[") { return true }
        // SOUL-SOUL_DESKTOP-183: catch bare URLs that the markdown parser
        // auto-links without bracket syntax (the `https://github.com/...`
        // shape in agent replies). Without this, the cursor stays as an
        // I-beam even though the URL is clickable.
        if s.contains("://") {
            let lower = s.lowercased()
            if lower.contains("http://") || lower.contains("https://")
                || lower.contains("file://") || lower.contains("ftp://")
                || lower.contains("ssh://") {
                return true
            }
        }
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
            // Skip if this range already has a link attribute — Apple's
            // markdown parser may have linkified `[label](url)` earlier, and
            // we don't want to clobber that.
            let tokenRange = s.range(of: token, range: r) ?? r
            guard let lower = AttributedString.Index(tokenRange.lowerBound, within: attr),
                  let upper = AttributedString.Index(tokenRange.upperBound, within: attr) else { continue }
            var attrRange = clampPathCandidateToFirstAttributeRun(lower..<upper, in: attr)
            token = String(attr.characters[attrRange])
            while let last = token.last, ".,;:)]}\"'".contains(last), attrRange.lowerBound < attrRange.upperBound {
                token.removeLast()
                attrRange = attrRange.lowerBound..<attr.characters.index(before: attrRange.upperBound)
            }
            guard token.count >= 3 else { continue }
            if requirePathish {
                let slashes = token.filter({ $0 == "/" }).count
                let lastSeg = token.split(separator: "/").last.map(String.init) ?? ""
                let hasExt = lastSeg.contains(".") && !lastSeg.hasSuffix(".") && !lastSeg.hasPrefix(".")
                guard slashes >= 2 || (slashes >= 1 && hasExt) else { continue }
            }
            if attr[attrRange].link != nil { continue }
            var comps = URLComponents()
            comps.scheme = "soulpath"
            comps.queryItems = [URLQueryItem(name: "p", value: token)]
            guard let url = comps.url else { continue }
            attr[attrRange].link = url
        }
    }

    /// Apple's markdown pass removes delimiter characters before this path
    /// linker runs. A source like `file.swift.**Title**` therefore appears as
    /// `file.swift.Title` in the plain attributed characters, and the path
    /// regex would otherwise absorb the first title word into the link. When a
    /// candidate crosses a markdown styling boundary, keep only the first
    /// attributed run and let normal trailing-punctuation trimming finish it.
    private static func clampPathCandidateToFirstAttributeRun(
        _ range: Range<AttributedString.Index>,
        in attr: AttributedString
    ) -> Range<AttributedString.Index> {
        guard let run = attr.runs.first(where: {
            $0.range.lowerBound <= range.lowerBound && range.lowerBound < $0.range.upperBound
        }) else {
            return range
        }
        guard run.range.upperBound < range.upperBound else { return range }
        return range.lowerBound..<run.range.upperBound
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
        case 1: return h1Font
        case 2: return h2Font
        case 3: return h3Font
        default: return h4Font
        }
    }
}

/// Forces the pointing-hand cursor over a paragraph/bullet that contains a
/// link. SOUL-SOUL_DESKTOP-178: previously used `NSCursor.push()` on hover
/// enter and `.pop()` on exit, but with `.textSelection(.enabled)` on the
/// parent bubble SwiftUI re-asserts the I-beam cursor on every mouse-move
/// event, so the one-shot push gets overridden almost immediately and the
/// user sees a text cursor even on linkified rows. `.onContinuousHover`
/// fires per movement, and `NSCursor.pointingHand.set()` (which replaces
/// the active cursor, no stack semantics) wins the race.
///
/// On exit we restore the I-beam explicitly — the parent's selection
/// cursor would otherwise stay as pointing-hand until SwiftUI's next
/// natural reset.
private struct LinkHoverCursor: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            guard active else { return }
            switch phase {
            case .active:
                NSCursor.pointingHand.set()
            case .ended:
                NSCursor.iBeam.set()
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
    /// SOUL-SOUL_DESKTOP-177: collapse-by-default for large blocks. Renders
    /// the first `collapsedHeadLines` then a "Show all N lines" button.
    /// A long code dump inside a single `Text` is the dominant scroll-perf
    /// cost in transcripts that contain file content — collapsing past the
    /// threshold turns a multi-MB selectable Text into a small fixed
    /// preview until the user opts in.
    @State private var expanded = false
    private static let collapseThreshold = 40
    private static let collapsedHeadLines = 20

    private var lineCount: Int {
        if code.isEmpty { return 0 }
        var n = code.components(separatedBy: "\n").count
        if code.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }

    private var preview: String {
        let lines = code.components(separatedBy: "\n")
        let head = lines.prefix(Self.collapsedHeadLines)
        return head.joined(separator: "\n")
    }

    private var shouldCollapse: Bool {
        lineCount > Self.collapseThreshold && !expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(lang ?? "text")
                    .font(SoulFont.code(10, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                if lineCount > 0 {
                    Text("· \(lineCount) lines")
                        .font(SoulFont.code(10, weight: .regular))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
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
                .buttonStyle(.soulHover)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.surface.opacity(0.7))
            .overlay(alignment: .bottom) {
                Rectangle().fill(SoulColor.border.opacity(0.5)).frame(height: 1)
            }

            Text(shouldCollapse ? preview : code)
                .font(font)
                .foregroundStyle(fg)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)

            if lineCount > Self.collapseThreshold {
                Button {
                    withAnimation(.easeOut(duration: 0.08)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .regular))
                        Text(expanded
                             ? "Collapse"
                             : "Show all \(lineCount) lines")
                            .font(SoulFont.code(11, weight: .regular))
                    }
                    .foregroundStyle(SoulColor.fgMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SoulColor.surface.opacity(0.4))
                    .overlay(alignment: .top) {
                        Rectangle().fill(SoulColor.border.opacity(0.4)).frame(height: 0.5)
                    }
                }
                .buttonStyle(.soulHover)
            }
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

/// SOUL-SOUL_DESKTOP-160: blockquote rendering with hover-revealed copy
/// button. Left rail + 12pt indent visually separates quoted prose from
/// the surrounding stream; the top-right button copies the un-prefixed
/// quote body to the pasteboard (the agent's paste-ready LinkedIn /
/// email drafts are the primary use case).
///
/// Inline formatting (bold/italic/code/links) goes through the same
/// `attributedInline` pipeline as paragraphs, so wrapped markdown inside
/// the quote renders correctly.
private struct BlockquoteView: View {
    let lines: [String]
    let bodyFont: Font
    let bodyColor: Color
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(SoulColor.border.opacity(0.55))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    // Group consecutive non-empty lines into paragraphs;
                    // bare `>` (empty content after stripping) creates a
                    // paragraph break. Each paragraph runs through
                    // attributedInline so bold/italic/code/links work.
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                        Text(MarkdownView.attributedInline(para))
                            .font(bodyFont)
                            .foregroundStyle(bodyColor.opacity(0.92))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 24) // reserve room for the copy button
            }
            .padding(.vertical, 4)

            if hovering || copied {
                Button(action: copy) {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .regular))
                        if copied {
                            Text("copied")
                                .font(.system(size: 10, weight: .regular))
                        }
                    }
                    .foregroundStyle(copied ? SoulColor.accent : SoulColor.fgMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help("Copy quoted text")
                .padding(.top, 2)
                .padding(.trailing, 4)
            }
        }
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) { hovering = h }
        }
    }

    /// Re-assemble paragraphs from the stripped lines: consecutive
    /// non-empty lines join with a space, empty lines (the `>` blank
    /// separator) start a new paragraph.
    private var paragraphs: [String] {
        var out: [String] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    out.append(current.joined(separator: " "))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    private var copyText: String {
        // Strip the bare-`>` placeholders, join with single newlines.
        paragraphs.joined(separator: "\n\n")
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        #endif
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.12)) { copied = false }
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
    // SOUL-SOUL_DESKTOP-160: blockquote groups consecutive `> ` lines
    // (including bare `>` blank lines as inter-paragraph separators).
    // Lines are stored with the leading `>` (and any single space after
    // it) stripped — the renderer adds the left rail + indent itself.
    case blockquote([String])
    // SOUL-SOUL_DESKTOP-160: `***`, `---`, `___` standalone lines render
    // as a thin SoulColor divider.
    case horizontalRule
}

/// SOUL-SOUL_DESKTOP-160: collapse wrapped `[text](url)` constructs before
/// the markdown parser sees them. Agent outputs containing
/// long file:// URLs wrap across multiple lines, but markdown's inline
/// link syntax doesn't allow newlines inside `[text]` or `(url)` — so
/// `[applications/x/\nFILE.md](file:///long/wrapped/\nURL.md)` rendered
/// as literal `]` + raw URL after styled bracket text. This pre-pass
/// glues the wrapped spans back into one logical line.
///
/// State machine walks the string. When `[` is seen, scans for the
/// matching `]`; then if a `(` follows (whitespace/newline tolerated),
/// scans for the matching `)`. Label newlines collapse to spaces for
/// readability; URL target whitespace is removed so wrapped filesystem paths
/// do not acquire bogus spaces.
private func collapseMultilineLinks(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "[" {
            // Scan for the matching `]`.
            var depth = 1
            var j = s.index(after: i)
            while j < s.endIndex {
                let cj = s[j]
                if cj == "[" { depth += 1 }
                else if cj == "]" { depth -= 1; if depth == 0 { break } }
                j = s.index(after: j)
            }
            if j < s.endIndex, s[j] == "]" {
                // Skip optional whitespace/newlines between `]` and `(`.
                var k = s.index(after: j)
                while k < s.endIndex, s[k] == " " || s[k] == "\t" || s[k] == "\n" {
                    k = s.index(after: k)
                }
                if k < s.endIndex, s[k] == "(" {
                    // Scan for the matching `)`.
                    var urlDepth = 1
                    var u = s.index(after: k)
                    while u < s.endIndex {
                        let cu = s[u]
                        if cu == "(" { urlDepth += 1 }
                        else if cu == ")" { urlDepth -= 1; if urlDepth == 0 { break } }
                        u = s.index(after: u)
                    }
                    if u < s.endIndex, s[u] == ")" {
                        out.append("[")
                        out.append(collapseLinkLabel(s[s.index(after: i)..<j]))
                        out.append("](")
                        out.append(collapseLinkTarget(s[s.index(after: k)..<u]))
                        out.append(")")
                        i = s.index(after: u)
                        continue
                    }
                }
            }
        }
        out.append(c)
        i = s.index(after: i)
    }
    return out
}

private func collapseLinkLabel(_ label: Substring) -> String {
    var out = ""
    out.reserveCapacity(label.count)
    var pendingSpace = false
    for ch in label {
        if ch == "\n" || ch == "\t" || ch == "\r" {
            pendingSpace = true
        } else {
            if pendingSpace, !out.hasSuffix(" ") {
                out.append(" ")
            }
            out.append(ch)
            pendingSpace = false
        }
    }
    return out
}

private func collapseLinkTarget(_ target: Substring) -> String {
    target.filter { !$0.isWhitespace }.map(String.init).joined()
}

/// SOUL-SOUL_DESKTOP-160: horizontal-rule detection. Recognizes `***`,
/// `---`, `___` lines (3+ of the same char, with optional intermixed
/// spaces — matches CommonMark). The trimmed line must be non-empty
/// after collapsing whitespace, must be all the same character, and
/// must be at least 3 chars long.
private func isHorizontalRule(_ trimmed: String) -> Bool {
    guard !trimmed.isEmpty else { return false }
    let compact = trimmed.filter { !$0.isWhitespace }
    guard compact.count >= 3 else { return false }
    guard let first = compact.first, "*-_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
}

private func parse(_ markdown: String) -> [Block] {
    var blocks: [Block] = []
    // SOUL-SOUL_DESKTOP-160: glue `[text](url)` spans wrapped across
    // newlines before the line split — see collapseMultilineLinks.
    let preprocessed = collapseMultilineLinks(markdown)
    let lines = preprocessed.components(separatedBy: "\n")

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // SOUL-SOUL_DESKTOP-160: horizontal rule — `***`, `---`, `___`
        // (3+ same char, optional spaces). Standalone line, no further
        // content interpretation.
        if isHorizontalRule(trimmed) {
            blocks.append(.horizontalRule)
            i += 1
            continue
        }

        // SOUL-SOUL_DESKTOP-160: blockquote — greedy gather consecutive
        // lines starting with `>` (including bare `>` blank-content
        // lines, which act as inter-paragraph separators inside the
        // quoted body). Strip the leading `>` and at most one space.
        if trimmed.hasPrefix(">") {
            var quotedLines: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                var inner = String(t.dropFirst())
                if inner.hasPrefix(" ") { inner.removeFirst() }
                quotedLines.append(inner)
                i += 1
            }
            blocks.append(.blockquote(quotedLines))
            continue
        }

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
        // GFM table separators allow internal whitespace for column alignment
        // (e.g., `| :---  | : --- |`). Gemini emits these regularly when it
        // pads cells to align visually. Strip whitespace before checking the
        // substantive characters, require at least one `-`.
        let compact = cell.filter { !$0.isWhitespace }
        return !compact.isEmpty
            && compact.contains("-")
            && compact.allSatisfy { $0 == "-" || $0 == ":" }
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
