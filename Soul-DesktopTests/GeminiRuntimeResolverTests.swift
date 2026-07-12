import Foundation
import Testing
import SoulCore
@testable import Soul_Desktop

struct GeminiRuntimeResolverTests {
    @Test func localGeminiShortcutUsesCheckoutBundle() {
        #expect(
            localGeminiEntryPath(raw: "1", home: "/Users/example")
                == "/Users/example/Code/gemini-cli/bundle/gemini.js"
        )
        #expect(
            localGeminiEntryPath(raw: "true", home: "/Users/example")
                == "/Users/example/Code/gemini-cli/bundle/gemini.js"
        )
    }

    @Test func localGeminiExplicitPathIsExpanded() {
        let expected = "\(NSHomeDirectory())/Code/gemini-cli/custom/gemini.js"
        #expect(localGeminiEntryPath(raw: "~/Code/gemini-cli/custom/gemini.js") == expected)
    }

    @Test func localGeminiSpawnUsesCheckoutBundleWhenShortcutEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-gemini-local-\(UUID().uuidString)", isDirectory: true)
        let bundleDir = root.appendingPathComponent("Code/gemini-cli/bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let geminiJS = bundleDir.appendingPathComponent("gemini.js")
        try "#!/usr/bin/env node\n".write(to: geminiJS, atomically: true, encoding: .utf8)

        let spawn = try #require(localGeminiSpawn(
            env: ["PATH": "/usr/bin"],
            processEnvironment: ["SOUL_GEMINI_LOCAL": "1"],
            home: root.path
        ))

        #expect(spawn.executablePath.hasSuffix("/node"))
        #expect(spawn.arguments.first == geminiJS.path)
        #expect(spawn.arguments.dropFirst().first == "--acp")
    }

    @Test func dotfilesLauncherPrefersDotfilesBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-gemini-runtime-\(UUID().uuidString)", isDirectory: true)
        let dotfilesBin = root.appendingPathComponent("dotfiles/bin", isDirectory: true)
        let userBin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotfilesGemini = dotfilesBin.appendingPathComponent("gemini")
        let userGemini = userBin.appendingPathComponent("gemini")
        try "#!/bin/sh\n".write(to: dotfilesGemini, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: userGemini, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dotfilesGemini.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: userGemini.path)

        #expect(dotfilesGeminiLauncherPath(home: root.path) == dotfilesGemini.path)
    }

    @Test func dotfilesLauncherFallsBackToUserBin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-gemini-runtime-\(UUID().uuidString)", isDirectory: true)
        let userBin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: userBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userGemini = userBin.appendingPathComponent("gemini")
        try "#!/bin/sh\n".write(to: userGemini, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: userGemini.path)

        #expect(dotfilesGeminiLauncherPath(home: root.path) == userGemini.path)
    }

    @Test func dotfilesSpawnUsesLauncherDirectlyWithACPArguments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soul-gemini-runtime-\(UUID().uuidString)", isDirectory: true)
        let dotfilesBin = root.appendingPathComponent("dotfiles/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfilesBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotfilesGemini = dotfilesBin.appendingPathComponent("gemini")
        try "#!/bin/sh\n".write(to: dotfilesGemini, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dotfilesGemini.path)

        let spawn = try #require(dotfilesGeminiSpawn(env: ["PATH": "/usr/bin"], home: root.path))
        #expect(spawn.executablePath == dotfilesGemini.path)
        #expect(spawn.arguments.first == "--acp")
        #expect(spawn.environment?["PATH"] == "/usr/bin")
    }

    @Test func geminiReasoningEffortInheritDoesNotForwardEnv() {
        let env = geminiEnvironment(
            applying: .inherit,
            to: ["PATH": "/usr/bin", "SOUL_REASONING_EFFORT": "high"]
        )

        #expect(env["PATH"] == "/usr/bin")
        #expect(env["SOUL_REASONING_EFFORT"] == nil)
    }

    @Test func geminiReasoningEffortExplicitValueForwardsEnv() {
        let env = geminiEnvironment(
            applying: .medium,
            to: ["PATH": "/usr/bin"]
        )

        #expect(env["SOUL_REASONING_EFFORT"] == "medium")
    }

    @Test func nonGeminiProvidersDoNotForwardReasoningEffortEnv() {
        for provider in [Provider.claude, .codex, .pi] {
            let env = providerEnvironment(
                for: provider,
                applying: .high,
                to: ["PATH": "/usr/bin"]
            )

            #expect(env["PATH"] == "/usr/bin")
            #expect(env["SOUL_REASONING_EFFORT"] == nil)
        }
    }

    @Test func geminiReasoningEffortStorageFallbackUsesInherit() {
        #expect(GeminiReasoningEffort.fromStorage("not-a-valid-effort") == .inherit)
    }
}
