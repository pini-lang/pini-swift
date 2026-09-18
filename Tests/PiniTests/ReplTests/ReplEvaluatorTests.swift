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
/// P4-4 moved evaluation into `ReplEvaluator`, on `PiniCore`, and these cases
/// drove it on both engines: the same scenario twice, so that claim was an
/// assertion rather than a statement.
///
/// WHAT `G-6c` CHANGED HERE
///
/// The walk retired, so there is no second engine to drive and "the two engines
/// agree" is no longer a question that can be asked. Two cases asserted exactly
/// that, and the honest successor is **not** to delete them: the agreement they
/// measured was the only reading those inputs had from any engine, so that
/// reading is frozen into the expectations instead. What was "the arms agree"
/// becomes "the outputs are these" — a stronger claim about one arm, and the
/// retired arm's last word kept as a specification rather than thrown away.
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
@Suite("P7-1 REPL 求值")
struct ReplEvaluatorTests {

    /// Evaluates one input and returns everything the snippet printed.
    private func eval(
        _ lines: [String],
        into session: ReplEvaluator = ReplEvaluator()
    ) throws -> [String] {
        var printed: [String] = []
        try session.evaluate(lines, output: { printed.append($0) })
        return printed
    }

    // MARK: - 表达式（REPL 的主路径）

    @Test("表达式求值：包装进 main 后可跑")
    func evaluatesAnExpression() throws {
        #expect(try eval(["1 + 2"]) == ["3"])
    }

    @Test("print(...) 输入不被二次包装")
    func printInputIsNotRewrapped() throws {
        // 二次包装会打印 `print` 返回的 null，多出一个空行。
        #expect(try eval(["print(7)"]) == ["7"])
    }

    @Test("运算符优先级由引擎而非 REPL 决定")
    func operatorPrecedenceIsTheEngines() throws {
        #expect(try eval(["1 + 2 * 3"]) == ["7"])
    }

    @Test("字符串与比较表达式")
    func stringsAndComparisons() throws {
        #expect(try eval(["\"hi\""]) == ["hi"])
        #expect(try eval(["1 == 1"]) == ["true"])
    }

    // MARK: - 声明路径（识别与累积）

    @Test("声明输入被识别为声明而非表达式")
    func declarationIsRecognized() throws {
        let session = ReplEvaluator()
        // `{名字}` 是 Pini 的引用类型定界符，也是当前唯一被 starters 认到的声明形态。
        let outcome = try session.evaluate(
            ["{盒子}", "v: I32 = 7"], output: { _ in }
        )
        #expect(outcome == .declaration)
        #expect(session.accumulatedDeclarations.count == 1)
    }

    @Test("只有声明、没有 main 是正常路径")
    func declarationWithoutMainIsFine() throws {
        // 「没有 main」这个状态出现在**降载期**：降载器要求一个可执行程序，于是它在
        // lower 期就拒绝。求值核必须把它当作正常 —— 会话中途只有声明是 REPL 的常态。
        let session = ReplEvaluator()
        #expect(throws: Never.self) {
            _ = try session.evaluate(
                ["{盒子}", "v: I32 = 7"], output: { _ in }
            )
        }
        #expect(session.accumulatedDeclarations.count == 1)
    }

    @Test("reset 清空累积声明（:clear）")
    func resetClearsDeclarations() throws {
        let session = ReplEvaluator()
        #expect(throws: Never.self) {
            _ = try session.evaluate(
                ["{盒子}", "v: I32 = 7"], output: { _ in }
            )
        }
        session.reset()
        #expect(session.accumulatedDeclarations.isEmpty)
    }

    // MARK: - 错误恢复

    @Test("解析失败抛 ReplError（不退出会话）")
    func malformedInputThrows() throws {
        #expect(throws: ReplError.self) {
            _ = try eval(["@#$%"])
        }
    }

    // MARK: - 冻结读数（原「两引擎逐项一致」的位置）

    @Test("同一批输入给出冻结的逐项输出")
    /// 意图：不比对「各自绿」，而要求**逐项等于一组具体值**。
    ///
    /// ⚠️ 这组值不是设计出来的，是**测出来再冻结的**：它原是本用例的「两臂逐项相同」
    /// 读数，即参照臂退役前对这批输入的最后一个答案。`G-6c` 把这批输入**逐条经 CLI REPL
    /// 实测**核对（`printf '<输入>\n' | pini repl`），再把它写成期望 —— 判据于是从
    /// 「两台实现互证」变成「一台实现对规格」，覆盖一条不丢。
    /// 哪天某条变了，红的是**具体那一条**，而不是一句「不一致」。
    func inputSetProducesTheFrozenOutputs() throws {
        let inputs: [[String]] = [
            ["1 + 2"],
            ["print(7)"],
            ["1 + 2 * 3"],
            ["\"hi\""],
            ["-5"],
            ["1 == 1"],
            ["true"],
        ]
        let frozen = ["3", "7", "7", "hi", "-5", "true", "true"]

        var printed: [String] = []
        for input in inputs {
            // 每个输入一个新会话：本用例比的是求值结果，不是会话状态。
            printed.append(contentsOf: try eval(input))
        }
        #expect(printed == frozen, "逐项输出偏离冻结读数：实际=\(printed)")
    }

    @Test("声明被累积后，下一次求值给出冻结的输出")
    /// 意图同上：原「两臂在下一次求值上仍然一致」的读数，冻结成具体值。
    /// 声明本身不产出输出，随后的 `1 + 1` 打印 `2`。
    func evaluationAfterADeclarationProducesTheFrozenOutput() throws {
        let session = ReplEvaluator()
        var printed: [String] = []
        try session.evaluate(["{盒子}", "v: I32 = 7"], output: { printed.append($0) })
        try session.evaluate(["1 + 1"], output: { printed.append($0) })
        #expect(printed == ["2"], "实际=\(printed)")
    }

    // MARK: - 已知差异（语义债的见证，不是缺陷断言）

    @Test("类型错误的输入被拒（降载要读检查器的推断）")
    /// 意图：把 P4-2 登记的那条「类型检查面不对等」钉在 **REPL 这一形态**上。
    /// 当时它是不对等的**一半**：AST 路径只跑语义门禁，HIR 路径必须读 checker 的推断
    /// 才能降载 ⇒ 未通过检查的输入在 HIR 下根本降不了载。
    /// ⚠️ 翻转后（默认引擎切 HIR）这条差异由**判据差异**变成**用户可见**：
    /// REPL 里带类型错误的输入会被拒 —— 该代价已在 P4-2 勘测件与 `D-P4-15` 登记。
    /// `G-6c` 删掉另一条路径后，剩下的是**唯一**行为，本用例即为它的规格。
    func typeIncorrectInputIsRefused() throws {
        // 输入形态取自 P4-2 已实测的 `E4-001` 最小例。
        #expect(throws: ReplError.self) {
            _ = try ReplEvaluator().evaluate(
                ["{盒子}", "v: I32 = 7", "", "((盒子))", "坏|self() -> (I32,):",
                 "    var x: I32 = \"str\"", "    return x"],
                output: { _ in }
            )
        }
    }
}
