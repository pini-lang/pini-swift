import Testing
import Foundation
@testable import PiniCore

/// P4-4：REPL **求值路径**的用例，按引擎参数化。
///
/// WHY THIS FILE EXISTS
///
/// The REPL suite next to this one covers *parsing* — and it re-implements the
/// expression wrap rather than driving the session, so nothing asserted what the
/// REPL does when it evaluates something. Evaluation additionally constructed
/// `Interpreter()` directly and lived in the executable target, where no test
/// could reach it. "REPL cases green on the HIR engine" therefore had no content
/// to be green about.
///
/// P4-4 moves evaluation into `ReplEvaluator` (PiniCore, engine as a parameter)
/// and these cases drive it on both engines: the same scenario twice, so the
/// claim is an assertion rather than a statement.
///
/// SCOPE NOTE — what these cases deliberately do not cover
///
/// The declaration path is exercised only as far as *recognition and
/// accumulation*. Two pre-existing limits make the rest unreachable, and both
/// are filed rather than fixed here (P4-4 is the engine seam, not REPL repair):
/// the declaration starters do not match Pini's real declaration syntax
/// (`名字|func(…)`, `(结构体)`, `[枚举]`, `<trait>` are all treated as
/// expressions), and a single-line `{名字}` balances its brackets so the
/// continuation detector submits it immediately, leaving no way to type a
/// multi-line body. Both are observable in the CLI and neither is caused by this
/// batch.
@Suite("P7-1 REPL 求值（双引擎）")
struct ReplEvaluatorTests {

    /// Evaluates one input and returns everything the snippet printed.
    private func eval(
        _ lines: [String],
        engine: InterpreterEngine,
        into session: ReplEvaluator = ReplEvaluator()
    ) throws -> [String] {
        var printed: [String] = []
        try session.evaluate(lines, engine: engine, output: { printed.append($0) })
        return printed
    }

    // MARK: - 表达式（REPL 的主路径）

    @Test("表达式求值：包装进 main 后可跑", arguments: InterpreterEngine.allCases)
    func evaluatesAnExpression(engine: InterpreterEngine) throws {
        #expect(try eval(["1 + 2"], engine: engine) == ["3"])
    }

    @Test("print(...) 输入不被二次包装", arguments: InterpreterEngine.allCases)
    func printInputIsNotRewrapped(engine: InterpreterEngine) throws {
        // 二次包装会打印 `print` 返回的 null，多出一个空行。
        #expect(try eval(["print(7)"], engine: engine) == ["7"])
    }

    @Test("运算符优先级由引擎而非 REPL 决定", arguments: InterpreterEngine.allCases)
    func operatorPrecedenceIsTheEngines(engine: InterpreterEngine) throws {
        #expect(try eval(["1 + 2 * 3"], engine: engine) == ["7"])
    }

    @Test("字符串与比较表达式", arguments: InterpreterEngine.allCases)
    func stringsAndComparisons(engine: InterpreterEngine) throws {
        #expect(try eval(["\"hi\""], engine: engine) == ["hi"])
        #expect(try eval(["1 == 1"], engine: engine) == ["true"])
    }

    // MARK: - 声明路径（识别与累积）

    @Test("声明输入被识别为声明而非表达式", arguments: InterpreterEngine.allCases)
    func declarationIsRecognized(engine: InterpreterEngine) throws {
        let session = ReplEvaluator()
        // `{名字}` 是 Pini 的引用类型定界符，也是当前唯一被 starters 认到的声明形态。
        let outcome = try session.evaluate(
            ["{盒子}", "v: I32 = 7"], engine: engine, output: { _ in }
        )
        #expect(outcome == .declaration)
        #expect(session.accumulatedDeclarations.count == 1)
    }

