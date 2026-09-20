import Foundation
@testable import PiniCore
import Testing

/// 并发能力的**分层自述**与**让出原语**（`DE-2b-3`：与 `DE-1` 的 ABI 形状对齐，解释器腿侧）。
///
/// **这一件测什么**：`DE-1` 定了两件事的**形状** —— `bk_task_yield() -> i32`
/// （`1` = 真让出 / `0` = 合规降级）与 `bk_capabilities() -> u32`（位图，启动解析一次、固化）
/// —— 以及一条 **MUST 纪律**：**后端兑现不了让出时降级，不失败**。
/// 形状若只在契约文件里写、执行路径读不到，那么纪律就只是一句话。本件钉的是它**读得到**。
///
/// ⚠️ 本件**不测让出是否发生**（那是 `ConcurrencyYieldTests`），也不测上下文与位置
/// （那是 `ConcurrentAwaitContextTests`）。本件只管：能力说自己有什么、让出原语回了什么、
/// 以及**回 `0` 的时候程序还跑不跑得完**。
struct ConcurrencyCapabilitiesTests {

    // MARK: - 替身后端：有调度、无让出

    /// 一个**兑现不了让出**的后端（`yieldTask()` 恒返 `0`）。
    ///
    /// 它模拟的不是坏配置，而是 `DE-1` §6.1 分层里「**L0 在场、L1 缺席**」这类**合规**后端 ——
    /// 最近的实例就是 `DE-3` 落地之前的 LLVM 腿。所以判据跑在它上面，等于提前跑了一遍
    /// 「新后端还没实现让出时，语言是什么行为」。
    ///
    /// 它照常用 `DispatchQueue` 异步派发（L0 要真的在场，否则测的就不是降级而是单线程），
    /// 只是**不让出**：`yieldTask()` 返 `0`，于是引擎走「占用线程等它决」那条路。
    private final class DispatchOnlyScheduler: Scheduler {
        private let lock = NSLock()
        private var spawnedCount = 0
        private var suspensionTotal = 0
        private let queue = DispatchQueue(
            label: "pini.scheduler.dispatch-only", qos: .default, attributes: .concurrent)

        var spawnCount: Int {
            lock.lock(); defer { lock.unlock() }; return spawnedCount
        }

        /// 体**真的让出**的次数。在兑现不了让出的后端上它**必须恒为 0** ——
        /// 这是驳回性证据：降级路径不是「让出之后又补救」，而是**从不让出**。
        var suspensionCount: Int {
            lock.lock(); defer { lock.unlock() }; return suspensionTotal
        }

        var activeTaskCount: Int { 0 }

        var capabilities: ConcurrencyCapabilities {
            ConcurrencyCapabilities.resolve(threadsAvailable: false)
        }

        func yieldTask() -> Int32 { 0 }

