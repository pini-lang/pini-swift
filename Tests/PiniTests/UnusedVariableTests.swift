import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics

/// 未使用局部变量的判据：只要变量出现在任何被检查的表达式里就算使用。
/// 反向用例（真正未用的变量必须告警）保证判据不是恒真。
struct UnusedVariableTests: Sendable {

    private func warnings(_ source: String) throws -> [SemanticWarning] {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = try FrontEnd.passes(module: parsed.module)
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
        return analyzer.warnings
    }

    @Test("函数结果取字段时，调用实参算作使用")
    func callArgumentInMemberAccessCountsAsUse() throws {
        let found = try warnings(
            """
            (盒)
            值: I32 = 0

            取|func(_t: I32,) -> (盒,):
                var b = 盒()
                b.值 = t
                return b

            main|func() -> ():
                let s = 4
                print(取(s).值)
                return
            """)
        #expect(!found.contains { $0.diagnosticCode == "E7-001" }, "\(found)")
    }

    @Test("下标与嵌套调用里的实参同样算作使用")
    func nestedArgumentsCountAsUse() throws {
        let found = try warnings(
            """
            main|func() -> ():
                let xs: Array<I32> = [1, 2, 3]
                let i = 1
                print(xs[i])
                let s = "ab"
                print(len(s) + 1)
                return
            """)
        #expect(!found.contains { $0.diagnosticCode == "E7-001" }, "\(found)")
    }

    @Test("真正未使用的局部变量仍然告警")
    func unusedVariableStillWarns() throws {
        let found = try warnings(
            """
            main|func() -> ():
                let unused = 1
                print(2)
                return
            """)
        #expect(found.contains { $0.diagnosticCode == "E7-001" }, "\(found)")
    }
}
