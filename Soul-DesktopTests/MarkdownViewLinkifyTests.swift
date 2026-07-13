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

    @Test func pathLinkDoesNotAbsorbPlainTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "I will read www/src/pages/sandbox.astro.Implementing the Split"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/pages/sandbox.astro"])
    }

    @Test func filenameLinkDoesNotAbsorbPlainTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "Read README.md.Implementing the Split"
        )

        #expect(Self.linkedText(in: attr) == ["README.md"])
    }

    @Test func pathLinkDoesNotAbsorbAcronymTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "Read docs/README.md.API changes"
        )

        #expect(Self.linkedText(in: attr) == ["docs/README.md"])
    }

    @Test func pathLinkDoesNotAbsorbSingleLetterTitleAfterFilename() throws {
        let attr = MarkdownView.attributedInline(
            "Read docs/README.md.A plan"
        )

        #expect(Self.linkedText(in: attr) == ["docs/README.md"])
    }

    @Test func ordinaryRelativePathStillLinks() throws {
        let attr = MarkdownView.attributedInline(
            "Open www/src/pages/sandbox.astro for the split controller"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/pages/sandbox.astro"])
    }

    @Test func dottedComponentFilenameStillLinksFully() throws {
        let attr = MarkdownView.attributedInline(
            "Open www/src/components/Button.Stories.tsx for the story"
        )

        #expect(Self.linkedText(in: attr) == ["www/src/components/Button.Stories.tsx"])
    }

    @Test func latexArrowFallbackRendersAsGlyphInProse() throws {
        let attr = MarkdownView.attributedInline(
            #"/Users/ilteris/Code/klaweht-blog $\rightarrow$ <cwd>"#
        )

        #expect(String(attr.characters).contains("/Users/ilteris/Code/klaweht-blog → <cwd>"))
        #expect(!String(attr.characters).contains(#"$\rightarrow$"#))
        #expect(Self.linkedText(in: attr) == ["/Users/ilteris/Code/klaweht-blog"])
    }

    @Test func latexArrowFallbackSkipsInlineCode() throws {
        let attr = MarkdownView.attributedInline(
            #"Keep `$\rightarrow$` literal inside code"#
        )

        #expect(String(attr.characters).contains(#"$\rightarrow$"#))
    }

    private static func linkedText(in attr: AttributedString) -> [String] {
        attr.runs.compactMap { run in
            guard run.link != nil else { return nil }
            return String(attr.characters[run.range])
        }
    }
}
