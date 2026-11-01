import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// 让出判据：`await` 一个未决子任务时，父体提前退出、把工作线程还回池子，等它决了再从精确恢复点续跑。
/// 观测面是 `GCDScheduler.yieldedTaskCount`：每次让出记一次，只由让出动作驱动。
/// 计数按调度器实例隔离 —— 进程级单例的读数会落进并行套件的让出，串行化本套件也挡不住别的套件。
@Suite(.serialized)
struct ConcurrencyYieldTests: Sendable, PiniSourceLowering {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 同一段程序，两个关键字只差一个词。三处标记都是判据的一部分：子任务先打 `S-start`（测试等它，
    /// 把判读起点挪到 spawn 之后），睡一段够判读跑完的时间，再打 `S-done`（睡完了、下一次判读该走了）。
    /// 对照形态是「先让子任务跑完，再 `await`」：同一代码路径、同一关键字，只差等待时它是否已决。
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

    /// 一个体里两处 `await` 的最小语料 —— 归并口径的判据靠它取区分力。只让出一次的程序上，
    /// 「只数首跑那一趟」与「每一次都数」读数相同 ⇒ 量不出差别。第二次 `await` 的对象是新 spawn 的子任务。
    /// 睡眠刻意远小于池水平线判读的那两份：本判据读让出计数的精确值，只要求 `await` 那刻子任务尚未决。
    private static let 探针两处让出 = """
    慢|func(n: I32,) => (I32,):
        print("S-start")
        sleep(60)
        print("S-done")
        return ok(n)

    父|func(n: I32,) => (I32,):
        let a = 慢(n)
        let x = try await a else e:
            return err(Error("failed"))
        let b = 慢(x)
        let y = try await b else e:
            return err(Error("failed"))
        return ok(y)

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

    /// 「子任务已决」这一前提靠时间差立住：子睡 100ms、父睡 1500ms，余量 1.4 秒。
    /// 余量须远大于并行套件造成的抖动，否则前提不成立，读数会凭空多一次让出。
    private static let 探针已决 = """
    慢|func(n: I32,) => (I32,):
        print("S-start")
        sleep(100)
        print("S-done")
        return ok(n)

    父|func(n: I32,) => (I32,):
        let a = 慢(n)
        sleep(1500)
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

