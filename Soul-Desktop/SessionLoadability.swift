import Foundation

/// Where on disk a session's transcript actually lives, plus the cwd to
/// spawn the agent in for a successful resume. Returned by the global
/// UUID-keyed lookup so callers can override their assumed project path
/// when a session's transcript lives outside the project bucket the row
/// happened to be filed under.
struct LoadableLocation {
    /// "claude" | "geminiCLI" | "pi" | "codex"
    let provider: String
    /// Absolute cwd to spawn the agent in. For Claude/Pi this comes from
    /// the encoded dir name (or a SoulProject match); for Gemini this is
    /// the project whose path basename matches the chats sibling; for
    /// Codex the project that owns the kernel ledger dir.
    let cwd: String
    /// For diagnostics / logging.
    let transcriptPath: String
}

/// Decides whether clicking a session would render content rather than
/// "no offline transcript on this machine," AND where that transcript
/// lives on disk so the caller can route the spawn correctly.
///
/// Two entry points:
///   • `canLoadFromDisk(sessionId:project:)` — cheap project-bounded check
///     for the sidebar's hot enrichment loop. Identical behavior to the
///     pre-refactor version so we don't regress sidebar paint cost.
///   • `discover(sessionId:)` — globally UUID-keyed scan across all known
///     provider dirs. Returns the `LoadableLocation` if any provider has
///     this UUID on disk, regardless of which project bucket the user
///     clicked from. Use this on session click before falling through to
///     the "can't be loaded" recovery sheet — it unblocks split-ledger
///     clicks (same UUID, two project buckets) and cross-project
///     transcript locations.
enum SessionLoadability {
    // MARK: - Fast path (sidebar enrichment)

    /// True iff *some* provider has a readable transcript for this UUID
    /// reachable from the passed project. Conservative on Pi/Codex: only
    /// returns true when the on-disk file actually exists.
    static func canLoadFromDisk(sessionId sid: String, project: SoulProject) -> Bool {
        if claudeFileExists(sessionId: sid, cwd: project.path) { return true }
        let claudeId = SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid, provider: "claude") ?? sid
        if claudeId != sid, claudeFileExists(sessionId: claudeId, cwd: project.path) { return true }

        if geminiFileHasContent(sessionId: sid, project: project) { return true }
        let geminiId = SoulRegistry.findNativeSessionID(projectKey: project.id, sessionId: sid, provider: "geminiCLI") ?? sid
        if geminiId != sid, geminiFileHasContent(sessionId: geminiId, project: project) { return true }

