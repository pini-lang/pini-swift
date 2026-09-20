import Foundation
@testable import PiniCore
import Testing

/// 让出（`await` 释放工作线程）的判据（缺口 `G74` 的兑现面）。
///
/// **这一件测什么**：`DE-2a` 已经让两个关键字在管线上分得开，但让出本身没落地 ——
/// 两台引擎都把 `await` 按**阻塞**处理，即 `await` 降级成 `wait`。本件测的是那一格被补上：
/// `await` 一个**未决**子任务时，父任务的体**提前退出**、把工作线程还回池子，
/// 等子任务决了再从精确恢复点续跑。
///
/// **怎么把它测成确定性的**：让出与阻塞的差别，直接读的是「池子里有几个任务」——
/// `GCDScheduler.activeTaskCount` 本就是为可观测立的（调度器自述：「可观测、可诊断」）。
/// 这正是契约里 `bk_task_yield` 返回码 `1`（真让出）/ `0`（降级）在解释器腿上的对应物：
/// **一个位就是「本次让出是否真的发生了」**。
///
/// ⚠️ 光读那个位还不够，会读到假的：父任务 spawn 子任务**之前**，池里也只有一个任务。
/// 所以语料让子任务在睡之前先打印一个标记，测试**等那个标记出现之后**才开始判读 ——
/// 于是「池里只剩一个」在那一刻只可能是父让出造成的。驳回性的那一半用同一段语料、
/// 只把关键字换成 `wait`：阻塞的父任务不会提前退出，池里**不会**出现那一格。
///
/// 每条用例三要素齐备：意图写在显示名与首行注释；推进性测量断言期望行为**发生**；
/// 驳回性测量断言不该发生的**确实没发生**（否定形态，见测试规程 `C5`）。
/// ⚠️ 串行化：本 suite 的判据会读调度器的观测面，两条用例并行会互相把对方的读数挪走。
@Suite(.serialized)
struct ConcurrencyYieldTests {

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

    private func lowered(_ source: String) throws -> HIRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 同一段程序，两个关键字只差一个词 —— 这是判据的最小语料。
    ///
    /// 三处标记都是判据的一部分，不是叙述：子任务先打 `S-start`（测试等它，以便把
    /// 「池里只剩一个」的判读起点挪到子任务已经 spawn **之后**），睡一段足以让判读跑完的
    /// 时间，再打 `S-done`（它同时是「睡完了」与「下一次判读该走了」的信号）。
    /// 子任务的返回值得以走到 `print(7)`，所以这条语料**同时**钉住结果正确性。
    /// ⚠️ **2026-09-20 改过对照的形态（裁定 35）**：原来是「同一体把 `await` 换成 `wait`」，
    /// 但新规则不许异步体写 `wait` ⇒ 那个对照在**语言层面已不可能**，留着一个编不过的语料
    /// 只会让判据变成装饰。改成「先让子任务跑完，再 `await`」—— 同一代码路径、同一个关键字，
    /// 只差**等待时子任务是否已决**。它证明的事情反而更准：让出不是 `await` 这个字造成的，
    /// 是「要等一个还没好的东西」造成的。
    private static func yieldProbe(_ mode: String) -> String {
        mode == "settled" ? 探针已决 : 探针未决
    }

    private static let 探针未决 = """
    慢|func(n: I32,) => (I32,):
        print("S-start")
        sleep(250)
        print("S-done")
        return ok(n)

    父|func(n: I32,) => (I32,):
        let a = 慢(n)
        let x = try await a else e:
            return err(Error("failed"))
        return ok(x)

    main|func() -> ():
        let t = 父(7)
        let r = wait t
        match r:
            case ok(v):
                print(v)
            case err(e):
                print("failed")
        return
    """

    private static let 探针已决 = """
    慢|func(n: I32,) => (I32,):
        print("S-start")
        sleep(250)
        print("S-done")
        return ok(n)

    父|func(n: I32,) => (I32,):
        let a = 慢(n)
        sleep(400)
        let x = try await a else e:
            return err(Error("failed"))
        return ok(x)

    main|func() -> ():
        let t = 父(7)
        let r = wait t
        match r:
            case ok(v):
                print(v)
            case err(e):
                print("failed")
        return
    """

    /// 跑一次探针，返回（本次运行里让出发生的次数，全部输出）。
    ///
    /// ⚠️ 判据读的是**增量**而不是池的水平线，这是被实测逼出来的：池水平线是「整台机器现在
    /// 有几个任务」的读数，而测试默认并行执行 ⇒ 另一条用例的任务会把读数挪走，
    /// 让一条本来成立的判据报红。让出计数只由「让出」驱动 ⇒ 取增量即可判定，
    /// 不需要独占整台机器。
    private func runYieldProbe(join: String) throws -> (yields: Int, lines: [String]) {
        let module = try lowered(Self.yieldProbe(join))
        let lock = NSLock()
        var lines: [String] = []
        var finished = false

        let executor = HIRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        let before = GCDScheduler.shared.yieldedTaskCount
        DispatchQueue.global().async {
            _ = try? executor.run(module: module)
            lock.lock()
            finished = true
            lock.unlock()
        }

        // 等程序跑完再收读数：判据不该靠「提前读」拿结论，那样量到的是过程中的某一瞬。
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { break }
            usleep(2000)
        }
        lock.lock()
        let seen = lines
        lock.unlock()
        return (GCDScheduler.shared.yieldedTaskCount - before, seen)
    }

    // MARK: - 判据 1：让出真的发生（推进性），且 `wait` 不占用同一格（驳回性）

    @Test("await 未决子任务时父任务把线程让出去 —— 子任务已决则不让出")
    func awaitingGivesTheTaskUp() throws {
        /// 意图：这是本批的核心判据，它一次测两面，因为「让出」这个概念**就是**那个差异。
        /// 推进性：`await` 版必须观测到**至少一次让出** —— 子任务还没决，父任务的体
        /// 就该把线程还回池子，等它决了再续跑。
        /// 驳回性：`wait` 版**不许**观测到任何一次让出。阻塞的父任务从头占着自己的线程
        /// 直到子任务决，它的体一刻也没有提前退出过。
        ///
        /// ⚠️ 两面必须同一语料、只差一个关键字：拿两段不同的程序对照，
        /// 差异就可能来自别处，而这条判据要说的恰恰是**唯有关键字**造成了差异。
        let yielding = try runYieldProbe(join: "await")
        let occupying = try runYieldProbe(join: "settled")

        #expect(yielding.yields >= 1, "await never gave its task up (yields: \(yielding.yields))")
        #expect(occupying.yields == 0, "wait gave its task up \(occupying.yields) time(s), so the two forms are not distinct")
    }

    // MARK: - 判据 2：让出后从精确恢复点续跑，值正确（推进性）

    @Test("让出之后体从恢复点接着跑 —— 结果值照旧算对")
    func theResumedBodyStillProducesTheRightValue() throws {
        /// 意图：让出最省事的错法，是「让出去之后从头再跑」——那样结果会**看起来**对
        /// （子任务会再 spawn 一次、值再算一遍），而副作用做了两遍。本判据用
        /// `S-start` 的**出现次数**把这条堵住：子任务只该被 spawn 一次。
        /// 同时钉住返回值走到了输出（`7`），即续跑的路径没有把语句尾巴丢掉。
        let probe = try runYieldProbe(join: "await")

        #expect(probe.lines.contains("7"), "the resumed body did not carry its value to the end")
        #expect(
            probe.lines.filter { $0 == "S-start" }.count == 1,
            "the child was spawned more than once, so the body restarted instead of resuming"
        )
    }
}
