import Testing
@testable import voxline

@Suite struct RefinementDirectiveTests {
    @Test func promptText_isStablePerDirective() {
        #expect(RefinementDirective.terser.promptText ==
            "Rewrite to be significantly more concise while preserving the full meaning.")
        #expect(RefinementDirective.longer.promptText ==
            "Expand into fuller, more complete sentences; keep the meaning, add no new claims.")
        #expect(RefinementDirective.clearer.promptText ==
            "Rewrite for clarity, grammar, and flow — fix awkward phrasing without changing the meaning or register.")
    }

    @Test func allCases_areTheThreeDirectives() {
        #expect(RefinementDirective.allCases == [.terser, .longer, .clearer])
    }
}
