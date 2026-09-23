import Foundation

/// 一次派发的结果：跑完了，还是把任务让出去了。
///
/// **为什么 `work` 不能只返回 `Value`**：`await` 的语义是「让出当前任务」——
/// 体在 join 处停下、**释放这个工作线程**，等 Future 决了再续跑。而「只返回 `Value`」
/// 的签名里没有「这次没跑完」这一格 ⇒ 引擎只能靠**阻塞**假装完成了让出，
/// 那正是让出缺位时 `await` 退化成的样子。本类型补的就是这一格。
///
/// ⚠️ 两种结果**移交责任不同**，这是它唯一的复杂度：
/// - `.finished(v)` —— 工作线程跑到底，由调度器把 `v` 送到 `future`（与旧行为一致）；
/// - `.suspended` —— 体已经把任务让出去了，`future` **仍未决**，
///   由**续跑方**（在决出那个 Future 的线程上）负责送值 ⇒ 工作线程在此即刻归还池子。
enum TaskRunOutcome {
    case finished(Value)
    case suspended
}

/// 并发调度脊柱的抽象边界（阶段 A）。
///
/// `Scheduler` 协议是「派发任务」这一动作的唯一契约边界：调用方（解释器）
/// 只依赖 `spawn`，不感知底层是 GCD、pthread 还是未来的 work-stealing executor。
///
/// ⚠️ **本协议名下曾有一条已失效的承诺**（2026-09-20 订正）：原注释称「可挂起 await」
/// 由 `SuspendScheduler` 后端实现、且「已落地，见 `SuspendScheduler.swift`」——
/// **该文件与它整篇所在的旧走查一并退役**（挂起模式退役）。指针指向一个不存在的载体，
/// 而接线口（`spawn` 的 `Value` 返回值）**从来就表达不出**挂起 ⇒ 另一份后端即使在场也无处落脚。
/// 现行形态是本协议之上加一格 `TaskRunOutcome`（`D`+`E` 批 `DE-2b`）。
///
/// - 本协议不含任何 GCD 专有类型，便于将来跨平台后端接入（见 并发后端抽象）。
protocol Scheduler {
    /// 派发 `work` 执行。`work` 返回 `.finished` 时由**调度器**把它送到 `future`；
    /// 返回 `.suspended` 时 `future` 仍待决、由续跑方送值。
    /// 具体实现决定「工作跑在哪、如何背压、如何观测」，调用方不感知。
    func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome)

    /// 当前并发活跃任务数（可观测、可诊断）。供饥饿/背压诊断使用。
    var activeTaskCount: Int { get }

    /// 本后端的能力自述（`DE-1` §6 分层）。**启动解析一次、此后固化**。
    var capabilities: ConcurrencyCapabilities { get }

    /// `bk_task_yield() -> i32` 在解释器后端的对应物（`DE-1` §3.2）。
    ///
    /// **让出当前任务**：后端能释放当前 OS 线程就让出，**否则立即返回**。
    ///
    /// - Returns: `1` = 真让出 · `0` = **合规降级**（后端兑现不了让出）。
    ///   ⛔ `0` **不是错误** —— 它是 `DE-1` §6.2 纪律 3 的落点（无合格版本则降级，不失败），
    ///   与 Go 的 WASM 目标等价 `GOMAXPROCS=1` 同性质（**语义保持、只降执行策略**）。
    ///   ⛔ 也**不得**读成「让出语义为空」—— 该读法已被否证。
    ///
    /// ⚠️ 调用它**不等于**已经让出：它回答的是「这次让出能不能真的发生」。
    /// 谁执行让出，随后端而异 —— 解释器后端是驱动器交出挂起帧（控制流返回），
    /// LLVM 后端是这一句调用本身切走（`DE-3`）。各后端必须在这一位上一致，否则
    /// 「`await` 让出 / `wait` 占用」这条可观测差异在跨后端时就没有共同基准。
    func yieldTask() -> Int32

    /// 登记**一次让出**。
    ///
    /// 与 `yieldTask()` 成对但性质相反：那个回答「这次让出**能不能**真的发生」——
    /// **无副作用**、可反复问；本方法**有副作用**，每调一次记一次。
    ///
    /// ⚠️ **谁调它**：让出被**消费**的每一处。首跑那一趟由派发口自己记；
    /// **续跑那几趟不经派发口**（由决出方直接驱动、不再走 `spawn`），
    /// 故由引擎在让出被消费时调本方法补记。两侧合起来，本计数才是「**每一次让出**」，
    /// 也才是与 LLVM 后端同一个量。
    ///
    /// ⚠️ 协议扩展给了**默认空实现**（见下）：只关心派发与能力、不持有让出计数的实现
    /// 无须写它。⛔ 但**包装型后端必须转发** —— 否则引擎的续跑登记停在包装层、
    /// 而计数在更内层，且这类漏计**没有任何症状**。
    func noteYield()
}

