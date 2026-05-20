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
