import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// 无实参枚举用例的裸名形态（`某用例`，不带括号）作局部变量初值时的类型推断判据。`infer` 对调用形态
/// `名(...)` 按「父枚举唯一 ⇒ 取父枚举类型」识别，而裸名走不到那条分支、返 nil；nil 在无线程期望类型的
/// 位置会落成 `Any` ⇒ 错误换个地方发，报错点与被推断的名字无关。结局只由初值形态决定，与声明位置无关。
struct BareCaseInitializerTests: Sendable {

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

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    // MARK: - 判据 1：裸名用例作初值 ⇒ 取父枚举类型

    @Test("无实参用例的裸名形态作变量初值时，变量取父枚举类型（不是 Any）")
    func bareCaseNameAsInitializerTakesTheParentEnumType() throws {
        /// 意图：`var f = 旗空` 的 `f` 必须是 `旗`。判别力 = 修前该 `f` 是 `Any`，
        /// 传进 `拿(f: 旗,)` 即被拒 ⇒ 本用例修前必红。
        let source = #"""
        [旗]
        旗空
        旗满

        拿|func(f: 旗,) -> (I32,):
            match f:
                case 旗空:
                    return 0
                case 旗满:
                    return 1
            return 1

        main|func() -> ():
            var f = 旗空
            print(拿(f,),)
            return
        """#
        #expect(try runOutput(source) == ["0"])
    }

    // MARK: - 判据 2：累积变量 + 块内构造（原现场形态）

    @Test("初值为裸名用例的累积变量，在循环体内被回赋构造结果后仍然可用")
    func accumulatorInitializedByBareCaseNameSurvivesTheLoop() throws {
        /// 意图：这是原现场形态 —— 累积变量以裸名用例起手，循环体内用块内声明的变量参与构造再回赋给外层变量。
        /// 它同时钉住「块内声明与回赋本身无问题」：结局只由初值形态决定，与声明位置无关。
        let source = #"""
        [表]
        表空
        表结(head: I32, tail: 表,)

        加|func(t: 表, i: I32,) -> (表,):
            return 表结(head = i, tail = t,)

        数|func(t: 表,) -> (I32,):
            var n = 0
            var cur = t
            var go = true
            while go:
                match cur:
                    case 表空:
                        go = false
                    case 表结(_, tail):
                        n = n + 1
                        cur = tail
            return n

        main|func() -> ():
            var acc = 表空
            var i = 0
            while i < 3:
                var 头 = i
                acc = 加(acc, 头,)
                i = i + 1
            print(数(acc,),)
            return
        """#
        #expect(try runOutput(source) == ["3"])
    }

    // MARK: - 判据 3：歧义用例名**不猜**

    @Test("同名用例跨枚举时，裸名初值不被猜测为其中任一父枚举")
    func ambiguousBareCaseNameIsNotGuessed() throws {
        // 意图：本支只收「父枚举唯一」这一档；歧义时不得挑一个父枚举了事（挑错会让运行期按错的枚举构造值）。
        // 判据 = 变量仍是 `Any`。判别力在报文里那个类型名：歧义若也取第一个父枚举，
        // 报文会由 `got Any` 变成 `got EmptyA` ⇒ 本用例转红。
        let source = #"""
        [EmptyA]
        空
        A用(x: I32,)

        [EmptyB]
        空
        B用(x: I32,)

        main|func() -> ():
            var v = 空
            var s: I32 = v
            print(s,)
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"Any\"") == true,
            "歧义时该保持不可解析，实际：\(String(describing: observed?.message))"
        )
    }

    // MARK: - 判据 4：同名局部绑定**优先于**用例名

    @Test("同名局部绑定存在时，按变量取类型，不被用例名顶掉")
    func localBindingShadowsTheBareCaseName() throws {
        /// 意图：值位解析必须先看变量表（作用域内可见者优先），本支只在变量表查不到时才成立。
        /// 判别力 = 若把本支挪到变量表之前，`旗空` 会被当成用例 ⇒ 报文由 `got I32`
        /// 变成 `got 旗`（或干脆不报）⇒ 本用例转红。
        let source = #"""
        [旗]
        旗空
        旗满

        拿|func(f: 旗,) -> (I32,):
            match f:
                case 旗空:
                    return 0
                case 旗满:
                    return 1
            return 1

        main|func() -> ():
            var 旗空 = 1
            print(拿(旗空,),)
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"I32\"") == true,
            "应取局部绑定的类型，实际：\(String(describing: observed?.message))"
        )
    }

    // MARK: - 判据 5：修复不得放宽后续赋值位的检查

    @Test("初值形态被修复之后，后续赋值位的类型不符仍然被拦")
    func bareCaseNameInitializerIsStillCheckedAgainstLaterAssignments() throws {
        /// 意图：本支的收益是**让初值有个确切类型**，不是「让这种写法一路免检」。
        /// 判别力 = 若把本支写成放行（例如让变量保持 `Any`、或在赋值位跳过比对），
        /// 本用例转红 —— 它挡的是「把修复做成改松」。
        let source = #"""
        [旗]
        旗空
        旗满

        主|func() -> ():
            var f = 旗空
            f = 1
            print("x",)
            return

        main|func() -> ():
            return
        """#
        let observed = failure { _ = try typeChecked(source) }
        #expect(observed?.code == "E4-001", "应报类型不符，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("got: \"I32\"") == true,
            "应报「把整数赋给了枚举」，实际：\(String(describing: observed?.message))"
        )
    }
}
