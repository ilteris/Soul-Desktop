import Testing
@testable import Soul_Desktop

@Suite("Tool call diff rendering")
struct ToolCallDiffViewTests {
    @Test func oldNewEditRowsOmitUnchangedContext() {
        let old = """
        title: Reference
        live: false
        status: draft
        """
        let new = """
        title: Reference
        live: true
        status: draft
        """

        let rows = DiffView.computeRows(old: old, new: new, startLine: 40)

        #expect(rows == [
            .removed(num: 41, text: "live: false"),
            .added(num: 41, text: "live: true")
        ])
    }

    @Test func oldNewEditRowsPreserveAddedLineNumbersAfterContext() {
        let old = """
        first
        second
        fourth
        """
        let new = """
        first
        second
        third
        fourth
        """

        let rows = DiffView.computeRows(old: old, new: new, startLine: 10)

        #expect(rows == [
            .added(num: 12, text: "third")
        ])
    }
}
