import Testing
import Foundation
@testable import Soul_Desktop

@MainActor
struct ThreadControllerTests {

    @Test func testScrollAnchorResetOnSend() async throws {
        let project = SoulProject(
            id: "test",
            name: "Test Project",
            path: "/tmp",
            pillar: "test",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
        let controller = ThreadController(provider: .geminiCLI, project: project)
        
        // Simulate a scroll anchor being set
        let midId = UUID()
        controller.scrollAnchorItemId = midId
        controller.scrollAnchorAtBottom = false
        
        // Sending a message should reset the anchor to the bottom
        await controller.send("hello")
        
        #expect(controller.scrollAnchorAtBottom == true)
        #expect(controller.scrollAnchorItemId == nil)
    }

    @Test func testDisplayTitleHeuristics() async throws {
        let project = SoulProject(
            id: "test",
            name: "Test Project",
            path: "/tmp",
            pillar: "test",
            tier: 1,
            status: "active",
            primaryHost: nil,
            devCommand: nil,
            devURL: nil
        )
        let controller = ThreadController(provider: .geminiCLI, project: project)
        
        #expect(controller.displayTitle == "New chat")
        
        // First user message should become the title
        let id1 = UUID()
        controller.items.append(ThreadItem.userMessage(id: id1, text: "How to bake a cake?", timestamp: Date()))
        #expect(controller.displayTitle == "How to bake a cake?")
        
        // Multi-line should be truncated and flattened
        let id2 = UUID()
        controller.items[0] = ThreadItem.userMessage(id: id2, text: "First line\nSecond line", timestamp: Date())
        #expect(controller.displayTitle == "First line Second line")
        
        // Slash commands should be skipped in favor of agent response if possible
        let id3 = UUID()
        controller.items[0] = ThreadItem.userMessage(id: id3, text: "/ls", timestamp: Date())
        #expect(controller.displayTitle == "/ls") // fallback to user if no agent yet
        
        let id4 = UUID()
        controller.items.append(ThreadItem.agentMessage(id: id4, text: "Here is the list of files:\n- index.ts\n- package.json", complete: true, timestamp: Date()))
        #expect(controller.displayTitle == "Here is the list of files:")
    }
}
