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

    @Test func explicitMachineVisibilityHidesConversationRow() throws {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "Has real content",
            eventCount: 3,
            promptCount: 1,
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "machine"

        #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
    }

    @Test func scaffoldTitleAloneDoesNotHideConversationRow() throws {
        let project = SessionLedgerTruthTests.testProject()
        let session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "<environment_context> <cwd>/tmp</cwd>",
            eventCount: 3,
            promptCount: 1,
            loadable: true,
            replayable: true
        )

        #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == true)
    }

    @Test func kernelHumanVisibilityBypassesLegacyPartialCaptureHide() throws {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "Partial but visible by contract",
            eventCount: 2,
            promptCount: 2,
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "human"
        session.sessionKind = "partial_capture"
        session.visibilityReason = "partial_capture"
        session.partialCapture = true
        session.hasConversation = false

        #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == true)
    }

    @Test func kernelHiddenVisibilityWinsOverConversationContent() throws {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "Should not render",
            eventCount: 10,
            promptCount: 5,
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "hidden"
        session.sessionKind = "conversation"
        session.visibilityReason = "policy_hidden"

        #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
    }

    @Test func kernelProviderWinsOverLegacySourceFilter() throws {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "Provider contract row",
            source: "claude",
            eventCount: 6,
            promptCount: 3,
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "human"
        session.provider = Provider.geminiCLI.rawValue

        let geminiCtx = SidebarRowResolver.VisibilityContext(
            archivedIds: [],
            showUnreadable: false,
            chatSourceFilter: Provider.geminiCLI.rawValue,
            hideUntitled: false
        )
        let claudeCtx = SidebarRowResolver.VisibilityContext(
            archivedIds: [],
            showUnreadable: false,
            chatSourceFilter: Provider.claude.rawValue,
            hideUntitled: false
        )

        #expect(SidebarRowResolver.shouldShow(session, in: geminiCtx) == true)
        #expect(SidebarRowResolver.shouldShow(session, in: claudeCtx) == false)
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

    @Test func latestFinalizeReadsLedgerFinalizeEvent() throws {
        try SessionLedgerTruthTests.withTempHome { _ in
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString
            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "Finalize",
                "session_id": sid,
                "timestamp": "2026-05-26T17:07:35.296852",
                "intent": "Record PayPal loop status change",
                "summary": "Updated PayPal application state.",
                "rationale": "Recruiter confirmed the role is paused.",
                "next_step": "Keep PayPal paused unless recruiter reopens.",
                "fixed": ["SOUL-001"],
                "source": "codex",
                "status": "finalized",
            ])
            SoulRegistry.flushHooks()

            let rec = try #require(SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid))
            #expect(rec.intent == "Record PayPal loop status change")
            #expect(rec.summary == "Updated PayPal application state.")
            #expect(rec.rationale == "Recruiter confirmed the role is paused.")
            #expect(rec.nextStep == "Keep PayPal paused unless recruiter reopens.")
            #expect(rec.fixed == "SOUL-001")
            #expect(rec.fixedIssues == ["SOUL-001"])
            #expect(rec.handoffPath?.hasSuffix("/\(sid)/hooks.jsonl") == true)
        }
    }

    @Test func latestFinalizePrefersLedgerEventOverLegacyJson() throws {
        try SessionLedgerTruthTests.withTempHome { home in
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString
            let dir = home.appendingPathComponent(".soul/sessions/\(project.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("""
            {"timestamp":"2026-05-25T17:00:00Z","intent":"legacy json","summary":"old"}
            """.utf8).write(to: dir.appendingPathComponent("\(sid).json"))

            SoulRegistry.appendHook(projectKey: project.id, sessionId: sid, event: [
                "event": "Finalize",
                "session_id": sid,
                "timestamp": "2026-05-26T17:07:35.296852",
                "intent": "ledger event",
                "summary": "new",
            ])
            SoulRegistry.flushHooks()

            let rec = try #require(SoulRegistry.latestFinalize(projectKey: project.id, sessionId: sid))
            #expect(rec.intent == "ledger event")
            #expect(rec.summary == "new")
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

    @Test func priorSessionContextDoesNotBecomeResolvedTitle() {
        let prior = """
        <prior_session_context>
        You're resuming an existing Soul Desktop session. Use the following ledger as context.
        </prior_session_context>
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: prior,
            finalizeIntent: nil,
            prompts: [prior, "Fix the sidebar title regression"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Fix the sidebar title regression")
    }

    @Test func liveDisplayTitleIgnoresPriorSessionContextEnvelope() {
        let controller = ThreadController(provider: .geminiCLI, project: SessionLedgerTruthTests.testProject())
        let prior = """
        <prior_session_context>
        You're resuming an existing Soul Desktop session. Use the following ledger as context.
        </prior_session_context>
        """
        controller.customTitle = prior
        controller.items = [
            .userMessage(id: UUID(), text: prior, timestamp: Date()),
            .userMessage(id: UUID(), text: "Restore missing sidebar rows", timestamp: Date()),
        ]

        #expect(controller.displayTitle == "Restore missing sidebar rows")
    }

    @Test func environmentContextDoesNotBecomeResolvedTitle() {
        let environment = """
        <environment_context>
          <cwd>/Users/ilteris/dotfiles/soul</cwd>
          <approval_policy>never</approval_policy>
        </environment_context>
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: environment,
            finalizeIntent: nil,
            prompts: [environment, "Fix app server title cleanup"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Fix app server title cleanup")
    }

    @Test func absolutePathOutputDoesNotBecomeResolvedTitle() {
        let pathOutput = "/Users/ilteris/.zshrc:668: command not found: foo"
        let title = SessionTitleResolver.resolve(.init(
            customTitle: pathOutput,
            finalizeIntent: nil,
            prompts: [pathOutput, "Repair shell startup for app server"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Repair shell startup for app server")
    }

    @Test func placeholderTitleDoesNotOverrideUsefulPrompt() {
        let title = SessionTitleResolver.resolve(.init(
            customTitle: "untitled",
            finalizeIntent: nil,
            prompts: ["Make the sidebar title generator skip scaffolds"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Make the sidebar title generator skip scaffolds")
    }

    @Test func scaffoldOnlyPromptsDoNotDerivePathTitle() {
        let title = SessionTitleResolver.resolve(.init(
            customTitle: nil,
            finalizeIntent: nil,
            prompts: ["/Users/ilteris/.zshrc:668: command not found: foo"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "New chat")
    }

    @Test func resolverMergesDuplicateDiskRowsBeforeVisibility() {
        let sid = UUID().uuidString
        let project = SessionLedgerTruthTests.testProject()
        let empty = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            intent: "untitled",
            loadable: true,
            replayable: true
        )
        var content = empty
        content.timestamp = Date(timeIntervalSince1970: 99)
        content.title = "Restore missing sidebar rows"
        content.promptCount = 3

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [empty, content],
            activeControllers: [],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        #expect(resolved.active.count == 1)
        #expect(resolved.active.first?.id == sid)
        #expect(resolved.active.first?.promptCount == 3)
        #expect(resolved.active.first?.title == "Restore missing sidebar rows")
    }

    @Test func kernelLifecyclePartitionsTrashedRowsOutOfActiveList() {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Trashed by kernel",
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "human"
        session.lifecycle = "trashed"
        session.trashedAt = Date(timeIntervalSince1970: 101)

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [session],
            activeControllers: [],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        #expect(resolved.active.isEmpty)
        #expect(resolved.archived.first?.id == session.id)
    }

    @Test func duplicateMergePreservesKernelSlashAndTaskContracts() {
        let sid = UUID().uuidString
        let project = SessionLedgerTruthTests.testProject()
        var base = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Base",
            loadable: true,
            replayable: true
        )
        var contract = base
        contract.promptCount = 2
        contract.slashSemantics = [
            "clear": SoulSlashCommandSemantics(
                localOnly: true,
                conversationWorthy: false,
                taskAffecting: false,
                titleWorthy: false,
                expansionStrategy: nil
            )
        ]
        contract.taskId = "SOUL-123"
        contract.taskStatus = "in_progress"
        contract.taskSubject = "Lift task association"

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [base, contract],
            activeControllers: [],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        let row = resolved.active.first
        #expect(row?.slashSemantics["clear"]?.localOnly == true)
        #expect(row?.slashSemantics["clear"]?.conversationWorthy == false)
        #expect(row?.taskId == "SOUL-123")
        #expect(row?.taskStatus == "in_progress")
        #expect(row?.taskSubject == "Lift task association")
    }

    @Test func sidebarRowsProjectionCachesRowsAndCounts() {
        let project = SessionLedgerTruthTests.testProject()
        let sid = UUID().uuidString
        let session = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Cache sidebar rows outside body",
            loadable: true,
            replayable: true
        )
        var projection = SidebarRowsProjection()

        let counts = projection.rebuild(
            projects: [project],
            projectIds: nil,
            currentCounts: [:]
        ) { _ in
            SidebarRowResolver.Output(active: [session], archived: [])
        }

        #expect(projection.rowsByProject[project.id]?.active.first?.id == sid)
        #expect(counts[project.id] == 1)
    }

    @Test func sidebarRowsProjectionTargetedRebuildDoesNotResolveOtherProjects() {
        let soul = SessionLedgerTruthTests.testProject()
        var other = SessionLedgerTruthTests.testProject()
        other.id = "other"
        other.name = "Other"
        var projection = SidebarRowsProjection()
        var resolvedProjectIds: [String] = []

        _ = projection.rebuild(
            projects: [soul, other],
            projectIds: Set([soul.id]),
            currentCounts: [other.id: 7]
        ) { project in
            resolvedProjectIds.append(project.id)
            return SidebarRowResolver.Output(active: [], archived: [])
        }

        #expect(resolvedProjectIds == [soul.id])
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
