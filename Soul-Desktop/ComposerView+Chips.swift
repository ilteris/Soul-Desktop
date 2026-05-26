import SwiftUI
import AppKit

/// Composer chip family + slash-command palette lifted out of
/// ComposerView. These are all the small UI widgets that sit around the
/// text field: the harness/provider picker, attachment chips, the slash
/// command popover, run-local / branch / context / project / permission
/// chips. Each is a self-contained struct with no shared state beyond
/// the action callbacks ComposerView passes in.
///
/// Pure file shuffle, no behavior change. ComposerView refactor 2/N —
/// agent ergonomics: shrink ComposerView.swift below the threshold
/// where a coding agent can hold it in context.

/// Hoverable wrapper that pairs a ToolbarChip with the help tooltip.
/// Hover/active treatment + hit-area expansion are inherited from the
/// global SoulHoverButtonStyle applied at the app root.
/// When `isActive` is true, paints the accent hover bg permanently —
/// used while an external modal (file picker, dropdown menu) tied to
/// this button is open.
struct HoverableToolbarButton: View {
    let icon: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Icon-only — drop ToolbarChip's own padding/bg and let
            // SoulHoverButtonStyle (minSize 24 + padding 4) own the geometry
            // so the + matches every other icon-only toolbar button.
            // Tint accent when associated UI (file picker) is open.
            SoulIcon(name: icon, color: isActive ? SoulColor.accent : SoulColor.fgMuted)
        }
        .buttonStyle(SoulHoverButtonStyle(isActive: isActive))
        .help(help)
    }
}

struct ToolbarChip: View {
    let icon: String
    let label: String?
    var trailingChevron: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            SoulIcon(name: icon, color: SoulColor.fgMuted)
            if let label {
                Text(label)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            if trailingChevron {
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
            }
        }
        .padding(.horizontal, label == nil ? 4 : 8)
        .padding(.vertical, 4)
        // Label chips keep their muted surface background; icon-only chips
        // stay transparent so the SoulHoverButtonStyle hover layer is the
        // only background that renders (no double-bg under the +).
        .background(
            label == nil ? AnyShapeStyle(Color.clear) : AnyShapeStyle(SoulColor.surface.opacity(0.6)),
            in: Capsule()
        )
    }
}

private struct ProviderPicker: View {
    @Binding var selection: Provider

    var body: some View {
        Menu {
            ForEach(Provider.allCases) { p in
                Button { selection = p } label: {
                    VStack(alignment: .leading) {
                        HStack {
                            ProviderGlyph(provider: p)
                            Text(p.label)
                            if selection == p { Image(systemName: "checkmark") }
                        }
                        Text(p.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                ProviderGlyph(provider: selection)
                    .foregroundStyle(SoulColor.fgMuted)
                Text(selection.label)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgMuted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct AttachmentChipRow: View {
    let paths: [String]
    let onRemove: (String) -> Void
    @Environment(\.openFilePreview) private var openFilePreview

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    AttachmentChip(path: path,
                                   onOpen: { openFilePreview(path) },
                                   onRemove: { onRemove(path) })
                }
            }
        }
    }
}

private struct AttachmentChip: View {
    let path: String
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    private var name: String { (path as NSString).lastPathComponent }
    private var icon: String {
        let ext = (path as NSString).pathExtension.lowercased()
        let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        if images.contains(ext) { return "photo" }
        if ext == "pdf" { return "doc.richtext" }
        return "doc"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: SoulMetric.iconHint))
                .foregroundStyle(SoulColor.accent)
            Button(action: onOpen) {
                Text(name)
                    .font(SoulFont.code(11))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
            }
            .buttonStyle(.soulHover)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .buttonStyle(.soulHover)
            .opacity(hovering ? 1 : 0.5)
            .help("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SoulColor.accentMuted, in: Capsule())
        .overlay(
            Capsule().strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        // SOUL-SOUL_DESKTOP-182: pointing-hand cursor on attachment chip.
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended:  NSCursor.arrow.set()
            }
        }
        .help(path)
    }
}

struct CommandChip: View {
    let command: SlashCommand
    let onClear: () -> Void