        if piFileExists(sessionId: sid, cwd: project.path) { return true }
        if codexFileExists(sessionId: sid, projectKey: project.id) { return true }
        return false
    }

    // MARK: - Slow path (cross-project discovery on click)

    /// Walk every known provider dir for a `<sid>` file. Returns the first
    /// match with a usable cwd. Run only on session click — not in the
    /// sidebar hot loop — so the O(dir) cost is acceptable.
    static func discover(sessionId sid: String) -> LoadableLocation? {
        if let hit = findClaudeAnywhere(sessionId: sid) { return hit }
        if let hit = findGeminiAnywhere(sessionId: sid) { return hit }
        if let hit = findPiAnywhere(sessionId: sid)     { return hit }
        if let hit = findCodexAnywhere(sessionId: sid)  { return hit }
        return nil
    }

    // MARK: - Claude

    private static func claudeFileExists(sessionId sid: String, cwd: String) -> Bool {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let encoded = trimmed.replacingOccurrences(of: "/", with: "-")
        let path = NSHomeDirectory() + "/.claude/projects/\(encoded)/\(sid).jsonl"
        return FileManager.default.fileExists(atPath: path)
    }

    /// Scan every `~/.claude/projects/<encoded-cwd>/` for `<sid>.jsonl`.
    /// Returns the cwd that the encoded dir name decodes to (via SoulProject
    /// lookup for hyphen-safe names, naive decode as a fallback).
    private static func findClaudeAnywhere(sessionId sid: String) -> LoadableLocation? {
        let base = NSHomeDirectory() + "/.claude/projects"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let path = "\(base)/\(dir)/\(sid).jsonl"
            if fm.fileExists(atPath: path) {
                let cwd = decodeClaudeCwd(encoded: dir)
                return LoadableLocation(provider: "claude", cwd: cwd, transcriptPath: path)
            }
        }
        return nil
    }

    /// Reverse `~/.claude/projects/-Users-foo-bar-Code-my-project`. Naive
    /// decode replaces every `-` with `/`, which breaks for hyphen-containing
    /// directory names (e.g. `Soul-Desktop`, `stock-activity`). First try
    /// matching against every active SoulProject's encoded path — exact
    /// match means we know the real cwd. If no project matches, fall back
    /// to naive decode and accept the risk.
    private static func decodeClaudeCwd(encoded: String) -> String {
        for proj in LiveSoulRegistryStore.shared.activeProjects() where !proj.path.isEmpty {
            let trimmed = proj.path.hasSuffix("/") ? String(proj.path.dropLast()) : proj.path
            if trimmed.replacingOccurrences(of: "/", with: "-") == encoded {
                return trimmed
            }
        }
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        return "/" + stripped.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Gemini

    private static func geminiFileHasContent(sessionId sid: String, project: SoulProject) -> Bool {
        let geminiBase = ("~/.gemini/tmp" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: geminiBase) else { return false }
        // SOUL-SOUL_DESKTOP-083: marker-first dir selection. See the warm-walk
        // in SoulRegistry.agentMatchCached for the rationale.
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

    /// Scan ALL chats dirs under `~/.gemini/tmp/*` for a file containing
    /// the requested sessionId. Returns the discovered location — including
    /// the project's path the basename maps to (so spawn cwd is correct).
    private static func findGeminiAnywhere(sessionId sid: String) -> LoadableLocation? {
        let base = ("~/.gemini/tmp" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let chatsDir = "\(base)/\(dir)/chats"
            guard let path = scanGeminiChatsDir(chatsDir, sessionId: sid) else { continue }
            let cwd = projectPathForGeminiBasename(dir) ?? ""
            if cwd.isEmpty { continue } // can't spawn without a real cwd
            return LoadableLocation(provider: "geminiCLI", cwd: cwd, transcriptPath: path)
        }
        return nil
    }

    /// Walk a single chats dir, fast-filter by first-8-prefix in filename,
    /// content-verify on first match. Returns the absolute path of the
    /// matching `.jsonl` or nil.
    private static func scanGeminiChatsDir(_ chatsDir: String, sessionId sid: String) -> String? {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: chatsDir)
        guard let chatEntries = try? fm.contentsOfDirectory(
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

    /// Map a `~/.gemini/tmp/<basename>` dir back to a real cwd. Marker-first
    /// (SOUL-SOUL_DESKTOP-083): read `.project_root` and match its resolved
    /// realpath against active SoulProjects — handles `-N` collision siblings,
    /// duplicate-basename projects in different parents, and gemini-cli slug
    /// normalization. Falls back to case-insensitive basename match for legacy
    /// dirs that pre-date the marker.
    private static func projectPathForGeminiBasename(_ dir: String) -> String? {
        let geminiBase = ("~/.gemini/tmp" as NSString).expandingTildeInPath
        let markerPath = "\(geminiBase)/\(dir)/.project_root"
        if let raw = try? String(contentsOfFile: markerPath, encoding: .utf8) {
            let resolved = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path
            for proj in LiveSoulRegistryStore.shared.activeProjects() where !proj.path.isEmpty {
                let projResolved = URL(fileURLWithPath: proj.path).resolvingSymlinksInPath().path
                if projResolved == resolved { return proj.path }
            }
            // Marker is authoritative: if it points at a path no active
            // project owns, don't silently fall back to basename — that
            // would re-introduce the cross-project misroute -083 is here
            // to prevent.
            return nil
        }

        // Legacy fallback: no marker → strip `-N` and case-insensitive
        // basename match (SOUL-SOUL_DESKTOP-084).
        let stripped: String = {
            if let dashIdx = dir.lastIndex(of: "-"),
               let tail = Int(dir[dir.index(after: dashIdx)...]),
               tail >= 0 { return String(dir[..<dashIdx]) }
            return dir
        }()
        let strippedLC = stripped.lowercased()
        let dirLC = dir.lowercased()
        for proj in LiveSoulRegistryStore.shared.activeProjects() where !proj.path.isEmpty {
            let basenameLC = (proj.path as NSString).lastPathComponent.lowercased()
            if basenameLC == strippedLC || basenameLC == dirLC { return proj.path }
        }
        return nil
    }

    private static func hasContent(file url: URL, expectedSessionId sid: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 1024)
        guard let s = String(data: head, encoding: .utf8) else { return false }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return false }
        guard let data = lines[0].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let firstSid = obj["sessionId"] as? String,
              firstSid == sid
        else { return false }
        return true
    }

    // MARK: - Pi

    /// Pi files sessions at `~/.pi/agent/sessions/--<dash-joined-parts>--/<ts>_<sid>.jsonl`.
    /// Encode the cwd to match (drop leading/trailing slashes, join with
    /// `-`, surround with `--`).
    private static func piFileExists(sessionId sid: String, cwd: String) -> Bool {
        let encoded = piEncode(cwd: cwd)
        guard !encoded.isEmpty else { return false }
        let dir = "\(NSHomeDirectory())/.pi/agent/sessions/\(encoded)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return false
        }
        for name in entries where name.hasSuffix(".jsonl") {
            let stem = (name as NSString).deletingPathExtension
            if let underscore = stem.lastIndex(of: "_"),
               String(stem[stem.index(after: underscore)...]) == sid {
                return true
            }
        }
        return false
    }

    private static func findPiAnywhere(sessionId sid: String) -> LoadableLocation? {
        let base = "\(NSHomeDirectory())/.pi/agent/sessions"
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let dirPath = "\(base)/\(dir)"
            guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in entries where name.hasSuffix(".jsonl") {
                let stem = (name as NSString).deletingPathExtension
                guard let underscore = stem.lastIndex(of: "_"),
                      String(stem[stem.index(after: underscore)...]) == sid
                else { continue }
                let cwd = decodePiCwd(encoded: dir)
                return LoadableLocation(provider: "pi", cwd: cwd, transcriptPath: "\(dirPath)/\(name)")
            }
        }
        return nil
    }

    private static func piEncode(cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        return "--" + parts.joined(separator: "-") + "--"
    }

    /// Reverse pi's `--Users-ilteris-Code-my-project--` encoding. Same
    /// hyphen-ambiguity as Claude — prefer a SoulProject match before
    /// falling back to naive decode.
    private static func decodePiCwd(encoded: String) -> String {
        var stripped = encoded
        if stripped.hasPrefix("--") { stripped.removeFirst(2) }
        if stripped.hasSuffix("--") { stripped.removeLast(2) }
        for proj in LiveSoulRegistryStore.shared.activeProjects() where !proj.path.isEmpty {
            let candidate = piEncode(cwd: proj.path)
            if candidate == encoded { return proj.path }
        }
        return "/" + stripped.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Codex

    /// Codex co-locates its transcript with the kernel ledger:
    /// `~/soul_registry/sessions/<projectKey>/<sid>/transcript.jsonl`.
    private static func codexFileExists(sessionId sid: String, projectKey: String) -> Bool {
        let path = "\(SoulRegistry.registryPath)/sessions/\(projectKey)/\(sid)/transcript.jsonl"
        return FileManager.default.fileExists(atPath: path)
    }

    private static func findCodexAnywhere(sessionId sid: String) -> LoadableLocation? {
        let base = "\(SoulRegistry.registryPath)/sessions"
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for projectKey in projects {
            let path = "\(base)/\(projectKey)/\(sid)/transcript.jsonl"
            if fm.fileExists(atPath: path) {
                let cwd = LiveSoulRegistryStore.shared.activeProjects()
                    .first(where: { $0.id == projectKey })?.path ?? ""
                if cwd.isEmpty { continue }
                return LoadableLocation(provider: "codex", cwd: cwd, transcriptPath: path)
            }
        }
        return nil
    }
}
