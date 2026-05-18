import SwiftUI
import Combine

/// SOUL-SOUL_DESKTOP-054: hover-revealed project info card anchored to the
/// top-right of the canvas. Shows branch details, change counts, git actions,
/// PR status, and the files the active session/working-tree has touched.
///
/// The card hides itself when the pointer leaves both the trigger strip and
/// the card body. A pin in the top-right of the card flips it into sticky
/// mode so the user can keep it open while reading.
struct CanvasInfoOverlay: View {
    let projectPath: String?
    let projectName: String?
    let projectKey: String?

    @Environment(\.openFilePreview) private var openFilePreview

    @State private var hoveringStrip: Bool = false
    @State private var hoveringCard: Bool = false
    @State private var pinned: Bool = false
    @StateObject private var gitModel = GitReviewModel()
    @StateObject private var taskStore = ActiveTaskStore()

    private var isVisible: Bool {
        pinned || hoveringStrip || hoveringCard
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Invisible hover trigger, inset 16pt from the trailing edge so
            // the macOS overlay scrollbar gutter is hit-testable. Without the
            // inset this strip swallowed every click/drag in the scrollbar
            // zone — even when invisible — because `.onHover` needs hit
            // testing on, so we can't just blanket-disable it.
            Color.clear
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hoveringStrip = $0 }
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .allowsHitTesting(!isVisible || !pinned)

