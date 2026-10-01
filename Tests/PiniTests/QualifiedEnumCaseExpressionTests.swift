import Foundation
import PiniCore
import Testing

/// 枚举**型名限定的零参用例**（`色彩.绿`，不带括号）作表达式时的降载判据。
///
/// **修的是哪一层**：`IRLowerer` 的 `.member` 表达式分支只认三种接收者
/// （Optional 型名 · 名义值 · 元组），**没有**「接收者是枚举型名」这一支 ⇒
/// 落到兜底的标识符降载上，报 `reference to undeclared variable '色彩'`（E6-004）。
/// ⚠️ 同一形态的**带参**写法（`色彩.绿(载荷)`）在 `lowerMemberCall` 里早已接线
/// ⇒ 缺口只在**无参**那一半，本件钉的就是这半。
///
/// **为什么它不是「罕见写法」**：小写枚举（零载荷）作常量用时，限定写法是**唯一**
/// 在跨文件/同名用例下仍然确定的写法；本仓的判据语料里正有一份用它。
///
/// 判据 1、2 修前必红；判据 3、4 钉「修复不得越过自己的边界」。
struct QualifiedEnumCaseExpressionTests {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

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

    private func lowered(_ source: String) throws -> IRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    private func runOutput(_ source: String) throws -> [String] {
        var lines: [String] = []
        let executor = IRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    // MARK: - 判据 1：型名限定的零参用例可作表达式（修前报 E6-004）

    @Test("枚举型名限定的零参用例作初值时不再报未声明变量，且取到的是该用例")
    func qualifiedZeroPayloadCaseLowers() throws {
        /// 意图：`色彩.绿` 的接收者是**类型名**、不是变量 ⇒ 必须在 lower receiver 之前拦截。
        /// 判别力 = 修前该处抛 `reference to undeclared variable '色彩'`（E6-004），
        /// 本用例直接跑不通；修后其 tag（声明序 1）必须落到 `查` 的第二个臂上。
        let source = #"""
        [色彩]
        红
        绿

        查|func(c: 色彩,) -> (I32,):
            match c:
                case 红:
                    return 1
                case 绿:
                    return 2
            return 0

        main|func() -> ():
            var c: 色彩 = 色彩.绿
            print(查(c,),)
            return
        """#
        #expect(try runOutput(source) == ["2"])
    }

    // MARK: - 判据 2：限定写法按**型名**决议，不被同名用例带偏

    @Test("两个枚举有同名用例时，限定写法取的是限定它的那个枚举")
    func qualifiedFormResolvesByTheQualifierNotByBareName() throws {
        /// 意图：本支的价值正在于「限定」二字 —— 裸名在跨枚举同名时要么歧义、要么靠
        /// 期望类型猜。判别力 = 若把本支实现成「忽略接收者、按裸名查」，两个枚举的
        /// `异` 撞名 ⇒ 取错父枚举 ⇒ 输出由 11 变 10（或直接因歧义报错）。
        let source = #"""
        [甲]
        同
        异

        [乙]
        同
        异

        取|func(x: 甲,) -> (I32,):
            match x:
                case 同:
                    return 10
                case 异:
                    return 11
            return 0

        main|func() -> ():
            var a: 甲 = 甲.异
            print(取(a,),)
            return
        """#
        #expect(try runOutput(source) == ["11"])
    }

    // MARK: - 判据 3：带载荷的用例**不走**本支（响亮拒绝，不静默取值）

    @Test("对带载荷用例误用无限定括号的写法则响亮拒绝")
    func payloadCaseWithoutCallIsRejectedLoudly() throws {
        /// 意图：本支只收「零载荷」这一档。带载荷的用例省略实参**不能**被当成
        /// 「载荷缺省」放过去 —— 那会造出一个载荷位未初始化的箱。
        /// 判别力 = 若把本支写成「一律按零载荷构造」，本用例由红转绿。
        let source = #"""
        [形状]
        圆(半径: I32,)
        方(边长: I32,)

        main|func() -> ():
            var s: 形状 = 形状.圆
            print(1,)
            return
        """#
        let observed = failure { _ = try lowered(source) }
        #expect(observed?.code == "E6-004", "应响亮拒绝，实际：\(String(describing: observed))")
        #expect(
            observed?.message.contains("carries associated values") == true,
            "拒绝理由应是「该用例带载荷」，实际：\(String(describing: observed?.message))"
        )
    }

    // MARK: - 判据 4：带实参的限定构造照旧可用（本支不得顶掉它）

    @Test("限定构造 Enum.Case(载荷) 的既有通路不受本支影响")
    func qualifiedPayloadConstructorStillWorks() throws {
        /// 意图：本支加在**表达式**分支上，带实参的形态走的是**调用**分支
        /// （`lowerMemberCall` 里那条早已存在的支）⇒ 两条路必须各归各。
        /// 判别力 = 若本支的拦截写在调用分支之前且不区分实参，本用例会由绿转红。
        let source = #"""
        [形状]
        圆(半径: I32,)
        方(边长: I32,)

        面|func(s: 形状,) -> (I32,):
            match s:
                case 圆(半径):
                    return 半径
                case 方(边长):
                    return 边长
            return 0

        main|func() -> ():
            var s: 形状 = 形状.圆(半径 = 5,)
            print(面(s,),)
            return
        """#
        #expect(try runOutput(source) == ["5"])
    }
}
