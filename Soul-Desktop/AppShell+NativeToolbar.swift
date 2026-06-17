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
                    Button(action: { toggleComputerUse() }) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: SoulMetric.icon, weight: .regular))
                            .foregroundStyle(rightPane.computerUseVisible ? SoulColor.accent : SoulColor.fgMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.soulHover)
                    .help("Open computer use")
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
