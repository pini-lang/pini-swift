import Foundation
import PiniCore
import Testing

/// `await` / `wait` 的**形态载体**判据（缺口 `G74`）。
///
/// **这一件测什么**：语法把一次 join 分成两种形态 —— `await`（异步函数体内等待、**可以让出**
/// 当前任务）与 `wait`（任意上下文等待、**占用**当前线程）。管线**曾经完全分辨不出**它们：
/// 两个关键字产出同一个节点、关键字当场丢掉，运行时只能去问一个**生产面零赋值点**的模式开关；
/// 那个开关随挂起模式退役一并消失之后，两种形态就再没有任何可分之处。补上的载体是一个
/// `form` 字段，从 `Parser` 一路带到 HIR 节点。
///
/// **本件不测让出**，因为让出**还没实现** —— 引擎是树走查，任务的状态就是机器栈，要在 join 处
/// 让出、稍后从精确恢复点续跑，得先有「体可恢复」这一层。当下两种形态都按**阻塞**处理，
/// `await` **降级为 `wait`**；降级方向是合规的（让出可选、join 不可选），但它与「让出」的
/// 字面语义不符，这一点由缺口登记承载，不由一条假装通过的判据掩盖。
///
/// ⇒ 本件钉的是**载体不丢**：`form` 必须一路到得了 HIR（否则下游无从分辨），
/// 且两种形态的**运行结果一致**（降级是当前的合规行为，不是回归）。
///
/// 每条用例三要素齐备：意图写在显示名与首行注释；推进性测量断言期望行为**发生**；
/// 驳回性测量断言不该发生的**确实没发生**（否定形态，见测试规程 `C5`）。
struct ConcurrencyJoinFormTests {

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
    private func lowered(_ source: String) throws -> HIRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 完整跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        var lines: [String] = []
        let executor = HIRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    /// 同一段程序里两种形态各写一次，**各自写在自己的上下文里** —— 这是判据的最小语料。
    ///
    /// ⚠️ **2026-09-20 改过语料（裁定 35）**：原语料把 `await` 写在同步的 `main` 里，那是当时
    /// 允许的写法。新规则要求 `await` 只在异步体内、`wait` 只在同步体内，所以语料随之改。
    /// 判据的**意图没变**：两种形态都得给出正确结果 —— 只是现在还要各自落在自己的上下文里。
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

    // MARK: - 判据 1：载体一路到得了 HIR（正向）

    @Test("HIR 打印面回显写的是哪个关键字 —— 两种形态在降载结果里不再混成同一样子")
    func theFormSurvivesLowering() throws {
        /// 意图：`form` 从 Parser 带到 HIR，且**在唯一能看见降载结果的地方**（打印面）
        /// 能被读出。若载体在中途被丢掉，两者都会退化成同一个词 —— 那正是补载体之前的
        /// 状态，也正是本判据要挡住的东西。
        let dump = HIRPrinter.dump(module: try lowered(Self.bothForms))
        #expect(dump.contains("wait("), "occupying form missing from the lowered dump")
        #expect(dump.contains("await("), "yielding form missing from the lowered dump")
    }

    // MARK: - 判据 2：降级是合规行为，不是回归（驳回性）

    @Test("两种形态各自在自己的上下文里都给出正确结果 —— 少了让出，不少 join 本身")
    func bothFormsAgreeInTheirOwnContexts() throws {
        /// 意图：这是**驳回性**测量 —— 它断言「两种形态此刻**不**产生不同结果」。
        /// 让出没实现时，`await` 只能降级为 `wait`；降级必须**安静地**成立（结果正确），
        /// 而不是报错、也不是给出不同的值。判据 1 证明载体在、判据 2 证明降级不伤结果，
        /// 二者合起来说明这一批改的是**载体**，没顺手动语义。
        ///
        /// ⚠️ **2026-09-20（裁定 35）**：让出已落地，两形态不再同结果 —— `await` 让出、
        /// `wait` 占用，且各自限定在自己的上下文里。所以本判据的落点从「两形态同结果」改为
        /// 「两形态各自可用且结果一致」。**让出是否真的发生**由别处把关
        /// （`ConcurrencyYieldTests` 读让出计数）；本件只管两种写法都能拿到值。
        #expect(try runOutput(Self.bothForms) == ["1", "2"])
    }
}