/// `noteYield()` 的默认实现：**空**。
///
/// 让出计数的持有人是**生产后端**（让出这个动作发生在它手上）。测试替身与将来其他后端
/// 若不需要这个读数，继承本默认即可。
///
/// ⚠️ **包装型后端不适用本默认** —— 它必须把记账转发给内层；理由见各包装类型自己的说明。
extension Scheduler {
    func noteYield() {}
}

/// P5 B3-2 更新：有界并发池 + 信号量背压（GCD 后端）。
///
/// 将异步函数体派发到 GCD 有界并发池，防止线程爆炸与线程池饥饿（R5）。
/// `wait` **占用**当前任务线程直至决（见 `FutureValue.wait`）；`await` 在可让出位置
/// **让出**任务（见 `TaskRunOutcome`）⇒ 让出时本线程**即刻归还池子**，
/// 这正是「有界池」与「让出」两件事互相成全的地方：池子有界，让出才有意义。
///
/// ⚠️ **一处已退役的并列后端**（2026-09-20 订正）：原注释称挂起路径「由 `SuspendScheduler`
/// 实现、两后端并存」—— 该后端与其所在走查已退役、载体不存在。本类是**唯一**后端。
///
/// 基线池大小 = max(4, 处理器数 × 2)；最大并发任务数 = 基线 × 4。
/// GCD concurrent queue 在需要时仍能创建额外线程，信号量提供「可观测的上界」。
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

    /// 派发 `work` 到有界并发池；若池满则**阻塞调用线程**直至有空槽（背压）。
    ///
    /// B3-2 防护：若并发任务已满（信号量归零），`spawn` 调用方（通常是解释器主线程）
    /// 会被挂起，从而阻止继续生成新任务——这是「有限背压」，等价于生产者暂停。
    /// GCD 在需要时仍可创建额外线程推进阻塞中的任务，避免经典信号量死锁。
    ///
    /// ⚠️ **让出时本线程立刻归还**（`DE-2b`）：`work` 返回 `.suspended` 表示体已经把任务
    /// 让出去了、`future` 仍待决。此处**不做任何事**——不送值、不报错，
    /// 因为送值的责任已随让出移交给续跑方。代价是这一趟只跑了一半就归还了槽位，
    /// 而那正是让出要的效果；`defer` 里的信号量归还照常执行。
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
                    // Counted here rather than inferred from the pool level: a
                    // level is a reading of the whole machine, so a second
                    // program running alongside would move it. This number is
                    // driven by giving up alone, which is what makes it the
                    // signal a criterion can read without owning the machine.
                    //
                    // 计数本身挪进了 `noteYield()`：这一趟只是**两个来源之一**
                    // （另一处是续跑，它不走这里）⇒ 两处必须落到同一个数上。
                    if let self = self { self.noteYield() }
                }
            } catch {
                future.reject(GCDScheduler.coerce(error))
            }
        }
    }

    /// 登记一次让出 —— 本后端的**两个来源**都落在这里（协议侧的说明见同名方法）。
    ///
    /// ① **派发那一趟**：体返回 `.suspended`，本类型在派发口内自己调。
    /// ② **续跑那几趟**：续跑不经派发口（由决出方直接驱动），由引擎在让出被消费时调。
    /// ⚠️ 漏掉 ② 的后果是「计数只数得到首跑那一趟」—— 而这正是归并前后端之间分岔的形态。
    func noteYield() {
        countLock.lock()
        yieldedCount += 1
        countLock.unlock()
    }

    /// 让出发生的累计次数（可观测、可诊断）。
    ///
    /// 「`await` 让出 / `wait` 占用」这条差异的可观测面。它记的是**每一次让出**
    /// （两个来源都落在 `noteYield()` 上），即体真的把任务让出去了。与 `activeTaskCount`
    /// 并列但不同性质：那个读的是
    /// **整台机器现在有几个任务**，任何并行的程序都会挪动它；本计数只由「让出」这一个动作驱动
    /// ⇒ 取**增量**即可判定，不需要独占整台机器。
    ///
    /// 契约侧的对应物是 `bk_task_yield` 的返回码 `1`（真让出）/ `0`（降级为立即返回）——
    /// 同一个位，一个在 C ABI 上，一个在解释器后端的调度器上。
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

    /// 本后端的进程级能力读数（`DE-1` §3.4 / §6）。
    ///
    /// **启动解析一次、此后固化** —— Swift 的 `static let` 天然满足这两条
    /// （惰性、一次性、线程安全，此后不再重算），于是纪律 1「不逐调用点判」自动成立：
    /// 调用点读的是这个已经算好的位图，而不是每次去问一遍宿主。
    ///
    /// ⚠️ 这里的 `threadsAvailable: true` 是**本后端的实情自述**，不是常量装饰：
    /// 本类建在 `DispatchQueue` 上，它的并发执行**依赖宿主线程**。将来若接一个
    /// 单线程后端（无线程宿主），那个后端自述 `false` ⇒ 它的 L1 自动不可用、
    /// `await` 降级为占用，**而没有任何东西报错**。
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

    /// Coerce anything thrown out of a dispatched body into a `RuntimeError`, so
    /// a rejected task's failure has a description the CLI can print.
    ///
    /// Not private because the resume path needs it too: a body that is picked
    /// back up on a continuation runs outside this class, and its failures have to
    /// arrive at the task's future in the same shape as a first run's.
    static func coerce(_ error: Error) -> RuntimeError {
        if let re = error as? RuntimeError { return re }
        return RuntimeError.invalidOperation(
            reason: "异步任务执行失败: \(error.localizedDescription)",
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }
}