    var body: some View {
        Text("/\(command.name)")
            .font(SoulFont.code(12, weight: .regular))
            .foregroundStyle(SoulColor.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SoulColor.accentMuted, in: Capsule())
            .overlay(
                Capsule().strokeBorder(SoulColor.accent.opacity(0.3), lineWidth: 0.5)
            )
            .help(command.description ?? "/\(command.name)")
    }
}

struct SlashCommandPalette: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(commands) { cmd in
                Button {
                    onSelect(cmd)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(cmd.name)")
                            .font(SoulFont.code(12, weight: .regular))
                            .foregroundStyle(SoulColor.fg)
                        if let hint = cmd.inputHint {
                            Text(hint)
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer(minLength: 12)
                        if let desc = cmd.description {
                            Text(desc)
                                .font(SoulFont.ui(11))
                                .foregroundStyle(SoulColor.fgMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.soulHover)
            }
        }
        .padding(6)
        .frame(width: 420)
    }
}

struct RunLocalChip: View {
    let isRunning: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                SoulIcon(
                    name: isRunning ? "stop.fill" : "play.fill",
                    size: 10,
                    color: isRunning ? .red : SoulColor.accent
                )
                Text(isRunning ? "Stop" : "Run locally")
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fg)
            }
            .background(
                (isRunning ? Color.red.opacity(0.12) : SoulColor.accentMuted),
                in: Capsule()
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulChip)
    }
}

struct BranchChip: View {
    let currentBranch: String
    let projectPath: String?
    var onSwitched: (String) -> Void
    @State private var branches: [String] = []
    @State private var checkoutError: String? = nil

    var body: some View {
        Menu {
            if branches.isEmpty {
                Text("Loading…")
            } else {
                ForEach(branches, id: \.self) { b in
                    Button {
                        switchTo(b)
                    } label: {
                        HStack {
                            if b == currentBranch { Image(systemName: "checkmark") }
                            Text(b)
                        }
                    }
                    .disabled(b == currentBranch)
                }
            }
            if let err = checkoutError {
                Divider()
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } label: {
            HStack(spacing: 4) {
                SoulIcon(name: "arrow.triangle.branch", size: SoulMetric.icon, color: SoulColor.fgMuted)
                Text(currentBranch).font(SoulFont.ui(13)).foregroundStyle(SoulColor.fgMuted)
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .task(id: projectPath ?? "") {
            branches = await GitInfo.localBranches(at: projectPath)
        }
    }

    private func switchTo(_ b: String) {
        Task {
            checkoutError = nil
            if let err = await GitInfo.checkout(branch: b, at: projectPath) {
                checkoutError = err.split(separator: "\n").first.map(String.init) ?? err
                return
            }
            onSwitched(b)
            branches = await GitInfo.localBranches(at: projectPath)
        }
    }
}

private struct ContextChip: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            SoulIcon(name: icon, size: SoulMetric.icon, color: SoulColor.fgMuted)
            Text(label).font(SoulFont.ui(12)).foregroundStyle(SoulColor.fgMuted)
            SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
        }
    }
}

struct ProjectChip: View {
    let currentName: String
    let projects: [SoulProject]
    let currentID: String
    let onSelect: (String) -> Void
    let onCreate: () -> Void

    var body: some View {
        Menu {
            ForEach(projects) { p in
                Button {
                    onSelect(p.id)
                } label: {
                    HStack {
                        if p.id == currentID { Image(systemName: "checkmark") }
                        Text(p.name)
                    }
                }
            }
            Divider()
            Button("New project…", action: onCreate)
        } label: {
            HStack(spacing: 4) {
                SoulIcon(name: "folder", size: SoulMetric.icon, color: SoulColor.fgMuted)
                Text(currentName).font(SoulFont.ui(13)).foregroundStyle(SoulColor.fgMuted)
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Composer-row chip exposing the umbrella permission mode for the active
/// thread. Tap to open a menu of `PermissionMode` choices; selection writes
/// straight through to the bound state and (via ThreadController didSet) to
/// the live ACP client policy.
struct PermissionModePicker: View {
    @Binding var mode: PermissionMode

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { m in
                Button {
                    mode = m
                } label: {
                    HStack {
                        Image(systemName: m.sfSymbol)
                        VStack(alignment: .leading) {
                            Text(m.label)
                            Text(m.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        if mode == m { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.sfSymbol)
                    .font(.system(size: SoulMetric.icon))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(mode.label)
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                SoulIcon(name: "chevron.down", size: SoulMetric.iconHint, color: SoulColor.fgSubtle)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SoulColor.surface.opacity(0.6), in: Capsule())
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.subtitle)
    }
}
