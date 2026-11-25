import Foundation
import Testing
import PiniIR
import PiniSemantics
import PiniSyntax

/// 泛型实例的判定面：显式类型实参只能落在泛型模板上，个数与声明的类型形参一致。
/// 名字解析与实参校验各归自己的面；这里只钉实例能否成立的那一条。
struct GenericInstanceTests: Sendable {

    private func module(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return try FrontEnd.passes(module: parsed.module)
    }

    private func checked(_ source: String) throws -> [TypeError] {
        let module = try module(source)
        try SemanticAnalyzer().analyze(module: module)
        return TypeChecker().checkCollecting(module: module, foreignConstantFailures: [:])
    }

    @Test("非泛型函数带显式类型实参：E4-006，期望 0 个")
    func plainFunctionTakesNoTypeArguments() throws {
        let errors = try checked(
            """
            加一|func(x: I32,) -> (I32,):
                return x + 1

            调用|func() -> (I32,):
                return 加一<I32>(1)
            """)
        guard case .genericArgumentCountMismatch(let name, let expected, let got, let location) = errors[0]
        else {
            Issue.record("期望 genericArgumentCountMismatch，实际 \(errors[0])")
            return
        }
        #expect(name == "加一")
        #expect(expected == 0)
        #expect(got == 1)
        #expect(location.line == 5)
        #expect(errors[0].diagnosticCode == "E4-006")
    }

    @Test("泛型函数写全类型实参：不报实例错误")
    func genericFunctionWithFullArgumentsIsSilent() throws {
        let errors = try checked(
            """
            配对|func<T, U>(a: T, b: U,) -> (T,):
                return a

            调用|func() -> (I32,):
                return 配对<I32, String>(a = 1, b = "x")
            """)
        #expect(errors.isEmpty)
    }

    @Test("泛型函数少写类型实参：E4-006，个数按声明算")
    func genericFunctionArityMismatch() throws {
        let errors = try checked(
            """
            配对|func<T, U>(a: T, b: U,) -> (T,):
                return a

            调用|func() -> (I32,):
                return 配对<I32>(1, "x")
            """)
        guard case .genericArgumentCountMismatch(_, let expected, let got, _) = errors[0] else {
            Issue.record("期望 genericArgumentCountMismatch，实际 \(errors[0])")
            return
        }
        #expect(expected == 2)
        #expect(got == 1)
    }
}
