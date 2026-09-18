import XCTest
@testable import PiniCore
import Foundation

/// 结构化并发：任务作用域（父返回自动取消未 join 子）与协作式取消检查点。
///
/// 契约依据 `Pini草稿.md（异步函数块）` 3.7：
/// - 「父任务返回（正常/被取消）时，其未 join 子任务自动 cancel()，零泄漏」；
/// - 「协作式检查点（循环头 / sleep / `<=` / `=>` 体入口 / 递归入口）读取当前任务 cancelled，
///   发现则提前结束；拒绝抢占式线程 kill」。
///
/// 覆盖两层：
/// 1. `FutureValue` 作用域单元——未完成子被取消 / 已完成子不动 / detach 后免疫；
/// 2. 共享规则接缝——`joinFuture` 消费后子脱离父、`checkCancellation` 同步路径零影响；
/// 3. 语言层端到端——取消真正打断运行中的循环与 sleep。
///
/// `G-6c` 的收缩（**已裁决**，非本文件的技术选择）：原语言层有 8 条，其中 5 条
/// **随 AST 走查一同退役**。它们不是「改指失败」，而是引擎能力不够——换到现役引擎上
/// 实测全红，且每条都撞在**已有主的缺口**上（`Result` 值打印、结果类型、取消时的
/// `defer` 清理）。承其覆盖的判据仍在：上面前两条与 `testCancelUnjoinedChildren*`
/// 守住了作用域与取消的原语语义，本节第 3 条守住语言层端到端。
/// ⚠️ **代价如实登记**：`defer` 清理那一条退役后，该缺陷**不再有测试见证**，
/// 只在工单里；明细见「残余引用面」件的退役账与 `issue-hir-defer-not-run-on-cancel-2026-09-18`。
final class StructuredConcurrencyTests: XCTestCase {

    // MARK: - B2-2 任务作用域：父返回自动取消

    /// 意图：父返回时只取消**未完成**的子任务；已完成的子结果仍可读取（取消不是追溯性失效）。
    func testCancelUnjoinedChildrenOnlyCancelsPendingOnes() {
        let parent = FutureValue()
        let finished = FutureValue()
        let pending = FutureValue()
        parent.addChild(finished)
        parent.addChild(pending)
        finished.resolve(.int(1))

        parent.cancelUnjoinedChildren()

        XCTAssertFalse(finished.isCancelled, "已完成的子任务无需取消，其结果应保持可读")
        XCTAssertTrue(pending.isCancelled, "未完成的子任务应随父返回被取消，避免泄漏")
        guard case .int(let kept)? = try? finished.wait() else {
            return XCTFail("已完成子任务的结果应仍可 join 读取")
        }
        XCTAssertEqual(kept, 1)
    }

    /// 意图：父返回自动取消沿整棵子树下发——孙任务同样不得逃逸父的生命周期。
    func testCancelUnjoinedChildrenPropagatesToGrandchildren() {
        let parent = FutureValue()
        let child = FutureValue()
        let grandchild = FutureValue()
        parent.addChild(child)
        child.addChild(grandchild)

        parent.cancelUnjoinedChildren()

        XCTAssertTrue(child.isCancelled)
        XCTAssertTrue(grandchild.isCancelled, "取消应递归下发到孙任务")
        XCTAssertFalse(parent.isCancelled, "取消下发不得波及父自身（父返回只是清理未 join 子）")
    }

    /// 意图：显式 join 过的子任务脱离父节点，此后不再受「父返回自动取消」约束。
    func testDetachedChildSurvivesParentReturn()  throws {
        let parent = FutureValue()
        let child = FutureValue()
        parent.addChild(child)

        child.detachFromParent()

        XCTAssertNil(child.parent, "detach 后应断开父链接")
        XCTAssertTrue(parent.childrenSnapshot().isEmpty, "detach 应从父的子表中摘除，避免无界增长")
        parent.cancelUnjoinedChildren()
        XCTAssertFalse(child.isCancelled, "已脱离的子任务不应被父返回取消")
    }

    /// 意图：`<=` 消费（joinFuture）即视为「已 join」，共享规则上必须完成 detach。
    ///
    /// `G-6b` 起断言的是 **`RuntimeOps` 的那一条规则**，不再经解释器实例 ——
    /// 两侧本是逐字转发，而经实例断言会让这条判据随实例类型的删除一起消失。
    func testJoinFutureDetachesChildFromParent()  throws {
        let parent = FutureValue()
        let child = FutureValue()
        parent.addChild(child)
        child.resolve(.int(7))

        _ = RuntimeOps.joinFuture(child, timeoutMs: nil)

        XCTAssertTrue(parent.childrenSnapshot().isEmpty, "join 后子任务应脱离父节点")
        XCTAssertNil(child.parent)
        XCTAssertFalse(child.isCancelled, "join 消费结果不应取消子任务（结果仍应可读）")
    }

    // MARK: - B2-3 检查点单元

