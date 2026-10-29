import Foundation
@testable import PiniCore
import Testing

/// 并发能力的分层自述与让出原语：`bk_task_yield() -> i32`（`1` = 真让出 / `0` = 合规降级）与
/// `bk_capabilities() -> u32`（位图，启动解析一次、固化），外加一条纪律：后端兑现不了让出时降级，不失败。
/// 本件只管能力说自己有什么、让出原语回了什么、以及回 `0` 时程序还跑不跑得完。
struct ConcurrencyCapabilitiesTests {

    // MARK: - 替身后端：有调度、无让出

    /// 一个兑现不了让出的后端（`yieldTask()` 恒返 `0`）：模拟「L0 在场、L1 缺席」这类合规后端，
    /// 等于提前跑一遍「新后端还没实现让出时，语言是什么行为」。它照常用 `DispatchQueue` 异步派发
    /// （L0 要真的在场，否则测的就不是降级而是单线程），只是不让出 ⇒ 引擎走「占用线程等它决」那条路。
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

    private func lowered(_ source: String) throws -> IRModule {
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
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String, scheduler: Scheduler) throws -> [String] {
        var lines: [String] = []
        let executor = IRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: scheduler)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
        return lines
    }

    /// 一份两后端共用的语料 —— 契约参照就长这样：各后端 vs 同一份期望输出，而不是各后端互相对拍。
    /// 子任务先睡一会儿，是为了让 `await` 到达时它确实未决；否则走「已决直接取值」那条路，
    /// 两后端都会给出正确结果，但那条路测不到让出判定本身。
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
        /// 意图：「一层套一层」是不变式，故对两种解析结果都要成立，而不是只对当前后端成立的巧合。
        /// 「反过来不成立」那一半同样要钉：无线程不是「什么都没有」—— 调度仍在，只是让出没了；
        /// 若把无线程后端解析成空位图，`await` 连降级的路都没有，本条会红。
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
        // 意图：`1` / `0` 是契约 §3.2 定下的同一位。各后端若在这一位上不一致，
        // 「`await` 让出 / `wait` 占用」这条可观测差异跨后端就没有共同基准。
        // ⛔ 断言的是 `0` 不是错误 —— 它是纪律 3 的合规答案。
        #expect(GCDScheduler.shared.yieldTask() == 1)
        #expect(DispatchOnlyScheduler().yieldTask() == 0)
    }

    // MARK: - 判据 3：降级不失败（纪律 3 的落点）

    @Test("兑现不了让出的后端：程序仍跑完、结果正确，且体从未让出")
    func backEndWithoutYieldDegradesInsteadOfFailing() throws {
        // 意图：本件最重要的一条 —— 「无合格版本则降级，不失败」钉在可执行的证据上。两条断言分工：
        // 推进性（输出正确 ⇒ 降级真的走通了）；驳回性（体让出次数为 0 ⇒ 降级是从不让出，
        // 而不是让出了再补救）。后者才是纪律的内容：照样挂起、指望别人续跑在真无线程宿主上是死锁。
        let scheduler = DispatchOnlyScheduler()
        let lines = try runOutput(Self.共用语料, scheduler: scheduler)
        #expect(lines == ["7"], "degraded back end produced \(lines)")
        #expect(scheduler.spawnCount > 0, "the child was never dispatched: L0 was not really present")
        #expect(scheduler.suspensionCount == 0, "a back end that cannot yield must never suspend")
    }

    // MARK: - 判据 4：同一份语料、两个后端、同一份期望输出

    @Test("同一份语料在两个后端上给出同一份输出 —— 契约参照的雏形")
    func theSameCorpusAgreesAcrossBackEnds() throws {
        /// 意图：契约参照的形态 —— 各后端 vs 同一份期望输出，而不是各后端互相对拍（同错时会绿）。
        /// 本判据是它的最小实例：同一语料在「能让出」与「不能让它出」两个后端上都必须得到 `7`。
        /// 它顺手证明让出是执行策略、不是语义：后端换掉让出能力，程序的值不受影响。
        let yielding = try runOutput(Self.共用语料, scheduler: GCDScheduler.shared)
        let degrading = try runOutput(Self.共用语料, scheduler: DispatchOnlyScheduler())
        #expect(yielding == ["7"], "yielding back end produced \(yielding)")
        #expect(degrading == ["7"], "degrading back end produced \(degrading)")
        #expect(yielding == degrading, "the two back ends disagree on the oracle")
    }
}
