import SwiftUI
import AppKit
import Splash
import Highlightr

/// SOUL-SOUL_DESKTOP-041: right-side inline file preview pane. Wired from
/// FileChipRow taps (instead of NSWorkspace.shared.open). Reads up to 1MB of
/// the file synchronously, renders markdown via MarkdownView for .md, plain
/// monospaced text for other text-ish extensions, and a fallback open-
/// externally affordance for everything else.

/// Environment key that lets descendants (FileChipRow inside ToolCallRow
/// inside ThreadView) ask the shell to open a path in the preview pane
/// without dragging a binding through every intermediate view.
private struct OpenFilePreviewKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var openFilePreview: (String) -> Void {
        get { self[OpenFilePreviewKey.self] }
        set { self[OpenFilePreviewKey.self] = newValue }
    }
}

struct FilePreviewPanel: View {
    let path: String
    let onClose: () -> Void
    /// When true, suppress the internal breadcrumb/filename/close header
    /// so the tab strip in the host can carry that identity.
    var embedded: Bool = false

    @State private var content: String = ""
    @State private var loadError: String? = nil
    @State private var truncated: Bool = false
    @State private var binary: Bool = false
    @State private var showingSource: Bool = false

    private var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    private var filename: String { url.lastPathComponent }
    private var breadcrumb: String {
        // Show last 3 path components so the user knows where it lives
        // without dedicating the whole header line to /Users/ilteris/…
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.suffix(4).joined(separator: " / ")
    }
    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                header
                Divider().opacity(0.4)
            }
            body(for: ext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SoulColor.bg)
        .task(id: path) { await loadAsync() }
        .onChange(of: path) { _, _ in showingSource = false }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(breadcrumb)
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Open externally")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.soulHover)
                .help("Close preview")
            }
            HStack(spacing: 8) {
                Text(filename)
                    .font(SoulFont.ui(15, weight: .semibold))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if truncated {
                    Text("truncated")
                        .font(SoulFont.ui(9, weight: .medium))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(SoulColor.surface, in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func body(for ext: String) -> some View {
        if let err = loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't read file").font(SoulFont.ui(13, weight: .semibold))
                Text(err).font(SoulFont.code(11)).foregroundStyle(SoulColor.fgMuted)
            }
            .padding(20)
        } else if binary {
            VStack(alignment: .leading, spacing: 10) {
                Text("Binary file — preview not available")
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fgMuted)
                Button("Open externally") { NSWorkspace.shared.open(url) }
            }
            .padding(20)
        } else if isHTML(ext) {
            htmlPreview
        } else if ext == "md" || ext == "markdown" {
            ScrollView {
                MarkdownView(text: content, lazy: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if ext == "swift" {
            CodePreview(attributed: SwiftHighlighter.highlight(content))
        } else if let lang = HighlightrBridge.language(for: ext),
                  let attributed = HighlightrBridge.highlight(content, as: lang) {
            CodePreview(attributed: attributed)
        } else {
            CodePreview(plain: content)
        }
    }

    private func isHTML(_ ext: String) -> Bool {
        ext == "html" || ext == "htm"
    }

    private var htmlPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    showingSource = false
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.soulHover)
                .foregroundStyle(!showingSource ? SoulColor.fg : SoulColor.fgMuted)
                .background(
                    !showingSource ? SoulColor.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .help("Rendered preview")

                Button {
                    showingSource = true
                } label: {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.soulHover)
                .foregroundStyle(showingSource ? SoulColor.fg : SoulColor.fgMuted)
                .background(
                    showingSource ? SoulColor.surface : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .help("View source")

                Spacer()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.soulHover)
                .foregroundStyle(SoulColor.fgMuted)
                .help("Open externally")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SoulColor.bg)

            Divider().background(SoulColor.border.opacity(0.4))
            if showingSource {
                htmlSourcePreview
            } else {
                WebPreviewPanel(source: .file(url))
            }
        }
    }

    @ViewBuilder
    private var htmlSourcePreview: some View {
        if let attributed = HighlightrBridge.highlight(content, as: "xml") {
            CodePreview(attributed: attributed)
        } else {
            CodePreview(plain: content)
        }
    }

    /// Splash-backed Swift syntax highlighter. Splash only ships a Swift
    /// grammar; for everything else we keep the plain-text branch above.
    /// The highlighter + theme are built once; results are cached by source
    /// string so flipping between files doesn't re-tokenize.
    private enum SwiftHighlighter {
        nonisolated(unsafe) private static let highlighter: SyntaxHighlighter<AttributedStringOutputFormat> = {
            SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
        }()

        nonisolated(unsafe) private static var cache: [String: NSAttributedString] = [:]

        private static var theme: Splash.Theme {
            // Custom palette mapped against SoulColor — Splash's built-in
            // .midnight / .sundellsColors are green-saturated dark themes
            // that clash hard with Soul-Desktop's cream surface. We map the
            // tokens to muted earthy tones that read on both light and dark
            // canvas backgrounds. Colors approximate the existing
            // SoulColor.fg / fgMuted / accent palette plus three subtle hues
            // for keyword / string / type distinction.
            let fg = Splash.Color(red: 30/255,  green: 30/255,  blue: 46/255,  alpha: 1)    // SoulColor.fg
            let muted = Splash.Color(red: 92/255, green: 95/255, blue: 119/255, alpha: 1)   // SoulColor.fgMuted
            let comment = Splash.Color(red: 140/255, green: 143/255, blue: 161/255, alpha: 1) // SoulColor.fgSubtle
            let keyword = Splash.Color(red: 136/255, green: 57/255, blue: 239/255, alpha: 1)   // muted purple
            let string = Splash.Color(red: 64/255, green: 124/255, blue: 90/255, alpha: 1)     // forest (single, restrained)
            let type = Splash.Color(red: 30/255, green: 102/255, blue: 245/255, alpha: 1)      // blue
            let number = Splash.Color(red: 254/255, green: 100/255, blue: 11/255, alpha: 1)    // amber
            let call = Splash.Color(red: 32/255, green: 105/255, blue: 165/255, alpha: 1)      // deep blue
            return Splash.Theme(
                font: Splash.Font(size: 14),
                plainTextColor: fg,
                tokenColors: [
                    .keyword: keyword,
                    .string: string,
                    .type: type,
                    .call: call,
                    .number: number,
                    .comment: comment,
                    .property: muted,
                    .dotAccess: muted,
                    .preprocessing: keyword,
                ],
                backgroundColor: Splash.Color.clear
            )
        }

        static func highlight(_ source: String) -> NSAttributedString {
            if let hit = cache[source] { return hit }
            let out = highlighter.highlight(source)
            if cache.count > 32 { cache.removeAll(keepingCapacity: true) }
            cache[source] = out
            return out
        }
    }

    /// Highlightr-backed multi-language highlighter (highlight.js via
    /// JSContext). Used for everything except Swift (Splash) and Markdown
    /// (rendered as prose). Lazy-init keeps the ~100ms JSContext cold-start
    /// out of app launch; cache keyed by lang+source so repeat opens are
    /// instant.
    private enum HighlightrBridge {
        nonisolated(unsafe) private static let instance: Highlightr? = {
            let h = Highlightr()
            // xcode = light, low-saturation. atom-one-dark / monokai etc.
            // clash hard with Soul-Desktop's cream surface (everything went
            // green). xcode is closest to the Swift branch's custom palette
            // above so the two highlighters look consistent.
            h?.setTheme(to: "xcode")
            return h
        }()

        nonisolated(unsafe) private static var cache: [String: NSAttributedString] = [:]

        /// Map our preview-pane extension whitelist to highlight.js language
        /// identifiers. Unknown extensions return nil → plain-text fallback.
        static func language(for ext: String) -> String? {
            switch ext {
            case "py": return "python"
            case "js", "jsx": return "javascript"
            case "ts", "tsx": return "typescript"
            case "rs": return "rust"
            case "go": return "go"
            case "c", "h": return "c"
            case "cpp", "hpp", "cc", "cxx": return "cpp"
            case "m", "mm": return "objectivec"
            case "sh", "zsh", "bash", "fish": return "bash"
            case "json": return "json"
            case "yaml", "yml": return "yaml"
            case "toml": return "ini"
            case "xml", "plist": return "xml"
            case "html": return "xml"
            case "css", "scss": return "scss"
            case "sql": return "sql"
            case "rb": return "ruby"
            case "java": return "java"
            case "kt", "kts": return "kotlin"
            case "lua": return "lua"
            case "conf", "config", "xcconfig": return "ini"
            case "dockerfile": return "dockerfile"
            case "make", "mk": return "makefile"
            default: return nil
            }
        }

        static func highlight(_ source: String, as language: String) -> NSAttributedString? {
            let key = language + "\u{1F}" + source
            if let hit = cache[key] { return hit }
            guard let attributed = instance?.highlight(source, as: language, fastRender: true) else { return nil }
            if cache.count > 32 { cache.removeAll(keepingCapacity: true) }
            cache[key] = attributed
            return attributed
        }
    }

    /// 1 MB cap. Above that we slice and flag truncated. Detects binary by
    /// sniffing for null bytes in the head; saves us from dumping a render
    /// of an .o or .pdf into the panel. The IO + decode happens off the
    /// main thread so the panel can animate in without blocking on disk.
    private struct LoadResult {
        var content: String = ""
        var error: String? = nil
        var truncated: Bool = false
        var binary: Bool = false
    }

    private func loadAsync() async {
        // Reset state immediately on main; the load result will overwrite.
        content = ""
        loadError = nil
        truncated = false
        binary = false
        let target = url
        let result: LoadResult = await Task.detached(priority: .userInitiated) {
            FilePreviewPanel.readFile(at: target)
        }.value
        // Honor cancellation — if the user clicked a different file mid-read,
        // the .task(id:) firing reset us already; bail rather than overwrite.
        if Task.isCancelled { return }
        content = result.content
        loadError = result.error
        truncated = result.truncated
        binary = result.binary
    }

    nonisolated private static func readFile(at url: URL) -> LoadResult {
        var out = LoadResult()
        let cap = 1_048_576
        guard FileManager.default.fileExists(atPath: url.path) else {
            out.error = "File not found at \(url.path)"
            return out
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let handoff = url.appendingPathComponent("handoff_body.md")
            if FileManager.default.fileExists(atPath: handoff.path) {
                return readFile(at: handoff)
            }
            out.error = "Path is a directory, not a readable file: \(url.path)"
            return out
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = handle.readData(ofLength: cap + 1)
            out.truncated = data.count > cap
            let slice = out.truncated ? data.prefix(cap) : data
            if slice.contains(0) {
                out.binary = true
                return out
            }
            out.content = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
            if out.truncated {
                out.content += "\n\n… (file truncated at 1 MB — open externally for full content)"
            }
        } catch {
            out.error = error.localizedDescription
        }
        return out
    }
}

