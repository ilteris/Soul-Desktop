import Testing
@testable import Soul_Desktop

@Suite("Specialist Palette")
struct SpecialistPaletteTests {
    @Test
    func parsesGeminiSoulDelegateCommand() {
        let parsed = SpecialistPalette.parseDelegateCommand(
            #"soul delegate product_shaper "Audit the player failure" --project truss-labs"#
        )

        #expect(parsed?.specialist == "product_shaper")
        #expect(parsed?.objective == "Audit the player failure")
    }

    @Test
    func parsesPythonWrappedSoulDelegateCommand() {
        let parsed = SpecialistPalette.parseDelegateCommand(
            #".venv/bin/python /Users/ilteris/dotfiles/soul/bin/soul delegate adversarial_judge "Second opinion" --project soul --provider claude"#
        )

        #expect(parsed?.specialist == "adversarial_judge")
        #expect(parsed?.objective == "Second opinion")
    }

    @Test
    func parsesDelegationIdFromSoulOutput() {
        let output = "Delegating to @product_shaper (ID: e6de69ab, Provider: claude)..."

        #expect(SpecialistPalette.parseDelegationId(from: output) == "e6de69ab")
    }
}
