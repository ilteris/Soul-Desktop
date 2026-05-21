import Testing
import Foundation
@testable import Soul_Desktop

@Suite(.serialized)
struct SoulRegistryBackfillTests {
    
    private func withTempHome(_ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        let oldHome = SoulRegistry.homePath
        let oldSoul = SoulRegistry.soulPath
        let oldSoulHome = SoulRegistry.soulHomePath
        let oldReg = SoulRegistry.registryPath
        
        SoulRegistry.homePath = tempDir.path
        SoulRegistry.soulPath = tempDir.appendingPathComponent("dotfiles/soul").path
        SoulRegistry.soulHomePath = tempDir.appendingPathComponent(".soul").path
        SoulRegistry.registryPath = tempDir.appendingPathComponent("soul_registry").path
        
        defer {
            SoulRegistry.homePath = oldHome
            SoulRegistry.soulPath = oldSoul
            SoulRegistry.soulHomePath = oldSoulHome
            SoulRegistry.registryPath = oldReg
            try? fm.removeItem(at: tempDir)
        }
        
        try body(tempDir)
    }

    @Test func testGeminiJsonHit() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "12345678-1234-1234-1234-123456781234"
            let nativeId = "NATIVE-UUID-1"
            let cwd = "/work/test-proj"
            
            // 1. Setup registry hooks
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hooksPath = hooksDir.appendingPathComponent("hooks.jsonl").path
            let firstPrompt = "Hello agent, please help me with testing."
            let hookLine = "{\"event\":\"UserPrompt\",\"text\":\"\(firstPrompt)\",\"timestamp\":\"2026-05-11T10:00:00.000000\",\"session_id\":\"\(sessionId)\"}\n"
            try hookLine.write(toFile: hooksPath, atomically: true, encoding: .utf8)
            
            // 2. Setup Gemini transcript
            let chatsDir = home.appendingPathComponent(".gemini/tmp/test-proj/chats")
            try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let geminiPath = chatsDir.appendingPathComponent("session-123-\(nativeId.prefix(8)).json").path
            let geminiJson = """
            {
                "sessionId": "\(nativeId)",
                "messages": [
                    {
                        "type": "user",
                        "content": [{"text": "\(firstPrompt)"}]
                    }
                ]
            }
            """
            try geminiJson.write(toFile: geminiPath, atomically: true, encoding: .utf8)
            
