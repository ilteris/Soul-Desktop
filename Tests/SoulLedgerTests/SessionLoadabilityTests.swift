import Foundation
import Testing
import SoulLedger

@Suite("SoulLedger session loadability")
struct SessionLoadabilityTests {
    @Test("detects project-bounded Claude native transcript")
    func claudeCanLoadFromDisk() throws {
        let fixture = try Fixture()
        let project = LedgerProject(id: "app", name: "App", path: "\(fixture.root.path)/Code/My-App")
        let encoded = LedgerSessionLoadability.claudeEncodedCwd(project.path)
        let dir = fixture.home.appendingPathComponent(".claude/projects/\(encoded)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{}\n".write(
            to: dir.appendingPathComponent("sid-1.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        #expect(LedgerSessionLoadability.canLoadFromDisk(
            sessionId: "sid-1",
            project: project,
            sessionDir: fixture.sessionDir,
            homeDirectory: fixture.home.path
        ))
    }

    @Test("discovers Gemini session by project root marker")
    func geminiDiscoverUsesProjectRootMarker() throws {
        let fixture = try Fixture()
        let projectPath = "\(fixture.root.path)/Projects/DuplicateName"
        let project = LedgerProject(id: "dup", name: "Duplicate", path: projectPath)
        let chats = fixture.home.appendingPathComponent(".gemini/tmp/random-slug/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        try projectPath.write(
            to: fixture.home.appendingPathComponent(".gemini/tmp/random-slug/.project_root"),
            atomically: true,
            encoding: .utf8
        )
        let transcript = chats.appendingPathComponent("abc12345.jsonl")
        try (#"{"sessionId":"abc12345-session"}"# + "\n" + #"{"type":"message"}"#).write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )

        let hit = try #require(LedgerSessionLoadability.discover(
            sessionId: "abc12345-session",
            activeProjects: [project],
            sessionRoots: [fixture.sessions.path],
            homeDirectory: fixture.home.path
        ))

        #expect(hit.provider == "geminiCLI")
        #expect(hit.cwd == projectPath)
        #expect(URL(fileURLWithPath: hit.transcriptPath).standardizedFileURL.path == transcript.standardizedFileURL.path)
    }

    @Test("discovers Pi session and decodes cwd through active projects")
    func piDiscoverUsesActiveProjectForHyphenatedPath() throws {
        let fixture = try Fixture()
        let project = LedgerProject(id: "soul", name: "Soul", path: "\(fixture.root.path)/Code/Soul-Desktop")
        let encoded = LedgerSessionLoadability.piEncodedCwd(project.path)
        let dir = fixture.home.appendingPathComponent(".pi/agent/sessions/\(encoded)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("20260525_pi-session.jsonl")
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let hit = try #require(LedgerSessionLoadability.discover(
            sessionId: "pi-session",
            activeProjects: [project],
            sessionRoots: [fixture.sessions.path],
            homeDirectory: fixture.home.path
        ))

        #expect(hit.provider == "pi")
        #expect(hit.cwd == project.path)
        #expect(hit.transcriptPath == transcript.path)
    }

    @Test("discovers Codex transcript from session roots")
    func codexDiscoverUsesSessionRoots() throws {
        let fixture = try Fixture()
        let project = LedgerProject(id: "soul", name: "Soul", path: "\(fixture.root.path)/Code/Soul-Desktop")
        let dir = fixture.sessions.appendingPathComponent("soul/codex-session")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcript = dir.appendingPathComponent("transcript.jsonl")
        try "{}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let hit = try #require(LedgerSessionLoadability.discover(
            sessionId: "codex-session",
            activeProjects: [project],
            sessionRoots: [fixture.sessions.path],
            homeDirectory: fixture.home.path
        ))

        #expect(hit.provider == "codex")
        #expect(hit.cwd == project.path)
        #expect(hit.transcriptPath == transcript.path)
    }
}

private struct Fixture {
    let root: URL
    let home: URL
    let sessions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-loadability-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    func sessionDir(projectKey: String, sessionId: String) -> String {
        sessions.appendingPathComponent("\(projectKey)/\(sessionId)").path
    }
}
