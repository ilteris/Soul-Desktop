import Foundation
import Testing
import SoulCore
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
            #expect(session.sessionVisibility == "machine")
            #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
        }
    }

    @Test func desktopMetadataOnlyNativeBindingIsNotRescuedByProviderTranscript() throws {
        try SessionLedgerTruthTests.withTempHome { home in
            let fm = FileManager.default
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString.lowercased()
            let nativeId = UUID().uuidString.lowercased()
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(project.id)/\(sid)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hooks = """
            {"event":"SessionOwner","writer":"soul-desktop","provider":"claude","session_id":"\(sid)","timestamp":"2026-05-28T02:43:27Z"}
            {"event":"NativeSessionID","provider":"claude","native_session_id":"\(nativeId)","session_id":"\(sid)","timestamp":"2026-05-28T02:43:49Z"}

            """
            try hooks.write(to: hooksDir.appendingPathComponent("hooks.jsonl"), atomically: true, encoding: .utf8)

            let claudeDir = home.appendingPathComponent(".claude/projects/-tmp-soul")
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let transcript = """
            {"type":"user","message":{"content":"Our soul CLI commands should be included in the system instructions."}}
            {"type":"assistant","message":{"content":"Added the hydrator block."}}

            """
            try transcript.write(to: claudeDir.appendingPathComponent("\(nativeId).jsonl"), atomically: true, encoding: .utf8)

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.sessionVisibility == "machine")
            #expect(session.sessionKind == "metadata_only")
            #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
        }
    }

    @Test func externalMetadataOnlyNativeBindingStaysHiddenWhenKernelSaysMachine() throws {
        try SessionLedgerTruthTests.withTempHome { home in
            let fm = FileManager.default
            let project = SessionLedgerTruthTests.testProject()
            let sid = UUID().uuidString.lowercased()
            let nativeId = UUID().uuidString.lowercased()
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(project.id)/\(sid)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hooks = """
            {"event":"SessionOwner","writer":"terminal","provider":"claude","session_id":"\(sid)","timestamp":"2026-05-28T02:43:27Z"}
            {"event":"NativeSessionID","provider":"claude","native_session_id":"\(nativeId)","session_id":"\(sid)","timestamp":"2026-05-28T02:43:49Z"}

            """
            try hooks.write(to: hooksDir.appendingPathComponent("hooks.jsonl"), atomically: true, encoding: .utf8)

            let claudeDir = home.appendingPathComponent(".claude/projects/-tmp-soul")
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let transcript = """
            {"type":"user","message":{"content":"Fix the sidebar session routing regression."}}
            {"type":"assistant","message":{"content":"I traced and fixed the routing issue."}}

            """
            try transcript.write(to: claudeDir.appendingPathComponent("\(nativeId).jsonl"), atomically: true, encoding: .utf8)

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.sessionVisibility == "machine")
            #expect(session.sessionKind == "metadata_only")
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
            source: "claude",
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

    @Test func unownedKernelPartialCaptureIsHiddenAsFixtureNoise() throws {
        let project = SessionLedgerTruthTests.testProject()
        var session = SoulSession(
            id: UUID().uuidString,
            project: project.id,
            timestamp: Date(),
            title: "hello",
            eventCount: 2,
            promptCount: 1,
            loadable: true,
            replayable: true
        )
        session.sessionVisibility = "human"
        session.sessionKind = "partial_capture"
        session.visibilityReason = "partial_capture"
        session.partialCapture = true
        session.writer = .unknown

        #expect(SidebarRowResolver.shouldShow(session, in: Self.defaultCtx) == false)
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
            let dir = home.appendingPathComponent("soul_registry/sessions/\(project.id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let finalize = dir.appendingPathComponent("\(sid).json")
            try Data("""
            {"timestamp":"2026-05-22T17:00:00Z","summary":"Administrative summary only"}
            """.utf8).write(to: finalize)

            let session = try #require(SoulRegistry.allSessions(forProject: project.id, projectPath: project.path).first { $0.id == sid })
            #expect(session.sessionVisibility == "machine")
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
            let dir = home.appendingPathComponent("soul_registry/sessions/\(project.id)")
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
        controller.isHydrating = false

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
        controller.isHydrating = false
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

    @Test func codexFilesMentionedEnvelopeUsesRequestForTitle() {
        let codexEnvelope = """
        # Files mentioned by the user:

        ## Screenshot 2026-05-27 at 8.13.05 PM.png: /var/folders/example/Screenshot.png

        ## My request for Codex:
        when I do `/pulse` I get this error in the xcode console. when I start typing `/` I see too many commands
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: nil,
            finalizeIntent: nil,
            prompts: [codexEnvelope],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "when I do /pulse I get this error in the xcode console. when…")
    }

    @Test func promptCopyCustomTitleDoesNotWinOverAgentFallback() {
        let prompt = "a problem that I notice is if I resize the application window, it jumps the scroll to the middle of the view. investigate"
        let title = SessionTitleResolver.resolve(.init(
            customTitle: prompt,
            finalizeIntent: nil,
            prompts: [prompt],
            firstAgentLine: "Patched transcript resize anchoring in ThreadView.swift.",
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Patched transcript resize anchoring in ThreadView.swift.")
    }

    @Test func codexFilesEnvelopePromptCopyCustomTitleDoesNotWin() {
        let codexEnvelope = """
        # Files mentioned by the user:

        ## Screenshot.png: /var/folders/example/Screenshot.png

        ## My request for Codex:
        why do I get this when I try to resume?
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: "why do I get this when I try to resume?",
            finalizeIntent: nil,
            prompts: [codexEnvelope],
            firstAgentLine: "Fixed Codex resume handling",
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Fixed Codex resume handling")
    }

    @Test func codexOverviewEnvelopeDoesNotBecomeResolvedTitle() {
        let codexOverview = """
        # Overview

        Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project: /Users/ilteris/Code/Soul-Desktop

        Get an understanding of the user's intent and goals by deeply viewing their connected apps.
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: nil,
            finalizeIntent: nil,
            prompts: [codexOverview, "Fix the session title resolver"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Fix the session title resolver")
    }

    @Test func jsonAssistantFallbackDoesNotBecomeResolvedTitle() {
        let title = SessionTitleResolver.resolve(.init(
            customTitle: nil,
            finalizeIntent: nil,
            prompts: ["# Overview\n\nGenerate 0 to 3 hyperpersonalized suggestions"],
            firstAgentLine: #"{"suggestions":[{"title":"Extract project mutations"}]}"#,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "New chat")
    }

    @Test func registryPulseScaffoldDoesNotBecomeResolvedTitle() {
        let pulseScaffold = """
        You are Teddy, the Systems Architect. Perform a Registry Pulse.

        1. **Execution**:
           - Call the kernel:
             `python3 ~/dotfiles/soul/kernel/commands/pulse.py`

        2. **Report**:
           - Summarize the active task, pending tasks, and recent session activity shown in the output.
        """
        let title = SessionTitleResolver.resolve(.init(
            customTitle: pulseScaffold,
            finalizeIntent: nil,
            prompts: [pulseScaffold, "Check stalled tasks"],
            firstAgentLine: nil,
            branchSummary: nil,
            skillHint: nil
        ))

        #expect(title == "Check stalled tasks")
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

    @Test func resolverMergesDuplicateDiskRowsWithMachineVisibilityWinning() {
        let sid = UUID().uuidString
        let project = SessionLedgerTruthTests.testProject()
        var human = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            title: #"23:55:24 ← wire: {"jsonrpc":"2.0","method":"session/update"}"#,
            source: Provider.codex.rawValue,
            eventCount: 3,
            promptCount: 1,
            loadable: true,
            replayable: true
        )
        human.sessionVisibility = "human"
        human.sessionKind = "partial_capture"

        var machine = human
        machine.promptCount = 0
        machine.sessionVisibility = "machine"
        machine.sessionKind = "acp_wire_trace"
        machine.visibilityReason = "acp_wire_trace"

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [human, machine],
            activeControllers: [],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        #expect(resolved.active.isEmpty)
    }

    @Test func activeControllerOverlayPromotesLiveGeneratedTitle() {
        let sid = UUID().uuidString
        let project = SessionLedgerTruthTests.testProject()
        let disk = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            intent: "/pulse",
            loadable: true,
            replayable: true
        )
        let controller = ThreadController(provider: .geminiCLI, project: project)
        controller.sessionId = sid
        controller.items = [
            .userMessage(id: UUID(), text: "/pulse", timestamp: Date(timeIntervalSince1970: 100)),
            .userMessage(
                id: UUID(),
                text: "register a task for pick a portfolio project and draft first real MDX case study",
                timestamp: Date(timeIntervalSince1970: 101)
            )
        ]
        controller.customTitle = "Register Task: Portfolio Project and MDX Case Study"

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [disk],
            activeControllers: [controller],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        let row = resolved.active.first
        #expect(row?.title == "Register Task: Portfolio Project and MDX Case Study")
        #expect(row?.intent == "/pulse")
    }

    @Test func activeControllerOverlayDoesNotReplaceDiskTitleWithPlaceholder() {
        let sid = UUID().uuidString
        let project = SessionLedgerTruthTests.testProject()
        var disk = SoulSession(
            id: sid,
            project: project.id,
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Saved Meta Design Producer Job Notes",
            loadable: true,
            replayable: true
        )
        disk.promptCount = 2
        disk.transcriptTurns = 2
        let controller = ThreadController(provider: .claude, project: project)
        controller.sessionId = sid
        controller.isHydrating = true
        controller.items = []

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: project.id,
            diskSessions: [disk],
            activeControllers: [controller],
            draft: nil,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        #expect(resolved.active.first?.title == "Saved Meta Design Producer Job Notes")
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

    @Test func resolverFiltersActiveControllersAndDraftByProjectKey() {
        let projectA = SessionLedgerTruthTests.testProject()
        let projectB = SoulProject(
            id: "ilteriskaplan.com",
            name: "ilteriskaplan.com",
            path: "/tmp/ilteris",
            pillar: "Platform",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )

        let controllerB = ThreadController(provider: .geminiCLI, project: projectB)
        controllerB.sessionId = "session-b"
        controllerB.items = [
            .userMessage(id: UUID(), text: "Hello B", timestamp: Date())
        ]

        let draftB = SoulSession(
            id: "draft-b",
            project: projectB.id,
            timestamp: Date(),
            title: "Draft B",
            loadable: true,
            replayable: true
        )

        let resolved = SidebarRowResolver.resolve(.init(
            projectKey: projectA.id,
            diskSessions: [],
            activeControllers: [controllerB],
            draft: draftB,
            archivedIds: [],
            starredIds: [],
            visibilityContext: Self.defaultCtx
        ))

        #expect(resolved.active.isEmpty)
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
        SoulRegistry.invalidateCache()

        SoulRegistry.homePath = tempDir.path
        SoulRegistry.soulPath = tempDir.appendingPathComponent("dotfiles/soul").path
        SoulRegistry.registryPath = tempDir.appendingPathComponent("soul_registry").path
        SoulRegistry.soulHomePath = SoulRegistry.registryPath
        // The Swift-side `SoulRegistry.*Path` swizzle only steers in-process
        // file I/O. `allSessions` subprocesses to `soul session list --json`,
        // and the current kernel scans strictly SOUL_REGISTRY/sessions.
        // Keep Desktop's primary write root and the kernel read root aligned.
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
            SoulRegistry.invalidateCache()
            try? fm.removeItem(at: tempDir)
        }

        try body(tempDir)
    }
}
