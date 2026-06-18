import SwiftUI
import AppKit

extension AppShell {
    var rightSidePanels: some View {
        ZStack(alignment: .leading) {
            if rightPane.isOpen {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(SoulColor.border.opacity(0.5))
                        .frame(width: 1)
                    rightPaneContent
                        .frame(width: 540)
                }
            }
        }
        .frame(width: rightPane.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(SoulColor.bg)
        .clipped()
    }

    var rightPaneContent: some View {
        VStack(spacing: 0) {
            rightPaneTabStrip
            Divider().background(SoulColor.border.opacity(0.5))
            ZStack {
                if rightPane.effectiveActiveTab == .review, rightPane.reviewVisible {
                    ReviewPanel(
                        projectPath: currentProject()?.path,
                        onClose: { closeRightTab(.review) },
                        embedded: true
                    )
                } else if rightPane.effectiveActiveTab == .file, let preview = rightPane.filePreviewPath {
                    FilePreviewPanel(
                        path: preview,
                        onClose: { closeRightTab(.file) },
                        embedded: true
                    )
                } else if rightPane.effectiveActiveTab == .computerUse, rightPane.computerUseVisible {
                    ComputerUseConsolePanel(
                        projectPath: thread?.project.path ?? replay.controller?.project.path ?? currentProject()?.path,
                        onClose: { closeRightTab(.computerUse) }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var rightPaneTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(rightPane.openTabs, id: \.self) { tab in
                rightPaneTabButton(tab)
            }
            Spacer()
            Button(action: closeRightPane) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.soulHover)
            .help("Close pane")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(SoulColor.bg)
    }

    func closeRightPane() {
        withAnimation(sidePanelAnimation) {
            rightPane.closePane()
            showReview = rightPane.reviewVisible
            showComputerUse = rightPane.computerUseVisible
        }
    }

    @ViewBuilder
    func rightPaneTabButton(_ tab: AppRightPaneTab) -> some View {
        let isActive = rightPane.effectiveActiveTab == tab
        HStack(spacing: 6) {
            Button(action: {
                if isActive, tab == .file, let path = rightPane.filePreviewPath {
                    revealInFinder(path)
                } else {
                    rightPane.activeTab = tab
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: rightPaneIcon(for: tab))
                        .font(.system(size: 10))
                    Text(rightPane.label(for: tab))
                        .font(SoulFont.ui(11, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(isActive ? SoulColor.fg : SoulColor.fgMuted)
            }
            .buttonStyle(.soulHover)
            .help(isActive && tab == .file ? "Click again to reveal in Finder" : "")
            .contextMenu {
                if tab == .file, let path = rightPane.filePreviewPath {
                    Button("Reveal in Finder") { revealInFinder(path) }
                    Button("Open with Default App") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    }
                    Divider()
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString((path as NSString).expandingTildeInPath, forType: .string)
                    }
                }
            }

            Button(action: { closeRightTab(tab) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SoulColor.fgMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.soulHover)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isActive ? SoulColor.surface : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isActive ? SoulColor.border.opacity(0.6) : Color.clear,
                    lineWidth: 0.5
                )
        )
    }

    func revealInFinder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }

    func closeRightTab(_ tab: AppRightPaneTab) {
        withAnimation(sidePanelAnimation) {
            rightPane.closeTab(tab)
            showReview = rightPane.reviewVisible
            showComputerUse = rightPane.computerUseVisible
        }
    }

    func rightPaneIcon(for tab: AppRightPaneTab) -> String {
        switch tab {
        case .review: return "checklist"
        case .file: return "doc.text"
        case .computerUse: return "cursorarrow.rays"
        }
    }
}
