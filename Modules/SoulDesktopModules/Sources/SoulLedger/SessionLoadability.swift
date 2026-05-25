import Foundation

public struct LedgerLoadableLocation: Codable, Hashable, Sendable {
    public var provider: String
    public var cwd: String
    public var transcriptPath: String

    public init(provider: String, cwd: String, transcriptPath: String) {
        self.provider = provider
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}

public enum LedgerSessionLoadability {
    public static func canLoadFromDisk(
        sessionId sid: String,
        project: LedgerProject,
        nativeSessionIDs: [String: String] = [:],
        sessionDir: (String, String) -> String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        if claudeFileExists(sessionId: sid, cwd: project.path, homeDirectory: homeDirectory) { return true }
        let claudeId = nativeSessionIDs["claude"] ?? sid
        if claudeId != sid, claudeFileExists(sessionId: claudeId, cwd: project.path, homeDirectory: homeDirectory) {
            return true
        }

        if geminiFileHasContent(sessionId: sid, project: project, homeDirectory: homeDirectory) { return true }
        let geminiId = nativeSessionIDs["geminiCLI"] ?? sid
        if geminiId != sid, geminiFileHasContent(sessionId: geminiId, project: project, homeDirectory: homeDirectory) {
            return true
        }

        if piFileExists(sessionId: sid, cwd: project.path, homeDirectory: homeDirectory) { return true }
        if codexFileExists(sessionId: sid, projectKey: project.id, sessionDir: sessionDir) { return true }
        return false
    }

    public static func discover(
        sessionId sid: String,
        activeProjects: [LedgerProject],
        sessionRoots: [String],
        homeDirectory: String = NSHomeDirectory()
    ) -> LedgerLoadableLocation? {
        if let hit = findClaudeAnywhere(sessionId: sid, activeProjects: activeProjects, homeDirectory: homeDirectory) {
            return hit
        }
        if let hit = findGeminiAnywhere(sessionId: sid, activeProjects: activeProjects, homeDirectory: homeDirectory) {
            return hit
        }
        if let hit = findPiAnywhere(sessionId: sid, activeProjects: activeProjects, homeDirectory: homeDirectory) {
            return hit
        }
        if let hit = findCodexAnywhere(sessionId: sid, activeProjects: activeProjects, sessionRoots: sessionRoots) {
            return hit
        }
        return nil
    }

    public static func claudeEncodedCwd(_ cwd: String) -> String {
        trimTrailingSlash(cwd).replacingOccurrences(of: "/", with: "-")
    }

    public static func piEncodedCwd(_ cwd: String) -> String {
        let trimmed = trimTrailingSlash(cwd)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        return "--" + parts.joined(separator: "-") + "--"
    }

    private static func claudeFileExists(sessionId sid: String, cwd: String, homeDirectory: String) -> Bool {
        let path = "\(homeDirectory)/.claude/projects/\(claudeEncodedCwd(cwd))/\(sid).jsonl"
        return FileManager.default.fileExists(atPath: path)
    }

    private static func findClaudeAnywhere(
        sessionId sid: String,
        activeProjects: [LedgerProject],
        homeDirectory: String
    ) -> LedgerLoadableLocation? {
        let base = "\(homeDirectory)/.claude/projects"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let path = "\(base)/\(dir)/\(sid).jsonl"
            if fm.fileExists(atPath: path) {
                let cwd = decodeClaudeCwd(encoded: dir, activeProjects: activeProjects)
                return LedgerLoadableLocation(provider: "claude", cwd: cwd, transcriptPath: path)
            }
        }
        return nil
    }

    private static func decodeClaudeCwd(encoded: String, activeProjects: [LedgerProject]) -> String {
        for project in activeProjects where !project.path.isEmpty {
            let trimmed = trimTrailingSlash(project.path)
            if claudeEncodedCwd(trimmed) == encoded {
                return trimmed
            }
        }
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return "/" + stripped.replacingOccurrences(of: "-", with: "/")
    }

