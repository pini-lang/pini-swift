import Foundation
import Testing
import PiniSyntax
@testable import PiniSemantics

/// 调用点实参标签：默认强制、`_名` 退出、标签按名对位。
/// 判据只认编译期结果，不落到运行期才发现错位。
struct ArgumentLabelTests: Sendable, PiniSourceLowering {

    /// 收集全部类型错误：逐条断言码，避免首错即停掩盖后面的判据。
    private func errors(_ source: String) throws -> [TypeError] {
        let fileName = "labels.pini"
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = try FrontEnd.passes(module: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        return TypeChecker().checkCollecting(module: module)
    }

    private func codes(_ source: String) throws -> [String] {
        try errors(source).map(\.diagnosticCode)
    }

    @Test("形参没写 _ 时，位置实参逐位报缺标签")
    func missingLabels() throws {
        let source = #"""
        f|func(a: I32, b: I32,) -> (I32,):
            return a + b

        g|func() -> (I32,):
            return f(1, 2,)
        """#
        #expect(try codes(source) == ["E4-036", "E4-036"])
    }

    @Test("形参写 _ 后，调用点按位置传且体内仍用原名")
    func underscoreOptOut() throws {
        let source = #"""
        f|func(_a: I32, b: I32,) -> (I32,):
            return a + b

        g|func() -> (I32,):
            return f(1, b = 2,)
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("已退出标签面的形参收到标签报 E4-037")
    func unexpectedLabel() throws {
        let source = #"""
        f|func(_a: I32,) -> (I32,):
            return a

        g|func() -> (I32,):
            return f(a = 1,)
        """#
        #expect(try codes(source) == ["E4-037"])
    }

    @Test("标签按名字对位，允许乱序")
    func reorderedLabels() throws {
        let source = #"""
        f|func(a: I32, b: I32,) -> (I32,):
            return a - b

        g|func() -> (I32,):
            return f(b = 2, a = 5,)
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("同一形参收到两个标签报 E4-038")
    func duplicateLabel() throws {
        let source = #"""
        f|func(a: I32, b: I32,) -> (I32,):
            return a + b

        g|func() -> (I32,):
            return f(a = 1, a = 2,)
        """#
        #expect(try codes(source) == ["E4-038"])
    }

    @Test("标签对不上任何形参报 E4-009")
    func unknownLabel() throws {
        let source = #"""
        f|func(a: I32, b: I32,) -> (I32,):
            return a + b

        g|func() -> (I32,):
            return f(a = 1, c = 2,)
        """#
        #expect(try codes(source) == ["E4-009"])
    }

    @Test("方法调用同样按声明的标签面判")
    func methodMissingLabel() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        加|self(dx: I32,) -> (I32,):
            return 1 + dx

        g|func() -> (I32,):
            var p = 点()
            return p.加(2,)
        """#
        #expect(try codes(source) == ["E4-036"])
    }

    @Test("方法形参写 _ 后按位置传")
    func methodOptOut() throws {
        let source = #"""
        (点)
        x: I32 = 0

        ((点))
        加|self(_dx: I32,) -> (I32,):
            return 1 + dx

        g|func() -> (I32,):
            var p = 点()
            return p.加(2,)
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("特征实现的标签面与声明不一致报 E4-008")
    func traitLabelMismatch() throws {
        let source = #"""
        <取数>
        取|self(键: I32,) -> (I32,)

        (盒)
        实现: 取数

        ((盒))
        取|self(_键: I32,) -> (I32,):
            return 0
        """#
        let found = try errors(source)
        #expect(found.count == 1)
        #expect(found.first?.diagnosticCode == "E4-008")
    }

    @Test("内建调用不判标签")
    func builtinExempt() throws {
        let source = #"""
        g|func() -> (I32,):
            let xs = [1, 2,]
            return len(xs) + xs[0]
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("函数值调用不判标签")
    func functionValueExempt() throws {
        let source = #"""
        f|func(a: I32,) -> (I32,):
            return a

        g|func(fn: (I32,) -> (I32,),) -> (I32,):
            return fn(1,)
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("零参数调用不受影响")
    func zeroArity() throws {
        let source = #"""
        f|func() -> (I32,):
            return 1

        g|func() -> (I32,):
            return f()
        """#
        #expect(try codes(source).isEmpty)
    }

    @Test("参数位的 _ 打印时回写")
    func printerRestoresUnderscore() throws {
        let fileName = "labels.pini"
        let source = #"""
        f|func(_a: I32, b: I32,) -> (I32,):
            return a + b
        """#
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        let module = try FrontEnd.passes(module: parsed.module)
        #expect(Printer.print(module: module).contains("_a: I32"))
    }
}