/// 能力由**语言侧声明**决定的后端：派发照旧走 `inner`，而「能不能让出」按语言的声明答。
///
/// 它是「派发点用语言侧那个调度器」这条接线的落点。为什么要包一层、而不是换掉后端本体：
/// 后端本体做的事（池容、背压、把工作放到线程上）属**原语层**、由宿主提供，
/// 而语言今天能说的只有**能力那一格**。包一层把「宿主怎么做」与「语言说它能做什么」分开 ——
/// 将来语言侧能说的东西变多时，本类型只多读几个字段，接缝不动。
///
/// ⚠️ `yieldTask()` **不委派给 `inner`**，这是本类型存在的全部理由：
/// `inner` 的自述是它自己的实情，而语言侧的声明若被那一层委派覆盖掉，这条接线就等于没接。
/// 两者不一致时以**语言的声明**为准 —— 声明不能让出就照不能办，
/// 引擎随之走「占用线程等它决」那条路（降级而不失败，既有规范纪律）。
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

    /// 记账**转发给 `inner`** —— 与上面那个刻意不委派的方法形成对照：
    /// 那一个答的是「**语言声明**它能做什么」，声明即答案，⛔ 不许被宿主的自述覆盖；
    /// 本方法记的是「**宿主后端实际让出了几次**」，而那个事实发生在 `inner` 手上，
    /// 计数也该住在那里。
    /// ⚠️ 不转发则引擎的续跑登记停在包装层 ⇒ 计数漏，而这类漏计**没有症状**。
    func noteYield() { inner.noteYield() }
}
