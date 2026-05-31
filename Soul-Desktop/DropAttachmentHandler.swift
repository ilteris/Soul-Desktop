import AppKit
import Foundation
import UniformTypeIdentifiers

/// Shared drop-payload processor used by every surface that accepts image/
/// file drags (ComposerView, ThreadView outer canvas, HeroEmptyState).
///
/// Lifts the previously-internal ComposerView logic out so the larger
/// ThreadView area can also catch drops without duplicating code or
/// reaching into a sibling view's state.
///
/// NSItemProvider callbacks arrive asynchronously. Callers should accept
/// the SwiftUI drop synchronously, then call `process` from a Task and
/// append the returned paths once provider loading finishes.
enum DropAttachmentHandler {
    /// UTType list every drop surface should accept. Centralized so adding
    /// a new type updates every surface at once.
    static let acceptedTypes: [UTType] = [.fileURL, .image, .png, .jpeg, .tiff, .gif]

    /// Process a batch of providers and return any new attachment paths.
    /// `existing` is the current set of attached paths used to dedupe.
    /// Returns paths that weren't already in `existing`.
    @MainActor
    static func process(
        providers: [NSItemProvider],
        projectPath: String?,
        existing: [String]
    ) async -> [String] {
        var fileURLs: [URL] = []
        var dataDrops: [(Data, String?)] = []

        await withTaskGroup(of: LoadedProvider.self) { group in
            for provider in providers {
                group.addTask {
                    await loadProvider(provider)
                }
            }
            for await loaded in group {
                fileURLs.append(contentsOf: loaded.fileURLs)
                dataDrops.append(contentsOf: loaded.dataDrops)
            }
        }

        var newPaths: [String] = []
        // Copy dropped image files into the project's attachments dir so
        // they survive if the source moves (e.g. a Screenshot drag from
        // /private/var/folders/.../TemporaryItems/...). Non-image files
        // are referenced in place — the agent reads them as paths.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var attachmentsDir: String? = nil
        if let project = projectPath, !project.isEmpty,
           fileURLs.contains(where: { isImageURL($0) }) {
            let dir = "\(project)/.soul/attachments"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            attachmentsDir = dir
        }
        let maxSize = 5 * 1024 * 1024
        for (i, src) in fileURLs.enumerated() {
            if isImageURL(src) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
                let size = attrs?[.size] as? Int ?? 0
                if size > maxSize {
                    let alert = NSAlert()
                    alert.messageText = "Image too large"
                    alert.informativeText = "The image \(src.lastPathComponent) is larger than the 5MB limit."
                    alert.alertStyle = .warning
                    alert.runModal()
                    continue
                }
            }
            let finalPath: String
            if isImageURL(src), let dir = attachmentsDir {
                let dst = "\(dir)/\(stamp)-\(i)-\(src.lastPathComponent)"
                do {
                    try FileManager.default.copyItem(atPath: src.path, toPath: dst)
                    finalPath = dst
                } catch {
                    finalPath = src.path
                }
            } else {
                finalPath = src.path
            }
            if !existing.contains(finalPath) && !newPaths.contains(finalPath) {
                newPaths.append(finalPath)
            }
        }
        for (data, hint) in dataDrops {
            if data.count > maxSize {
                let alert = NSAlert()
                alert.messageText = "Image too large"
                alert.informativeText = "The pasted image is larger than the 5MB limit."
                alert.alertStyle = .warning
                alert.runModal()
                continue
            }
            if let path = writeImageDataAsAttachment(data, hint: hint, projectPath: projectPath),
               !existing.contains(path),
               !newPaths.contains(path) {
                newPaths.append(path)
            }
        }

        return newPaths
    }

    private struct LoadedProvider: Sendable {
        var fileURLs: [URL] = []
        var dataDrops: [(Data, String?)] = []
    }

    private static func loadProvider(_ provider: NSItemProvider) async -> LoadedProvider {
        if provider.canLoadObject(ofClass: URL.self),
           let url = await loadFileURL(from: provider) {
            return LoadedProvider(fileURLs: [url])
        }

        // Probe image type identifiers in order of fidelity; first
        // responder wins so we don't load the same bytes twice.
        let imageTypes = ["public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.image"]
        for type in imageTypes where provider.hasItemConformingToTypeIdentifier(type) {
            if let data = await loadData(from: provider, type: type) {
                return LoadedProvider(dataDrops: [(data, extHint(forType: type))])
            }
            return LoadedProvider()
        }
        return LoadedProvider()
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url, u.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: u)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func isImageURL(_ url: URL) -> Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private static func extHint(forType uti: String) -> String? {
        switch uti {
        case "public.png":          return "png"
        case "public.jpeg":         return "jpg"
        case "public.tiff":         return "tiff"
        case "com.compuserve.gif":  return "gif"
        default:                    return nil
        }
    }

    /// Persist raw image bytes (from a non-file drag — Messages, Mail, web
    /// browsers all flatten an image to a Transferable image payload, not
    /// a file URL) into the project's attachments dir and return the
    /// on-disk path. Returns nil if there's no project to write into.
    private static func writeImageDataAsAttachment(
        _ data: Data,
        hint: String?,
        projectPath: String?
    ) -> String? {
        guard let project = projectPath, !project.isEmpty else { return nil }
        let dir = "\(project)/.soul/attachments"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        let ext: String = {
            if let h = hint?.lowercased(), !h.isEmpty,
               !h.contains("/"), h.count <= 5 {
                return h
            }
            // Sniff first bytes for the common formats — `hint` from
            // public.image is generic and tells us nothing.
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
            if data.starts(with: [0xFF, 0xD8, 0xFF])       { return "jpg" }
            if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
            return "png"
        }()
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-drag.\(ext)"
        let path = "\(dir)/\(name)"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return path
        } catch {
            return nil
        }
    }
}
