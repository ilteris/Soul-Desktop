import Foundation
import Combine
import SwiftUI

enum GitLineKind { case context, add, del, hunk }

struct GitDiffLine: Identifiable {
    let id = UUID()
    let kind: GitLineKind
    let oldNo: Int?
    let newNo: Int?
    let text: String
}

struct GitDiffHunk: Identifiable {
    let id = UUID()
    let header: String
    var lines: [GitDiffLine]
}

struct GitDiffFile: Identifiable {
    let id = UUID()
    let path: String
    let oldPath: String?
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isNew: Bool
    let isDeleted: Bool
    let isRenamed: Bool
    var hunks: [GitDiffHunk]
}

struct GitError: Error { let message: String }

struct GitReviewSnapshot {
    var branch: String?
    var upstream: String?
    var additions: Int
    var deletions: Int
    var files: [GitDiffFile]

    static let empty = GitReviewSnapshot(branch: nil, upstream: nil, additions: 0, deletions: 0, files: [])
}

@MainActor
final class GitReviewModel: ObservableObject {
    @Published private(set) var snapshot: GitReviewSnapshot = .empty
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String? = nil

    private(set) var projectPath: String? = nil

    func bind(projectPath: String?) {
        guard projectPath != self.projectPath else { return }
        self.projectPath = projectPath
        Task { await refresh() }
    }

    func refresh() async {
        guard let path = projectPath, !path.isEmpty else {
            snapshot = .empty
            return
        }
        isLoading = true
        defer { isLoading = false }
        let snap = await Task.detached(priority: .utility) { GitReviewModel.compute(at: path) }.value
        switch snap {
        case .success(let s):
            snapshot = s
            lastError = nil
        case .failure(let e):
            snapshot = .empty
            lastError = e.message
        }
    }

    func commit(message: String) async -> Result<Void, GitError> {
        guard let path = projectPath else { return .failure(GitError(message: "no project")) }
        return await Task.detached(priority: .utility) {
            if case .failure(let e) = GitReviewModel.run("git", ["-C", path, "add", "-A"]) { return .failure(e) }
            if case .failure(let e) = GitReviewModel.run("git", ["-C", path, "commit", "-m", message]) { return .failure(e) }
            return .success(())
        }.value
    }

    func push() async -> Result<Void, GitError> {
        guard let path = projectPath else { return .failure(GitError(message: "no project")) }
        return await Task.detached(priority: .utility) {
            switch GitReviewModel.run("git", ["-C", path, "push"]) {
            case .success: return .success(())
            case .failure(let e):
                // try push -u origin <branch>
                if let branch = GitReviewModel.runCapture("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) {
                    if case .success = GitReviewModel.run("git", ["-C", path, "push", "-u", "origin", branch]) {
                        return .success(())
                    }
                }
                return .failure(e)
            }
        }.value
    }

    func createBranch(name: String) async -> Result<Void, GitError> {
        guard let path = projectPath else { return .failure(GitError(message: "no project")) }
        return await Task.detached(priority: .utility) {
            GitReviewModel.run("git", ["-C", path, "checkout", "-b", name]).map { _ in () }
        }.value
    }

    func openCreatePR() async -> Result<Void, GitError> {
        guard let path = projectPath else { return .failure(GitError(message: "no project")) }
        return await Task.detached(priority: .utility) {
            GitReviewModel.run("gh", ["-C", path, "pr", "create", "--web", "--fill"]).map { _ in () }
        }.value
    }

    // MARK: - Static workers (off-main)

    nonisolated private static func compute(at path: String) -> Result<GitReviewSnapshot, GitError> {
        guard let _ = runCapture("git", ["-C", path, "rev-parse", "--is-inside-work-tree"]) else {
            return .failure(GitError(message: "not a git repository"))
        }
        let branch = runCapture("git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        let upstream = runCapture("git", ["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])

        // Determine base: merge-base with upstream if available, else HEAD
        let base: String? = {
            if let up = upstream {
                if let mb = runCapture("git", ["-C", path, "merge-base", "HEAD", up]) { return mb }
            }
            return nil
        }()