    private static func geminiFileHasContent(sessionId sid: String, project: LedgerProject, homeDirectory: String) -> Bool {
        let geminiBase = "\(homeDirectory)/.gemini/tmp"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: geminiBase) else { return false }
        let projectRealpath: String? = project.path.isEmpty ? nil
            : URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let keyLC = project.id.lowercased()
        let prefixLC = "\(keyLC)-"
        let candidateDirs = entries.filter { dir in
            let markerPath = "\(geminiBase)/\(dir)/.project_root"
            if let raw = try? String(contentsOfFile: markerPath, encoding: .utf8) {
                guard let projectRealpath else { return false }
                let resolved = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                    .resolvingSymlinksInPath().path
                return resolved == projectRealpath
            }
            let dirLC = dir.lowercased()
            return dirLC == keyLC || dirLC.hasPrefix(prefixLC)
        }
        for dir in candidateDirs {
            if scanGeminiChatsDir("\(geminiBase)/\(dir)/chats", sessionId: sid) != nil {
                return true
            }
        }
        return false
    }

    private static func findGeminiAnywhere(
        sessionId sid: String,
        activeProjects: [LedgerProject],
        homeDirectory: String
    ) -> LedgerLoadableLocation? {
        let base = "\(homeDirectory)/.gemini/tmp"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let chatsDir = "\(base)/\(dir)/chats"
            guard let path = scanGeminiChatsDir(chatsDir, sessionId: sid) else { continue }
            let cwd = projectPathForGeminiBasename(dir, activeProjects: activeProjects, homeDirectory: homeDirectory) ?? ""
            if cwd.isEmpty { continue }
            return LedgerLoadableLocation(provider: "geminiCLI", cwd: cwd, transcriptPath: path)
        }
        return nil
    }

    private static func scanGeminiChatsDir(_ chatsDir: String, sessionId sid: String) -> String? {
        let dirURL = URL(fileURLWithPath: chatsDir)
        guard let chatEntries = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let jsonls = chatEntries.filter { $0.pathExtension == "jsonl" }
        let shortId = String(sid.prefix(8))
        if let hint = jsonls.first(where: { $0.lastPathComponent.contains(shortId) }),
           hasContent(file: hint, expectedSessionId: sid) {
            return hint.path
        }
        for url in jsonls {
            if hasContent(file: url, expectedSessionId: sid) { return url.path }
        }
        return nil
    }

    private static func projectPathForGeminiBasename(
        _ dir: String,
        activeProjects: [LedgerProject],
        homeDirectory: String
    ) -> String? {
        let geminiBase = "\(homeDirectory)/.gemini/tmp"
        let markerPath = "\(geminiBase)/\(dir)/.project_root"
        if let raw = try? String(contentsOfFile: markerPath, encoding: .utf8) {
            let resolved = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path
            for project in activeProjects where !project.path.isEmpty {
                let projectResolved = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
                if projectResolved == resolved { return project.path }
            }
            return nil
        }

        let stripped: String = {
            if let dashIndex = dir.lastIndex(of: "-"),
               let tail = Int(dir[dir.index(after: dashIndex)...]),
               tail >= 0 {
                return String(dir[..<dashIndex])
            }
            return dir
        }()
        let strippedLC = stripped.lowercased()
        let dirLC = dir.lowercased()
        for project in activeProjects where !project.path.isEmpty {
            let basenameLC = (project.path as NSString).lastPathComponent.lowercased()
            if basenameLC == strippedLC || basenameLC == dirLC { return project.path }
        }
        return nil
    }

    private static func hasContent(file url: URL, expectedSessionId sid: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1024)
        guard let string = String(data: head, encoding: .utf8) else { return false }
        let lines = string.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2,
              let data = lines[0].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let firstSessionId = object["sessionId"] as? String,
              firstSessionId == sid else {
            return false
        }
        return true
    }

    private static func piFileExists(sessionId sid: String, cwd: String, homeDirectory: String) -> Bool {
        let encoded = piEncodedCwd(cwd)
        guard !encoded.isEmpty else { return false }
        let dir = "\(homeDirectory)/.pi/agent/sessions/\(encoded)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return false }
        for name in entries where name.hasSuffix(".jsonl") {
            let stem = (name as NSString).deletingPathExtension
            if let underscore = stem.lastIndex(of: "_"),
               String(stem[stem.index(after: underscore)...]) == sid {
                return true
            }
        }
        return false
    }

    private static func findPiAnywhere(
        sessionId sid: String,
        activeProjects: [LedgerProject],
        homeDirectory: String
    ) -> LedgerLoadableLocation? {
        let base = "\(homeDirectory)/.pi/agent/sessions"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let dirPath = "\(base)/\(dir)"
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in entries where name.hasSuffix(".jsonl") {
                let stem = (name as NSString).deletingPathExtension
                guard let underscore = stem.lastIndex(of: "_"),
                      String(stem[stem.index(after: underscore)...]) == sid else {
                    continue
                }
                let cwd = decodePiCwd(encoded: dir, activeProjects: activeProjects)
                return LedgerLoadableLocation(provider: "pi", cwd: cwd, transcriptPath: "\(dirPath)/\(name)")
            }
        }
        return nil
    }

    private static func decodePiCwd(encoded: String, activeProjects: [LedgerProject]) -> String {
        var stripped = encoded
        if stripped.hasPrefix("--") { stripped.removeFirst(2) }
        if stripped.hasSuffix("--") { stripped.removeLast(2) }
        for project in activeProjects where !project.path.isEmpty {
            if piEncodedCwd(project.path) == encoded { return project.path }
        }
        return "/" + stripped.replacingOccurrences(of: "-", with: "/")
    }

    private static func codexFileExists(
        sessionId sid: String,
        projectKey: String,
        sessionDir: (String, String) -> String
    ) -> Bool {
        let path = "\(sessionDir(projectKey, sid))/transcript.jsonl"
        return FileManager.default.fileExists(atPath: path)
    }

    private static func findCodexAnywhere(
        sessionId sid: String,
        activeProjects: [LedgerProject],
        sessionRoots: [String]
    ) -> LedgerLoadableLocation? {
        let fm = FileManager.default
        for base in sessionRoots {
            guard let projects = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for projectKey in projects {
                let path = "\(base)/\(projectKey)/\(sid)/transcript.jsonl"
                if fm.fileExists(atPath: path) {
                    let cwd = activeProjects.first(where: { $0.id == projectKey })?.path ?? ""
                    if cwd.isEmpty { continue }
                    return LedgerLoadableLocation(provider: "codex", cwd: cwd, transcriptPath: path)
                }
            }
        }
        return nil
    }

    private static func trimTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
