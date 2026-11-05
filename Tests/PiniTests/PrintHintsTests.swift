import Foundation
import PiniSyntax
import Testing

/// 位置旁路判据：字面量原文与行前导空格必须被词法原样登记，取用时只改写法不改树。
/// 拼写保留与缩进还原的取用判据各见其套件。
@Suite("位置旁路")
struct PrintHintsTests {

    private func scan(_ source: String) -> FrontEnd.Scan {
        FrontEnd.syntaxOnly(source: source, fileName: "/tmp/hints.pini")
    }

    private func module(_ scan: FrontEnd.Scan) -> Module? {
        guard case .parsed(let module) = scan.outcome else { return nil }
        return module
    }

    @Test("拼写：进制与指数写法原样登记，位置指向字面量起点")
    func spellings() {
        let source = """
            main|func() -> ():
                let 甲 = 0xFF
                let 乙 = 0b1010
                let 丙 = 0o17
                let 丁 = 1.5e3
                let 戊 = 2e-2
                let 己 = 3.0E+2
                return
            """
        let hints = scan(source).hints
        #expect(hints.spellings.map(\.text) == ["0xFF", "0b1010", "0o17", "1.5e3", "2e-2", "3.0E+2"])
        #expect(hints.spellings.first?.line == 2)
        #expect(hints.spellings.first?.column == 13)
    }

    @Test("拼写：前缀大小写不归一")
    func spellingKeepsCase() {
        let hints = scan(
            """
            main|func() -> ():
                let a = 0XFF
                let b = 1.5E3
                return
            """
        ).hints
        #expect(hints.spellings.map(\.text) == ["0XFF", "1.5E3"])
    }

    @Test("缩进：每行前导空格数按行登记")
    func indents() {
        let hints = scan(
            """
            main|func() -> ():
              print(1)
            """
        ).hints
        #expect(hints.indents[1] == 0)
        #expect(hints.indents[2] == 2)
    }

    @Test("缩进：注释行与空行不入表")
    func indentsSkipBlankAndComment() {
        let hints = scan(
            """
            main|func() -> ():
              ; 注释

              print(1)
            """
        ).hints
        #expect(hints.indents[2] == nil)
        #expect(hints.indents[3] == nil)
        #expect(hints.indents[4] == 2)
    }

    @Test("接线：旁路只改字面量写法，不改树")
    func printingKeepsTree() throws {
        let source = """
            main|func() -> ():
                let a = 0xFF
                print(a)
                return
            """
        let scanned = scan(source)
        let parsed = try #require(module(scanned))
        let plain = Printer.print(module: parsed, comments: scanned.comments)
        let withHints = Printer.print(module: parsed, comments: scanned.comments, hints: scanned.hints)
        #expect(plain != withHints)
        #expect(withHints.contains("0xFF"))

        let reparsed = FrontEnd.syntaxOnly(source: withHints, fileName: "/tmp/hints.pini")
        guard case .parsed(let again) = reparsed.outcome else {
            Issue.record("保留拼写后的源码应可解析")
            return
        }
        #expect(Printer.print(module: again) == Printer.print(module: parsed))
    }
}
