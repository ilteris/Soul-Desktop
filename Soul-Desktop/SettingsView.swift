import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, configuration, personalization, mcp, hooks, git, environments, worktrees, browser, computerUse, advanced, archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:        return "General"
        case .appearance:     return "Appearance"
        case .configuration:  return "Configuration"
        case .personalization:return "Personalization"
        case .mcp:            return "MCP servers"
        case .hooks:          return "Hooks"
        case .git:            return "Git"
        case .environments:   return "Environments"
        case .worktrees:      return "Worktrees"
        case .browser:        return "Browser"
        case .computerUse:    return "Computer use"
        case .advanced:       return "Advanced"
        case .archived:       return "Archived chats"
        }
    }

    var icon: String {
        switch self {
        case .general:         return "gearshape"
        case .appearance:      return "sun.max"
        case .configuration:   return "slider.horizontal.3"
        case .personalization: return "person.crop.circle"
        case .mcp:             return "shippingbox"
        case .hooks:           return "link"
        case .git:             return "arrow.triangle.branch"
        case .environments:    return "macwindow"
        case .worktrees:       return "rectangle.split.3x1"
        case .browser:         return "macwindow.on.rectangle"
        case .computerUse:     return "cursorarrow.rays"
        case .advanced:        return "wrench.and.screwdriver"
        case .archived:        return "archivebox"
        }
    }
}

struct SettingsView: View {
    @Binding var harness: Provider
    var onDismiss: () -> Void

    @State private var selected: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            ScrollView {
                paneContent
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(SoulColor.bg)
        }
        .frame(minWidth: 880, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .background(SoulColor.bg)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 11, weight: .regular))
                    Text("Back to app")
                        .font(SoulFont.ui(12))
                }
                .foregroundStyle(SoulColor.fgMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.soulHover)
            .keyboardShortcut(.cancelAction)
            .padding(.top, 38)
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPane.allCases) { pane in
                    Button { selected = pane } label: {
                        HStack(spacing: 8) {
                            SoulIcon(name: pane.icon, size: SoulMetric.icon, color: SoulColor.fgMuted)
                            Text(pane.label)
                                .font(SoulFont.ui(13))
                                .foregroundStyle(SoulColor.fg)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            selected == pane
                                ? AnyShapeStyle(SoulColor.surface)
                                : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: SoulMetric.radiusS)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.soulChip)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SoulColor.sidebar)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selected {
        case .general:         GeneralPane(harness: $harness)
        case .appearance:      AppearancePane()
        case .configuration:   ComingSoonPane(title: "Configuration", note: "Project-level overrides and prompt presets land here.")
        case .personalization: ComingSoonPane(title: "Personalization", note: "Custom system prompt, response style, and identity tuning.")
        case .mcp:             MCPServersPane()
        case .hooks:           HooksPane()
        case .git:             ComingSoonPane(title: "Git", note: "Per-project git defaults, signing, and remote auth.")
        case .environments:    ComingSoonPane(title: "Environments", note: "Sandboxed shell environments per harness.")
        case .worktrees:       ComingSoonPane(title: "Worktrees", note: "Tracked under SOUL-SOUL_DESKTOP-002. Manage forked worktrees from here once shipped.")
        case .browser:         ComingSoonPane(title: "Browser", note: "In-app browser pane for previewing changes.")
        case .computerUse:     ComingSoonPane(title: "Computer use", note: "Granular controls for screen + cursor automation.")
        case .advanced:        AdvancedPane()
        case .archived:        ComingSoonPane(title: "Archived chats", note: "Restore archived sessions from the registry.")
        }
    }
}

// MARK: - Advanced

