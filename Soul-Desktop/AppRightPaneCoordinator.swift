import SwiftUI

enum AppRightPaneTab: Hashable {
    case review
    case file
}

@MainActor
@Observable
final class AppRightPaneCoordinator {
    var reviewVisible: Bool
    var filePreviewPath: String?
    var activeTab: AppRightPaneTab = .review

    init(reviewVisible: Bool = false, filePreviewPath: String? = nil) {
        self.reviewVisible = reviewVisible
        self.filePreviewPath = filePreviewPath
    }

    var openTabs: [AppRightPaneTab] {
        var tabs: [AppRightPaneTab] = []
        if reviewVisible { tabs.append(.review) }
        if filePreviewPath != nil { tabs.append(.file) }
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

    func closePane() {
        reviewVisible = false
        filePreviewPath = nil
    }

    func closeTab(_ tab: AppRightPaneTab) {
        switch tab {
        case .review:
            reviewVisible = false
        case .file:
            filePreviewPath = nil
        }
    }

    func label(for tab: AppRightPaneTab) -> String {
        switch tab {
        case .review:
            return "Review"
        case .file:
            guard let path = filePreviewPath else { return "File" }
            return (path as NSString).lastPathComponent
        }
    }
}