    /// 意图：检查点在同步路径（owner == nil）必须完全无副作用——这是「主线程零开销」的前提。
    ///
    /// `G-6b` 起断言的是**共享规则本身**（`RuntimeOps`），不再经某个引擎的名字：该规则
    /// 原先在两侧各有一份、HIR 那份还是 `private`，于是这条接缝只能由仍存活的引擎代为作证
    /// —— 而那正是它会在删除日一起消失的原因。
    func testCheckpointIsNoOpWithoutOwner()  throws {
        XCTAssertNoThrow(try RuntimeOps.checkCancellation(nil))

        let live = FutureValue()
        XCTAssertNoThrow(try RuntimeOps.checkCancellation(live), "未取消的任务不应被检查点中断")

        live.cancel()
        XCTAssertThrowsError(try RuntimeOps.checkCancellation(live)) { error in
            guard case RuntimeError.taskCancelled = error else {
                return XCTFail("已取消任务的检查点应抛 taskCancelled，实际: \(error)")
            }
        }
    }

    // MARK: - 语言层端到端

    /// 意图：取消能真正打断**运行中的循环**（循环头检查点），而不是等它自然跑完。
    /// 推进性测量：循环规模足以跑数秒，取消后整体应在 3s 内收敛，且任务体末尾的打印不得出现。
    func testCancelInterruptsRunningLoop() throws {
        let source = try loadPiniFixture("testCancelInterruptsRunningLoop", filePath: #filePath)
        let start = Date()
        let output = try runProgramOnHIRTree(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("已取消"), "被取消的任务 join 应归约为 err(CancelError)，实际输出: \(output)")
        XCTAssertFalse(output.contains("循环跑完了"), "循环头检查点应提前结束任务体，实际输出: \(output)")
        XCTAssertLessThan(elapsed, 5.0, "取消未生效会退化为等待整个循环跑完")
    }

    /// 意图：纯同步程序（主线程 owner == nil）完全不受取消检查点影响——循环与函数调用行为
    /// 不变（推进性：同步求值照常出结果；驳回性：任何「已取消/检查点打断」副作用不得出现）。
    func testSynchronousProgramUnaffectedByCheckpoints() throws {
        let source = try loadPiniFixture("testSynchronousProgramUnaffectedByCheckpoints", filePath: #filePath)
        let output = try runProgramOnHIRTree(source)
        XCTAssertTrue(output.contains("45"), "同步路径应完全不受取消检查点影响，实际输出: \(output)")
    }

    // MARK: - Helpers

    /// 跑一份源码并捕获 stdout（LR-4 `G-5`）。
    ///
    /// 原有一份逐行对应、只换驱动入口的孪生助手（走已删除的 AST 走查）。可改指的
    /// 语言层用例由此摆脱「驱动入口会被删除」的处境；它们的断言本来就是**绝对期望**
    /// （输出含某串 / 不含某串 / 耗时上限），不是臂间对照 ⇒ 换腿不改变判据强度。
    /// `G-6c` 删掉旧引擎后，本助手即**唯一**驱动，孪生那份随之消失。
    private func runProgramOnHIRTree(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let runner = ProgramRunner()
            try runner.run(module: module)
        } catch {
            fflush(stdout)
            pipe.fileHandleForWriting.closeFile()
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - （甲）scope 收口：leaked 失败上浮

    /// 意图：`closeScope` 须区分 ok/err/未完成，只把「已完成且为 err」的子计入 leaked，
    /// 并取消未完成的子（B2-2）。
    func testCloseScopeCollectsLeakedErrAndCancelsPending()  throws {
        let parent = FutureValue()
        let okChild = FutureValue()
        let errChild = FutureValue()
        let pending = FutureValue()
        parent.addChild(okChild)
        parent.addChild(errChild)
        parent.addChild(pending)
        okChild.resolve(RuntimeOps.makeResult(caseName: "ok", payload: .int(1)))
        errChild.resolve(RuntimeOps.makeResult(caseName: "err", payload: RuntimeOps.makeError("leaked boom")))
        // pending 故意保持未完成

        let leaked = parent.closeScope()

        XCTAssertEqual(leaked.count, 1, "仅未 join 且已完成为 err 的子应泄漏")
        XCTAssertTrue(pending.isCancelled, "未完成子应被取消（B2-2），防生命周期泄漏")
        XCTAssertFalse(okChild.isCancelled, "已 ok 完成的子不应被取消")
        XCTAssertFalse(errChild.isCancelled, "已 err 完成的子不应被取消（结果仍可读）")
    }

    /// 意图：`detach` 语句把子任务从父 scope 剪枝——之后父返回不再追踪其结局。
    func testDetachBuiltinPrunesChildFromParent() throws {
        let src = try loadPiniFixture("testDetachBuiltinPrunesChildFromParent", filePath: #filePath)
        let out = try runProgramOnHIRTree(src)
        XCTAssertTrue(out.contains("detached"))
    }
}