/// SOUL-SOUL_DESKTOP-024: per-provider stall budgets + auto-cancel ceiling.
/// Steppers are bounded to keep the watchdog timer honest — sub-30s budgets
/// would trip the capsule on normal tool-call latency; ceilings under 60s
/// risk killing legitimate long-running turns before the agent recovers.
private struct AdvancedPane: View {
    @AppStorage("soul.stall.budget.geminiCLI") private var geminiBudget: Int = 240
    @AppStorage("soul.stall.budget.claude")    private var claudeBudget: Int = 180
    @AppStorage("soul.stall.budget.pi")        private var piBudget: Int = 300
    @AppStorage("soul.stall.autoCancelCeiling") private var autoCancelCeiling: Int = 900
    @AppStorage("soul.toolCallTimeout.seconds") private var toolCallTimeout: Int = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PaneHeader(title: "Advanced",
                       subtitle: "Operational thresholds the watchdog uses to surface stall recovery.")

            SectionHeader("Stall budgets",
                          subtitle: "Per-provider seconds of agent silence before the Recover capsule appears and a StallDetected hook is written to hooks.jsonl.")

            StepperRow(title: "Gemini-CLI",
                       description: "Default 90s. Higher than Claude because gemini-cli's tool-call streams routinely run long on bigger repos.",
                       value: $geminiBudget,
                       range: 30...600,
                       suffix: "seconds")
            StepperRow(title: "Claude",
                       description: "Default 60s. Claude's most common stall mode is the end-of-turn omission after \"waiting for your go-ahead\" replies.",
                       value: $claudeBudget,
                       range: 30...600,
                       suffix: "seconds")
            StepperRow(title: "Pi",
                       description: "Default 120s. Pi's local-agent turns trend slower; keep this conservative until we have more signal.",
                       value: $piBudget,
                       range: 30...600,
                       suffix: "seconds")

            SectionHeader("Auto-recover",
                          subtitle: "Hard ceiling on agent silence before the watchdog cancels the turn for you. Independent of per-provider budgets.")

            StepperRow(title: "Auto-cancel ceiling",
                       description: "Default 300s (5 min). Set to a high value to disable; the manual Recover capsule still works.",
                       value: $autoCancelCeiling,
                       range: 60...3600,
                       suffix: "seconds")

            SectionHeader("Tool-call timeout",
                          subtitle: "Independent of the per-turn budgets above: any single tool call that sits in_progress past this threshold gets force-stopped, a ToolCallTimeout hook is written, and the turn is cancelled. Catches the `tail -f` / streaming-follow case where a hung tool keeps the turn from resolving.")

            StepperRow(title: "Per-tool-call timeout",
                       description: "Default 60s. Each in-flight tool call has its own deadline; only the stuck call gets stopped, not all of them.",
                       value: $toolCallTimeout,
                       range: 10...1800,
                       suffix: "seconds")
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Binding var harness: Provider

    @AppStorage("soul.workMode")          private var workMode: String = "coding"
    @AppStorage("soul.defaultPermissions") private var defaultPermissions: Bool = true
    @AppStorage("soul.autoReview")        private var autoReview: Bool = true
    @AppStorage("soul.fullAccess")        private var fullAccess: Bool = false
    @AppStorage("soul.defaultEditor")     private var defaultEditor: String = "vscode"
    @AppStorage("soul.language")          private var language: String = "auto"
    @AppStorage("soul.showInMenuBar")     private var showInMenuBar: Bool = true
    @AppStorage("soul.preventSleep")      private var preventSleep: Bool = false
    @AppStorage("soul.requireCmdEnter")   private var requireCmdEnter: Bool = false
    @AppStorage("soul.followUpBehavior")  private var followUpBehavior: String = "queue"
    @AppStorage("soul.codeReviewMode")    private var codeReviewMode: String = "inline"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(title: "General")

            SectionHeader("Work mode", subtitle: "Choose how much technical detail Soul shows")
            HStack(spacing: 10) {
                WorkModeCard(
                    icon: "terminal",
                    title: "For coding",
                    subtitle: "More technical responses",
                    selected: workMode == "coding",
                    onTap: { workMode = "coding" }
                )
                WorkModeCard(
                    icon: "bubble.left.and.bubble.right",
                    title: "For everyday work",
                    subtitle: "Same power, less technical",
                    selected: workMode == "everyday",
                    onTap: { workMode = "everyday" }
                )
            }

