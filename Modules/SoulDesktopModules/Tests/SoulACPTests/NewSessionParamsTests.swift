import Foundation
import Testing
@testable import SoulACP

/// SOUL-SOUL_DESKTOP-356: the `_meta.systemPrompt` path of `session/new`
/// must always carry `mcpServers`. Dropping it when empty made
/// claude-agent-acp reject every Claude stall/stop-recovery resume with
/// `-32602 Invalid params`, since that path is the only one that sets a
/// system-meta preamble and most sessions run zero MCP servers.
@Suite("session/new params (meta systemPrompt branch)")
struct NewSessionParamsTests {

    @Test("mcpServers is always present, even with no servers")
    func mcpServersAlwaysPresent() {
        let p = ACPClient.newSessionParams(
            cwd: "/tmp/project",
            mcpServersJSON: nil,
            systemPrompt: "you are a helpful agent"
        )
        // The bug: this key used to be absent when mcpServers was empty.
        guard case .array(let servers)? = p["mcpServers"] else {
            Issue.record("mcpServers must be present; got \(String(describing: p["mcpServers"]))")
            return
        }
        #expect(servers.isEmpty)
        #expect(p["cwd"] == .string("/tmp/project"))
        guard case .object(let meta)? = p["_meta"] else {
            Issue.record("_meta must carry the systemPrompt")
            return
        }
        #expect(meta["systemPrompt"] == .string("you are a helpful agent"))
    }

    @Test("provided mcpServers JSON is preserved")
    func mcpServersPreserved() {
        let servers: JSONValue = .array([.object(["name": .string("github")])])
        let p = ACPClient.newSessionParams(
            cwd: "/tmp/project",
            mcpServersJSON: servers,
            systemPrompt: "sys"
        )
        #expect(p["mcpServers"] == servers)
    }
}
