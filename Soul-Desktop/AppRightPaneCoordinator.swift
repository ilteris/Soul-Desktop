import SwiftUI

enum AppRightPaneTab: Hashable {
    case review
    case file
    case computerUse
}

@MainActor
@Observable
final class AppRightPaneCoordinator {
    var reviewVisible: Bool
    var filePreviewPath: String?
    var computerUseVisible: Bool
    var activeTab: AppRightPaneTab = .review

    init(reviewVisible: Bool = false, filePreviewPath: String? = nil, computerUseVisible: Bool = false) {
        self.reviewVisible = reviewVisible
        self.filePreviewPath = filePreviewPath
        self.computerUseVisible = computerUseVisible
    }

    var openTabs: [AppRightPaneTab] {
        var tabs: [AppRightPaneTab] = []
        if reviewVisible { tabs.append(.review) }
        if filePreviewPath != nil { tabs.append(.file) }
        if computerUseVisible { tabs.append(.computerUse) }
        return tabs
    }

    var isOpen: Bool {
        !openTabs.isEmpty
    }

    var width: CGFloat {
        isOpen ? 541 : 0
    }

    var effectiveActiveTab: AppRightPaneTab {
        let tabs = openTabs
        if tabs.contains(activeTab) { return activeTab }
        return tabs.first ?? .review
    }

    func toggleReview() {
        reviewVisible.toggle()
        if reviewVisible {
            activeTab = .review
        }
    }

    func setFilePreviewPath(_ path: String?) {
        filePreviewPath = path
        if path != nil {
            activeTab = .file
        }
    }

    func toggleComputerUse() {
        computerUseVisible.toggle()
        if computerUseVisible {
            activeTab = .computerUse
        }
    }

    func openComputerUse() {
        computerUseVisible = true
        activeTab = .computerUse
    }

    func closePane() {
        reviewVisible = false
        filePreviewPath = nil
        computerUseVisible = false
    }

    func closeTab(_ tab: AppRightPaneTab) {
        switch tab {
        case .review:
            reviewVisible = false
        case .file:
            filePreviewPath = nil
        case .computerUse:
            computerUseVisible = false
        }
    }

    func label(for tab: AppRightPaneTab) -> String {
        switch tab {
        case .review:
            return "Review"
        case .file:
            guard let path = filePreviewPath else { return "File" }
            return (path as NSString).lastPathComponent
        case .computerUse:
            return "Computer"
        }
    }
}
