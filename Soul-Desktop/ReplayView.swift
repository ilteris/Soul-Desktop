import SwiftUI

/// Read-only replay surface: playback bar on top, item stream below.
/// No composer, no agent — purely client-side scroll through a finished session.
struct ReplayView: View {
    @Bindable var controller: ReplayController
    var onExit: () -> Void

    @AppStorage(SoulColor.accentStorageKey) private var _accentObserver: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            PlaybackBar(controller: controller, onExit: onExit)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Color.clear.frame(height: 8)
                        ForEach(Array(controller.visible.enumerated()), id: \.element.id) { i, item in
                            ThreadItemRow(item: item, isHistorical: false)
                                .id(item.id)
                                .padding(.top, ReplayView.isTurnStart(item: item, index: i, items: controller.visible) ? 10 : 0)
                        }
                        // Empty-state only when there is truly no transcript on disk.
                        // visible.isEmpty during the first tick is normal — don't
                        // confuse the user with a "not found" message in that window.
                        if controller.total == 0 {
                            VStack(spacing: 6) {
                                Text("No transcript")
                                    .font(SoulFont.ui(13, weight: .medium))
                                    .foregroundStyle(SoulColor.fgMuted)
                                Text("Session \(controller.sessionId.prefix(8))… has no Claude transcript under this project's cwd.")
                                    .font(SoulFont.ui(11))
                                    .foregroundStyle(SoulColor.fgSubtle)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 320)
                            }
                            .padding(.top, 32)
                        }
                        Color.clear.frame(height: 60).id("__bottom__")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
                .onChange(of: controller.visible.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    static func isTurnStart(item: ThreadItem, index: Int, items: [ThreadItem]) -> Bool {
        guard index > 0 else { return false }
        guard case .userMessage = item else { return false }
        if case .userMessage = items[index - 1] { return false }
        return true
    }
}
