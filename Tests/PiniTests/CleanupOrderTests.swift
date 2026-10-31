import Testing
import PiniSyntax

@testable import PiniCore
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackendLLVM

/// `defer` 体与局部释放共用一条清理栈：登记顺序即源码顺序，退出时逆序执行。
/// 判据钉发射产物的先后——两条都只差「defer 与局部谁先登记」，输出里的次序必须相反。
@Suite("清理栈的次序")
struct CleanupOrderTests: Sendable {

    private func emitted(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        return try IREmitter().emit(module: lowered)
    }

    /// 标记函数用 ASCII 名：IR 里非 ASCII 名会被改写，判据不该跟着改写规则走。
    private static let marker = "define void @mark()"

    private func firstIndex(of needle: String, in text: String) throws -> Int {
        try #require(text.range(of: needle), "产物里找不到 \(needle)").lowerBound
            .utf16Offset(in: text)
    }

    @Test("defer 先登记、局部后登记 ⇒ 退出时局部先释放，defer 后跑")
    func theLaterLocalIsReleasedBeforeTheEarlierDefer() throws {
        let ir = try emitted(
            #"""
            mark|func() -> ():
                print("m")
                return

            main|func() -> ():
                defer mark()
                let xs: Array<I32> = [1, 2]
                print(len(xs))
                return
            """#)
        let destroy = try firstIndex(of: "call void @bk_array_destroy", in: ir)
        let call = try firstIndex(of: "call void @mark()", in: ir)
        #expect(destroy < call, "局部在 defer 之后登记 ⇒ 先释放局部，再跑 defer")
    }

    @Test("局部先登记、defer 后登记 ⇒ 退出时 defer 先跑，局部后释放")
    func theLaterDeferRunsBeforeTheEarlierLocalIsReleased() throws {
        let ir = try emitted(
            #"""
            mark|func() -> ():
                print("m")
                return

            main|func() -> ():
                let xs: Array<I32> = [1, 2]
                defer mark()
                print(len(xs))
                return
            """#)
        let destroy = try firstIndex(of: "call void @bk_array_destroy", in: ir)
        let call = try firstIndex(of: "call void @mark()", in: ir)
        #expect(call < destroy, "defer 在局部之后登记 ⇒ 先跑 defer（它能引用那个局部），再释放它")
    }

    @Test("同一作用域两层 defer 仍是后进先出")
    func defersWithinOneScopeStayLIFO() throws {
        let ir = try emitted(
            #"""
            mark|func() -> ():
                print("m")
                return

            other|func() -> ():
                print("o")
                return

            main|func() -> ():
                defer mark()
                defer other()
                return
            """#)
        let mark = try firstIndex(of: "call void @mark()", in: ir)
        let other = try firstIndex(of: "call void @other()", in: ir)
        #expect(other < mark, "后登记的 defer 先跑")
    }
}
