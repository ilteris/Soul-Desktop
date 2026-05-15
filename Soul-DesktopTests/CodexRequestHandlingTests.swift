import Testing
import Foundation
@testable import Soul_Desktop

@Suite(.serialized)
struct CodexRequestHandlingTests {
    @Test func codexEnvelopeWithIdAndMethodClassifiesAsRequest() {
        var envelope = JSONRPCEnvelope()
        envelope.jsonrpc = nil
        envelope.id = .int(42)
        envelope.method = "item/commandExecution/requestApproval"
        envelope.params = .object(["command": .string("soul finalize")])

        guard let event = CodexClient.classifyEnvelope(envelope) else {
            Issue.record("Expected event")
            return
        }
        switch event {
        case .request(let id, let method, let params):
            #expect(id == .int(42))
            #expect(method == "item/commandExecution/requestApproval")
            #expect(params?["command"]?.stringValue == "soul finalize")
        default:
            Issue.record("Expected request, got \(event)")
        }
    }

    @Test func codexEnvelopeWithoutIdClassifiesAsNotification() {
        var envelope = JSONRPCEnvelope()
        envelope.jsonrpc = nil
        envelope.method = "thread/status/changed"

        guard let event = CodexClient.classifyEnvelope(envelope) else {
            Issue.record("Expected event")
            return
        }
        switch event {
        case .notification(let method, _):
            #expect(method == "thread/status/changed")
        default:
            Issue.record("Expected notification, got \(event)")
        }
    }

    @Test func fullAccessPrefersExecPolicyAmendment() {
        let params: JSONValue = .object([
            "availableDecisions": .array([
                .string("accept"),
                .object([
                    "acceptWithExecpolicyAmendment": .object([
                        "execpolicy_amendment": .array([.string("soul"), .string("finalize")])
                    ])
                ]),
                .string("cancel")
            ])
        ])

        let decision = CodexApprovalPolicy.decision(params: params, permissionMode: .fullAccess)
        guard case .object(let obj)? = decision else {
            Issue.record("Expected object decision")
            return
        }
        #expect(obj["acceptWithExecpolicyAmendment"] != nil)
    }

    @Test func approvalResponseWrapsDecisionField() {
        let params: JSONValue = .object([
            "availableDecisions": .array([
                .object([
                    "acceptWithExecpolicyAmendment": .object([
                        "execpolicy_amendment": .array([.string("soul"), .string("finalize")])
                    ])
                ])
            ])
        ])

        let result = CodexApprovalPolicy.responseResult(params: params, permissionMode: .fullAccess)
        guard case .object(let response) = result,
              case .object(let decision)? = response["decision"] else {
            Issue.record("Expected { decision: { ... } } response")
            return
        }
        #expect(decision["acceptWithExecpolicyAmendment"] != nil)
    }

    @Test func autoReviewCancelsWriteCommand() {
        let params: JSONValue = .object([
            "command": .string("soul finalize"),
            "availableDecisions": .array([.string("accept"), .string("cancel")])
        ])

        let decision = CodexApprovalPolicy.decision(params: params, permissionMode: .autoReview)
        guard case .string(let value)? = decision else {
            Issue.record("Expected string decision")
            return
        }
        #expect(value == "cancel")
    }

    @Test func codexRegistryHooksReplayApprovalAndToolRows() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-hook-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let oldHome = SoulRegistry.homePath
        let oldSoul = SoulRegistry.soulPath
        let oldRegistry = SoulRegistry.registryPath
        SoulRegistry.homePath = tempDir.path
        SoulRegistry.soulPath = tempDir.appendingPathComponent("dotfiles/soul").path
        SoulRegistry.registryPath = tempDir.appendingPathComponent("soul_registry").path
        defer {
            SoulRegistry.homePath = oldHome
            SoulRegistry.soulPath = oldSoul
            SoulRegistry.registryPath = oldRegistry
            try? FileManager.default.removeItem(at: tempDir)
        }

        let project = SoulProject(
            id: "soul-desktop",
            name: "Soul Desktop",
            path: "/tmp/soul-desktop",
            pillar: nil,
            tier: nil,
            status: nil,
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
        let sessionId = UUID().uuidString
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId, event: [
            "event": "CodexApproval",
            "op": "APPROVAL",
            "intent": "Codex command approval handled: soul finalize",
            "provider": "codex",
            "method": "item/commandExecution/requestApproval",
            "decision": "\"accept\"",
            "command": "soul finalize",
            "permission_mode": "full-access",
        ])
        SoulRegistry.appendHook(projectKey: project.id, sessionId: sessionId, event: [
            "event": "AfterTool",
            "tool": "Bash",
            "target": "soul finalize",
            "rationale": "soul finalize",
            "provider": "codex",
            "codex_item_type": "commandExecution",
            "status": "completed",
            "cwd": project.path,
        ])

        let hooksPath = tempDir
            .appendingPathComponent("soul_registry/sessions/\(project.id)/\(sessionId)/hooks.jsonl")
            .path
        let hooks = try String(contentsOfFile: hooksPath, encoding: .utf8)
        #expect(hooks.contains("\"event\":\"CodexApproval\""))
        #expect(hooks.contains("\"op\":\"APPROVAL\""))

        let events = HooksReader.events(forSession: sessionId, project: project)
        #expect(events.contains { event in
            if case .toolCall(_, let kind, let title, let status, _, _) = event.item {
                return kind == "execute" && title == "soul finalize" && status == "completed"
            }
            return false
        })
    }
}
