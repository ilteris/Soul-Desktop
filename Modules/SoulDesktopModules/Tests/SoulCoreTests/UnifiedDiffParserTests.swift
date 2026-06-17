import Testing
@testable import SoulCore

@Suite("Unified diff parser")
struct UnifiedDiffParserTests {
    @Test("Codex modify diffs become edited rows without patch headers or context")
    func modifyDiffBecomesChangedRows() throws {
        let diff = """
        --- a/index.astro
        +++ b/index.astro
        @@ -10,7 +10,7 @@
         const title = "Home"
        -const enabled = false
        +const enabled = true
         export default title
        """

        let details = try #require(UnifiedDiffParser.details(from: diff, changeKind: "modify"))
        guard case .patch(let lines) = details.kind else {
            Issue.record("Expected parsed patch rows")
            return
        }

        #expect(details.startLine == 10)
        #expect(lines == [
            ToolCallDetails.DiffLine(kind: .removed, oldLine: 11, newLine: nil, text: "const enabled = false"),
            ToolCallDetails.DiffLine(kind: .added, oldLine: nil, newLine: 11, text: "const enabled = true"),
        ])
    }

    @Test("Codex delete diffs preserve old line numbers")
    func deleteDiffPreservesOldLineNumbers() throws {
        let diff = """
        --- a/index.astro
        +++ b/index.astro
        @@ -42,5 +42,3 @@
         keep()
        -removeOne()
        -removeTwo()
         keepGoing()
        """

        let details = try #require(UnifiedDiffParser.details(from: diff, changeKind: "delete"))
        guard case .patch(let lines) = details.kind else {
            Issue.record("Expected parsed patch rows")
            return
        }

        #expect(details.startLine == 42)
        #expect(lines == [
            ToolCallDetails.DiffLine(kind: .removed, oldLine: 43, newLine: nil, text: "removeOne()"),
            ToolCallDetails.DiffLine(kind: .removed, oldLine: 44, newLine: nil, text: "removeTwo()"),
        ])
    }

    @Test("Codex add diffs become write content without unified diff metadata")
    func addDiffBecomesWriteContent() throws {
        let diff = """
        --- /dev/null
        +++ b/new-file.swift
        @@ -0,0 +1,2 @@
        +let answer = 42
        +print(answer)
        """

        let details = try #require(UnifiedDiffParser.details(from: diff, changeKind: "add"))
        guard case .write(let content) = details.kind else {
            Issue.record("Expected write content")
            return
        }

        #expect(details.startLine == 1)
        #expect(content == "let answer = 42\nprint(answer)")
    }
}
