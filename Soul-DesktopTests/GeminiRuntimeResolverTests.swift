import Foundation
import Testing
import SoulCore
@testable import Soul_Desktop

struct GeminiRuntimeResolverTests {
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
}