/// Code preview with line-number gutter and JetBrains Mono enforcement.
/// Used for both syntax-highlighted (Splash / Highlightr → NSAttributedString)
/// and plain text. The highlighters embed their own NSFont attributes inside
/// the attributed string, which SwiftUI's `.font()` modifier on a Text view
/// can't override — so we rewrite font attributes to JetBrains Mono before
/// rendering. Line numbers are right-aligned in a fixed-width gutter so the
/// code column has a stable left edge as line counts grow.
private struct CodePreview: View {
    private let lines: [AttributedString]
    private let lineCount: Int

    private static let fontSize: CGFloat = 14
    private static let gutterFont: SwiftUI.Font = SoulFont.code(13)
    private static let lineSpacing: CGFloat = 2

    init(plain: String) {
        let attr = CodePreview.plainAttributed(plain)
        self.lines = CodePreview.split(attr)
        self.lineCount = self.lines.count
    }

    init(attributed: NSAttributedString) {
        let normalized = CodePreview.rewriteFont(attributed, size: CodePreview.fontSize)
        self.lines = CodePreview.split(normalized)
        self.lineCount = self.lines.count
    }

    var body: some View {
        let gutterWidth = CodePreview.gutterWidth(for: lineCount)
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: CodePreview.lineSpacing) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(idx + 1)")
                            .font(CodePreview.gutterFont)
                            .foregroundStyle(SoulColor.fgSubtle.opacity(0.7))
                            .frame(width: gutterWidth, alignment: .trailing)
                            .padding(.top, 1)
                        Text(line)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func gutterWidth(for count: Int) -> CGFloat {
        let digits = max(2, String(count).count)
        return CGFloat(digits) * 9 + 4
    }

