import Foundation
import Testing
@testable import Soul_Desktop

@Suite(.serialized)
@MainActor
struct SessionLedgerTruthTests {
    /// Default visibility context: no archive filter, no source filter,
    /// don't hide unreadable, don't hide untitled. Mirrors what the sidebar
    /// uses for a freshly-loaded project before any user filter toggles.
    /// Post-SOUL-270 the `substantive` flag was folded into the resolver;
    /// these tests now assert the actual visibility outcome instead.
    private static let defaultCtx = SidebarRowResolver.VisibilityContext(
        archivedIds: [],
        showUnreadable: false,
        chatSourceFilter: nil,
        hideUntitled: false
    )

    @Test func metadataOnlyLedgerIsNotVisibleConversation() throws {
        try SessionLedgerTruthTests.withTempHome { _ in
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "NativeSessionID",
                "provider": "geminiCLI",
                "native_session_id": "native-\(sid)",
            ])
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "Title",
                "title": "New chat",
            ])
            SoulRegistry.flushHooks()

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.promptCount == 0)
            #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
        }
    }

    @Test func promptBearingLedgerIsVisibleConversation() throws {
        try SessionLedgerTruthTests.withTempHome { _ in
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "NativeSessionID",
                "provider": "geminiCLI",
                "native_session_id": "native-\(sid)",
            ])
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "UserPrompt",
                "text": "Explain the ledger contract",
            ])
            // AfterAgent must follow the UserPrompt — otherwise the kernel
            // tags the row `partial_capture: true` (UserPrompt with zero
            // AfterAgent content) and the resolver drops it via rule
            // 1a-partial-capture, masking the visibility outcome we
            // actually want to assert here.
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "AfterAgent",
                "content": "Here's how it works.",
            ])
            SoulRegistry.flushHooks()

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.promptCount == 1)
            #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == true)
        }
    }

    @Test func finalizeOnlyRecordIsNotVisibleConversation() throws {
        try SessionLedgerTruthTests.withTempHome { home in
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString
            let dir = home.appendingPathComponent(".soul/sessions/\(project.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let finalize = dir.appendingPathComponent("\(sid).json")
            try Data("""
            {"timestamp":"2026-05-22T17:00:00Z","summary":"Administrative summary only"}
            """.utf8).write(to: finalize)

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.promptCount == 0)
            #expect(session.eventCount == 0)
            #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
        }
    }

    @Test func freshAcceptedPromptAssignsSessionIdBeforeDispatch() {
        let controller = ThreadController(provider: .geminiCLI, project: SessionLedgerTruthTests.testProject())

        let pending = controller.acceptUserPrompt(display: "hello", agent: "hello")

        #expect(pending != nil)
        #expect(controller.sessionId == controller.id)
        #expect(controller.items.contains { item in
            if case .userMessage(_, let text, _) = item {
                return text == "hello"
            }
            return false
        })
    }

    @Test func queuedPromptEditReportsAcceptanceOnlyWhenQueueStillOwnsItem() {
        let controller = ThreadController(provider: .geminiCLI, project: SessionLedgerTruthTests.testProject())
        controller.isWorking = true
        _ = controller.acceptUserPrompt(display: "first", agent: "first")
        _ = controller.acceptUserPrompt(display: "queued", agent: "queued")
        let queuedId = try! #require(controller.queuedPrompts.first?.itemId)

        #expect(controller.editQueuedPrompt(itemId: queuedId, newText: "replacement") == true)
        #expect(controller.queuedPrompts.first?.display == "replacement")
        #expect(controller.editQueuedPrompt(itemId: UUID(), newText: "lost text") == false)
        #expect(controller.editQueuedPrompt(itemId: queuedId, newText: "   ") == false)
    }

    private static func testProject() -> SoulProject {
        SoulProject(
            id: "soul",
            name: "Soul",
            path: "/tmp/soul",
            pillar: "Platform",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
    }

    private static func withTempHome(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ledger-truth-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oldHome = SoulRegistry.homePath
        let oldSoul = SoulRegistry.soulPath
        let oldSoulHome = SoulRegistry.soulHomePath
        let oldRegistry = SoulRegistry.registryPath
        let oldSoulRegistryEnv = ProcessInfo.processInfo.environment["SOUL_REGISTRY"]
        let oldSoulHomeEnv = ProcessInfo.processInfo.environment["SOUL_HOME"]

        SoulRegistry.homePath = tempDir.path
        SoulRegistry.soulPath = tempDir.appendingPathComponent("dotfiles/soul").path
        SoulRegistry.soulHomePath = tempDir.appendingPathComponent(".soul").path
        SoulRegistry.registryPath = tempDir.appendingPathComponent("soul_registry").path
        // The Swift-side `SoulRegistry.*Path` swizzle only steers in-process
        // file I/O. `allSessions` now subprocesses to `soul session list
        // --json` (kernel CLI), and that child reads from BOTH
        // SOUL_HOME/sessions (primary) AND SOUL_REGISTRY/sessions (legacy)
        // — see soul_session_view.py:39-40.
        //
        // `appendHook` writes to `primarySessionsRoot = soulHomePath/sessions`
        // — so SOUL_HOME for the kernel child must match `soulHomePath`,
        // not `registryPath` (those resolve to different temp subdirs).
        // SOUL_REGISTRY points at `registryPath` so the legacy fallback
        // also lands inside the temp tree (defense in depth — primary
        // scan should already hit).
        setenv("SOUL_HOME", SoulRegistry.soulHomePath, 1)
        setenv("SOUL_REGISTRY", SoulRegistry.registryPath, 1)

        defer {
            if let v = oldSoulRegistryEnv { setenv("SOUL_REGISTRY", v, 1) }
            else { unsetenv("SOUL_REGISTRY") }
            if let v = oldSoulHomeEnv { setenv("SOUL_HOME", v, 1) }
            else { unsetenv("SOUL_HOME") }
            SoulRegistry.homePath = oldHome
            SoulRegistry.soulPath = oldSoul
            SoulRegistry.soulHomePath = oldSoulHome
            SoulRegistry.registryPath = oldRegistry
            try? fm.removeItem(at: tempDir)
        }

        try body(tempDir)
    }
}
