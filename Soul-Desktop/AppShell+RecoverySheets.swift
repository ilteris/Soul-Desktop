import SwiftUI
import AppKit

extension AppShell {
    @ViewBuilder
    func externalLiveSessionSheet(_ session: SoulSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(SoulColor.accent)
                Text(session.writer == .external ? "Session is running elsewhere" : "Session can't be loaded here")
                    .font(SoulFont.ui(15)).bold()
            }
            Text(session.writer == .external
                ? "This chat is being driven by a terminal Claude/Gemini/Pi/Codex session, not by Soul-Desktop. Loading it here would spawn a second writer on the same session and stream the entire transcript back. You can open it in read-only Replay instead."
                : "The agent transcript for this session isn't available on disk — it may have been rotated out, force-quit, or never written. You can replay the kernel hooks ledger (prompts + decisions) in read-only mode.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                let rawTitle = (session.title ?? session.intent ?? session.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = SoulRegistry.stripCommandTags(rawTitle)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    Text(title)
                        .font(SoulFont.ui(12)).bold()
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(session.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Cancel") { externalLiveSession = nil }
                Spacer()
                Button("Open Replay") {
                    externalLiveSession = nil
                    startReplay(session)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    @ViewBuilder
    func corruptedSessionSheet(_ ctx: ThreadController.RecoveryContext) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.orange)
                Text("Session can't be resumed")
                    .font(SoulFont.ui(15)).bold()
            }
            Text("Gemini-CLI couldn't parse this session's chat file — most likely the app was force-quit while it was being written. Your conversation is safe in the backup; pick how you'd like to continue.")
                .font(SoulFont.ui(12))
                .foregroundStyle(SoulColor.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    Text(ctx.sessionId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SoulColor.fgMuted)
                }
                HStack(alignment: .top) {
                    Text("Parser said")
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                    Text(ctx.rpcMessage)
                        .font(SoulFont.ui(11))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Replay (read-only)") {
                    let cap = ctx
                    thread?.pendingRecovery = nil
                    if let project = currentProject(),
                       let session = synthesizeSessionRow(forContext: cap, project: project) {
                        startReplay(session)
                    }
                }
                Button("Reveal backup in Finder") {
                    let url = URL(fileURLWithPath: ctx.backupPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Spacer()
                Button("Start fresh chat") {
                    let projectId = thread?.project.id
                    thread?.pendingRecovery = nil
                    if let key = sessions.activeThreadKey {
                        closeThread(key)
                    }
                    newChat(targetProjectID: projectId)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }

    func synthesizeSessionRow(forContext ctx: ThreadController.RecoveryContext, project: SoulProject) -> SoulSession? {
        SoulSession(
            id: ctx.sessionId,
            project: project.id,
            timestamp: Date(),
            title: ctx.title,
            source: "gemini",
            isLive: true,
            writer: .soulDesktop
        )
    }
}
