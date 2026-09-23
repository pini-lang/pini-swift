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
/// 这正是契约里 `bk_task_yield` 返回码 `1`（真让出）/ `0`（降级）在解释器后端上的对应物：
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

    /// 一个体里**两处** `await` 的最小语料 —— 归并口径的判据靠它取区分力。
    ///
    /// 为什么必须是**两处**：只让出一次的程序上，「只数首跑那一趟」与「每一次都数」
    /// **读数相同** ⇒ 那种语料量不出归并前后的差别（这也正是它此前没被发现的原因）。
    /// 第二次 `await` 的对象是**新 spawn 的**子任务 ⇒ 它同样未决、同样会让出。
    ///
    /// ⚠️ 睡眠取值刻意**远小于**下面那两份为「池水平线判读」留窗口的语料：本判据读的是
    /// **让出计数的精确值**、不需要判读窗口，只要求「`await` 那一刻子任务尚未决」
    /// —— 而 spawn 到 await 之间只隔微秒 ⇒ 留一点余量即可。取大值的代价是**整机负载**：
    /// 全量并行时它会去挤别的判据（本仓另有一条判据用固定秒数的看门狗等结果）。
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
    private func runYieldProbe(_ source: String) throws -> (yields: Int, lines: [String]) {
        let module = try lowered(source)
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

    /// 同一份语料，但让出读数取自**只归本次运行**的后端（替身）。
    ///
    /// ⚠️ 为什么要能换读数来源：进程级单例的计数是**整台机器**的读数，并行的另一条用例
    /// 让出一次就把它挪走（上面那条也因此取**增量**）。替身把生产后端整个委派出去、
    /// 只在体的结局处挂一个计数 ⇒ 只数自己的，不必靠增量。
    ///
    /// ⚠️ 断言形态与上面那条**一致**（同一个精确值），两条各是一次独立判定 ——
    /// **合起来才是「两侧同口径」**；只保一侧的话，「归并完成」会变成一侧的完成。
    /// ⚠️ 它与上面那条同住一个**串行化**的 suite：两条都会真的跑程序，
    /// 并行跑会互相挪动读数（本 suite 的串行正是为这个立的）。
    private func runYieldProbe(
        _ source: String, via counting: YieldCountingScheduler
    ) throws -> (yields: Int, lines: [String]) {
        let module = try lowered(source)
        var lines: [String] = []
        let executor = HIRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: counting)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: module)
        // 读在运行**之后**：`main` 的那一处 `wait` 会把整条链等到决 ⇒ 此刻所有让出都已发生。
        return (counting.yieldCount, lines)
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
        let yielding = try runYieldProbe(Self.yieldProbe("await"))
        let occupying = try runYieldProbe(Self.yieldProbe("settled"))

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
        /// 意图：各后端的让出计数必须是**同一个量**（口径 = 让出动作次数）。归并前本后端只数
        /// 「体在派发那一趟上让出」—— 续跑由决出方直接驱动、不经派发口 ⇒ 一个体内让出两次的
        /// 程序只读得到 1，而 LLVM 后端读得到 2。本判据用**精确值**把归并钉住。
        ///
        /// ⚠️ 它的区分力**全在语料上**：只让出一次的程序，两种口径读数相同 ⇒ 那种语料
        /// 量不出这次归并（这正是该缺口此前只能靠读各后端的代码发现的原因）。
        ///
        /// 驳回性的一半由**语料自检**承担：两个子任务必须都起来过（两处 `S-start`），
        /// 否则「读数 = 2」可能出自别的原因，而语料已经不再测它自称要测的东西。
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

    @Test("替身也数续跑那一次 ⇒ 读数 = 2（与生产后端同一个量）")
    func theCountingBackendCountsResumedRunsToo() throws {
        /// 意图：口径归并要求**两侧同时**跟上。只改生产后端会让「替身与生产后端读数一致」
        /// 这条前提**静默失效** —— 两边的数**各自都看不出错**，差别只在「一个体内让出多次」
        /// 的语料上显形（只让出一次时两种口径读数相同）。
        ///
        /// ⚠️ 本条读替身的读数、上一条读生产后端的读数，两条断的是**同一个精确值**
        /// ⇒ 合起来等价于「两侧相等」。分居两条不是因为可以少验一侧，而是读数来源不同。
        let counting = YieldCountingScheduler(inner: GCDScheduler.shared)
        let probe = try runYieldProbe(Self.探针两处让出, via: counting)

        #expect(
            probe.yields == 2,
            "the counting backend saw \(probe.yields) give-ups — the resumed one did not land here"
        )
        #expect(probe.lines.contains("7"), "the second await did not carry its value to the end")
    }

    // MARK: - 判据 5：顺序由**策略**决定，而不是由**决出顺序**决定（改道那一格的验收面）

    /// 一对判据共用的语料 —— 两份**只差**开头那一段 `[[调度器]]` 覆盖块。
    ///
    /// ⭐ 语料的机关在**时间**上，三处缺一不可：
    /// - `父` 先派发 `甲`/`乙`（各自 await 一个闸），**再** await 自己的闸 ⇒
    ///   「父被挂起」先发生；
    /// - `父` 的**续跑段**睡一段（300ms）⇒ 它占住驱动，而 `甲`（100ms）与 `乙`（150ms）的闸
    ///   在这期间先后决出 ⇒ **两笔入队都发生在任何一次挑选之前**；
    /// - 于是策略层拿到的是一个**装着两件待跑项的队列**，它挑谁谁就先跑。
    ///
    /// ⚠️ 不作覆盖（默认策略 = 先进先出）时，顺序应当**等于决出顺序**（甲先于乙）；
    /// 覆盖成后进先出之后，**先跑的必须是后决出的乙**。两条读数互为反证：
    /// 只看后一条，「策略生效」与「碰巧乙先跑」在读数上**同形**。
    ///
    /// ⚠️ 为什么这条判据**不能省**（本 suite 的串行化正是为这类判据立的，代价是它占住整个套件）：
    /// 它是「结果决出 ⇒ 入队」这处改道**唯一**的验收面。判据面里最直观的候选
    /// （验「选择下一个任务被调用过至少一次」）**区分力不足** —— 回调式实现下它也会绿:
    /// 一次「调用记录」不证明顺序由策略决定。只有「顺序 = 策略给的顺序」能把它证伪。
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
        /// 意图：整段「改道」的验收面。
        /// 推进性：默认策略下顺序**等于决出顺序**（甲先于乙）——
        /// 这一步同时证明语料里的两个闸确实是先后决出的，否则后一条读数没有意义。
        /// 驳回性：同一段语料只多一个覆盖块，先跑的必须变成**后决出的乙**。
        /// 两条合起来才说明「先跑谁」是**策略**说了算，而不是决出时刻说了算。
        ///
        /// ⚠️ 变异（必须转红）：去掉改道（恢复「决出 ⇒ 直接重入体」）⇒ 顺序退回决出顺序，
        /// 覆盖块形同虚设 ⇒ 本条的后一个断言读到 `甲/乙/父续`（已实测）。
        let preset = try runYieldProbe(Self.strategyOrderCorpus(overriding: false)).lines
        #expect(preset == ["父续", "甲", "乙"], "默认策略下顺序应当等于决出顺序：\(preset)")

        let overridden = try runYieldProbe(Self.strategyOrderCorpus(overriding: true)).lines
        #expect(
            overridden == ["父续", "乙", "甲"],
            "覆盖成后进先出后，先跑的应当是后决出的乙：\(overridden)"
        )
    }
}