            SectionHeader("Default harness")
            SettingRow(
                title: "Active harness",
                description: "Used when starting a new chat. Picking a different one in the toolbar still works."
            ) {
                Picker("", selection: $harness) {
                    ForEach(Provider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }

            SectionHeader("Permissions")
            VStack(spacing: 0) {
                ToggleRow(
                    title: "Default permissions",
                    description: "By default, Soul can read and edit files in its workspace. It can ask for additional access when needed.",
                    value: $defaultPermissions
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Auto-review",
                    description: "Soul automatically reviews requests for additional access. Auto-review can make mistakes.",
                    value: $autoReview
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Full access",
                    description: "When Soul runs with full access, it can edit any file on your computer and run commands with network, without your approval. This significantly increases the risk of data loss, leaks, or unexpected behavior.",
                    value: $fullAccess,
                    danger: true
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))

            SectionHeader("General")
            VStack(spacing: 0) {
                MenuRow(
                    title: "Default open destination",
                    description: "Where files and folders open by default",
                    selection: $defaultEditor,
                    options: [
                        ("vscode", "VS Code"),
                        ("cursor", "Cursor"),
                        ("xcode",  "Xcode"),
                        ("finder", "Finder")
                    ]
                )
                Divider().padding(.leading, 14)
                MenuRow(
                    title: "Language",
                    description: "Language for the app UI",
                    selection: $language,
                    options: [("auto", "Auto Detect"), ("en", "English")]
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Show in menu bar",
                    description: "Keep Soul in the macOS menu bar when the main window is closed",
                    value: $showInMenuBar
                )
                Divider().padding(.leading, 14)
                StaticActionRow(
                    title: "Popout Window hotkey",
                    description: "Set a global shortcut for Popout Window. Leave unset to keep it off.",
                    actionLabel: "Off",
                    actionButton: "Set",
                    disabled: true
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Prevent sleep while running",
                    description: "Keep your computer awake while Soul is running a chat",
                    value: $preventSleep
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Require ⌘ + enter to send long prompts",
                    description: "When enabled, multiline prompts require ⌘ + enter to send.",
                    value: $requireCmdEnter
                )
                Divider().padding(.leading, 14)
                SegmentedRow(
                    title: "Follow-up behavior",
                    description: "Queue follow-ups while Soul runs or steer the current run. Press ⌘Enter to do the opposite for one message.",
                    selection: $followUpBehavior,
                    options: [("queue", "Queue"), ("steer", "Steer")]
                )
                Divider().padding(.leading, 14)
                SegmentedRow(
                    title: "Code review",
                    description: "Start /review in the current chat when possible or launch a separate review chat",
                    selection: $codeReviewMode,
                    options: [("inline", "Inline"), ("detached", "Detached")]
                )
                Divider().padding(.leading, 14)
                StaticActionRow(
                    title: "Import work from other AI apps",
                    description: "Bring over your setup, projects, and recent chats",
                    actionLabel: nil,
                    actionButton: "Import",
                    disabled: true
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage("soul.uiFontSize")    private var uiFontSize: Int = 13
    @AppStorage("soul.codeFontSize")  private var codeFontSize: Int = 13
    @AppStorage("soul.fontSmoothing") private var fontSmoothing: Bool = true
    @AppStorage("soul.pointerCursors")private var pointerCursors: Bool = true
    @AppStorage(SoulColor.accentStorageKey) private var accentHex: Int = Int(SoulColor.defaultAccentHex)
    @AppStorage("soul.appearance") private var appearancePref: String = "system"

    private let presets: [(label: String, hex: UInt32)] = [
        ("Mauve",   0x8839EF),
        ("Blue",    0x1E66F5),
        ("Teal",    0x179299),
        ("Green",   0x40A02B),
        ("Peach",   0xFE640B),
        ("Red",     0xD20F39),
        ("Pink",    0xEA76CB)
    ]

    private var accentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: UInt32(accentHex == 0 ? Int(SoulColor.defaultAccentHex) : accentHex)) },
            set: { accentHex = Int(Color.toHex($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PaneHeader(title: "Appearance")

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Accent color")
                Text("Used for selection highlights, the active toolbar pill, and submit buttons.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)

                HStack(spacing: 10) {
                    ForEach(presets, id: \.hex) { preset in
                        Button {
                            accentHex = Int(preset.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        UInt32(accentHex) == preset.hex ? SoulColor.fg : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.soulHover)
                        .help(preset.label)
                    }
                    Divider().frame(height: 22)
                    ColorPicker("", selection: accentBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30)
                    Button("Reset") { accentHex = Int(SoulColor.defaultAccentHex) }
                        .buttonStyle(.borderless)
                        .font(SoulFont.ui(11))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Appearance")
                Text("Choose whether the UI follows your system appearance or stays on one side.")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                Picker("", selection: $appearancePref) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)
            }

            VStack(spacing: 0) {
                ToggleRow(
                    title: "Use pointer cursors",
                    description: "Change the cursor to a pointer when hovering over interactive elements",
                    value: $pointerCursors
                )
                Divider().padding(.leading, 14)
                StepperRow(
                    title: "UI font size",
                    description: "Adjust the base size used for the Soul UI",
                    value: $uiFontSize,
                    range: 11...18,
                    suffix: "px"
                )
                Divider().padding(.leading, 14)
                StepperRow(
                    title: "Code font size",
                    description: "Adjust the base size used for code across chats and diffs",
                    value: $codeFontSize,
                    range: 10...18,
                    suffix: "px"
                )
                Divider().padding(.leading, 14)
                ToggleRow(
                    title: "Font Smoothing",
                    description: "Use native macOS font anti-aliasing",
                    value: $fontSmoothing
                )
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - MCP servers

private struct MCPServersPane: View {
    @State private var servers: [MCPEntry] = []

    struct MCPEntry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let command: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "MCP servers", subtitle: "Read from ~/.claude/.claude.json and ~/.gemini/settings.json")

            if servers.isEmpty {
                EmptyHint(text: "No MCP servers detected.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element) { idx, s in
                        if idx > 0 { Divider().padding(.leading, 14) }
                        HStack(spacing: 10) {
                            SoulIcon(name: "shippingbox", size: SoulMetric.icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name)
                                    .font(SoulFont.ui(13, weight: .regular))
                                    .foregroundStyle(SoulColor.fg)
                                Text(s.command)
                                    .font(SoulFont.code(11))
                                    .foregroundStyle(SoulColor.fgSubtle)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
            }
        }
        .task { servers = MCPDiscovery.scan() }
    }
}

fileprivate enum MCPDiscovery {
    static func scan() -> [MCPServersPane.MCPEntry] {
        var out: [MCPServersPane.MCPEntry] = []
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.claude/.claude.json",
            "\(home)/.gemini/settings.json"
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard let servers = json["mcpServers"] as? [String: [String: Any]] else { continue }
            for (name, cfg) in servers {
                let cmd = cfg["command"] as? String ?? ""
                let args = (cfg["args"] as? [String])?.joined(separator: " ") ?? ""
                out.append(.init(name: name, command: [cmd, args].filter { !$0.isEmpty }.joined(separator: " ")))
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}

// MARK: - Hooks

private struct HooksPane: View {
    private struct HookKind: Hashable {
        let name: String
        let detail: String
    }

    private let kinds: [HookKind] = [
        .init(name: "PreToolUse",        detail: "Before a tool executes"),
        .init(name: "PermissionRequest", detail: "When permission is requested"),
        .init(name: "PostToolUse",       detail: "After a tool executes"),
        .init(name: "SessionStart",      detail: "When a new session starts"),
        .init(name: "UserPromptSubmit",  detail: "When the user submits a prompt"),
        .init(name: "Stop",              detail: "Right before Soul ends its turn")
    ]

    @State private var counts: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: "Hooks", subtitle: "Manage lifecycle hooks from ~/.claude/settings.json and enabled plugins")

            VStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { idx, k in
                    if idx > 0 { Divider().padding(.leading, 14) }
                    HStack(spacing: 10) {
                        SoulIcon(name: "link", size: SoulMetric.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name).font(SoulFont.ui(13, weight: .regular)).foregroundStyle(SoulColor.fg)
                            Text(k.detail).font(SoulFont.ui(11)).foregroundStyle(SoulColor.fgSubtle)
                        }
                        Spacer()
                        Text("\(counts[k.name, default: 0]) installed")
                            .font(SoulFont.ui(11))
                            .foregroundStyle(SoulColor.fgSubtle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
        .task { counts = HookDiscovery.scan() }
    }
}

enum HookDiscovery {
    static func scan() -> [String: Int] {
        var out: [String: Int] = [:]
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else { return out }
        for (name, val) in hooks {
            if let arr = val as? [Any] {
                out[name] = arr.count
            } else if val is [String: Any] {
                out[name] = 1
            }
        }
        return out
    }
}

// MARK: - Coming soon

private struct ComingSoonPane: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PaneHeader(title: title)
            HStack(spacing: 10) {
                SoulIcon(name: "hourglass", size: SoulMetric.iconLarge)
                Text(note)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - Reusable rows

private struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(SoulFont.hero(20))
                .foregroundStyle(SoulColor.fg)
            if let subtitle {
                Text(subtitle)
                    .font(SoulFont.ui(12))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(SoulFont.ui(13, weight: .regular))
                .foregroundStyle(SoulColor.fg)
            if let subtitle {
                Text(subtitle)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
        .padding(.bottom, 2)
    }
}

private struct WorkModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                SoulIcon(name: icon, size: SoulMetric.iconLarge)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SoulFont.ui(13, weight: .regular))
                        .foregroundStyle(SoulColor.fg)
                    Text(subtitle)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Circle()
                    .strokeBorder(selected ? SoulColor.accent : SoulColor.border, lineWidth: selected ? 5 : 1)
                    .frame(width: 12, height: 12)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? SoulColor.accent.opacity(0.5) : SoulColor.border.opacity(0.4), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulChip)
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SoulFont.ui(13, weight: .regular))
                    .foregroundStyle(SoulColor.fg)
                if let description {
                    Text(description)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct ToggleRow: View {
    let title: String
    let description: String
    @Binding var value: Bool
    var danger: Bool = false

    var body: some View {
        SettingRow(title: title, description: description) {
            Toggle("", isOn: $value)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(danger ? .orange : SoulColor.accent)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let description: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SettingRow(title: title, description: description) {
            Picker("", selection: $selection) {
                ForEach(options, id: \.0) { (key, label) in
                    Text(label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
        }
    }
}

private struct SegmentedRow: View {
    let title: String
    let description: String
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 0) {
                ForEach(options, id: \.0) { (key, label) in
                    Button { selection = key } label: {
                        Text(label)
                            .font(SoulFont.ui(11, weight: .regular))
                            .foregroundStyle(selection == key ? SoulColor.fg : SoulColor.fgMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selection == key
                                    ? AnyShapeStyle(SoulColor.surface)
                                    : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.soulChip)
                }
            }
            .padding(2)
            .background(SoulColor.bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
        }
    }
}

private struct StepperRow: View {
    let title: String
    let description: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 4) {
                Stepper(value: $value, in: range) {
                    Text("\(value)")
                        .font(SoulFont.code(12))
                        .frame(width: 28, alignment: .trailing)
                }
                .labelsHidden()
                Text(suffix)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
            }
        }
    }
}

private struct StaticActionRow: View {
    let title: String
    let description: String
    let actionLabel: String?
    let actionButton: String
    let disabled: Bool

    var body: some View {
        SettingRow(title: title, description: description) {
            HStack(spacing: 8) {
                if let actionLabel {
                    Text(actionLabel)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                Button(actionButton) {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(disabled)
            }
        }
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            SoulIcon(name: "tray", size: SoulMetric.icon)
            Text(text)
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SoulColor.border.opacity(0.4), lineWidth: 1))
    }
}
