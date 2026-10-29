import Foundation

/// 一次派发的结果：`.finished(v)` 由调度器把值送进 future，`.suspended` 表示体已让出、future 仍待决。
/// 后者是 `await` 的唯一载体：只返回 `Value` 的签名表达不出「这次没跑完」，引擎就只能靠阻塞假装让出。
/// 移交责任随结果分岔——`.suspended` 的送值归续跑方（决出 Future 的线程），工作线程即刻归还池子。
enum TaskRunOutcome {
    case finished(Value)
    case suspended
}

/// 派发任务的唯一契约边界：调用方只依赖 `spawn`，不感知底层是 GCD、pthread 还是别的执行器。
/// 不含 GCD 专有类型，便于跨平台后端接入；让出与否由 `TaskRunOutcome` 加能力位表达。
/// 各后端须在「能不能让出」这一位上一致，否则 `await`/`wait` 的可观测差异跨后端就没有共同基准。
protocol Scheduler {
    /// 派发 `work` 执行。`work` 返回 `.finished` 时由**调度器**把它送到 `future`；
    /// 返回 `.suspended` 时 `future` 仍待决、由续跑方送值。
    /// 具体实现决定「工作跑在哪、如何背压、如何观测」，调用方不感知。
    func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome)

    /// 当前并发活跃任务数（可观测、可诊断）。供饥饿/背压诊断使用。
    var activeTaskCount: Int { get }

    /// 本后端的能力自述。**启动解析一次、此后固化**。
    var capabilities: ConcurrencyCapabilities { get }

    /// 让出当前任务：后端能释放当前 OS 线程就让出，否则立即返回 `0`——合规降级，不是错误。
    /// 调它不等于已经让出，只是问「这次让出能不能真的发生」：无副作用，可反复问。
    /// 谁执行让出随后端而异：解释器后端交出挂起帧，LLVM 后端是这一句调用本身切走。
    func yieldTask() -> Int32

    /// 登记一次让出。与 `yieldTask()` 成对而性质相反：那个问「能不能」，本方法有副作用、每调一次记一次。
    /// 两个来源：首跑由派发口自己记，续跑不经派发口、由引擎在让出被消费时补记；漏一处计数就只数得到一半。
    /// 默认空实现给不持有计数的后端；包装型后端必须转发，否则计数停在外层且没有任何症状。
    func noteYield()
}

/// `noteYield()` 的默认实现：空。让出计数的持有人是生产后端，让出这个动作发生在它手上；
/// 测试替身与不读这个数的后端继承本默认即可，包装型后端不适用——它必须转发给内层。
extension Scheduler {
    func noteYield() {}
}

/// GCD 后端：异步体派发到有界并发池，防线程爆炸与池饥饿；池满时派发方阻塞形成背压。
/// `wait` 占用当前线程直至决，`await` 让出并即刻归还池子——池子有界，让出才有意义。
/// 池大小 = max(4, 核数×2)，并发上限 = 池大小×4；GCD 按需额外建线程，信号量给出可观测上界。
final class GCDScheduler: Scheduler {
    static let shared = GCDScheduler()

    /// 基线池大小（常规并发度）。
    let basePoolSize: Int
    /// 最大并发任务数（溢出容限）。
    let maxPoolSize: Int

    private let semaphore: DispatchSemaphore
    private let queue = DispatchQueue(
        label: "pini.scheduler", qos: .default,
        attributes: .concurrent
    )

    // MARK: - 并发度观测（调试/饥饿诊断）

    private var activeCount: Int = 0
    private var yieldedCount: Int = 0
    private let countLock = NSLock()

    /// 高水位警告阈值：activeCount / maxPoolSize 超过此比例时打印日志。
    private static let watermarkWarning: Double = 0.9

    private init() {
        let procCount = ProcessInfo.processInfo.activeProcessorCount
        self.basePoolSize = max(4, procCount * 2)
        self.maxPoolSize = basePoolSize * 4
        self.semaphore = DispatchSemaphore(value: maxPoolSize)
    }

