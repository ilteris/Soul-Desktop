import SwiftUI

private struct PreviewRoutingModifier: ViewModifier {
    let filePreviewPath: String?
    let webPreviewURL: URL?
    let openFile: (String) -> Void
    let openWeb: (URL) -> Void
    let restoreSidebarIfNeeded: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.openFilePreview, openFile)
            .environment(\.openWebPreview, openWeb)
            .onChange(of: filePreviewPath) { _, new in
                if new == nil {
                    restoreSidebarIfNeeded()
                }
            }
            .onChange(of: webPreviewURL) { _, new in
                if new == nil {
                    restoreSidebarIfNeeded()
                }
            }
    }
}

extension View {
    func previewRouting(
        filePreviewPath: String?,
        webPreviewURL: URL?,
        openFile: @escaping (String) -> Void,
        openWeb: @escaping (URL) -> Void,
        restoreSidebarIfNeeded: @escaping () -> Void
    ) -> some View {
        modifier(
            PreviewRoutingModifier(
                filePreviewPath: filePreviewPath,
                webPreviewURL: webPreviewURL,
                openFile: openFile,
                openWeb: openWeb,
                restoreSidebarIfNeeded: restoreSidebarIfNeeded
            )
        )
    }
}