    /// 跑一次探针，返回（本次运行里让出发生的次数，全部输出）。每次各建一个调度器实例：
    /// 读数只归本次运行，不必靠「前后增量」把窗口缩小到一次运行 —— 那个窗口里仍会落进别的套件。
    private func runYieldProbe(_ source: String) throws -> (yields: Int, lines: [String]) {
        let module = try lowered(source)
        var lines: [String] = []
        let scheduler = GCDScheduler.isolated()
        let executor = IRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: scheduler)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: module)
        // 读在运行之后：`main` 的 `wait` 把整条链等到决 ⇒ 此刻所有让出都已发生。
        return (scheduler.yieldedTaskCount, lines)
    }

    /// 同一份语料，但让出读数取自只归本次运行的后端（替身）：它把生产后端整个委派出去、只在体的结局
    /// 挂一个计数 ⇒ 只数自己的，不必靠增量。断言形态与上一条一致（同一个精确值），两条各是一次独立判定；
    /// 合起来才是「两侧同口径」—— 只保一侧的话，「归并完成」会变成一侧的完成。两条同住串行化 suite。
    private func runYieldProbe(
        _ source: String, via counting: YieldCountingScheduler
    ) throws -> (yields: Int, lines: [String]) {
        let module = try lowered(source)
        var lines: [String] = []
        let executor = IRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: counting)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: module)
        // 读在运行**之后**：`main` 的那一处 `wait` 会把整条链等到决 ⇒ 此刻所有让出都已发生。
        return (counting.yieldCount, lines)
    }

    // MARK: - 判据 1：让出真的发生（推进性），且 `wait` 不占用同一格（驳回性）

    @Test("await 未决子任务时父任务把线程让出去 —— 子任务已决则不让出")
    func awaitingGivesTheTaskUp() throws {
        /// 意图：核心判据，一次测两面，因为「让出」这个概念就是那个差异。推进性：`await` 版必须观测到
        /// 至少一次让出（子任务还没决，父体就该把线程还回池子，等它决了再续跑）。驳回性：`wait` 版不许
        /// 观测到任何让出（阻塞的父任务从头占到子任务决，体一刻也没提前退出）。两面同语料、只差一个关键字。
        let yielding = try runYieldProbe(Self.yieldProbe("await"))
        let occupying = try runYieldProbe(Self.yieldProbe("settled"))

        #expect(yielding.yields >= 1, "await never gave its task up (yields: \(yielding.yields))")
        #expect(occupying.yields == 0, "wait gave its task up \(occupying.yields) time(s), so the two forms are not distinct")
    }

    // MARK: - 判据 2：让出后从精确恢复点续跑，值正确（推进性）

    @Test("让出之后体从恢复点接着跑 —— 结果值照旧算对")
    func theResumedBodyStillProducesTheRightValue() throws {
        /// 意图：让出最省事的错法是「让出去之后从头再跑」—— 结果会看起来对，而副作用做了两遍。
        /// 判据用 `S-start` 的出现次数堵住这条：子任务只该被 spawn 一次。同时钉返回值走到输出（`7`）。
        let probe = try runYieldProbe(Self.yieldProbe("await"))

        #expect(probe.lines.contains("7"), "the resumed body did not carry its value to the end")
        #expect(
            probe.lines.filter { $0 == "S-start" }.count == 1,
            "the child was spawned more than once, so the body restarted instead of resuming"
        )
    }

    // MARK: - 判据 3：让出次数是「每一次」，不是「首跑那一趟」

    @Test("一个体内让出两次 ⇒ 读数 = 2（首跑一次 + 续跑一次）")
    func everyGiveUpIsCountedNotOnlyTheFirstRun() throws {
        /// 意图：各后端的让出计数必须是同一个量（口径 = 让出动作次数）。一个体内让出两次的程序上，
        /// 「只数派发那一趟」读 1 而「每次让出都数」读 2 ⇒ 本判据用精确值把口径钉住。
        /// 区分力全在语料上：只让出一次时两种口径读数相同。驳回性由语料自检承担 —— 两处 `S-start` 都要出现。
        let probe = try runYieldProbe(Self.探针两处让出)

        #expect(
            probe.lines.filter { $0 == "S-start" }.count == 2,
            "expected two children, hence two waits — the corpus stopped measuring what it claims"
        )
        #expect(
            probe.yields == 2,
            "expected every give-up (outbound run + resumed run), got \(probe.yields)"
        )
        #expect(probe.lines.contains("7"), "the second await did not carry its value to the end")
    }

    // MARK: - 判据 4：替身与生产后端必须是同一个量（两侧同时跟上口径）

    @Test("替身也数续跑那一次 ⇒ 与生产后端读数相同")
    func theCountingBackendCountsResumedRunsToo() throws {
        /// 意图：口径归要求两侧同时跟上。只改生产后端会让「替身与生产后端读数一致」这条前提静默失效。
        /// 推进性：两侧各跑一遍同一份语料，都必须读出 2。驳回性：两侧读数不等即报出两个数 ——
        /// 只断替身一侧的话，「生产漏数续跑」在替身读数里看不见。
        let production = try runYieldProbe(Self.探针两处让出)
        let counting = try runYieldProbe(
            Self.探针两处让出, via: YieldCountingScheduler(inner: GCDScheduler.isolated()))

        #expect(production.yields == 2, "生产后端漏了续跑那一次：读数 \(production.yields)")
        #expect(
            counting.yields == production.yields,
            "两侧口径不同：生产 \(production.yields)，替身 \(counting.yields)")
        #expect(production.lines.contains("7"), "the second await did not carry its value to the end")
    }

    // MARK: - 判据 5：顺序由**策略**决定，而不是由**决出顺序**决定（改道那一格的验收面）

    /// 一对判据共用的语料 —— 两份只差开头那一段 `[[调度器]]` 覆盖块。机关在时间上：`父` 先派发
    /// `甲`/`乙`、再 await 自己的闸 ⇒ 父先被挂起；父的续跑段睡 300ms 占住驱动，`甲`(100) 与 `乙`(150)
    /// 在这期间先后决出 ⇒ 两笔入队都在任何一次挑选之前。默认先进先出下顺序等于决出顺序，覆盖后先跑乙。
    private static func strategyOrderCorpus(overriding: Bool) -> String {
        let overrideBlock = overriding ? """
        [[调度器]]
            选择下一个任务|self() -> (*U8,):
                var 个数 = len(self.元素)
                if 个数 == 0:
                    return 空句柄
                var 队尾 = self.元素.get(个数 - 1)
                match 队尾:
                    case some(任务):
                        self.元素 = self.元素.slice(0, 个数 - 1)
                        return 任务
                    case none:
                        return 空句柄

        """ : ""
        return overrideBlock + """
        闸|func(毫秒: I32,) => (I32,):
            sleep(毫秒)
            return ok(0)

        甲|func() => (I32,):
            var g = 闸(100)
            let x = try await g else e:
                return err(Error("闸"))
            print("甲")
            return ok(0)

        乙|func() => (I32,):
            var g = 闸(150)
            let x = try await g else e:
                return err(Error("闸"))
            print("乙")
            return ok(0)

        父|func() => (I32,):
            var a = 甲()
            var b = 乙()
            var g0 = 闸(50)
            let x = try await g0 else e:
                return err(Error("闸"))
            sleep(300)
            print("父续")
            let ra = try await a else e:
                return err(Error("甲"))
            return ok(0)

        main|func() -> ():
            var t = 父()
            var q = wait t
            return
        """
    }

    @Test("顺序由策略决定 —— 换成后进先出后，先跑的是后决出的那个")
    func thePolicyDecidesTheOrder() throws {
        /// 意图：整段「改道」的验收面。推进性：默认策略下顺序等于决出顺序（甲先于乙），这同时证明两个闸
        /// 确实先后决出。驳回性：同一段语料只多一个覆盖块，先跑的必须变成后决出的乙。两条合起来才说明
        /// 「先跑谁」由策略说了算。变异面：去掉改道则顺序退回决出顺序，后一条断言会转红。
        let preset = try runYieldProbe(Self.strategyOrderCorpus(overriding: false)).lines
        #expect(preset == ["父续", "甲", "乙"], "默认策略下顺序应当等于决出顺序：\(preset)")

        let overridden = try runYieldProbe(Self.strategyOrderCorpus(overriding: true)).lines
        #expect(
            overridden == ["父续", "乙", "甲"],
            "覆盖成后进先出后，先跑的应当是后决出的乙：\(overridden)"
        )
    }

    // MARK: - 判据 6：被等待过的失败子任务不再倒扣体的结果（配对保住上浮规则）

    /// 两份语料都含一个会失败的子任务，只差父等没等它。成对才把「收窄」与「砍功能」分开：只测前一份，
    /// 把整条「未 join 的失败子任务 ⇒ 结果上浮为 `err(aggregate)`」关掉也全绿；只测后一份则看不见缺陷。
    /// 两处 `sleep` 都是判据的一部分：前一份让子任务在父 `await` 时未决，后一份让父等它决完（仍在册）。
    private static let 探针已等的失败子任务 = """
    坏|func() => (I32,):
        sleep(60)
        return err(Error("failed"))

    父|func() => (I32,):
        let t = 坏()
        match await t:
            case ok(v):
                return ok(v)
            case err(e):
                print("handled")
                return ok(777)

    main|func() -> ():
        let t = 父()
        let r = wait t
        match r:
            case ok(v):
                print(v)
            case err(e):
                print("flipped")
        return
    """

    private static let 探针未等的失败子任务 = """
    坏|func() => (I32,):
        sleep(60)
        return err(Error("failed"))

    父|func() => (I32,):
        坏()
        sleep(200)
        return ok(555)

    main|func() -> ():
        let t = 父()
        let r = wait t
        match r:
            case ok(v):
                print(v)
            case err(e):
                print("flipped")
        return
    """

    @Test("已 `await` 的失败子任务不倒扣体的结果 —— 未 `await` 的失败子任务照旧上浮")
    func anAwaitedFailingChildDoesNotFlipTheBodysResult() throws {
        /// 意图：`await` 一个会失败的子任务本身就是一次 join；父体拿结果做了什么（err 臂处理掉或丢掉）是
        /// 父体的事，子任务的失败不该在父的 `return` 边界上再翻一次。未剪枝时边界把它读成「没人 join 过的
        /// 失败子任务」⇒ 父体的 `ok` 被翻成 `err(aggregate)`。本条读数只有解释器后端一侧：LLVM 腿另有缺口。
        let handled = try runYieldProbe(Self.探针已等的失败子任务)
        #expect(
            handled.yields >= 1,
            "语料没走到让出那一路（让出 \(handled.yields) 次）⇒ 本条测的就不是续跑那条路"
        )
        #expect(
            handled.lines == ["handled", "777"],
            "err 臂处理过之后体的结果应当算数，实际输出：\(handled.lines)"
        )

        let unjoined = try runYieldProbe(Self.探针未等的失败子任务)
        #expect(
            unjoined.lines == ["flipped"],
            "未 join 的失败子任务必须照旧上浮，实际输出：\(unjoined.lines)"
        )
    }
}
