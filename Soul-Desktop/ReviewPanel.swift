import SwiftUI

struct ReviewPanel: View {
    let projectPath: String?
    var onClose: () -> Void

    @StateObject private var model = GitReviewModel()
    @State private var collapsed: Set<UUID> = []
    @State private var collapseAll = false
    @State private var showCommit = false
    @State private var showCreateBranch = false
    @State private var actionMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(SoulColor.border.opacity(0.5))
            branchBar
            Divider().background(SoulColor.border.opacity(0.5))
            content
        }
        .frame(minWidth: 380, idealWidth: 460)
        .background(SoulColor.bg)
        .task(id: projectPath ?? "") { model.bind(projectPath: projectPath) }
        .sheet(isPresented: $showCommit) {
            CommitSheet { msg in
                showCommit = false
                Task {
                    let r = await model.commit(message: msg)
                    handle(r, ok: "Committed.")
                    await model.refresh()
                }
            } onCancel: { showCommit = false }
        }
        .sheet(isPresented: $showCreateBranch) {
            CreateBranchSheet { name in
                showCreateBranch = false
                Task {
                    let r = await model.createBranch(name: name)
                    handle(r, ok: "Branch created.")
                    await model.refresh()
                }
            } onCancel: { showCreateBranch = false }
        }
        .overlay(alignment: .bottom) {
            if let msg = actionMessage {
                Text(msg)
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fg)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(SoulColor.bgElevated, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(SoulColor.border, lineWidth: 0.5))
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 11))
                .foregroundStyle(SoulColor.fgMuted)
            Text("Review")
                .font(SoulFont.ui(12, weight: .medium))
                .foregroundStyle(SoulColor.fg)
            Spacer()
            Button(action: { Task { await model.refresh() } }) {
                Image(systemName: model.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.accent)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(SoulColor.accentMuted))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SoulColor.bg)
    }

    private var branchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("Branch")
                    .font(SoulFont.ui(11))
                    .foregroundStyle(SoulColor.fgMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(SoulColor.fgSubtle)
            }
            if model.snapshot.additions > 0 || model.snapshot.deletions > 0 {
                Text("+\(model.snapshot.additions)")
                    .font(SoulFont.code(11, weight: .medium))
                    .foregroundStyle(diffAddColor)
                Text("-\(model.snapshot.deletions)")
                    .font(SoulFont.code(11, weight: .medium))
                    .foregroundStyle(diffDelColor)
            }
            HStack(spacing: 4) {
                Text(model.snapshot.branch ?? "—")
                    .font(SoulFont.code(11, weight: .medium))
                    .foregroundStyle(SoulColor.fg)
                if let up = model.snapshot.upstream {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(SoulColor.fgSubtle)
                    Text(up)
                        .font(SoulFont.code(11))
                        .foregroundStyle(SoulColor.fgMuted)
                }
            }
            Spacer()
            optionsMenu
            actionsMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(SoulColor.bg)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Refresh") { Task { await model.refresh() } }
            Button(collapseAll ? "Expand all diffs" : "Collapse all diffs") { toggleCollapseAll() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var actionsMenu: some View {
        Menu {
            Button {
                showCommit = true
            } label: { Label("Commit", systemImage: "checkmark.circle") }
                .disabled(model.snapshot.files.isEmpty)
            Button {
                Task {
                    let r = await model.push()
                    handle(r, ok: "Pushed.")
                }
            } label: { Label("Push", systemImage: "arrow.up.circle") }
            Button {
                Task {
                    let r = await model.openCreatePR()
                    handle(r, ok: "Opened PR draft.")
                }
            } label: { Label("Create PR", systemImage: "arrow.triangle.pull") }
            Button {
                showCreateBranch = true
            } label: { Label("Create branch", systemImage: "arrow.triangle.branch") }
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(SoulColor.fgMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if model.projectPath == nil {
            placeholder("No project selected.")
        } else if let err = model.lastError {
            placeholder(err)
        } else if model.snapshot.files.isEmpty {
            placeholder(model.isLoading ? "Loading…" : "No changes.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.snapshot.files) { file in
                        fileBlock(file)
                        Divider().background(SoulColor.border.opacity(0.4))
                    }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(SoulFont.ui(11)).foregroundStyle(SoulColor.fgMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func fileBlock(_ file: GitDiffFile) -> some View {
        let isCollapsed = collapsed.contains(file.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isCollapsed { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
            } label: {
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(SoulFont.code(11, weight: .medium))
                        .foregroundStyle(SoulColor.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.additions > 0 {
                        Text("+\(file.additions)").font(SoulFont.code(10)).foregroundStyle(diffAddColor)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)").font(SoulFont.code(10)).foregroundStyle(diffDelColor)
                    }
                    if file.isNew { tag("new") }
                    if file.isDeleted { tag("del") }
                    if file.isRenamed { tag("ren") }
                    if file.isBinary { tag("binary") }
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9))
                        .foregroundStyle(SoulColor.fgSubtle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(SoulColor.bg)

            if !isCollapsed && !file.isBinary {
                ForEach(file.hunks) { hunk in
                    hunkView(hunk)
                }
            }
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s)
            .font(SoulFont.ui(9, weight: .medium))
            .foregroundStyle(SoulColor.fgMuted)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(SoulColor.surface, in: RoundedRectangle(cornerRadius: 3))
    }

    private func hunkView(_ hunk: GitDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(line.oldNo.map { String($0) } ?? "")
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .frame(width: 36, alignment: .trailing)
                    Text(line.newNo.map { String($0) } ?? "")
                        .font(SoulFont.code(10))
                        .foregroundStyle(SoulColor.fgSubtle)
                        .frame(width: 36, alignment: .trailing)
                        .padding(.trailing, 8)
                    Text(prefix(for: line.kind) + line.text)
                        .font(SoulFont.code(11))
                        .foregroundStyle(textColor(for: line.kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
                .background(rowBg(for: line.kind))
            }
        }
    }

    // MARK: - Style helpers

    private var diffAddColor: Color { Color(hex: 0x40A02B) }
    private var diffDelColor: Color { Color(hex: 0xD20F39) }

    private func prefix(for kind: GitLineKind) -> String {
        switch kind {
        case .add: return "+ "
        case .del: return "- "
        case .context: return "  "
        case .hunk: return ""
        }
    }
    private func textColor(for kind: GitLineKind) -> Color {
        switch kind {
        case .add: return diffAddColor
        case .del: return diffDelColor
        case .context: return SoulColor.fg
        case .hunk: return SoulColor.fgMuted
        }
    }
    private func rowBg(for kind: GitLineKind) -> Color {
        switch kind {
        case .add: return Color(hex: 0x40A02B).opacity(0.10)
        case .del: return Color(hex: 0xD20F39).opacity(0.10)
        default:   return Color.clear
        }
    }

    private func toggleCollapseAll() {
        collapseAll.toggle()
        if collapseAll {
            collapsed = Set(model.snapshot.files.map(\.id))
        } else {
            collapsed.removeAll()
        }
    }

    private func handle(_ r: Result<Void, GitError>, ok: String) {
        switch r {
        case .success: actionMessage = ok
        case .failure(let e):
            actionMessage = e.message.split(separator: "\n").first.map(String.init) ?? e.message
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { actionMessage = nil }
        }
    }
}

private struct CommitSheet: View {
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commit").font(SoulFont.ui(13, weight: .semibold)).foregroundStyle(SoulColor.fg)
            TextEditor(text: $message)
                .font(SoulFont.code(12))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(SoulColor.border))
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Commit") { onCommit(message.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}

private struct CreateBranchSheet: View {
    var onCreate: (String) -> Void
    var onCancel: () -> Void
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create branch").font(SoulFont.ui(13, weight: .semibold)).foregroundStyle(SoulColor.fg)
            TextField("branch-name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(SoulFont.code(12))
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