    /// Replace every `.font` attribute on `s` with JetBrains Mono at `size`,
    /// preserving every other attribute (foreground color etc.). Splash's
    /// default theme bakes in Menlo at a fixed size; Highlightr bakes in
    /// Courier. Without this rewrite the SwiftUI Text shows their fonts.
    private static func rewriteFont(_ s: NSAttributedString, size: CGFloat) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: s)
        let full = NSRange(location: 0, length: mutable.length)
        let jbm = SoulFont.nsFont(size, weight: .regular)
        mutable.addAttribute(.font, value: jbm, range: full)
        return mutable
    }

    private static func plainAttributed(_ s: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: SoulFont.nsFont(fontSize, weight: .regular),
            .foregroundColor: NSColor(SoulColor.fg),
        ]
        return NSAttributedString(string: s, attributes: attrs)
    }

    /// Split an NSAttributedString by "\n" into per-line AttributedStrings.
    /// Empty trailing line is preserved so a final newline still renders an
    /// empty row (matches Xcode behavior).
    private static func split(_ s: NSAttributedString) -> [AttributedString] {
        let ns = s.string as NSString
        var out: [AttributedString] = []
        var cursor = 0
        let total = ns.length
        while cursor <= total {
            let remaining = NSRange(location: cursor, length: total - cursor)
            let nl = ns.range(of: "\n", options: [], range: remaining)
            let end = nl.location == NSNotFound ? total : nl.location
            let lineRange = NSRange(location: cursor, length: end - cursor)
            let sub = s.attributedSubstring(from: lineRange)
            out.append(AttributedString(sub))
            if nl.location == NSNotFound { break }
            cursor = nl.location + nl.length
            if cursor == total {
                out.append(AttributedString(""))
                break
            }
        }
        return out
    }
}
