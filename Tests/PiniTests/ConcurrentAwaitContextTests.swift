import Foundation
import PiniCore
import Testing

/// `await` / `wait` 的**上下文与位置**判定（裁定 35 的兑现面）。
///
/// **这一件测什么**：两个关键字各自绑定自己的上下文 —— `await` 只许写在异步函数体（`=>`）内、
/// `wait` 只许写在同步函数体（`->`）内 —— 且 `await` 还额外要求自己落在**语句根位置**。
/// 三条拒绝理由的修法各不相同，所以用两个码：上下文不符（`E6-009`）改的是函数签名或关键字，
/// 位置越界（`E6-010`）改的是写法。
///
/// **为什么位置也要拒**：`await` 与 `wait` 的唯一运行区别就是让不让出，而让出需要**可恢复的体**
/// （`DE-2b` 的挂起帧）。语句根之外没有续跑点，于是同一个 `await` 会在 A 处让出、B 处静默按
/// 阻塞处理，而使用者无从知道 —— 那正是这条规则要消灭的东西。
///
/// 判据分两组：**驳回性**（四种越界各自报出正确的码）与**推进性**（四个合法形态照旧编译通过、
/// 顶层的语句根不被误伤）。没有后面这组，规则退化成「一律拒绝」也能全绿。
///
/// ⚠️ **受理面于 2026-09-24 收窄**：可让出位置除「语句根四形态」外，还须落在**体那一层**
/// ⇒ 嵌套块里的语句根**也**报 `E6-010`（此前那一格由发射层拒，且是内部断言）。本件里
/// 「嵌套块里的语句根」那一条随之**反转方向**；`theFourStatementRootsStillLower` 不动，
/// 两者一收一放合起来才说明规则仍只在划边界。
struct ConcurrentAwaitContextTests {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 前端四道门 + 降载；返回诊断码，`nil` 表示顺利降载。
    private func loweringCode(_ source: String) throws -> String? {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        do {
            _ = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
            return nil
        } catch let error as IRLowerer.IRLoweringError {
            return error.code
        }
    }

    private static let 子任务 = """
    慢|func(n: I32,) => (I32,):
        return ok(n)

    """

    // MARK: - 驳回性：四种越界各自报出正确的码

    @Test("`await` 写在同步体里报 E6-009 —— 上下文不符，不是位置问题")
    func awaitOutsideAsyncBodyIsRejected() throws {
        /// 意图：`await` 承诺让出，而同步体没有可让出的任务。报的必须是**上下文**码：
        /// 位置其实是合法的（`try` 的 operand 位），若报位置码会把人引到错误的修法上。
        let source = Self.子任务 + """
        main|func() -> ():
            let t = 慢(1)
            let r = try await t else e:
                return
            return
        """
        #expect(try loweringCode(source) == "E6-009")
    }

    @Test("`wait` 写在异步体里报 E6-009 —— 这条规则的另一面")
    func waitInsideAsyncBodyIsRejected() throws {
        /// 意图：`wait` 占住线程直到子任务结束。异步体内这样写，池里的槽位会各等各自的
        /// 子任务、子任务排不到线程（池饥饿）。驳回的是**上下文**，与位置无关 ——
        /// 同一个 `wait` 写在同步体里就是对的（见本件推进性那组）。
        let source = Self.子任务 + """
        父|func() => (I32,):
            let t = 慢(1)
            let r = try wait t else e:
                return ok(0)
            return ok(0)
        """
        #expect(try loweringCode(source) == "E6-009")
    }

    @Test("`await` 落在语句根之外报 E6-010 —— 上下文是对的，位置不对")
    func awaitOutsideStatementRootIsRejected() throws {
        /// 意图：这里函数体是异步的（上下文合法），但 `await` 藏在 `if` 的条件位里。
        /// 条件位没有续跑点，让出去了回不来。报**位置**码，因为要改的是写法而不是签名。
        let source = Self.子任务 + """
        父|func() => (I32,):
            let t = 慢(1)
            print(await t)
            return ok(0)
        """
        #expect(try loweringCode(source) == "E6-010")
    }

