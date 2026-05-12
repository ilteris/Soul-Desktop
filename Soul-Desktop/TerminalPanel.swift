import SwiftUI
import AppKit
import Combine
import SwiftTerm

// MARK: - Tab model

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    @Published var title: String
    let pending = PassthroughSubject<String, Never>()

    init(cwd: String, title: String? = nil) {
        self.cwd = cwd
        self.title = title ?? (cwd as NSString).lastPathComponent
    }
}

@MainActor
final class TerminalPanelModel: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeID: UUID? = nil

    var active: TerminalTab? { tabs.first(where: { $0.id == activeID }) }

    func ensureSeeded(with cwd: String) {
        if tabs.isEmpty {
            let tab = TerminalTab(cwd: cwd)
            tabs.append(tab)
            activeID = tab.id
        }
    }

    func addTab(cwd: String) {
        let tab = TerminalTab(cwd: cwd)
        tabs.append(tab)
        activeID = tab.id
    }

    /// Send text into the active tab (no trailing newline — caller controls).
    func requestSend(_ text: String) {
        active?.pending.send(text)
    }

    /// Returns true if the panel should now hide (last tab closed).
    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return false }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            activeID = nil
            return true
        }
        if activeID == id {
            activeID = tabs[max(0, idx - 1)].id
        }
        return false
    }
}

// MARK: - SwiftTerm host (NSViewRepresentable)

struct TerminalHost: NSViewRepresentable {
    let cwd: String
    let pending: PassthroughSubject<String, Never>
    let onTitle: (String) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTitle: onTitle, onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        for sub in view.subviews where sub is NSScroller {
            sub.isHidden = true
        }

        // Theme — keep close to the rest of the app (light surface, dark text).
        view.nativeBackgroundColor = NSColor(SoulColor.bg)
        view.nativeForegroundColor = NSColor(SoulColor.fg)
        view.font = SoulFont.nsFont(12, weight: .regular)

        // Login shell, full PATH via -l. Seed cwd; let prompt theming do its thing.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        if !env.contains(where: { $0.hasPrefix("LANG=") }) {
            env.append("LANG=en_US.UTF-8")
        }
        view.startProcess(executable: shell, args: ["-l"], environment: env, execName: "-\(shell)")

        // chdir via the shell — startProcess() doesn't take a workingDir, so seed cwd
        // through the spawned shell. This is reliable across zsh/bash and survives login config.
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        view.send(txt: "cd \"\(escaped)\" && clear\n")

        context.coordinator.cancellable = pending.sink { [weak view] text in
            view?.send(txt: text)
        }

        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTitle: (String) -> Void
        let onExit: () -> Void
        var cancellable: AnyCancellable?

        init(onTitle: @escaping (String) -> Void, onExit: @escaping () -> Void) {
            self.onTitle = onTitle
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            onTitle(title)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onExit()
        }
    }
}

// MARK: - Panel view

struct TerminalPanel: View {
    @ObservedObject var model: TerminalPanelModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            terminalArea
        }
        .background(SoulColor.bg)
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: tab.id == model.activeID,
                            onSelect: { model.activeID = tab.id },
                            onClose: {
                                if model.close(tab.id) { onClose() }
                            }
                        )
                    }
                    Button {
                        let cwd = model.active?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
                        model.addTab(cwd: cwd)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(SoulColor.fgMuted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New tab")
                }
                .padding(.leading, 10)
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide terminal")
            .padding(.trailing, 8)
        }
        .background(SoulColor.bg)
    }

    private var terminalArea: some View {
        ZStack {
            ForEach(model.tabs) { tab in
                TerminalHost(
                    cwd: tab.cwd,
                    pending: tab.pending,
                    onTitle: { newTitle in
                        if !newTitle.isEmpty { tab.title = newTitle }
                    },
                    onExit: {
                        if model.close(tab.id) { onClose() }
                    }
                )
                .opacity(tab.id == model.activeID ? 1 : 0)
                .allowsHitTesting(tab.id == model.activeID)
            }
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? SoulColor.fg : SoulColor.fgMuted)
            Text(tab.title)
                .font(SoulFont.ui(11, weight: .regular))
                .foregroundStyle(isActive ? SoulColor.fg : SoulColor.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isActive ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? SoulColor.surface.opacity(0.7) : (hovering ? SoulColor.surface.opacity(0.4) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? SoulColor.border.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}
