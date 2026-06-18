import Foundation
import Testing
@testable import Soul_Desktop

@Suite("Preview path target routing")
struct PreviewPathTargetTests {
    @Test func existingDirectoryRoutesToFinder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("applications/fireworks-product-engineer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AppShell.PreviewPathTarget.resolve(directory.path) == .directory(directory.path))
    }

    @Test func existingFileRoutesToPreviewPane() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-preview-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try "# Read me\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AppShell.PreviewPathTarget.resolve(file.path) == .file(file.path))
    }

    @Test func missingPathStillRoutesToPreviewPaneForErrorDisplay() {
        let missing = "/tmp/soul-preview-target-\(UUID().uuidString)/missing.md"

        #expect(AppShell.PreviewPathTarget.resolve(missing) == .file(missing))
    }

    @Test func sameFilesystemPathNormalizesDotComponents() {
        let base = "/tmp/soul-preview-target-\(UUID().uuidString)"

        #expect(AppShell.sameFilesystemPath("\(base)/folder/../folder", "\(base)/folder"))
    }
}