    /// 派发 `work` 到有界池；池满则阻塞调用线程直至有空槽——这就是背压，等价于生产者暂停。
    /// 返回 `.suspended` 时此处不做任何事：送值责任已随让出移交续跑方，不送值也不报错。
    /// 这一趟只跑一半就归还槽位，正是让出要的效果；`defer` 里的信号量归还照常执行。
    func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome) {
        semaphore.wait()
        countLock.lock()
        let current = activeCount + 1
        activeCount = current
        countLock.unlock()
        if let em = Self.emergencyMsg(current) { print(em) }
        queue.async { [weak self] in
            defer {
                if let self = self {
                    self.countLock.lock()
                    self.activeCount -= 1
                    self.countLock.unlock()
                    self.semaphore.signal()
                }
            }
            do {
                let outcome = try work()
                switch outcome {
                case .finished(let value):
                    future.resolve(value)
                case .suspended:
                    // 计在 `noteYield()` 上，不从池水位推断：水位是整台机器的读数，并行跑第二个程序就会挪动它；
                    // 本数只由让出这一个动作驱动，故判据取增量即可，无须独占机器。
                    // 这一趟只是两个来源之一（另一处是续跑，不走这里），两处必须落到同一个数上。
                    if let self = self { self.noteYield() }
                }
            } catch {
                future.reject(GCDScheduler.coerce(error))
            }
        }
    }

    /// 登记一次让出：本后端的两个来源都落在这里。派发那一趟由本类型在派发口内自己调；
    /// 续跑不经派发口、由引擎在让出被消费时调。漏掉后者则计数只数得到首跑那一趟。
    func noteYield() {
        countLock.lock()
        yieldedCount += 1
        countLock.unlock()
    }

    /// 让出发生的累计次数：「`await` 让出 / `wait` 占用」这条差异的可观测面，只由让出动作驱动。
    /// 与 `activeTaskCount` 不同性质——那个读整台机器现在的任务数，任何并行程序都会挪动它，故判定要看本计数的增量。
    /// 契约侧对应 `bk_task_yield` 的 `1`/`0`：同一个位，一个在 C ABI 上，一个在调度器上。
    var yieldedTaskCount: Int {
        countLock.lock()
        let c = yieldedCount
        countLock.unlock()
        return c
    }

    /// 当前并发的活跃任务数（可观测、可诊断）。
    var activeTaskCount: Int {
        countLock.lock()
        let c = activeCount
        countLock.unlock()
        return c
    }

    /// 本后端的进程级能力：启动解析一次、此后固化，`static let` 的惰性与一次性让「不逐调用点判」自动成立。
    /// `threadsAvailable: true` 是本后端的实情自述——并发执行依赖宿主线程。
    /// 单线程后端自述 `false` 则该后端的 L1 自动不可用、`await` 降级为占用，而不会有任何东西报错。
    static let capabilities = ConcurrencyCapabilities.resolve(threadsAvailable: true)

    var capabilities: ConcurrencyCapabilities { GCDScheduler.capabilities }

    /// 见协议声明。本后端有线程 ⇒ L1 在场 ⇒ 恒返 `1`（真让出）。
    func yieldTask() -> Int32 {
        GCDScheduler.capabilities.supports(.yield) ? 1 : 0
    }

    private static func emergencyMsg(_ active: Int) -> String? {
        let chans = shared.maxPoolSize
        let ratio = Double(active) / Double(chans)
        guard ratio >= watermarkWarning else { return nil }
        return "[scheduler] ⚠️ 高并发水位：\(active)/\(chans) 活跃任务 (\(Int(ratio * 100))% 池容)"
    }

    /// Coerce anything thrown out of a dispatched body into a `RuntimeError`, so a rejected
    /// task's failure has a description the CLI can print. Not private because the resume path
    /// also runs bodies outside this class and needs failures to reach the future in the same shape.
    static func coerce(_ error: Error) -> RuntimeError {
        if let re = error as? RuntimeError { return re }
        return RuntimeError.invalidOperation(
            reason: "异步任务执行失败: \(error.localizedDescription)",
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }
}

/// 能力由语言侧声明决定的后端：派发照旧走 `inner`，能不能让出按语言的声明答。
/// 包一层而非换掉后端本体：池容、背压、放线程属原语层由宿主提供，语言今天能说的只有能力那一格。
/// `yieldTask()` 刻意不委派——委派会让宿主自述覆盖语言声明；两者不一致时以声明为准，引擎随之走占用那条路。
final class SchedulerWithDeclaredCapability: Scheduler {
    private let inner: Scheduler

    /// 语言侧声明的能力。**固化一次**：声明在读它的那一刻定下，
    /// 逐调用点重读等于让同一个程序在不同时刻自述不同能力。
    let capabilities: ConcurrencyCapabilities

    init(inner: Scheduler, canYield: Bool) {
        self.inner = inner
        self.capabilities = ConcurrencyCapabilities.resolve(threadsAvailable: canYield)
    }

    func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome) {
        inner.spawn(future, work: work)
    }

    var activeTaskCount: Int { inner.activeTaskCount }

    /// 见类型说明：答的是**语言的声明**，不是 `inner` 的自述。
    func yieldTask() -> Int32 { capabilities.supports(.yield) ? 1 : 0 }

    /// 记账转发给 `inner`，与上面刻意不委派的方法形成对照：那个答「语言声明能做什么」，声明即答案。
    /// 本方法记「宿主后端实际让出了几次」，事实发生在 `inner` 手上，计数也该住在那里。
    /// 不转发则续跑登记停在包装层、计数漏在更内层，且这类漏计没有任何症状。
    func noteYield() { inner.noteYield() }
}
