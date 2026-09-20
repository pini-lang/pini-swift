import Foundation
import PiniCore
import Testing

/// `Result` 型 scrutinee 的 `match` 分派判据（缺口 `G72`）。
///
/// **修的是哪一层**：`match` 一个 `Result` 值时，`case ok(v)` 的绑定此前**保留 scrutinee 的
/// 类型**而不是取**载荷类型** —— 于是 `v` 的每一种真实用法（赋给载荷类型的标注、参与算术、
/// 直接打印）都判成类型不符，而源程序从未写过那个类型。修法 = 给 `match` 的类型分派补
/// `Result` 一支，照既有 Optional 一支的形态。
///
/// **两侧刻意不对称，且不对称正是这一支存在的理由**：`ok` 侧取**载荷类型**（窄化，本支线要的
/// 就是它）；`err` 侧取 `try-else` 早已确立的**类型擦除错误字**形态 —— `Result` 的 HIR 类型
/// 只带 ok 侧字段，没有可窄化的错误类型，且 IR ABI 把该槽擦成一个机器字。
/// ⇒ 后果是**打印 err 绑定仍然被拒**，但拒得**响亮**（既有错误绑定门禁），
/// 且文案现在说的是真实理由，不再把绑定的类型当替罪羊。
///
/// **两条判据即本支线的验收面**（克制口径：内联、不建夹具、不建整套并发套件）。
/// 二者都**不依赖并发** —— 分派在降载层完成，与执行腿无关；掺进 `=>` 只会让红因不可归因。
///
/// **⚠️ 发射臂不在此件覆盖内**：本件走 `HIRExecutor`（解释器臂）。发射臂那一支由命令行
/// 两臂对照取证 —— 在补它之前，`Result` scrutinee 落到「无字面量分支」的兜底路上，
/// 会**静默跳过全部 arm 且退出码为 0**，那是一处独立缺陷，由同一批一并处置。
///
/// 每条用例三要素齐备：意图写在显示名与首行注释；推进性测量断言期望行为**发生**；
/// 驳回性测量断言不该发生的**确实没发生**（否定形态，见测试规程 `C5`）。
struct ResultNarrowingTests {

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

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    // MARK: - 判据 1：`ok` 绑定取载荷类型

    @Test("同步 match 一个 Result 时，ok 绑定取载荷类型（标注与直接打印两条路都通）")
    func okBindingTakesThePayloadType() throws {
        /// 意图：`case ok(v)` 的 `v` 是 `I32`、不是 `Result<I32>`。
        /// 两条路各测一次：赋给**载荷类型的标注**（类型面），与**直接打印**（既是类型面、
        /// 也是八个并发样例的真实形态）。修前两条都红：前者报载荷与 Result 不符，
        /// 后者撞打印门禁。
        let source = #"""
        造|func() -> (^I32,):
            return ok(5)

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    let w: I32 = v
                    print(w)
                    print(v)
                case err(e):
                    print("err")
            return
        """#
        #expect(try runOutput(source) == ["5", "5"])
    }

    // MARK: - 判据 2：`ok` 绑定参与算术

    @Test("同步 match 一个 Result 时，ok 绑定可直接参与算术")
    func okBindingTakesPartInArithmetic() throws {
        /// 意图：单测算术面 —— 它覆盖的是「运算类型不符」那条报文，且**无门禁参与**，
        /// 故纯判类型推断是否拿到了载荷类型。修前必红。
        let source = #"""
        造|func() -> (^I32,):
            return ok(5)

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    print(v + 1)
                case err(e):
                    print("err")
            return
        """#
        #expect(try runOutput(source) == ["6"])
    }

    // MARK: - 驳回性：`err` 侧维持既有形态（响亮拒绝，非静默）

    @Test("err 绑定维持类型擦除形态：打印它被响亮拒绝，而不是静默出错值")
    func errBindingPrintingStaysLoudlyRejected() throws {
        /// 意图：钉住本条**刻意不做**的那一半。`err` 侧没有可窄化的类型（HIR 类型不带错误
        /// 类型），故它沿用 `try-else` 已确立的擦除字形态 ⇒ 打印它应报既有诊断，
        /// **而不是**静默给出一个值。
        /// ⚠️ 这条是**否定形态**：它断言「不该发生的确实没发生」——若哪天有人把 err 侧
        /// 改成静默可打印，本用例转红。
        let source = #"""
        造|func() -> (^I32,):
            return err(Error("boom"))

        main|func() -> ():
            let x = 造()
            match x:
                case ok(v):
                    print(v)
                case err(e):
                    print(e)
            return
        """#
        let observed = failure { _ = try lowered(source) }
        #expect(observed?.code == "E6-004", "应报降载期诊断，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("type-erased") == true,
            "文案应说明擦除理由，实际：\(String(describing: observed?.message))"
        )
    }
}
