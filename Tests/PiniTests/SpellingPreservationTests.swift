import Foundation
import PiniSyntax
import Testing

/// 拼写保留判据：作者写的进制与指数写法经格式化后逐字节不变，查不到原文时退回值输出。
/// 两条分开判——只查保留时，折叠产物继承错原文也照样通过。
@Suite("拼写保留")
struct SpellingPreservationTests {

    private func printed(_ source: String, folding: Bool = false) -> String? {
        let scan =
            folding
            ? FrontEnd.scan(source: source, fileName: "/tmp/spell.pini")
            : FrontEnd.syntaxOnly(source: source, fileName: "/tmp/spell.pini")
        guard case .parsed(let module) = scan.outcome else { return nil }
        return Printer.print(module: module, comments: scan.comments, hints: scan.hints)
    }

    @Test("六种写法：进制与指数原样保留")
    func keepsSpellings() throws {
        let source = """
            main|func() -> ():
                let a = 0xFF
                let b = 0b1010
                let c = 0o17
                let d = 1.5e3
                let e = 2e-2
                let f = 3.0E+2
                return
            """
        let text = try #require(printed(source))
        #expect(text.contains("0xFF"))
        #expect(text.contains("0b1010"))
        #expect(text.contains("0o17"))
        #expect(text.contains("1.5e3"))
        #expect(text.contains("2e-2"))
        #expect(text.contains("3.0E+2"))
        #expect(!text.contains("255"))
    }

    @Test("前缀大小写不归一")
    func keepsPrefixCase() throws {
        let text = try #require(printed("main|func() -> ():\n    let a = 0XFF\n    return\n"))
        #expect(text.contains("0XFF"))
    }

    @Test("二次打印逐字节相同")
    func idempotent() throws {
        let source = """
            main|func() -> ():
                let a = 0xFF
                let b = 1.5e3
                return
            """
        let once = try #require(printed(source))
        let twice = try #require(printed(once))
        #expect(once == twice)
    }

    @Test("无旁路：退回值输出")
    func fallsBackWithoutHints() throws {
        let scan = FrontEnd.syntaxOnly(
            source: "main|func() -> ():\n    let a = 0xFF\n    return\n", fileName: "/tmp/spell.pini")
        guard case .parsed(let module) = scan.outcome else {
            Issue.record("样例应解析通过")
            return
        }
        let text = Printer.print(module: module, comments: scan.comments)
        #expect(text.contains("255"))
        #expect(!text.contains("0xFF"))
    }

    @Test("函数字面量体内：同样保留")
    func keepsSpellingInFuncLiteral() throws {
        let source = """
            main|func() -> ():
                let f = func (n: I32,) -> (I32,): return n + 0x10
                return
            """
        let text = try #require(printed(source))
        #expect(text.contains("0x10"))
    }

    @Test("折叠产物不继承字面量原文")
    func foldedLiteralFallsBack() throws {
        let text = try #require(printed("main|func() -> ():\n    print(0xFF + 1)\n    return\n", folding: true))
        #expect(text.contains("256"))
        #expect(!text.contains("0xFF"))
    }
}