        func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome) {
            lock.lock()
            spawnedCount += 1
            lock.unlock()
            queue.async { [weak self] in
                do {
                    switch try work() {
                    case .finished(let value):
                        future.resolve(value)
                    case .suspended:
                        // 不该发生：本后端宣称不能让出，引擎就不会让出。
                        // 真发生了就是引擎没读能力 —— 响亮记下，交给判据抓。
                        self?.lock.lock()
                        self?.suspensionTotal += 1
                        self?.lock.unlock()
                        future.resolve(.null)
                    }
                } catch {
                    future.reject(GCDScheduler.coerce(error))
                }
            }
        }
    }

    // MARK: - 私有 helper

    private func lowered(_ source: String) throws -> HIRModule {
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
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String, scheduler: Scheduler) throws -> [String] {
        var lines: [String] = []
        let executor = HIRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: scheduler)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    /// 一份**两后端共用**的语料 —— `DE-4` 的契约参照就长这样：
    /// 各后端 vs **同一份**期望输出，而不是两腿互相对拍。
    ///
    /// 子任务先睡一会儿，是为了让 `await` 到达时它**确实未决**；
    /// 否则走的是「已决直接取值」那条路，两个后端都会给出正确结果，
    /// 但那条路测不到让出判定本身。
    private static let 共用语料 = """
    慢|func(n: I32,) => (I32,):
        sleep(40)
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

    // MARK: - 判据 1：能力自述与分层一致

    @Test("主后端自述 L0 与 L1，且不宣称 L2 —— 位图与分层读法一致")
    func theStandardBackEndDescribesItself() throws {
        /// 意图：位图与分层查询必须互相印证（`supports` 是位运算，`bitmap` 是读数，
        /// 两者若不一致，任何按位图做的跨后端比较都会静默失准）。
        /// L2 缺席是**裁定 29** 的直接后果（登记不实现）—— 任何后端都不许宣称它。
        let caps = GCDScheduler.capabilities
        #expect(caps.supports(.dispatch), "L0 missing: nothing can be scheduled")
        #expect(caps.supports(.yield), "L1 missing on a threaded back end")
        #expect(!caps.supports(.preemption), "L2 must never be claimed (ruling 29)")
        #expect(caps.bitmap == 1 | 2, "bitmap \(caps.bitmap) disagrees with the tier readings")
    }

    @Test("有让出 ⇒ 必有调度；反过来不成立 —— 分层不是矩阵")
    func tiersAreNestedNotAMatrix() throws {
        /// 意图：`DE-1` §6.1 说「一层套一层」。这是**不变式**，所以对两种解析结果
        /// 都要成立，而不是只对当前后端成立的巧合。
        /// 「反过来不成立」那一半同样要钉：无线程**不是**「什么都没有」——
        /// 调度仍在，只是让出没了。若哪天有人把无线程后端解析成「空位图」，
        /// 这一条会红，而那种实现会让 `await` 连**降级**的路都没有。
        let threaded = ConcurrencyCapabilities.resolve(threadsAvailable: true)
        let threadless = ConcurrencyCapabilities.resolve(threadsAvailable: false)
        #expect(threaded.supports(.yield) && threaded.supports(.dispatch))
        #expect(!threadless.supports(.yield))
        #expect(threadless.supports(.dispatch), "dispatch must survive without threads")
        for caps in [threaded, threadless] {
            if caps.supports(.yield) {
                #expect(caps.supports(.dispatch), "yield without dispatch is not a tier set")
            }
        }
    }

    // MARK: - 判据 2：让出原语的返回码

    @Test("让出原语在主后端回 1、在兑现不了的后端回 0 —— 两个后端各答各的")
    func yieldTaskReportsPerBackEnd() throws {
        /// 意图：`1` / `0` 是 `DE-1` §3.2 定下的**同一位**。两腿若在这一位上不一致，
        /// 「`await` 让出 / `wait` 占用」这条可观测差异跨后端就没有共同基准。
        /// ⛔ 注意断言的是 `0` **不是错误** —— 它是纪律 3 的合规答案。
        #expect(GCDScheduler.shared.yieldTask() == 1)
        #expect(DispatchOnlyScheduler().yieldTask() == 0)
    }

    // MARK: - 判据 3：降级不失败（纪律 3 的落点）

    @Test("兑现不了让出的后端：程序仍跑完、结果正确，且体从未让出")
    func backEndWithoutYieldDegradesInsteadOfFailing() throws {
        /// 意图：这是本件**最重要**的一条 —— `DE-1` §6.2 纪律 3 说
        /// 「**无合格版本则降级，不失败**」，本判据把它钉在可执行的证据上。
        ///
        /// 两条断言分工：**推进性**（输出正确 ⇒ 降级真的走通了，而不是把程序搞死）；
        /// **驳回性**（体让出次数为 0 ⇒ 降级路径是「从不让出」，而不是「让出了再补救」）。
        /// 后者才是这条纪律的**内容**：若某实现改成「照样挂起、指望别人来续跑」，
        /// 输出那一半可能仍然通过（子任务夺在别处），但这一半会红 ——
        /// 而在真无线程宿主上，那种实现是**死锁**，不是一个跑得通的分支。
        let scheduler = DispatchOnlyScheduler()
        let lines = try runOutput(Self.共用语料, scheduler: scheduler)
        #expect(lines == ["7"], "degraded back end produced \(lines)")
        #expect(scheduler.spawnCount > 0, "the child was never dispatched: L0 was not really present")
        #expect(scheduler.suspensionCount == 0, "a back end that cannot yield must never suspend")
    }

    // MARK: - 判据 4：同一份语料、两个后端、同一份期望输出

    @Test("同一份语料在两个后端上给出同一份输出 —— 契约参照的雏形")
    func theSameCorpusAgreesAcrossBackEnds() throws {
        /// 意图：`DE-1` §7 要求 `DE-4` 的判据取**契约参照**（各后端 vs **同一份**期望输出），
        /// 而**不是两腿互相对拍**（那种写法在两腿同错时会绿）。本判据是那个形态的最小实例：
        /// 同一个语料在「能让出」与「不能让它出」两个后端上都必须得到 `7`。
        ///
        /// ⭐ 它顺手证明了一件对 `DE-3` 有用的事：**让出是执行策略，不是语义**。
        /// 后端换掉让出能力，程序的**值**不受影响 —— 这正是「语义保持、只降执行策略」。
        let yielding = try runOutput(Self.共用语料, scheduler: GCDScheduler.shared)
        let degrading = try runOutput(Self.共用语料, scheduler: DispatchOnlyScheduler())
        #expect(yielding == ["7"], "yielding back end produced \(yielding)")
        #expect(degrading == ["7"], "degrading back end produced \(degrading)")
        #expect(yielding == degrading, "the two back ends disagree on the oracle")
    }
}
