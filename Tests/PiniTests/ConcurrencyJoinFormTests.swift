import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// `await` / `wait` 的形态载体判据：语法把一次 join 分成两种形态 —— `await`（异步体内等待、可以让出当前任务）
/// 与 `wait`（任意上下文等待、占用当前线程）。载体是 `form` 字段，从 `Parser` 一路带到 IR 节点。
/// 本件钉载体不丢：`form` 必须到得了 IR（否则下游无从分辨），且两种形态各自落在自己的上下文里、结果一致。
struct ConcurrencyJoinFormTests: Sendable {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 前端四道门：词法 → 语法 → 常量折叠 → 语义 → 类型。任一拒绝即抛出首条诊断。
    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        return (module, checker)
    }

    /// 跑到降载层为止，返回可执行模块。
    private func lowered(_ source: String) throws -> IRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 完整跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    /// 同一段程序里两种形态各写一次，各自写在自己的上下文里 —— 这是判据的最小语料。
    /// `await` 只在异步体内、`wait` 只在同步体内，故语料按此分工；判据的意图是两种形态都得给出正确结果。
    private static let bothForms = #"""
    取|func(n: I32,) => (I32,):
        return ok(n)

    ; 同步体：只能写 wait
    经等待|func(n: I32,) -> (I32,):
        let a = 取(n)
        let x = try wait a else e:
            return 0
        return x

    ; 异步体：只能写 await
    经让出|func(n: I32,) => (I32,):
        let a = 取(n)
        let x = try await a else e:
            return ok(0)
        return ok(x)

    main|func() -> ():
        print(经等待(1))
        let f = 经让出(2)
        let r = try wait f else g:
            print("err")
            return
        print(r)
        return
    """#

    // MARK: - 判据 1：载体一路到得了 IR（正向）

    @Test("IR 打印面回显写的是哪个关键字 —— 两种形态在降载结果里不再混成同一样子")
    func theFormSurvivesLowering() throws {
        /// 意图：`form` 从 Parser 带到 IR，且**在唯一能看见降载结果的地方**（打印面）
        /// 能被读出。若载体在中途被丢掉，两者都会退化成同一个词 —— 那正是补载体之前的
        /// 状态，也正是本判据要挡住的东西。
        let dump = IRPrinter.dump(module: try lowered(Self.bothForms))
        #expect(dump.contains("wait("), "occupying form missing from the lowered dump")
        #expect(dump.contains("await("), "yielding form missing from the lowered dump")
    }

    // MARK: - 判据 2：降级是合规行为，不是回归（驳回性）

    @Test("两种形态各自在自己的上下文里都给出正确结果 —— 少了让出，不少 join 本身")
    func bothFormsAgreeInTheirOwnContexts() throws {
        /// 意图：驳回性测量 —— 两种形态此刻不产生不同结果：各自可用、结果一致。
        /// 判据 1 证明载体在（`form` 到得了 IR），本条证明两种写法都能拿到值，二者合起来说明改的是载体，没顺手动语义。
        /// 让出是否真的发生由别处把关（读让出计数），本件不重复它。
        #expect(try runOutput(Self.bothForms) == ["1", "2"])
    }
}
