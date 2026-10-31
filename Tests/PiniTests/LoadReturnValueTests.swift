import Foundation
import Testing
import PiniSyntax

@testable import PiniCore
@testable import PiniHost
@testable import PiniIR
@testable import PiniSemantics

/// `load(p)` 的静态类型是 `*T` 的元素类型，不是 `()`。判据分三面：值位可用、参与算术、
/// 非指针实参在静态层被拒 —— 只测第一面的话，「返回一个占位值」也能过。
@Suite("load 的返回值")
struct LoadReturnValueTests: Sendable {

    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        return (module, checker)
    }

    private func run(_ source: String) throws -> [String] {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory(), ffiConfig: .default)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    @Test("load 作为 print 的第二参：按元素类型入参，不再判成 void")
    func loadIsUsableAsAValue() throws {
        let lines = try run(
            #"""
            main|func() -> ():
                var x: I64 = 7
                var p = unsafe &x
                print("v =", unsafe load(p))
                return
            """#)
        #expect(lines == ["v = 7"])
    }

    @Test("load 的结果参与算术：类型是元素的 I64，不是 void")
    func loadFeedsArithmetic() throws {
        let lines = try run(
            #"""
            main|func() -> ():
                var x: I64 = 41
                var one: I64 = 1
                var p = unsafe &x
                var y: I64 = unsafe load(p) + one
                print(y)
                return
            """#)
        #expect(lines == ["42"])
    }

    @Test("load 的实参不是指针 ⇒ 静态拒绝")
    func loadRejectsANonPointer() {
        let source = #"""
            main|func() -> ():
                print(load(1))
                return
            """#
        #expect(throws: TypeError.self) { try typeChecked(source) }
    }
}
