import SwiftUI
import AppKit

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

    @State private var content: String = ""
    @State private var loadError: String? = nil
    @State private var truncated: Bool = false
    @State private var binary: Bool = false

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
            header
            Divider().opacity(0.4)
            body(for: ext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SoulColor.bg)
        .task(id: path) { load() }
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
                .buttonStyle(.plain)
                .help("Open externally")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.plain)
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
        } else if ext == "md" || ext == "markdown" {
            ScrollView {
                MarkdownView(text: content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(content)
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 1 MB cap. Above that we slice and flag truncated. Detects binary by
    /// sniffing for null bytes in the head; saves us from dumping a render
    /// of an .o or .pdf into the panel.
    private func load() {
        content = ""
        loadError = nil
        truncated = false
        binary = false
        let cap = 1_048_576
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "File not found at \(url.path)"
            return
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = handle.readData(ofLength: cap + 1)
            truncated = data.count > cap
            let slice = truncated ? data.prefix(cap) : data
            if slice.contains(0) {
                binary = true
                return
            }
            content = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
            if truncated {
                content += "\n\n… (file truncated at 1 MB — open externally for full content)"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}