    @Test("赋值语句里的 `await` 报 E6-010 —— 它的求值点不在运行时的让出计划里")
    func assignRHSIsRejected() throws {
        /// 意图：`x = await t` 看起来像语句根，但运行时的让出计划只认四形态
        /// （裸语句 · `var` 初值 · `match` 判别式 · try 的 operand），赋值不在其中。
        /// 放行它会造出「检查器说合法、运行时静默按阻塞处理」—— 那正是这条规则要消灭的混合，
        /// 所以按 fail-closed 拒绝。这是**刻意的**，不是遗漏。
        let source = Self.子任务 + """
        父|func() => (I32,):
            let t = 慢(1)
            var slot = await t
            slot = await t
            return ok(0)
        """
        #expect(try loweringCode(source) == "E6-010")
    }

    // MARK: - 推进性：合法的照旧合法

    @Test("四个语句根形态都照旧编译通过 —— 规则没有误伤它们")
    func theFourStatementRootsStillLower() throws {
        /// 意图：规则的价值全在**边界**上，所以边界内侧必须逐个钉住。四形态与运行时的
        /// 让出计划同源；若这里有任何一个被拒，规则就已经从「划边界」变成了「砍功能」。
        let source = Self.子任务 + """
        父|func() => (I32,):
            let t = 慢(1)
            await t
            var a = await t
            let b = try await t else e:
                return ok(0)
            match await t:
                case ok(v):
                    return ok(v)
                case err(e):
                    return ok(0)
            return ok(0)

        main|func() -> ():
            return
        """
        let code = try loweringCode(source)
        #expect(code == nil, "实际码：\(String(describing: code))")
    }

    @Test("嵌套块里的语句根也报 E6-010 —— 可让出位置收在体那一层")
    func nestedBlockStatementRootIsRejectedToo() throws {
        /// ⚠️ **这一条的方向于 2026-09-24 被用户裁定反转**，原样保留在此以免读的人以为它一直如此：
        /// 它**曾经**钉的是「**不被误伤**」—— 原委是「嵌套控制流内部非法」只对**条件位 / 判别式位**
        /// 成立、不对**体**成立，混淆两者是当时最容易犯的错。
        /// ⭐ 新裁定把受理面收窄为**体那一层**，理由是发射层给不出嵌套块的续跑点：
        /// 续跑的跳转只跳得回体那一层的那一块，嵌套块的进入条件在那条路径上被整段跳过。
        /// ⇒ 收窄是**把两层收口到同一个答案上**，不是新增限制（此前这里放行、发射层拒绝，
        /// 而那次拒绝是**内部断言** —— 编译器直接崩，用户输入的是一段能跑的程序却编不过）。
        ///
        /// ⛔ 为什么**改而不删**：它原先是「防过度拒绝」的哨兵，现在改为钉**新边界的另一侧**。
        /// 与它成对的 `theFourStatementRootsStillLower`（顶层四形态照旧合法）必须**继续绿** ——
        /// 两者合起来才说明「收窄到体那一层」没有变成「砍掉让出」。
        let source = Self.子任务 + """
        父|func(c: Bool) => (I32,):
            let t = 慢(1)
            if c:
                var r = await t
            while c:
                await t
                break
            return ok(0)

        main|func() -> ():
            return
        """
        #expect(try loweringCode(source) == "E6-010")
    }

    @Test("同步体的表达式位 `wait` 不受影响 —— 既有语料照旧")
    func waitInSyncExpressionPositionStillWorks() throws {
        /// 意图：驳回性测量。规则收紧的是 `await` 的位置，不能顺手把 `wait` 也限位 ——
        /// `wait` 是该位置的阻塞值，随处可用是它的语义（既有语料 `match wait a:` 就靠这一点）。
        let source = Self.子任务 + """
        main|func() -> ():
            let t = 慢(1)
            match wait t:
                case ok(v):
                    print(v)
                case err(e):
                    print("err")
            return
        """
        let code = try loweringCode(source)
        #expect(code == nil, "实际码：\(String(describing: code))")
    }
}
