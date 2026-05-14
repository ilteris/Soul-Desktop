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

    @Environment(\.openFilePreview) private var openFilePreview

    @State private var hoveringStrip: Bool = false
    @State private var hoveringCard: Bool = false
    @State private var pinned: Bool = false
    @StateObject private var model = CanvasInfoModel()

    private var isVisible: Bool {
        pinned || hoveringStrip || hoveringCard
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Invisible hover trigger — a 28pt strip glued to the right edge.
            // We keep it allowsHitTesting(true) but transparent so the
            // toolbar buttons sitting above it (rendered earlier in the Z
            // order) still receive their own clicks.
            Color.clear
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { hoveringStrip = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .allowsHitTesting(!isVisible || !pinned)

            if isVisible {
                card
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .onHover { hoveringCard = $0 }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isVisible)
        .onChange(of: projectPath) { _, new in
            model.bind(projectPath: new)
        }
        .task { model.bind(projectPath: projectPath) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            branchSection
            if !model.artifacts.isEmpty {
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
            Text("Branch details")
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
            .buttonStyle(.plain)
            .help(pinned ? "Unpin" : "Keep this card open")
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
                if model.additions == 0 && model.deletions == 0 {
                    Text("clean")
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgSubtle)
                } else {
                    HStack(spacing: 6) {
                        Text("+\(model.additions)")
                            .font(SoulFont.code(11))
                            .foregroundStyle(Color.green.opacity(0.9))
                        Text("-\(model.deletions)")
                            .font(SoulFont.code(11))
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgMuted)
                Text(model.branch ?? "—")
                    .font(SoulFont.ui(13))
                    .foregroundStyle(SoulColor.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let pr = model.prSummary {
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

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artifacts")
                .font(SoulFont.ui(11, weight: .regular))
                .foregroundStyle(SoulColor.fgSubtle)
                .textCase(.uppercase)
                .tracking(0.5)
            let shown = Array(model.artifacts.prefix(8))
            ForEach(shown, id: \.self) { rel in
                Button(action: { openArtifact(rel) }) {
                    HStack(spacing: 8) {
                        Image(systemName: artifactIcon(rel))
                            .font(.system(size: 11))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(width: 14)
                        Text((rel as NSString).lastPathComponent)
                            .font(SoulFont.code(12))
                            .foregroundStyle(SoulColor.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(rel)
            }
            if model.artifacts.count > shown.count {
                Text("+\(model.artifacts.count - shown.count) more")
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

@MainActor
final class CanvasInfoModel: ObservableObject {
    @Published private(set) var branch: String? = nil
    @Published private(set) var additions: Int = 0
    @Published private(set) var deletions: Int = 0
    @Published private(set) var artifacts: [String] = []
    @Published private(set) var prSummary: String? = nil

    private var boundPath: String? = nil
    private var refreshTimer: Timer? = nil

    func bind(projectPath: String?) {
        guard projectPath != boundPath else { return }
        boundPath = projectPath
        branch = nil
        additions = 0
        deletions = 0
        artifacts = []
        prSummary = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard let path = projectPath, !path.isEmpty else { return }
        Task { await refresh(path: path) }
        // Poll lightly so the card stays current while the user hovers.
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let p = self.boundPath else { return }
                await self.refresh(path: p)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func refresh(path: String) async {
        let snap = await Task.detached(priority: .utility) { CanvasInfoModel.compute(at: path) }.value
        branch = snap.branch
        additions = snap.additions
        deletions = snap.deletions
        artifacts = snap.artifacts
        // PR fetch is independent and slower — only kick it once per bind to
        // keep the gh subprocess off the 5-second refresh loop.
        if prSummary == nil {
            let pr = await Task.detached(priority: .utility) { CanvasInfoModel.fetchPR(at: path) }.value
            if path == boundPath { prSummary = pr }
        }
    }

    private struct Snap {
        var branch: String? = nil
        var additions: Int = 0
        var deletions: Int = 0
        var artifacts: [String] = []
    }

    nonisolated private static func compute(at path: String) -> Snap {
        var s = Snap()
        s.branch = runCapture("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        if let diffStat = runCapture("git", ["-C", path, "diff", "--numstat", "HEAD"], allowEmpty: true) {
            for line in diffStat.split(separator: "\n") {
                let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cols.count >= 2 else { continue }
                let add = Int(cols[0]) ?? 0
                let del = Int(cols[1]) ?? 0
                s.additions += add
                s.deletions += del
            }
        }
        if let status = runCapture("git", ["-C", path, "status", "--porcelain"], allowEmpty: true) {
            var out: [String] = []
            for line in status.split(separator: "\n", omittingEmptySubsequences: true) {
                // porcelain v1: "XY path" (possibly "R old -> new")
                let str = String(line)
                guard str.count > 3 else { continue }
                var rest = String(str.dropFirst(3))
                if let arrow = rest.range(of: " -> ") {
                    rest = String(rest[arrow.upperBound...])
                }
                out.append(rest)
            }
            s.artifacts = out
        }
        return s
    }

    nonisolated private static func fetchPR(at path: String) -> String? {
        // `gh pr view --json state,number,title` returns the current branch's PR.
        guard let raw = runCapture("gh", ["-C", path, "pr", "view", "--json", "state,number,title"]) else {
            return "no PR for this branch"
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let state = (obj["state"] as? String) ?? "OPEN"
        let number = obj["number"] as? Int ?? 0
        let title = (obj["title"] as? String) ?? ""
        return "#\(number) · \(state.capitalized) · \(title)"
    }

    nonisolated private static func runCapture(_ tool: String, _ args: [String], allowEmpty: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8) ?? ""
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !allowEmpty && trimmed.isEmpty { return nil }
        return allowEmpty ? s : trimmed
    }
}