        let diffArgs: [String]
        if let b = base {
            diffArgs = ["-C", path, "diff", "--no-color", "--no-ext-diff", b]
        } else {
            diffArgs = ["-C", path, "diff", "--no-color", "--no-ext-diff", "HEAD"]
        }
        guard let raw = runCapture("git", diffArgs, allowEmpty: true) else {
            return .success(GitReviewSnapshot(branch: branch, upstream: upstream, additions: 0, deletions: 0, files: []))
        }
        let files = parseUnifiedDiff(raw)
        let adds = files.reduce(0) { $0 + $1.additions }
        let dels = files.reduce(0) { $0 + $1.deletions }
        return .success(GitReviewSnapshot(
            branch: branch, upstream: upstream,
            additions: adds, deletions: dels, files: files
        ))
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> Result<String, GitError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(GitError(message: error.localizedDescription)) }
        p.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        if p.terminationStatus == 0 {
            return .success(String(data: outData, encoding: .utf8) ?? "")
        } else {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(p.terminationStatus)"
            return .failure(GitError(message: msg.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    nonisolated private static func runCapture(_ tool: String, _ args: [String], allowEmpty: Bool = false) -> String? {
        switch run(tool, args) {
        case .success(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !allowEmpty && t.isEmpty { return nil }
            return allowEmpty ? s : t
        case .failure: return nil
        }
    }

    // MARK: - Unified diff parser

    nonisolated private static func parseUnifiedDiff(_ raw: String) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if !line.hasPrefix("diff --git ") { i += 1; continue }

            // diff --git a/<old> b/<new>
            var (oldPath, newPath) = parseDiffHeader(line)
            var isBinary = false
            var isNew = false
            var isDeleted = false
            var isRenamed = false
            var hunks: [GitDiffHunk] = []
            var adds = 0, dels = 0
            i += 1

            // Pre-hunk metadata lines
            while i < lines.count {
                let l = lines[i]
                if l.hasPrefix("diff --git ") { break }
                if l.hasPrefix("@@") { break }
                if l.hasPrefix("new file mode") { isNew = true }
                if l.hasPrefix("deleted file mode") { isDeleted = true }
                if l.hasPrefix("rename from ") { isRenamed = true }
                if l.hasPrefix("rename to ") { isRenamed = true }
                if l.hasPrefix("Binary files ") { isBinary = true }
                if l.hasPrefix("--- ") {
                    let p = String(l.dropFirst(4))
                    if p != "/dev/null", p.hasPrefix("a/") { oldPath = String(p.dropFirst(2)) }
                }
                if l.hasPrefix("+++ ") {
                    let p = String(l.dropFirst(4))
                    if p != "/dev/null", p.hasPrefix("b/") { newPath = String(p.dropFirst(2)) }
                }
                i += 1
            }

            // Hunks
            var oldNo = 0
            var newNo = 0
            while i < lines.count {
                let l = lines[i]
                if l.hasPrefix("diff --git ") { break }
                if l.hasPrefix("@@") {
                    let (oStart, nStart, header) = parseHunkHeader(l)
                    oldNo = oStart
                    newNo = nStart
                    var hunk = GitDiffHunk(header: header, lines: [])
                    i += 1
                    while i < lines.count {
                        let h = lines[i]
                        if h.hasPrefix("diff --git ") || h.hasPrefix("@@") { break }
                        if h.hasPrefix("\\ ") { i += 1; continue } // \ No newline at end of file
                        if h.hasPrefix("+") {
                            hunk.lines.append(GitDiffLine(kind: .add, oldNo: nil, newNo: newNo, text: String(h.dropFirst())))
                            newNo += 1; adds += 1
                        } else if h.hasPrefix("-") {
                            hunk.lines.append(GitDiffLine(kind: .del, oldNo: oldNo, newNo: nil, text: String(h.dropFirst())))
                            oldNo += 1; dels += 1
                        } else {
                            let text = h.hasPrefix(" ") ? String(h.dropFirst()) : h
                            hunk.lines.append(GitDiffLine(kind: .context, oldNo: oldNo, newNo: newNo, text: text))
                            oldNo += 1; newNo += 1
                        }
                        i += 1
                    }
                    hunks.append(hunk)
                } else {
                    i += 1
                }
            }

            let path = newPath ?? oldPath ?? "?"
            files.append(GitDiffFile(
                path: path,
                oldPath: (isRenamed ? oldPath : nil),
                additions: adds,
                deletions: dels,
                isBinary: isBinary,
                isNew: isNew,
                isDeleted: isDeleted,
                isRenamed: isRenamed,
                hunks: hunks
            ))
        }
        return files
    }

    nonisolated private static func parseDiffHeader(_ line: String) -> (String?, String?) {
        // diff --git a/<old> b/<new> — paths may contain spaces; assume no for MVP
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return (nil, nil) }
        let a = parts[2], b = parts[3]
        let old = a.hasPrefix("a/") ? String(a.dropFirst(2)) : a
        let new = b.hasPrefix("b/") ? String(b.dropFirst(2)) : b
        return (old, new)
    }

    nonisolated private static func parseHunkHeader(_ line: String) -> (Int, Int, String) {
        // @@ -oldStart,oldLen +newStart,newLen @@ optional
        var header = ""
        var oStart = 0, nStart = 0
        if let endRange = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) {
            header = String(line[endRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let meta = String(line[line.startIndex..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            // meta = "@@ -a,b +c,d"
            let toks = meta.split(separator: " ").map(String.init)
            for t in toks {
                if t.hasPrefix("-") {
                    let v = t.dropFirst().split(separator: ",").first.map(String.init) ?? "0"
                    oStart = Int(v) ?? 0
                } else if t.hasPrefix("+") {
                    let v = t.dropFirst().split(separator: ",").first.map(String.init) ?? "0"
                    nStart = Int(v) ?? 0
                }
            }
        }
        return (oStart, nStart, header)
    }
}
