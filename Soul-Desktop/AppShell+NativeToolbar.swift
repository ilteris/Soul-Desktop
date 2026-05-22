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

        rightPaneToggleItem
    }

    @ToolbarContentBuilder
    private var rightPaneToggleItem: some ToolbarContent {
        // Only show the right-pane toggle when a thread is active. On the
        // hero / empty state there's nothing reviewable, so the toggle is
        // chrome with no purpose.
        if thread != nil {
            ToolbarItem(id: "soul.right", placement: .primaryAction) {
                Button(action: toggleReview) {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(SoulColor.fgMuted)
                }
                .buttonStyle(.plain)
                .help("Toggle right pane")
                .padding(.trailing, 16)
            }
        }
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
                    ThreadOverflowMenu(
                        controller: thread,
                        onSmokeTest: { showSmoke = true },
                        onBranch: { provider in
                            branchFrom(thread, to: provider)
                        },
                        onReload: { reloadActiveSession() }
                    )
                }
                .padding(.horizontal, 16)
            }
        }
    }
}
