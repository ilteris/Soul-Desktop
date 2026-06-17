import SwiftUI

/// SOUL-249 spike: native SwiftUI `.toolbar` items lifted from the custom
/// CanvasToolbar HStack. Factored out of AppShell.body to keep the type
/// checker under the "too complex" cliff. The AppDelegate's NSToolbar
/// installer is gated off; if this spike fails (BarAppearanceBridge KVO
/// panic or items don't render), restore both that installer and the
/// CanvasToolbar(...) call inside AppShell+Canvas.mainCanvas.
extension AppShell {
    @ToolbarContentBuilder
    var mainToolbarContent: some ToolbarContent {
        principalTitleItem

        trailingChipsGroup
    }

    @ToolbarContentBuilder
    private var principalTitleItem: some ToolbarContent {
        if let thread, thread.sessionId != nil, !replay.isActive {
            ToolbarItem(id: "soul.title", placement: .principal) {
                ThreadTitleCluster(controller: thread)
                    .padding(.horizontal, 24)
            }
        }
    }

    @ToolbarContentBuilder
    private var trailingChipsGroup: some ToolbarContent {
        if let thread {
            ToolbarItem(id: "soul.chips", placement: .primaryAction) {
                HStack(spacing: 6) {
                    if let usage = contextUsage {
                        ContextUsageChip(usage: usage)
                    }
                    SessionStatsChip(controller: thread)
                    AgentLogChip(controller: thread)
                    let computerUseActivity = thread.computerUseActivity
                    Button(action: { toggleComputerUse() }) {
                        ComputerUseToolbarIcon(
                            isActive: computerUseActivity != nil,
                            isOpen: rightPane.computerUseVisible
                        )
                    }
                    .buttonStyle(.soulHover)
                    .help(computerUseActivity ?? "Open computer use")
                    ThreadOverflowMenu(
                        controller: thread,
                        onSmokeTest: { showSmoke = true },
                        onBranch: { provider in
                            branchFrom(thread, to: provider)
                        },
                        onReload: { reloadActiveSession() },
                        onForkWorktree: { forkActiveSessionIntoWorktree() }
                    )
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ComputerUseToolbarIcon: View {
    let isActive: Bool
    let isOpen: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: SoulMetric.icon, weight: .regular))
                .foregroundStyle((isActive || isOpen) ? SoulColor.accent : SoulColor.fgMuted)
                .frame(width: 22, height: 22)

            if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.45)
                    .frame(width: 9, height: 9)
                    .background(SoulColor.bgElevated, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: isActive ? "Computer use active" : "Open computer use"))
    }
}
