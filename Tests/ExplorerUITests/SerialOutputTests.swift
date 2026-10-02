import Testing
@testable import ExplorerUI

@Suite("Serial output VT100 filter")
struct SerialOutputTests {
    @Test func removesBasicCsiFormattingAndCursorCommands() {
        var filter = VT100Filter()
        let input = "normal \u{1B}[31mred\u{1B}[0m\n\u{1B}[2Kready\u{1B}[1;4H!"
        #expect(filter.consume(input) == "normal red\nready!")
    }

    @Test func completesCsiSplitAcrossPollingFragments() {
        var filter = VT100Filter()
        #expect(filter.consume("before\u{1B}[38;5") == "before")
        #expect(filter.consume(";196mred\u{1B}[") == "red")
        #expect(filter.consume("0mafter") == "after")
    }

    @Test func keepsUnicodeAndDropsStandaloneEscape() {
        var filter = VT100Filter()
        #expect(filter.consume("inicio ñ \u{1B}Xfin") == "inicio ñ Xfin")
    }
}