            if isVisible {
                card
                    .padding(.top, 8)
                    // Leave room for the canvas scrollbar — macOS overlay
                    // scrollbars sit ~15pt off the trailing edge and a stack
                    // of buttons in the toolbar above add their own gutter.
                    // 24pt keeps the bar fully reachable without dragging
                    // the overlay too far inboard.
                    .padding(.trailing, 24)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .onHover { hoveringCard = $0 }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isVisible)
        .onChange(of: projectPath) { _, new in
            gitModel.bind(projectPath: new)
        }
        .onChange(of: projectKey) { _, new in
            taskStore.bind(projectKey: new)
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                // SOUL-SOUL_DESKTOP-054: lazy PR fetch when card becomes visible.
                Task { await gitModel.fetchPRStatus() }
            }
        }
        .task {
            gitModel.bind(projectPath: projectPath)
            taskStore.bind(projectKey: projectKey)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !taskStore.criteria.isEmpty {
                progressSection
                Divider().background(SoulColor.border.opacity(0.4))
            }
            branchSection
            Divider().background(SoulColor.border.opacity(0.4))
            actionsSection
            if !gitModel.snapshot.untracked.isEmpty {
                Divider().background(SoulColor.border.opacity(0.4))
                artifactsSection
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SoulColor.surface.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(SoulColor.border.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
    }

    private var header: some View {
        HStack {
            Text("Project Status")
                .font(SoulFont.ui(11, weight: .regular))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            Button(action: { pinned.toggle() }) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinned ? SoulColor.accent : SoulColor.fgSubtle)
                    .rotationEffect(.degrees(pinned ? 0 : 45))
            }
            .buttonStyle(.soulHover)
            .help(pinned ? "Unpin" : "Keep this card open")
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Progress")
                    .font(SoulFont.ui(11, weight: .regular))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if let tid = taskStore.taskId {
                    Text(tid)
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgSubtle.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let s = taskStore.status, !s.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Self.statusColor(s))
                            .frame(width: 6, height: 6)
                        Text(s)
                            .font(SoulFont.code(10))
                            .foregroundStyle(SoulColor.fgSubtle.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
                let done = taskStore.criteria.filter { $0.done }.count
                let total = taskStore.criteria.count
                Text("\(done)/\(total)")
                    .font(SoulFont.code(10))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            ForEach(taskStore.criteria, id: \.text) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: c.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(c.done ? SoulColor.accent : SoulColor.fgMuted)
                        .frame(width: 14)
                        .padding(.top, 1)
                    Text(c.text)
                        .font(SoulFont.ui(12))
                        .foregroundStyle(c.done ? SoulColor.fgSubtle : SoulColor.fg)
                        .strikethrough(c.done, color: SoulColor.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func statusColor(_ status: String) -> Color {
        switch status {
        case "completed", "done", "closed":          return .green
        case "in_progress", "active", "in-progress": return SoulColor.accent
        case "blocked", "stalled":                   return .orange
        case "pending":                              return SoulColor.fgMuted
        default:                                     return SoulColor.fgMuted
        }
    }

    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plusminus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgMuted)
                Text("Changes")
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fg)
                Spacer(minLength: 8)
                if gitModel.snapshot.additions == 0 && gitModel.snapshot.deletions == 0 && gitModel.snapshot.untracked.isEmpty {
                    Text("clean")
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                } else {
                    HStack(spacing: 6) {
                        if gitModel.snapshot.additions > 0 {
                            Text("+\(gitModel.snapshot.additions)")
                                .font(SoulFont.code(11))
                                .foregroundStyle(Color.green.opacity(0.9))
                        }
                        if gitModel.snapshot.deletions > 0 {
                            Text("-\(gitModel.snapshot.deletions)")
                                .font(SoulFont.code(11))
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                        if !gitModel.snapshot.untracked.isEmpty && gitModel.snapshot.additions == 0 && gitModel.snapshot.deletions == 0 {
                             Text("\(gitModel.snapshot.untracked.count) files")
                                .font(SoulFont.code(11))
                                .foregroundStyle(SoulColor.fgSubtle)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(gitModel.snapshot.branch ?? "—")
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let pr = gitModel.snapshot.prStatus {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundStyle(SoulColor.fgMuted)
                    Text(pr)
                        .font(SoulFont.ui(12))
                        .foregroundStyle(SoulColor.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Git Actions")
                .font(SoulFont.ui(11, weight: .regular))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .tracking(0.5)
            
            HStack(spacing: 8) {
                ActionButton(
                    icon: "plus.square",
                    label: "Stage",
                    active: !gitModel.snapshot.untracked.isEmpty,
                    action: { Task { await gitModel.stageAll(); await gitModel.refresh() } }
                )
                ActionButton(
                    icon: "arrow.up.circle",
                    label: "Push",
                    active: gitModel.snapshot.branch != nil,
                    action: { Task { _ = await gitModel.push(); await gitModel.refresh() } }
                )
            }
        }
    }

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artifacts")
                .font(SoulFont.ui(11, weight: .regular))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .tracking(0.5)
            let shown = Array(gitModel.snapshot.untracked.prefix(8))
            ForEach(shown, id: \.self) { rel in
                ArtifactRow(
                    rel: rel,
                    icon: artifactIcon(rel),
                    onOpen: { openArtifact(rel) }
                )
            }
            if gitModel.snapshot.untracked.count > shown.count {
                Text("+\(gitModel.snapshot.untracked.count - shown.count) more")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .padding(.leading, 22)
            }
        }
    }

    private func openArtifact(_ rel: String) {
        guard let base = projectPath else { return }
        let full = (base as NSString).appendingPathComponent(rel)
        openFilePreview(full)
    }

    private func artifactIcon(_ rel: String) -> String {
        if rel.hasSuffix(".md") { return "doc.text" }
        if rel.hasSuffix(".json") { return "curlybraces" }
        if rel.hasSuffix(".swift") || rel.hasSuffix(".ts") || rel.hasSuffix(".tsx") || rel.hasSuffix(".js") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "shippingbox"
    }
}

private struct ActionButton: View {
    let icon: String
    let label: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(SoulFont.ui(12))
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? (hovering ? SoulColor.accent.opacity(0.2) : SoulColor.accent.opacity(0.1)) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? SoulColor.accent.opacity(0.3) : SoulColor.border.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.soulHover)
        .disabled(!active)
        .opacity(active ? 1.0 : 0.5)
        .onHover { hovering = $0 }
    }
}

/// Artifact list row with explicit hover affordance — background tint,
/// pointer cursor, and a chevron that only appears on hover so the resting
/// state stays quiet. Makes the row read as "click to open" rather than
/// a static text line.
private struct ArtifactRow: View {
    let rel: String
    let icon: String
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(hovering ? SoulColor.accent : SoulColor.fgMuted)
                    .frame(width: 14)
                Text((rel as NSString).lastPathComponent)
                    .font(SoulFont.code(12))
                    .foregroundStyle(hovering ? SoulColor.accent : SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundStyle(SoulColor.fgSubtle)
                    .opacity(hovering ? 1 : 0)
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering ? SoulColor.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.soulHover)
        .help("Open \(rel) in preview panel")
        .onHover { inside in
            hovering = inside
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
