//
//  Soul_DesktopTests.swift
//  Soul-DesktopTests
//
//  Created by ilteris kaplan on 5/9/26.
//

import Testing
import Foundation
import SoulCore
@testable import Soul_Desktop

struct Soul_DesktopTests {

    @Test func testRunCaptureLargeOutputDoesNotDeadlock() async throws {
        // Exercises SoulCLI's concurrent stdout/stderr draining against a deterministic
        // large-output source. Drives `/bin/cat` over a generated temp file far larger than
        // a single pipe buffer (64KB on macOS), so a child that out-writes the buffer would
        // wedge if the drain regressed. No `soul` binary / registry
        // dependency, so it can't fast-fail under parallel test contention — the prior flake.
        let bytes = 8 * 1024 * 1024  // 8 MB ≫ 64KB pipe buffer
        let payload = Data(repeating: 0x41 /* 'A' */, count: bytes)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soulcli-drain-\(UUID().uuidString).bin")
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let capture = try await SoulCLI.captureProcess(
            executable: "/bin/cat",
            arguments: [tmp.path]
        )

        #expect(capture.status == 0)
        #expect(capture.stdout.count == bytes)  // byte-exact: nothing dropped or truncated by the drain
        #expect(capture.stderr.isEmpty)
    }

    @Test func safeProcessRunnerCapturesStdinAndStderr() async throws {
        let input = Data("hello runner".utf8)
        let result = try await SafeProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "cat; printf 'warn' >&2"],
            stdin: input,
            timeoutSeconds: 5
        )

        #expect(result.status == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello runner")
        #expect(String(data: result.stderr, encoding: .utf8) == "warn")
        #expect(result.timedOut == false)
    }

    @Test func safeProcessRunnerTimesOutHungChild() async throws {
        let result = try await SafeProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeoutSeconds: 0.2
        )

        #expect(result.status == SafeProcessRunner.timeoutStatus)
        #expect(result.timedOut == true)
    }

    @Test func peekabooCodexMCPSectionRoundTrips() throws {
        let original = """
        model = "gpt-5.5"

        [mcp_servers.node_repl]
        command = "node"
        """

        let enabled = ComputerUseMCPConfig.setCodexPeekaboo(
            original,
            enabled: true,
            command: "/Applications/Soul-Desktop.app/Contents/Helpers/peekaboo"
        )

        #expect(ComputerUseMCPConfig.codexPeekabooEnabled(in: enabled))
        #expect(enabled.contains("[mcp_servers.peekaboo]"))
        #expect(enabled.contains(#"command = "/Applications/Soul-Desktop.app/Contents/Helpers/peekaboo""#))
        #expect(enabled.contains(#"args = ["mcp"]"#))
        #expect(enabled.contains(#"PEEKABOO_DISABLE_TOOLS = "capture,agent,run,config,clean""#))

        let disabled = ComputerUseMCPConfig.setCodexPeekaboo(enabled, enabled: false)

        #expect(!ComputerUseMCPConfig.codexPeekabooEnabled(in: disabled))
        #expect(disabled.contains("[mcp_servers.node_repl]"))
        #expect(!disabled.contains("[mcp_servers.peekaboo]"))
    }

    @Test func peekabooJSONMCPRegistrationWritesExpectedShape() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soul-peekaboo-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("settings.json").path
        try ComputerUseMCPConfig.setJSONEnabled(
            true,
            at: path,
            command: "/Applications/Soul-Desktop.app/Contents/Helpers/peekaboo"
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let peekaboo = try #require(servers["peekaboo"] as? [String: Any])

        #expect(peekaboo["command"] as? String == "/Applications/Soul-Desktop.app/Contents/Helpers/peekaboo")
        #expect(peekaboo["args"] as? [String] == ["mcp"])
        #expect((peekaboo["env"] as? [String: String])?["PEEKABOO_DISABLE_TOOLS"] == "capture,agent,run,config,clean")

        try ComputerUseMCPConfig.setJSONEnabled(false, at: path)
        let disabledData = try Data(contentsOf: URL(fileURLWithPath: path))
        let disabledRoot = try #require(JSONSerialization.jsonObject(with: disabledData) as? [String: Any])
        let disabledServers = try #require(disabledRoot["mcpServers"] as? [String: Any])
        #expect(disabledServers["peekaboo"] == nil)
    }

    @Test func peekabooAppInventoryParserAcceptsServiceEnvelope() throws {
        let output = """
        {
          "success": true,
          "data": {
            "applications": [
              {
                "processIdentifier": 42,
                "bundleIdentifier": "com.apple.Safari",
                "name": "Safari",
                "isActive": false,
                "windowCount": 2
              },
              {
                "pid": 99,
                "bundle_id": "com.apple.finder",
                "app_name": "Finder",
                "is_active": true,
                "window_count": 1
              }
            ]
          }
        }
        """

        let apps = ComputerUseService.parseTargetApps(output)

        #expect(apps.count == 2)
        #expect(apps.first?.name == "Finder")
        #expect(apps.first?.isActive == true)
        #expect(apps.first?.targetArgument == "com.apple.finder")
        #expect(apps[1].detail.contains("2 windows"))
    }

    @Test func peekabooSeeParserExtractsSnapshotAndElements() throws {
        let output = """
        {
          "success": true,
          "data": {
            "snapshot_id": "snap-123",
            "ui_map": "/Users/me/.peekaboo/snapshots/snap-123/snapshot.json",
            "application_name": "Safari",
            "window_title": "Example",
            "element_count": 10,
            "interactable_count": 4,
            "capture_mode": "window",
            "ui_elements": [
              {
                "id": "B1",
                "role": "button",
                "title": "Reload",
                "label": null,
                "description": "Reload this page"
              },
              {
                "id": "T1",
                "role_description": "text field",
                "label": "Address"
              }
            ]
          }
        }
        """

        let inspection = try #require(ComputerUseService.parseInspection(output, imagePath: "/tmp/missing.png"))

        #expect(inspection.snapshotID == "snap-123")
        #expect(inspection.uiMapPath == "/Users/me/.peekaboo/snapshots/snap-123/snapshot.json")
        #expect(inspection.targetDetail == "Safari - Example")
        #expect(inspection.elementCount == 10)
        #expect(inspection.interactableCount == 4)
        #expect(inspection.elements.count == 2)
        #expect(inspection.elements[0].displayName == "Reload")
        #expect(inspection.elements[1].role == "text field")
    }

    @Test func computerUseExecutableResolutionIgnoresPathPeekabooWithoutBundle() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soul-peekaboo-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let tool = dir.appendingPathComponent("peekaboo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let bundleWithoutHelper = dir.appendingPathComponent("SoulDesktop.app", isDirectory: true)

        #expect(ComputerUseService.bundledPeekabooPath(bundleURL: bundleWithoutHelper) == nil)
        #expect(ComputerUseMCPConfig.command(bundleURL: bundleWithoutHelper) == nil)
    }

    @Test func computerUseExecutableResolutionPrefersBundledPeekaboo() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SoulDesktop-\(UUID().uuidString).app", isDirectory: true)
        let helperDir = bundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let bundled = helperDir.appendingPathComponent("peekaboo")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

        #expect(ComputerUseService.bundledPeekabooPath(bundleURL: bundle) == bundled.path)
        #expect(ComputerUseMCPConfig.command(bundleURL: bundle) == bundled.path)
    }

    @Test func computerUsePromptIntentDetectsScreenshotRequests() {
        #expect(ComputerUsePromptIntent.detect(in: "go to Chrome and get a screenshot")?.target == "Google Chrome")
        #expect(ComputerUsePromptIntent.detect(in: "inspect the UI in Xcode")?.target == "Xcode")
        #expect(ComputerUsePromptIntent.detect(in: "inspect Google Chrome's current display state")?.target == "Google Chrome")
        #expect(ComputerUsePromptIntent.detect(in: "tell me what is visible in the browser")?.target == "Google Chrome")
        #expect(ComputerUsePromptIntent.detect(in: "let's start with looking at google chrome and opening up trusslabs.org site and see what's visible. take a screenshot.")?.target == "Google Chrome")
        #expect(ComputerUsePromptIntent.detect(in: "search the repo for screenshot rendering") == nil)
    }

    @Test func computerUseArtifactScannerPrefersAnnotatedSnapshots() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soul-peekaboo-scan-\(UUID().uuidString)", isDirectory: true)
        let snapshot = root.appendingPathComponent("snapshots/ABC", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = snapshot.appendingPathComponent("raw.png")
        let annotated = snapshot.appendingPathComponent("annotated.png")
        try Data("raw".utf8).write(to: raw)
        try Data("annotated".utf8).write(to: annotated)

        let artifacts = ComputerUseArtifactScanner.currentArtifacts(directories: [root])

        #expect(artifacts.count == 1)
        #expect(artifacts.first?.path == annotated.resolvingSymlinksInPath().path)
        #expect(artifacts.first?.title == "Peekaboo screenshot: ABC")
    }

    @Test func computerUseArtifactSignalOnlyMatchesVisualToolActivity() {
        #expect(ComputerUseArtifactSignal.matches(kind: "mcp:peekaboo", title: "see", location: nil))
        #expect(ComputerUseArtifactSignal.matches(kind: "mcp:computer-use", title: "capture screenshot", location: nil))
        #expect(!ComputerUseArtifactSignal.matches(kind: "execute", title: "swift test", location: nil))
        #expect(!ComputerUseArtifactSignal.matches(kind: "search", title: "screenshot renderer source", location: nil))
    }

    @Test func computerUseArtifactsUseStableApplicationSupportDirectory() {
        let appSupport = URL(fileURLWithPath: "/Users/tester/Library/Application Support", isDirectory: true)

        let dir = ComputerUseService.artifactDirectory(applicationSupportDirectory: appSupport)

        #expect(dir.path == "/Users/tester/Library/Application Support/Soul-Desktop/ComputerUse")
        #expect(!dir.path.contains("/tmp"))
        #expect(!dir.path.contains("/T/"))
    }

    @Test func computerUseAgentContextReportsLatestStableInspectionArtifact() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soul-peekaboo-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let older = dir.appendingPathComponent("see-1-AAAA.png")
        let newer = dir.appendingPathComponent("see-2-BBBB.png")
        let annotated = dir.appendingPathComponent("see-3-CCCC_annotated.png")
        try Data("old".utf8).write(to: older)
        try Data("new".utf8).write(to: newer)
        try Data("annotated".utf8).write(to: annotated)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: annotated.path)

        let latest = try #require(ComputerUseAgentContext.latestInspectionArtifactPath(directory: dir))
        #expect(URL(fileURLWithPath: latest).standardizedFileURL == newer.standardizedFileURL)
    }

    @Test func registryWatcherFloorsFullRescanCadence() throws {
        let now = DispatchTime(uptimeNanoseconds: 10_000_000_000)
        let lastFire = DispatchTime(uptimeNanoseconds: 9_000_000_000)

        let deadline = RegistryWatcher.nextFireDeadline(
            now: now,
            lastFireAt: lastFire,
            debounceInterval: 0.25,
            minimumFireInterval: 5
        )

        #expect(deadline.uptimeNanoseconds == 14_000_000_000)
    }

    @Test func registryWatcherUsesDebounceWhenMinimumCadenceElapsed() throws {
        let now = DispatchTime(uptimeNanoseconds: 20_000_000_000)
        let lastFire = DispatchTime(uptimeNanoseconds: 10_000_000_000)

        let deadline = RegistryWatcher.nextFireDeadline(
            now: now,
            lastFireAt: lastFire,
            debounceInterval: 0.25,
            minimumFireInterval: 5
        )

        #expect(deadline.uptimeNanoseconds == 20_250_000_000)
    }

    @Test func testCompactSlashCommandIsRecognized() throws {
        // SOUL-SOUL_DESKTOP-359: /compact must parse as a slash command and
        // be classified as a Soul command so the composer intercepts it
        // (routes to forceCompact) rather than shipping it to the agent.
        #expect(SlashCommandParse.parse("/compact").commandName == "compact")
        #expect(SlashCommandParse.parse("/compact ").commandName == "compact")
        #expect(SlashCommand.compact.isSoulSlashCommand)
        #expect(SlashCommand.compact.name == "compact")
        // A bare prompt is not mistaken for the command.
        #expect(SlashCommandParse.parse("compact the code please").commandName == nil)
    }

    @Test func addProjectPlannerReusesRegisteredProject() throws {
        let resolution = ProjectFolderResolution(
            status: "registered",
            key: "truss-labs",
            name: "Truss Labs",
            matchKind: "primary_path",
            projectPath: "~/Code/truss-labs",
            matchedPath: "~/Code/truss-labs",
            inputPath: "/Users/ilteris/Code/truss-labs",
            projectStatus: "active",
            suggestedKey: nil,
            suggestedName: nil,
            candidates: nil,
            message: nil
        )

        let plan = ProjectAddPlanner.plan(for: resolution, selectedPath: "/Users/ilteris/Code/truss-labs")

        #expect(plan == .useExisting(ProjectAddExisting(
            key: "truss-labs",
            name: "Truss Labs",
            matchKind: "primary_path",
            matchedPath: "~/Code/truss-labs",
            projectPath: "~/Code/truss-labs",
            inputPath: "/Users/ilteris/Code/truss-labs",
            projectStatus: "active"
        )))
    }

    @Test func addProjectPlannerReactivatesRemoteProject() throws {
        let resolution = ProjectFolderResolution(
            status: "registered",
            key: "old-app",
            name: "Old App",
            matchKind: "primary_path",
            projectPath: "~/Code/old-app",
            matchedPath: "~/Code/old-app",
            inputPath: "/Users/ilteris/Code/old-app",
            projectStatus: "remote",
            suggestedKey: nil,
            suggestedName: nil,
            candidates: nil,
            message: nil
        )

        let plan = ProjectAddPlanner.plan(for: resolution, selectedPath: "/Users/ilteris/Code/old-app")

        guard case .useExisting(let existing) = plan else {
            Issue.record("expected existing-project plan")
            return
        }
        #expect(existing.key == "old-app")
        #expect(existing.isKnownRemote == true)
    }

    @Test func addProjectPlannerStillUsesExistingWhenResolverOmitsProjectStatus() throws {
        let resolution = ProjectFolderResolution(
            status: "registered",
            key: "sec-nexus",
            name: nil,
            matchKind: "primary_path",
            projectPath: "~/Code/sec-nexus",
            matchedPath: "~/Code/sec-nexus",
            inputPath: "/Users/ilteris/Code/sec-nexus",
            projectStatus: nil,
            suggestedKey: nil,
            suggestedName: nil,
            candidates: nil,
            message: nil
        )

        let plan = ProjectAddPlanner.plan(for: resolution, selectedPath: "/Users/ilteris/Code/sec-nexus")

        guard case .useExisting(let existing) = plan else {
            Issue.record("expected existing-project plan")
            return
        }
        #expect(existing.key == "sec-nexus")
        #expect(existing.isKnownRemote == false)
    }

    @Test func addProjectPlannerPreservesCompanionWorkspacePath() throws {
        let resolution = ProjectFolderResolution(
            status: "registered",
            key: "truss-labs",
            name: "Truss Labs",
            matchKind: "companion_path",
            projectPath: "~/Code/truss-labs",
            matchedPath: "~/Code/ilteris-company/truss-private",
            inputPath: "/Users/ilteris/Code/ilteris-company/truss-private",
            projectStatus: "active",
            suggestedKey: nil,
            suggestedName: nil,
            candidates: nil,
            message: nil
        )

        let plan = ProjectAddPlanner.plan(
            for: resolution,
            selectedPath: "/Users/ilteris/Code/ilteris-company/truss-private"
        )

        guard case .useExisting(let existing) = plan else {
            Issue.record("expected existing-project plan")
            return
        }
        #expect(existing.key == "truss-labs")
        #expect(existing.workspacePathOverride == "/Users/ilteris/Code/ilteris-company/truss-private")
    }

    @Test func addProjectPlannerShowsCandidatesForAmbiguousFolder() throws {
        let candidates = [
            ProjectFolderResolution.Candidate(
                key: "alpha",
                name: "Alpha",
                matchKind: "primary_path",
                matchedPath: "~/Code/shared",
                projectPath: "~/Code/shared",
                projectStatus: "active"
            ),
            ProjectFolderResolution.Candidate(
                key: "beta",
                name: "Beta",
                matchKind: "companion_path",
                matchedPath: "~/Code/shared",
                projectPath: "~/Code/beta",
                projectStatus: "active"
            )
        ]
        let resolution = ProjectFolderResolution(
            status: "ambiguous",
            key: nil,
            name: nil,
            matchKind: nil,
            projectPath: nil,
            matchedPath: nil,
            inputPath: "/Users/ilteris/Code/shared",
            projectStatus: nil,
            suggestedKey: nil,
            suggestedName: nil,
            candidates: candidates,
            message: nil
        )

        #expect(ProjectAddPlanner.plan(for: resolution, selectedPath: "/Users/ilteris/Code/shared") == .chooseCandidate(candidates))
    }

    @Test func addProjectPlannerSuggestsCreateForUnregisteredRoot() throws {
        let resolution = ProjectFolderResolution(
            status: "unregistered_project_root",
            key: nil,
            name: nil,
            matchKind: "project_shape",
            projectPath: nil,
            matchedPath: nil,
            inputPath: "/Users/ilteris/Code/My App",
            projectStatus: nil,
            suggestedKey: nil,
            suggestedName: nil,
            candidates: nil,
            message: nil
        )

        let plan = ProjectAddPlanner.plan(for: resolution, selectedPath: "/Users/ilteris/Code/My App")

        #expect(plan == .createSuggested(ProjectAddSuggestion(
            key: "my-app",
            name: "My App",
            path: "/Users/ilteris/Code/My App",
            warning: nil
        )))
    }

    @Test func testNativeCompactDirectiveParsing() throws {
        let jsonStr = """
        {
            "action": "native_compact",
            "method": "thread/compact/start",
            "banner": "Compacting Codex context…",
            "provider": "codex"
        }
        """
        guard let data = jsonStr.data(using: .utf8),
              let directive = AutoCompactController.Directive.parse(data)
        else {
            Issue.record("Failed to parse native_compact directive")
            return
        }
        if case .nativeCompact(let method, let banner) = directive {
            #expect(method == "thread/compact/start")
            #expect(banner == "Compacting Codex context…")
        } else {
            Issue.record("Parsed directive was not .nativeCompact")
        }
    }

    @MainActor
    @Test func autoCompactDeferredBannerClearsWhenUsageDropsBelowThreshold() throws {
        let policy = CompactPolicy(
            defaultThreshold: 0.50,
            debounceSeconds: 60,
            perProvider: [
                "codex": .init(threshold: 0.50, rearm: 0.95)
            ]
        )
        let autoCompact = AutoCompactController(enabled: true, policy: policy)
        let thread = ThreadController(provider: .codex, project: Self.codexTestProject())

        thread.isWorking = true
        autoCompact.evaluate(
            thread: thread,
            usage: ContextUsage(tokens: 60, max: 100, isEstimate: false, breakdown: nil)
        )
        #expect(autoCompact.banner == "Compaction queued until current turn completes...")

        thread.isWorking = false
        autoCompact.evaluate(
            thread: thread,
            usage: ContextUsage(tokens: 10, max: 100, isEstimate: false, breakdown: nil)
        )
        #expect(autoCompact.banner == nil)
    }

    @Test func testContextUsageFractionIsLinear() throws {
        // The donut ring draws straight off `fraction` — spent/budget, no
        // nonlinear curve. 79k / 1M must read as ~8% of the ring, not the
        // inflated 60%-knee value the old visualFraction produced.
        let small = ContextUsage(tokens: 79_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(abs(small.fraction - 0.079) < 1e-9)

        let half = ContextUsage(tokens: 100_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(half.fraction == 0.5)

        let full = ContextUsage(tokens: 200_000, max: 200_000, isEstimate: false, breakdown: nil)
        #expect(full.fraction == 1.0)

        // Clamps at 1.0 even when tokens exceed the budget.
        let over = ContextUsage(tokens: 1_200_000, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(over.fraction == 1.0)

        let zero = ContextUsage(tokens: 0, max: 1_000_000, isEstimate: false, breakdown: nil)
        #expect(zero.fraction == 0.0)
    }

    // MARK: - SOUL-379 Codex stream-coalescing contract
    //
    // Pins the drain-ordering invariant the adversarial audit of 2b8f1b2
    // flagged as untested: a future edit that breaks coalescing or the
    // finalize guard now fails a red test instead of silently regressing.

    private static func codexTestProject() -> SoulProject {
        SoulProject(id: "test", name: "Test", path: "/tmp/soul-test",
                    pillar: nil, tier: nil, status: nil,
                    primaryHost: nil, devCommand: nil, devURL: nil)
    }

    @MainActor
    @Test func codexCoalesceBuffersDeltasOffGraphThenFlushesOnce() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let uuid = UUID()
        controller.codexItemMap = ["c1": uuid]
        controller.agentStreamBuffer.registerCodexItem(itemId: "c1", id: uuid, kind: .message, initialText: "")

        controller.enqueueCodexDelta(itemId: "c1", delta: "Hel", kind: .agentText)
        controller.enqueueCodexDelta(itemId: "c1", delta: "lo", kind: .agentText)

        // Pre-flush: the observed transcript is untouched; deltas live in buffers.
        #expect(controller.items.isEmpty)
        #expect(controller.pendingCodexOrder == ["c1"])

        controller.flushPendingCodexDeltas()

        // Post-flush: deltas have moved into the stream buffer, not the
        // observed transcript. Materialization is the explicit UI boundary.
        #expect(controller.items.isEmpty)
        controller.materializeBufferedAgentStreams()
        guard case .agentMessage(_, let post, let complete, _) = controller.items[0] else {
            Issue.record("expected agentMessage"); return
        }
        #expect(post == "Hello")
        #expect(complete == true)
        #expect(controller.pendingCodexOrder.isEmpty)
        #expect(controller.codexFlushScheduled == false)
    }

    @MainActor
    @Test func codexCoalesceKeepsPerItemTextAndIsIdempotent() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let a = UUID(); let b = UUID()
        controller.codexItemMap = ["a": a, "b": b]
        controller.agentStreamBuffer.registerCodexItem(itemId: "a", id: a, kind: .message, initialText: "")
        controller.agentStreamBuffer.registerCodexItem(itemId: "b", id: b, kind: .thought, initialText: "")

        // Interleaved deltas for two items accumulate independently.
        controller.enqueueCodexDelta(itemId: "a", delta: "ans", kind: .agentText)
        controller.enqueueCodexDelta(itemId: "b", delta: "rea", kind: .reasoning)
        controller.enqueueCodexDelta(itemId: "a", delta: "wer", kind: .agentText)
        controller.flushPendingCodexDeltas()
        #expect(controller.items.isEmpty)
        controller.materializeBufferedAgentStreams()

        guard case .agentMessage(_, let aText, _, _) = controller.items[0],
              case .agentThought(_, let bText, _, _) = controller.items[1] else {
            Issue.record("unexpected item shapes"); return
        }
        #expect(aText == "answer")
        #expect(bText == "rea")

        // A second flush with an empty buffer is a no-op (text unchanged).
        controller.flushPendingCodexDeltas()
        guard case .agentMessage(_, let aText2, _, _) = controller.items[0] else {
            Issue.record("unexpected"); return
        }
        #expect(aText2 == "answer")
    }

    @MainActor
    @Test func codexCoalesceLateDeltaDoesNotReopenCompletedBubble() throws {
        // The finalize-guard hardening: a stray delta arriving after the bubble
        // finalized must not flip complete:true back to false or append text.
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        let uuid = UUID()
        controller.items = [.agentMessage(id: uuid, text: "done", complete: true, timestamp: Date())]
        controller.codexItemMap = ["c1": uuid]

        controller.enqueueCodexDelta(itemId: "c1", delta: " extra", kind: .agentText)
        controller.flushPendingCodexDeltas()

        guard case .agentMessage(_, let text, let complete, _) = controller.items[0] else {
            Issue.record("expected agentMessage"); return
        }
        #expect(text == "done")   // late delta dropped
        #expect(complete == true) // bubble stays finalized
    }

    @Test func codexContextWindowResolvesConfiguredModelMaxFromProviderCache() throws {
        let dir = try Self.makeTemporaryDirectory()
        let config = dir.appendingPathComponent("config.toml")
        let cache = dir.appendingPathComponent("models_cache.json")

        try """
        model = "gpt-5.4"
        model_reasoning_effort = "low"

        [projects."/tmp/project"]
        trust_level = "trusted"
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        {
          "models": [
            {
              "slug": "gpt-5.4",
              "context_window": 272000,
              "max_context_window": 1000000
            }
          ]
        }
        """.write(to: cache, atomically: true, encoding: .utf8)

        #expect(CodexContextWindowResolver.resolve(
            configPath: config.path,
            modelsCachePath: cache.path
        ) == 1_000_000)
    }

    @Test func codexConfiguredModelIgnoresProjectSections() throws {
        let dir = try Self.makeTemporaryDirectory()
        let config = dir.appendingPathComponent("config.toml")

        try """
        model = "gpt-5.4"

        [projects."/tmp/project"]
        model = "gpt-5.4-mini"
        """.write(to: config, atomically: true, encoding: .utf8)

        #expect(CodexContextWindowResolver.configuredModel(in: config.path) == "gpt-5.4")
    }

    @MainActor
    @Test func codexTokenUsagePrefersProviderContextWindow() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())

        controller.applyCodexTokenUsage(
            lastTotalTokens: 123_456,
            modelContextWindow: 258_000,
            providerContextWindow: 1_000_000
        )

        #expect(controller.codexTokensUsed == 123_456)
        #expect(controller.codexContextWindow == 1_000_000)
    }

    @MainActor
    @Test func codexTokenUsageFallsBackToLiveEventWindow() throws {
        let controller = ThreadController(provider: .codex, project: Self.codexTestProject())
        controller.didResolveCodexProviderContextWindow = true
        controller.codexProviderContextWindow = nil

        controller.applyCodexTokenUsage(
            lastTotalTokens: 1_200_000,
            modelContextWindow: 272_000,
            providerContextWindow: nil
        )

        #expect(controller.codexTokensUsed == 1_200_000)
        #expect(controller.codexContextWindow == 272_000)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoulDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}