            // 3. Run backfill
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: cwd
            )
            
            #expect(result == .hit(nativeId))
            
            // Verify hook was written
            let updatedHooks = try String(contentsOfFile: home.appendingPathComponent(".soul/sessions/\(projectKey)/\(sessionId)/hooks.jsonl").path)
            #expect(updatedHooks.contains("\"event\":\"NativeSessionID\""))
            #expect(updatedHooks.contains("\"nativeId\":\"\(nativeId)\""))
            #expect(updatedHooks.contains("\"source\":\"backfill\""))
        }
    }

    @Test func testGeminiJsonlHit() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "S-JSONL"
            let nativeId = "NATIVE-JSONL"
            let cwd = "/work/test-proj"
            let firstPrompt = "Testing JSONL format matching."
            
            // Setup hooks
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hookLine = "{\"event\":\"UserPrompt\",\"text\":\"\(firstPrompt)\"}\n"
            try hookLine.write(toFile: hooksDir.appendingPathComponent("hooks.jsonl").path, atomically: true, encoding: .utf8)
            
            // Setup Gemini .jsonl
            let chatsDir = home.appendingPathComponent(".gemini/tmp/test-proj/chats")
            try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let geminiPath = chatsDir.appendingPathComponent("session-456.jsonl").path
            let geminiJsonl = """
            {"sessionId": "\(nativeId)"}
            {"type": "user", "content": [{"text": "\(firstPrompt)"}]}
            """
            try geminiJsonl.write(toFile: geminiPath, atomically: true, encoding: .utf8)
            
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: cwd
            )
            
            #expect(result == .hit(nativeId))
        }
    }

    @Test func testClaudeHit() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "claude-proj"
            let sessionId = "S-CLAUDE"
            let nativeId = UUID().uuidString.lowercased()
            let cwd = "/work/claude-proj"
            let firstPrompt = "Claude testing for backfill."
            
            // Setup hooks
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hookLine = "{\"event\":\"UserPrompt\",\"text\":\"\(firstPrompt)\"}\n"
            try hookLine.write(toFile: hooksDir.appendingPathComponent("hooks.jsonl").path, atomically: true, encoding: .utf8)
            
            // Setup Claude .jsonl
            // SoulRegistry.backfillNativeSessionID encodes "/work/claude-proj" as "-work-claude-proj"
            let encodedCwd = "-work-claude-proj"
            let claudeDir = home.appendingPathComponent(".claude/projects/\(encodedCwd)")
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let claudePath = claudeDir.appendingPathComponent("\(nativeId).jsonl").path
            let claudeJsonl = """
            {"type": "user", "message": {"content": "\(firstPrompt)"}}
            """
            try claudeJsonl.write(toFile: claudePath, atomically: true, encoding: .utf8)
            
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "claude",
                cwd: cwd
            )
            
            #expect(result == .hit(nativeId))
        }
    }

    @Test func testAmbiguousMatch() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "S1"
            let cwd = "/work/test-proj"
            let firstPrompt = "Common opening prompt that is long enough to pass."
            
            // Setup hooks
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hookLine = "{\"event\":\"UserPrompt\",\"text\":\"\(firstPrompt)\"}\n"
            try hookLine.write(toFile: hooksDir.appendingPathComponent("hooks.jsonl").path, atomically: true, encoding: .utf8)
            
            // Setup two matching Gemini transcripts
            let chatsDir = home.appendingPathComponent(".gemini/tmp/test-proj/chats")
            try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            
            for i in 1...2 {
                let id = "NATIVE-\(i)"
                let path = chatsDir.appendingPathComponent("session-\(i).json").path
                let json = "{\"sessionId\": \"\(id)\", \"messages\": [{\"type\": \"user\", \"content\": [{\"text\": \"\(firstPrompt)\"}]}]}"
                try json.write(toFile: path, atomically: true, encoding: .utf8)
            }
            
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: cwd
            )
            
            if case .ambiguous(let candidates) = result {
                #expect(Set(candidates) == Set(["NATIVE-1", "NATIVE-2"]))
            } else {
                Issue.record("Expected ambiguous backfill result, got \(result)")
            }
            let updatedHooks = try String(contentsOfFile: home.appendingPathComponent(".soul/sessions/\(projectKey)/\(sessionId)/hooks.jsonl").path)
            #expect(updatedHooks.contains("\"event\":\"BackfillAmbiguous\""))
        }
    }
    
    @Test func testShortCircuit() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "S1"
            let nativeId = "ALREADY-MAPPED"
            
            // Setup hooks with existing NativeSessionID
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hookLine = "{\"event\":\"NativeSessionID\",\"nativeId\":\"\(nativeId)\"}\n"
            try hookLine.write(toFile: hooksDir.appendingPathComponent("hooks.jsonl").path, atomically: true, encoding: .utf8)
            
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: "/any"
            )
            
            #expect(result == .alreadyMapped(nativeId))
        }
    }

    @Test func test64KBCap() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "S1"
            let firstPrompt = "Prompt that is past 64KB mark."
            
            // Setup hooks
            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            try "{\"event\":\"UserPrompt\",\"text\":\"\(firstPrompt)\"}\n".write(toFile: hooksDir.appendingPathComponent("hooks.jsonl").path, atomically: true, encoding: .utf8)
            
            // Setup Gemini .json with 70KB of padding before the sessionId
            let chatsDir = home.appendingPathComponent(".gemini/tmp/test-proj/chats")
            try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let padding = String(repeating: " ", count: 70 * 1024)
            let geminiJson = "{\n\"padding\": \"\(padding)\",\n\"sessionId\": \"NATIVE-1\", \"messages\": [{\"type\": \"user\", \"content\": [{\"text\": \"\(firstPrompt)\"}]}]}"
            try geminiJson.write(toFile: chatsDir.appendingPathComponent("session-large.json").path, atomically: true, encoding: .utf8)
            
            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: "/work/test-proj"
            )
            
            // Should be nil because the 64KB read didn't reach the sessionId or messages
            #expect(result == .miss)
        }
    }

    @Test func testExistingIdentityMappingShortCircuits() throws {
        try withTempHome { home in
            let fm = FileManager.default
            let projectKey = "test-proj"
            let sessionId = "12345678-1234-1234-1234-123456781234"
            let cwd = "/work/test-proj"
            let firstPrompt = "This prompt would otherwise match another transcript."

            let hooksDir = home.appendingPathComponent("soul_registry/sessions/\(projectKey)/\(sessionId)")
            try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
            let hooksPath = hooksDir.appendingPathComponent("hooks.jsonl").path
            let hooks = """
            {"event":"NativeSessionID","nativeId":"\(sessionId)"}
            {"event":"UserPrompt","text":"\(firstPrompt)"}

            """
            try hooks.write(toFile: hooksPath, atomically: true, encoding: .utf8)

            let chatsDir = home.appendingPathComponent(".gemini/tmp/test-proj/chats")
            try fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let nativeId = "99999999-9999-4999-9999-999999999999"
            let geminiJson = "{\"sessionId\":\"\(nativeId)\",\"messages\":[{\"type\":\"user\",\"content\":[{\"text\":\"\(firstPrompt)\"}]}]}"
            try geminiJson.write(toFile: chatsDir.appendingPathComponent("session-hit.json").path, atomically: true, encoding: .utf8)

            let result = SoulRegistry.backfillNativeSessionID(
                projectKey: projectKey,
                sessionId: sessionId,
                provider: "geminiCLI",
                cwd: cwd
            )

            #expect(result == .alreadyMapped(sessionId))
            let updatedHooks = try String(contentsOfFile: hooksPath)
            #expect(updatedHooks.components(separatedBy: "\"event\":\"NativeSessionID\"").count - 1 == 1)
            #expect(!updatedHooks.contains(nativeId))
        }
    }

    @Test func testAppendHookWritesTimezoneExplicitUTC() throws {
        try withTempHome { home in
            let projectKey = "test-proj"
            let sessionId = "12345678-1234-1234-1234-123456781234"

            SoulRegistry.appendHook(projectKey: projectKey, sessionId: sessionId, event: [
                "event": "UserPrompt",
                "text": "Timestamp check",
            ])

            let hooksPath = home
                .appendingPathComponent(".soul/sessions/\(projectKey)/\(sessionId)/hooks.jsonl")
                .path
            let line = try String(contentsOfFile: hooksPath)
            #expect(line.contains("\"timestamp\""))
            #expect(line.contains("Z\""))
        }
    }
}