    @Test("只有声明、没有 main 是正常路径", arguments: InterpreterEngine.allCases)
    func declarationWithoutMainIsFine(engine: InterpreterEngine) throws {
        // 两引擎在这一步都会遇到「没有 main」，但**在不同的阶段**：AST 侧是解释器运行时
        // 抛 `mainNotFound`，HIR 侧是降载器在 lower 期就拒绝（它要求一个可执行程序）。
        // 求值核必须把两者都当作正常 —— 这正是本批修掉的对等缺口。
        let session = ReplEvaluator()
        #expect(throws: Never.self) {
            _ = try session.evaluate(
                ["{盒子}", "v: I32 = 7"], engine: engine, output: { _ in }
            )
        }
        #expect(session.accumulatedDeclarations.count == 1)
    }

    @Test("reset 清空累积声明（:clear）", arguments: InterpreterEngine.allCases)
    func resetClearsDeclarations(engine: InterpreterEngine) throws {
        let session = ReplEvaluator()
        #expect(throws: Never.self) {
            _ = try session.evaluate(
                ["{盒子}", "v: I32 = 7"], engine: engine, output: { _ in }
            )
        }
        session.reset()
        #expect(session.accumulatedDeclarations.isEmpty)
    }

    // MARK: - 错误恢复

    @Test("解析失败抛 ReplError（不退出会话）", arguments: InterpreterEngine.allCases)
    func malformedInputThrows(engine: InterpreterEngine) throws {
        #expect(throws: ReplError.self) {
            _ = try eval(["@#$%"], engine: engine)
        }
    }

    // MARK: - 两引擎一致性（核心判据）

    @Test("同一批输入在两台引擎上给出逐项相同的输出")
    /// 意图：不比对「各自绿」，而要求**逐项相同**。只有一边绿会红；两边都错但错得一样
    /// 也会绿 —— 这与 P4-3 的位置判据同构：真正的证人是一致性，不是通过。
    func bothEnginesAgreeOnTheSameInputs() throws {
        let inputs: [[String]] = [
            ["1 + 2"],
            ["print(7)"],
            ["1 + 2 * 3"],
            ["\"hi\""],
            ["-5"],
            ["1 == 1"],
            ["true"],
        ]
        var byEngine: [InterpreterEngine: [String]] = [:]
        for engine in InterpreterEngine.allCases {
            var printed: [String] = []
            for input in inputs {
                // 每个输入一个新会话：本用例比的是求值结果，不是会话状态。
                try ReplEvaluator().evaluate(input, engine: engine,
                                             output: { printed.append($0) })
            }
            byEngine[engine] = printed
        }
        #expect(byEngine[.hir]?.isEmpty == false, "HIR 侧必须真的求值过")
        #expect(byEngine[.ast] == byEngine[.hir])
    }

    @Test("声明被累积后，两引擎的下一次求值仍然一致")
    func bothEnginesAgreeAfterADeclaration() throws {
        var byEngine: [InterpreterEngine: [String]] = [:]
        for engine in InterpreterEngine.allCases {
            let session = ReplEvaluator()
            var printed: [String] = []
            try session.evaluate(["{盒子}", "v: I32 = 7"], engine: engine,
                                 output: { printed.append($0) })
            try session.evaluate(["1 + 1"], engine: engine, output: { printed.append($0) })
            byEngine[engine] = printed
        }
        #expect(byEngine[.hir]?.last == "2")
        #expect(byEngine[.ast] == byEngine[.hir])
    }

    // MARK: - 已知差异（语义债的见证，不是缺陷断言）

    @Test("已知差异：类型错误的声明在 HIR 下报类型错误")
    /// 意图：把 P4-2 登记的那条「类型检查面不对等」钉在 **REPL 这一形态**上。
    /// AST 路径只跑语义门禁；HIR 路径必须读 checker 的推断才能降载 ⇒ 未通过检查的输入
    /// 在 HIR 下根本降不了载。本用例断言的是「差异存在且方向已知」，不是「两边该一样」。
    /// ⚠️ 翻转后（默认引擎切 HIR）这条差异由**判据差异**变成**用户可见**：
    /// REPL 里带类型错误的输入会被拒 —— 该代价已在 P4-2 勘测件与 `D-P4-15` 登记。
    func typeErrorsAreReportedOnTheHIREngine() throws {
        // 输入形态取自 P4-2 已实测的 `E4-001` 最小例。
        #expect(throws: ReplError.self) {
            _ = try ReplEvaluator().evaluate(
                ["{盒子}", "v: I32 = 7", "", "((盒子))", "坏|self() -> (I32,):",
                 "    var x: I32 = \"str\"", "    return x"],
                engine: .hir, output: { _ in }
            )
        }
    }
}
