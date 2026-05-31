import Testing
import Foundation
import SoulCore
@testable import Soul_Desktop

struct ThreadItemGrouperTests {
    @Test func fileChangesGroupByLocationAcrossInterleavedTools() {
        let a = tool(kind: "edit", title: "Edit Foo", location: "Foo.swift")
        let search = tool(kind: "search", title: "Search", location: nil)
        let b = tool(kind: "write", title: "Write Foo", location: "Foo.swift")

        let grouped = ThreadItemGrouper.group([a, search, b])

        #expect(grouped.count == 1)
        guard case .toolCallGroup(_, let kind, _, let loc, let items) = grouped[0] else {
            Issue.record("Expected grouped file changes")
            return
        }
        #expect(kind == "edit")
        #expect(loc == "Foo.swift")
        #expect(items == [a, b])
    }

    @Test func verificationToolsCarouselByKindBeforeFileChanges() {
        let readA = tool(kind: "read", title: "Read A", location: "A.swift")
        let readB = tool(kind: "read", title: "Read B", location: "B.swift")
        let execute = tool(kind: "execute", title: "Run tests", location: nil)

        let grouped = ThreadItemGrouper.group([readA, execute, readB])

        #expect(grouped.count == 2)
        guard case .toolCallGroup(_, let kind, _, _, let items) = grouped[0] else {
            Issue.record("Expected read carousel")
            return
        }
        #expect(kind == "read")
        #expect(items == [readA, readB])
        #expect(grouped[1] == execute)
    }

    @Test func verificationToolsAfterFileChangesAreHidden() {
        let edit = tool(kind: "edit", title: "Edit Foo", location: "Foo.swift")
        let read = tool(kind: "read", title: "Read Foo", location: "Foo.swift")
        let execute = tool(kind: "execute", title: "Build", location: nil)

        let grouped = ThreadItemGrouper.group([edit, read, execute])

        #expect(grouped == [edit])
    }

    @Test func userMessageResetsTurnGrouping() {
        let first = tool(kind: "read", title: "Read A", location: "A.swift")
        let user = ThreadItem.userMessage(id: UUID(), text: "next", timestamp: Date())
        let second = tool(kind: "read", title: "Read B", location: "B.swift")

        let grouped = ThreadItemGrouper.group([first, user, second])

        #expect(grouped == [first, user, second])
    }

    @Test func singleItemGroupsUnwrap() {
        let read = tool(kind: "read", title: "Read A", location: "A.swift")

        let grouped = ThreadItemGrouper.group([read])

        #expect(grouped == [read])
    }

    private func tool(kind: String, title: String, location: String?) -> ThreadItem {
        ThreadItem.toolCall(
            id: UUID(),
            kind: kind,
            title: title,
            status: "completed",
            locationHint: location,
            details: nil
        )
    }
}
