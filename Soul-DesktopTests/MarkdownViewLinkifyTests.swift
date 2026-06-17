import Foundation
import Testing
@testable import Soul_Desktop

@Suite("MarkdownView path linkification")
struct MarkdownViewLinkifyTests {
    @Test func pathLinkDoesNotAbsorbBoldTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "I will read www/src/pages/sandbox.astro.**Implementing the Split**"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/pages/sandbox.astro"])
    }

    @Test func pathLinkDoesNotAbsorbItalicTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "Check www/src/pages/sandbox.astro._Implementing the Split_"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/pages/sandbox.astro"])
    }

    @Test func ordinaryRelativePathStillLinks() throws {
        let attr = MarkdownView.attributedInline(
            "Open www/src/pages/sandbox.astro for the split controller"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/pages/sandbox.astro"])
    }

    private static func linkedText(in attr: AttributedString) -> [String] {
        attr.runs.compactMap { run in
            guard run.link != nil else { return nil }
            return String(attr.characters[run.range])
        }
    }
}
