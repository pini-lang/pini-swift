import Foundation
@testable import PiniCore
@testable import PiniRuntime
import Testing

/// 并发原语的 **C ABI 面**判据（`DE-1` §3 的函数表 · `DE-3b` 的 `B-2` 段）。
///
/// **这一件测什么**：`DE-1` 定了 10 个符号的**形状**，本段落地了其中**与让出机制无关的 8 个**
/// （`bk_task_spawn` / `bk_task_yield` 受「走乙」影响、形状待重议，不在本段）。
/// 形状若只写在契约文件里、执行路径读不到，那它就只是一句声明 —— 本件钉的是**读得到**。
///
/// ⛔ **本件不是 `DE-3b` 的验收**：`DE-3b` 的判据是「符号存在性 + 形状与 `DE-1` 一致」，
/// 而**符号存在性只算辅助证据**（一个 `return 0` 的空壳同样存在）。本件把每个符号**真调一遍**
/// 并断言其效果 ⇒ 「存在」这一半被「可用」这一半盖住。
/// ⛔ **也不含**「LLVM 腿跑通并发程序」—— 那属 `DE-3c`（发射层接线，今天两处 `fatalError`、
/// `rc=133`）。**不得把本件全绿读成 LLVM 腿能跑并发。**
///
/// ⚠️ **`.serialized` 不是风格选择**：`bk_task_is_cancelled()` 读的是**线程本地**的「当前任务」，
/// 而 Swift Testing 默认并行、多个用例可能落在同一线程 ⇒ 并行会让当前任务互相污染，
/// 判据变成随机通过。串行是这个设计成立的前提。
///
/// **符号 → 判据对照**（8/8 全覆盖；`DE-6b` 补入让出族 3 个）：
///
/// | 符号 | 判据 |
/// |---|---|
/// | `bk_capabilities` | 能力位与位定义 |
/// | `bk_task_join` | join 三态 · join 真的阻塞 |
/// | `bk_task_join_within` | 超时归约 |
/// | `bk_task_join_all` | fail-fast · 全 ok 聚合 |
/// | `bk_task_cancel` | 检查点 · 沿树传播 · 认父时刻 · **让出态被取消 ⇒ 帧交还** |
/// | `bk_task_is_cancelled` | 检查点 |
/// | `bk_task_detach` | 剪枝阴性对照 |
/// | `bk_scope_close` | 有界 override（翻 / 不覆盖 / 不计未完成） |
/// | `bk_task_frame` | 派发点建帧（已清零）· 体内取回**同一块** |
/// | `bk_task_slot` | ⭐ **可重放**：同一体第 n 次进入的第 k 次取槽必得同一地址 |
/// | `bk_task_await` | ⭐ **续跑协议**：`2` 会让出且不写 `out` · 决出方续跑 · 已决则直线取值 |
@Suite(.serialized)
struct ConcurrencyRuntimeABITests {

    // MARK: - 跨线程传参包
    //
    // ⚠️ 这几个类型**不是**为了绕过检查而存在的，它们是**如实声明**：测试要把 C 句柄交给
    // 另一线程去阻塞 / 决出，而 `UnsafeMutableRawPointer` 不是 `Sendable`。裸捕获会给构建
    // 添 4 条告警，而本仓把**告警数**当判据 ⇒ 多出来的告警会把「本批有没有引入新问题」
    // 这条信号冲淡。故此处把参数**显式装包**、闭包只捕获包本身。
    //
    // 安全性依据（`@unchecked` 的代价，写出来才算数）：这些指针的跨线程使用全部由
    // `DispatchSemaphore` **排序** —— 要么写者 signal 之后测试线程才读，要么测试线程在读前
    // 已 wait 到「另一线程不再触碰」。不存在两个线程同时读写同一位置。

    /// 交给另一线程去**决出**的任务句柄与载荷。
    private struct ResolveArgs: @unchecked Sendable {
        let task: UnsafeMutableRawPointer
        let payload: Int64
    }

    /// 交给另一线程去**阻塞聚合**的三参数。
    private struct JoinAllArgs: @unchecked Sendable {
        let handles: UnsafeMutableRawPointer
        let count: Int32
        let out: UnsafeMutableRawPointer
    }

    /// 另一线程写回、测试线程读的返回值（由信号量排序）。
    private final class RcBox: @unchecked Sendable {
        var rc: Int32 = -1
    }

    // MARK: - 脚手架

    /// `Result` 三槽的输出缓冲（`DE-1` §3.1）：槽 0 = tag · 槽 1 = ok 载荷 · 槽 2 = err 载荷。
    /// 按 `Int64` 申请三格，既保证 24 字节，也保证对齐（裸 `allocate` 不保证后者）。
    private func makeOut() -> UnsafeMutablePointer<Int64> {
        let p = UnsafeMutablePointer<Int64>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }

    private func raw(_ p: UnsafeMutablePointer<Int64>) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(p)
    }

    /// 句柄数组（`bk_task_join_all` 的 `handles` 参数按 `void*` 数组走）。
    private func makeHandles(
        _ hs: [UnsafeMutableRawPointer]
    ) -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
        let p = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: hs.count)
        p.initialize(repeating: nil, count: hs.count)
        for (i, h) in hs.enumerated() { p[i] = h }
        return p
    }

    /// 由三槽的 ok 位置还原句柄（与 `_bkWord` 互逆）。
    private func handle(fromWord w: Int64) -> UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(w)))
    }

    /// 在另一线程延迟 `afterUs` 后决出任务。
    private func resolveOffThread(_ args: ResolveArgs, afterUs: UInt32) -> DispatchSemaphore {
        let signal = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            usleep(afterUs)
            _bkTaskResolveOk(args.task, args.payload)
            signal.signal()
        }
        return signal
    }

    /// 在另一线程调 `bk_task_join_all`，带超时。
    /// - Returns: `nil` = 超时。**这就是「它没返回」的判据**（而不是把测试挂死）。
    private func joinAllOffThread(_ args: JoinAllArgs) -> Int32? {
        let done = DispatchSemaphore(value: 0)
        let box = RcBox()
        DispatchQueue.global().async {
            box.rc = bk_task_join_all(args.handles, args.count, args.out)
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success else { return nil }
        return box.rc
    }

    // MARK: - 能力位

    @Test("能力位自述：位定义与解释器腿一致，L2 永不宣称，且本腿自 DE-6b 起宣称 L1")
    func capabilitiesAgreeWithTheInterpreterLeg() throws {
        /// 意图：`bk_capabilities()` 的**位定义**必须与解释器腿同源 —— 两腿各定一套的话，
        /// `DE-4` 的契约参照就没有共同基准（`DE-1` §3.4 定案表的原话）。
        /// 断言的是**子集关系**（本腿 ⊂ 解释器腿）：这条**将来仍成立**（相等也是子集），
        /// 所以它不是一次性判据。
        /// ⛔ L2 缺席是**裁定 29** 的直接后果（登记不实现）—— 任何后端都不许宣称它。
        /// ⭐ **L1 自 `DE-6b` 起在场**：此前它「必须缺席」是因为让出的执行路径没接上，
        /// 那时宣称 L1 就是发假绿；`DE-6b` 把路径接通（发射层在异步体语句根 `await` 交出控制流
        /// + 运行时由决出方续跑）⇒ 位与能力**同批**到位。⚠️ 反向同样要紧：若路径被撤而位还在，
        /// 本条与 `yieldAnswersFromTheCapabilityBit` 都会红。
        let actual = bk_capabilities()
        let oracle = ConcurrencyCapabilities.resolve(threadsAvailable: true)
        #expect(actual & 4 == 0, "L2 永不许宣称（裁定 29），实际位图 \(actual)")
        #expect(actual & 1 == 1, "L0 应在场，实际位图 \(actual)")
        #expect(actual & ~oracle.bitmap == 0, "本腿置了位定义之外的位：\(actual) 对 \(oracle.bitmap)")
        #expect(actual & 2 == 2, "L1 自 DE-6b 起在场（让出路径同批接通），实际位图 \(actual)")
    }

    // MARK: - join

    @Test("join 三态：ok 直通 · 任务自己的 err 直通 · 取消归约为 CancelError")
    func joinNormalisesThreeOutcomes() throws {
        /// 意图：`RuntimeOps.joinFuture` 的三条归一化各归一态 —— 它是两腿**唯一**容易分歧的
        /// 地方（一个复制品会在 happy path 上一致、在「哪个 catch 先命中」上分歧），故逐态钉。
        /// ⛔ 第三条断言的 `status == 1` **不是错误**：C ABI 面没有值构造器 ⇒ 取消身份
        /// 由 `status` 承载（本段定案，见源码段首 ②）。它与 `err(CancelError)` 同义。
        let t1 = _bkTaskMake(); defer { bk_handle_release(t1) }
        let o1 = makeOut(); defer { o1.deallocate() }
        _bkTaskResolveOk(t1, 41)
        #expect(bk_task_join(t1, raw(o1)) == 0)
        #expect(o1[0] == 0 && o1[1] == 41 && o1[2] == 0, "ok 三槽：\(o1[0])/\(o1[1])/\(o1[2])")

        let t2 = _bkTaskMake(); defer { bk_handle_release(t2) }
        let o2 = makeOut(); defer { o2.deallocate() }
        _bkTaskResolveErr(t2, 7)
        #expect(bk_task_join(t2, raw(o2)) == 0)
        #expect(o2[0] == 1 && o2[2] == 7, "任务自己的 err 须原样直通：\(o2[0])/\(o2[2])")

        let t3 = _bkTaskMake(); defer { bk_handle_release(t3) }
        let o3 = makeOut(); defer { o3.deallocate() }
        bk_task_cancel(t3)
        #expect(bk_task_join(t3, raw(o3)) == 1, "取消 ⇒ status 1（未取得 Result）")
        #expect(o3[0] == 1, "取消须归约为 err")
    }

    @Test("join 真的阻塞：体决出之前不返回（不是「查到未决就当空值返回」）")
    func joinBlocksUntilTheOutcomeArrives() throws {
        /// 意图：这是本件最容易被空壳实现骗过的一条 —— 一个直接 `return 0` 的 join 会让
        /// 前一条判据（先决出再 join）全绿，只有本条的**时序**能区分。
        /// 判别点 = `o[1] == 5`：它只有在**等到了**另一线程写入的值时才成立。
        /// ⚠️ 若实现压根不阻塞，这里得到的不是「断言失败」而是 `_bkTaskJoinOne` 的
        /// 「既未决又未取消」panic ⇒ 表现为**进程终止**而非一条红。如实登记，不假装它干净。
        let t = _bkTaskMake(); defer { bk_handle_release(t) }
        let o = makeOut(); defer { o.deallocate() }
        let writer = resolveOffThread(ResolveArgs(task: t, payload: 5), afterUs: 30_000)
        #expect(bk_task_join(t, raw(o)) == 0)
        #expect(o[1] == 5, "join 在体决出前就返回了：ok 载荷 = \(o[1])")
        #expect(writer.wait(timeout: .now() + 1) == .success)
    }

    @Test("joinWithin 超时：归约为 CancelError、且该任务被取消（与解释器腿 timeout 分支同构）")
    func joinWithinTimesOutAndCancelsTheTask() throws {
        /// 意图：`DE-1` §3.1 说超时「归约 `err(CancelError)`（与解释器腿 `joinWithin` 同构）」。
        /// 「同构」有两半，缺一不可：**值**（err）与**副作用**（取消那个任务）——
        /// 只回 err 不取消，会让一个没人在等的任务继续占线程，那正是 fail-fast 要避免的事。
        let t = _bkTaskMake(); defer { bk_handle_release(t) }
        let o = makeOut(); defer { o.deallocate() }
        #expect(bk_task_join_within(t, 20, raw(o)) == 1, "超时 ⇒ status 1")
        #expect(o[0] == 1, "超时须归约为 err")
        let restore = _bkTaskEnter(t)
        #expect(bk_task_is_cancelled() == 1, "超时须取消该任务")
        restore()
    }

    @Test("joinAll fail-fast：首个 err 决定聚合，其余成员被取消（没人在等它们）")
    func joinAllFailsFastAndCancelsTheRest() throws {
        /// 意图：第三个成员**永不决出**是本条的判别装置 —— 若 fail-fast 没实现，
        /// `joinAll` 会在它身上**永久阻塞**，于是超时判据先响。
        /// 只断言「聚合 = 第二个成员的 err」是不够的：那在「先等完全部再挑 err」的实现上也成立。
        /// ⚠️ 反向的误导同样要挡：聚合**不得**改写成员的父链（那会让某个调用方的返回取消掉
        /// 它从未拥有过的任务），故此处只用「被取消」这一条可观测后果。
        let a = _bkTaskMake(), b = _bkTaskMake(), c = _bkTaskMake()
        defer { bk_handle_release(a); bk_handle_release(b); bk_handle_release(c) }
        _bkTaskResolveOk(a, 1)
        _bkTaskResolveErr(b, 99)
        let handles = makeHandles([a, b, c]); defer { handles.deallocate() }
        let o = makeOut(); defer { o.deallocate() }

        let rc = joinAllOffThread(
            JoinAllArgs(handles: UnsafeMutableRawPointer(handles), count: 3, out: raw(o)))
        #expect(rc != nil, "joinAll 未在 3 秒内返回 ⇒ 第三个成员没被取消（fail-fast 失效）")
        guard let rc else { return }
        #expect(rc == 0)
        #expect(o[0] == 1 && o[2] == 99, "聚合应是第二个成员的 err：\(o[0])/\(o[2])")
        let restore = _bkTaskEnter(c)
        #expect(bk_task_is_cancelled() == 1, "fail-fast 须取消其余成员")
        restore()
    }

    @Test("joinAll 全 ok：聚合载荷是数组句柄，元素为各成员的 ok 载荷")
    func joinAllAggregatesOkMembers() throws {
        /// 意图：`DE-1` §3.1 说「`out` 写 `Result` 聚合」。载荷宽度是 i64 ⇒ 一个列表只能是
        /// **句柄**（三槽里没有放列表的地方）。本判据用**既有数组 ABI** 读回来，等于同时证明
        /// 「聚合句柄是既有数组句柄、不是新造的一种句柄」—— 那正是 `DE-3c` 能直接复用的前提。
        let a = _bkTaskMake(), b = _bkTaskMake()
        defer { bk_handle_release(a); bk_handle_release(b) }
        _bkTaskResolveOk(a, 11)
        _bkTaskResolveOk(b, 22)
        let handles = makeHandles([a, b]); defer { handles.deallocate() }
        let o = makeOut(); defer { o.deallocate() }
        #expect(bk_task_join_all(UnsafeMutableRawPointer(handles), 2, raw(o)) == 0)
        #expect(o[0] == 0, "全 ok ⇒ 聚合是 ok")
        guard let arr = handle(fromWord: o[1]) else {
            Issue.record("聚合载荷不是句柄：\(o[1])")
            return
        }
        defer { bk_handle_release(arr) }
        #expect(bk_array_len(arr) == 2, "聚合数组长度应为 2，实际 \(bk_array_len(arr))")
        #expect(bk_array_get(arr, 0).load(as: Int64.self) == 11, "第 0 个元素应是 11")
        #expect(bk_array_get(arr, 1).load(as: Int64.self) == 22, "第 1 个元素应是 22")
    }

    // MARK: - 取消与检查点

    @Test("取消检查点：无当前任务回 0 · 有且已取消回 1 · 未取消回 0 · 恢复后回 0")
    func isCancelledReadsTheCurrentTask() throws {
        /// 意图：`bk_task_is_cancelled()` 是**无参**的，故它只能问「**当前**任务」——
        /// 与解释器腿 `RuntimeOps.checkCancellation(owner)` 同职。
        /// ⛔ 第一条断言（主线程无任务 ⇒ 0）与 `checkCancellation(nil)`「不做事」同义：
        /// 「没有任务在跑」**不是**「被取消了」；若实现回 `1`，任何不在任务里的循环都会误退出。
        #expect(bk_task_is_cancelled() == 0, "没有任务在跑 ⇒ 不该报被取消")
        let t = _bkTaskMake(); defer { bk_handle_release(t) }
        let restore = _bkTaskEnter(t)
        #expect(bk_task_is_cancelled() == 0, "未取消")
        bk_task_cancel(t)
        #expect(bk_task_is_cancelled() == 1, "取消后检查点须看到")
        restore()
        #expect(bk_task_is_cancelled() == 0, "恢复后回到「无任务」")
    }

    @Test("取消沿树传播：取消父 ⇒ 子也被取消（句柄被丢弃也不漏网）")
    func cancelPropagatesDownTheTree() throws {
        /// 意图：让 `FutureValue` 的取消树在这儿也成立 —— 「父被取消时子一并停止」与调用方
        /// 是否保留子的句柄**无关**，这是类 Kotlin/Swift `Job`/`Task` 的那条保证。
        let parent = _bkTaskMake(), kid = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(kid) }
        _bkTaskAdopt(parent, kid)
        bk_task_cancel(parent)
        let restore = _bkTaskEnter(kid)
        #expect(bk_task_is_cancelled() == 1, "父被取消 ⇒ 子须一并被取消")
        restore()
    }

    @Test("认父：父已取消 ⇒ 新子立即被取消（不漏网）")
    func adoptingIntoACancelledParentCancelsImmediately() throws {
        /// 意图：`FutureValue.addChild` 里那条 `if cancelled { child.cancel() }` 分支。
        /// 它是「取消是最终一致的」这句话在**认父时刻**的那一半：否则一个在父取消**之后**
        /// 才派生的子任务会逃过整棵树的取消。
        let parent = _bkTaskMake(), kid = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(kid) }
        bk_task_cancel(parent)
        _bkTaskAdopt(parent, kid)
        let restore = _bkTaskEnter(kid)
        #expect(bk_task_is_cancelled() == 1, "认进已取消的父 ⇒ 立即被取消")
        restore()
    }

    // MARK: - detach 与 scope 收口

    @Test("detach：脱离父 ⇒ 父的 scope 收口不计它（同一子任务，detach 与否结论相反）")
    func detachRemovesTheChildFromTheParentsScope() throws {
        /// 意图：**阴性对照**。下一条判据证明「已决且 err 的子算 leaked」，本条用**一模一样**的
        /// 子任务、只多一次 `bk_task_detach`，结论必须相反。
        /// 缺了本条，一个「从不收集 leaked」的实现会让下一条红、但本条也红；
        /// 有了本条，两条一起才把「收集**在册**子任务」这句话夹住。
        let parent = _bkTaskMake(), kid = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(kid) }
        _bkTaskAdopt(parent, kid)
        _bkTaskResolveErr(kid, 3)   // 若不 detach，这就是一个 leaked
        bk_task_detach(kid)
        let o = makeOut(); defer { o.deallocate() }
        o[0] = 0; o[1] = 42         // 调用方自己写进 out 的 ok（out 是 in-out）
        #expect(bk_scope_close(parent, raw(o)) == 0)
        #expect(o[0] == 0 && o[1] == 42, "已 detach 的子不算 leaked ⇒ 不该翻：\(o[0])/\(o[1])")
    }

    @Test("scope 收口：有 leaked 才把调用方写进 out 的 ok 翻成 err（唯一有界 override）")
    func scopeCloseFlipsOkToErrWhenLeaked() throws {
        /// 意图：这是契约里**唯一**允许「改写值」的地方（严格结构化并发的有界 override），
        /// 所以它必须既有正例也有反例。本条的装置：两个子任务，一个 err（leaked）、
        /// 一个 ok（**不是** leaked）⇒ 计数必须是 1 而不是 2。
        let parent = _bkTaskMake(), k1 = _bkTaskMake(), k2 = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(k1); bk_handle_release(k2) }
        _bkTaskAdopt(parent, k1)
        _bkTaskAdopt(parent, k2)
        _bkTaskResolveErr(k1, 1)
        _bkTaskResolveOk(k2, 2)
        let o = makeOut(); defer { o.deallocate() }
        o[0] = 0; o[1] = 77
        #expect(bk_scope_close(parent, raw(o)) == 0)
        #expect(o[0] == 1, "有 leaked ⇒ 须翻成 err")
        #expect(o[2] == 1, "leaked 计数应恰为 1（ok 的子不算）：\(o[2])")
    }

    @Test("scope 收口有界：out 已带 err ⇒ 原样保留，不被聚合覆盖")
    func scopeCloseDoesNotOverwriteAnExistingErr() throws {
        /// 意图：「有界」的另一半 —— errors-as-data 已经载着一次失败时，覆盖它等于丢掉
        /// 「到底哪一次失败了」。装置：**同样**有 leaked，只把 out 的初始值换成 err。
        let parent = _bkTaskMake(), kid = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(kid) }
        _bkTaskAdopt(parent, kid)
        _bkTaskResolveErr(kid, 1)
        let o = makeOut(); defer { o.deallocate() }
        o[0] = 1; o[2] = 5          // 调用方自己的 err
        #expect(bk_scope_close(parent, raw(o)) == 0)
        #expect(o[0] == 1 && o[2] == 5, "已有 err 不得被覆盖：\(o[0])/\(o[2])")
    }

    @Test("scope 收口：未完成的子任务被取消，且不计为 leaked")
    func scopeCloseCancelsUnfinishedChildrenWithoutCountingThem() throws {
        /// 意图：`FutureValue.closeScope` 的分区 —— 未完成 ⇒ 取消（**预期行为**，不计失败）。
        /// 装置：子任务永不决出且**不是** err ⇒ 若实现把它当失败，`o[0]` 会变成 1。
        /// 两条断言分工：**值**（不翻）+ **副作用**（确实被取消）。
        let parent = _bkTaskMake(), kid = _bkTaskMake()
        defer { bk_handle_release(parent); bk_handle_release(kid) }
        _bkTaskAdopt(parent, kid)
        let o = makeOut(); defer { o.deallocate() }
        o[0] = 0; o[1] = 8
        #expect(bk_scope_close(parent, raw(o)) == 0)
        #expect(o[0] == 0, "未完成不是失败 ⇒ 不该翻")
        let restore = _bkTaskEnter(kid)
        #expect(bk_task_is_cancelled() == 1, "未完成的子须被取消")
        restore()
    }

    // MARK: - `B-3`：spawn / yield

    @Test("yield 的答案取自 L1 位 —— 与解释器腿同一条规则，且本腿自 DE-6b 起真的回 1")
    func yieldAnswersFromTheCapabilityBit() throws {
        /// 意图：`DE-1` §3.2 要求**两腿在这一位上一致**，否则「`await` 让出 / `wait` 占用」
        /// 这条可观测差异跨后端就没有共同基准。解释器腿的对应物就是
        /// `capabilities.supports(.yield) ? 1 : 0` ⇒ 本腿照**同一条规则**取答案。
        /// ⭐ 第一条断言写成**关系式**而不是常量：位图变了它仍成立 —— 常量式判据会变成一条
        /// 必须手改的假绿。
        /// ⭐ 第二条则是**关系式之外的一处刻意固化**（`DE-6b`）：本腿的 L1 不再是「将来时」，
        /// 让出的执行路径同批接上了 ⇒ 这里点明它现在必须回 `1`。若哪天有人把 L1 位撤掉而
        /// 忘了撤让出路径，本条会红 —— 那正是它该红的时刻。
        let expected: Int32 = (bk_capabilities() & 2) != 0 ? 1 : 0
        #expect(bk_task_yield() == expected, "yield 的答案必须由 L1 位推出")
        #expect(bk_task_yield() == 1, "`DE-6b` 起本腿宣称 L1 ⇒ 回 1（不再是合规降级）")
    }

    @Test("spawn 立刻返回，且体在**另一条线程**上跑完（急切派发不是「就地跑完」）")
    func spawnDispatchesOffTheCallerThread() throws {
        /// 意图：钉子句 `DE-1` §3.1 的「派发」二字。若 `spawn` 就地跑体，急切派发是假的 ——
        /// 调用方会一直等到体结束，`=>` 的语义也就没了。
        /// **判据的强度来自「体在等测试放行」**：`spawn` 若阻塞，本用例**会挂死**而不是悄悄通过。
        let probe = SpawnProbe()
        probe.status = 0
        probe.payload = 4242
        probe.callerThread = Thread.current
        let env = Unmanaged.passUnretained(probe).toOpaque()

        let kid = bk_task_spawn(bkTestBodyPtr(), nil, env, 8, 0)
        #expect(probe.entered.wait(timeout: .now() + 3) == .success, "体没被派发起来")
        probe.release.signal()

        let out = makeOut()
        #expect(bk_task_join(kid, raw(out)) == 0, "跑完的任务 join 应得 Result")
        #expect(out[0] == 0 && out[1] == 4242, "ok 载荷应原样搬运")
        probe.lock.lock()
        let ran = probe.bodyRan
        let offThread = probe.bodyOffCallerThread
        probe.lock.unlock()
        #expect(ran, "体没跑")
        #expect(offThread, "体跑在调用方那条线程上 ⇒ 那不是派发，是就地求值")
    }

    @Test("spawn 的两态：体返回非 0 ⇒ 任务**保持未决**（让出后由续跑方决出，不是跑完了）")
    func spawnLeavesTheTaskUnresolvedWhenTheBodyYields() throws {
        /// 意图：`DE-1` §3.2.1 的**唯一内容**就是这两态 —— 体返回 `0` 才算跑完；
        /// 返回非 `0` 表示「体已让出」，此时 `future` **仍未决**。
        /// ⛔ 若把非 0 也当成跑完，本用例会读到 `out` 里的默认值 ⇒ 立刻变红。
        let probe = SpawnProbe()
        probe.status = 1
        probe.payload = 999  // 刻意给一个值：让出态**不许**把它写出去
        probe.callerThread = Thread.current
        let env = Unmanaged.passUnretained(probe).toOpaque()

        let kid = bk_task_spawn(bkTestBodyPtr(), nil, env, 8, 0)
        #expect(probe.entered.wait(timeout: .now() + 3) == .success, "体没被派发起来")
        probe.release.signal()

        let out = makeOut()
        #expect(bk_task_join_within(kid, 120, raw(out)) == 1, "让出后仍未决 ⇒ join 只能超时归约")
        #expect(out[1] != 999, "让出态不许把载荷写出去（写出去就等于假装跑完了）")
    }

    // MARK: - `DE-6b`：让出族（frame / slot / await）

    @Test("⭐ 续跑协议：体让出后由**决出方**续跑；续跑拿回同一帧与**同一批槽**；让出时 out 一字节未写")
    func theYieldedBodyIsResumedByWhoeverSettlesTheAwaited() throws {
        /// 意图：`DE-6a` §3.2.2 定案的两件事，各用一条断言钉住 ——
        /// ① **续跑由决出方触发**（不是驱动器原地等）：被等待的任务一决出，让出方就被重入；
        /// ② **帧与槽可重放**：续跑重新执行取槽代码时必须拿回**上次那些地址**，否则「上下文留在
        ///    帧里」这句话是空的。
        /// ⛔ 本件看不见发射层（「发射层真的在 `await` 处让出」另有判据），但发射层也看不见
        /// **协议本身** —— 两者不可互相替代（`DE-6a` §3.6 的分工）。
        /// ⭐ 判据**不靠睡眠**：先等体把续跑点写进帧（那是「已让出」的可观测证据），再放行被等待的
        /// 任务。先后颠倒的话，本用例会退化成「谁先谁后」的抽签。
        let frame = UnsafeMutableRawPointer.allocate(byteCount: YieldFrameSlot.bytes, alignment: 8)
        defer { frame.deallocate() }
        _ = frame.initializeMemory(as: UInt8.self, repeating: 0, count: YieldFrameSlot.bytes)

        let h = bk_task_spawn(bkYieldOuterBodyPtr(), nil, frame, 0, 0)
        defer { bk_handle_release(h) }

        let deadline = Date(timeIntervalSinceNow: 5)
        while yieldFrameGet(frame, YieldFrameSlot.resumePoint) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(yieldFrameGet(frame, YieldFrameSlot.resumePoint) == 1, "体没走到让出点")
        #expect(yieldFrameGet(frame, YieldFrameSlot.lastStatus) == 2, "await 在未决对象上应回 2")
        #expect(
            yieldFrameGet(frame, YieldFrameSlot.outUntouched) == 1,
            "让出时 `out` **一个字节都不许被写**（`DE-6a` §3.2.1 的第三条边界）")
        #expect(
            yieldFrameGet(frame, YieldFrameSlot.frameIdentity) == 1,
            "`bk_task_frame(0)` 必须是派发点建的那块帧，否则续跑读的是另一块内存")

        bkYieldChildProbe.entered.wait(timeout: .now() + 5)
        bkYieldChildProbe.release.signal()

        let out = makeOut()
        defer { out.deallocate() }
        #expect(bk_task_join(h, raw(out)) == 0, "续跑完成后外层任务应决出（不是永远未决）")
        #expect(out[0] == 0 && out[1] == 42, "ok 载荷须来自被等待的子任务：\(out[0])/\(out[1])")
        #expect(yieldFrameGet(frame, YieldFrameSlot.entries) == 2, "体应被进入两次：首跑 + 续跑")
        #expect(
            yieldFrameGet(frame, YieldFrameSlot.slotsReplayed) == 1,
            "续跑须拿回**同一批槽地址** —— 取槽游标归零正是为此")
        #expect(yieldFrameGet(frame, YieldFrameSlot.lastStatus) == 0, "续跑后等待的对象已决 ⇒ 回 0")
    }

    @Test("await 的合规降级：不在任何任务里 ⇒ 直线阻塞等待（不假装让出）")
    func awaitOutsideATaskDegradesToABlockingJoin() throws {
        /// 意图：`DE-6a` §3.2.2 的降级面。`bk_task_await` 只有「有当前任务**且** L1 在位」时才
        /// 可能回 `2`；其余一律走与 `bk_task_join` 同一套归一化。
        /// ⛔ 这不是错误路径（`DE-1` §6.2 纪律 3：降级，不失败），但**必须与「真让出」可区分** ——
        /// 它回的是 `0` / `1`，绝不回 `2`。
        let t = _bkTaskMake()
        defer { bk_handle_release(t) }
        let o = makeOut()
        defer { o.deallocate() }
        _bkTaskResolveOk(t, 7)
        let status = bk_task_await(t, raw(o))
        #expect(status == 0, "已决的对象不值得交出控制流（解释器腿同一条规则）")
        #expect(o[0] == 0 && o[1] == 7, "三槽须与 join 同形：\(o[0])/\(o[1])")
    }

    // MARK: - `Q-4`：决出 ⇒ 入队，推进由策略的答案决定

    @Test("⭐ 改道可观测：决出 ⇒ 入队读作「可跑」，且入队经过策略层")
    func settlingHandsTheTaskToThePolicyQueue() throws {
        /// 意图：本段那处「改道」的**直接观测面**。
        ///
        /// ⚠️ 「决出 ⇒ 直接重入体」的那种实现里，「**可跑**」这个状态**永远不出现** ——
        /// 任务会直接变成在跑、随后已决 ⇒ 故这一条对那种实现有区分力。
        ///
        /// ⚠️ 四条读数各答一问：① 状态确实能读出「可跑」② 入队确实调了策略层的「收下」
        /// ③ 挑不挑由策略说了算（本条的输入是「答空」）④ 已决那一格能读出来。
        /// ⛔ 本条**不测**「两个任务一起就绪时谁先跑」—— 那要两次入队落在同一次挑选之前，
        /// 而语言面上写不出那种语料（那条路各是各的账）。
        let policy = Q4PolicyState()
        let target = _bkTaskMake()
        let waiter = spawnQ4Waiter(target: target)
        defer {
            bk_handle_release(waiter.handle)
            bk_handle_release(target)
        }

        // 未起：造出来、但从没进过体。
        let fresh = _bkTaskMake()
        defer { bk_handle_release(fresh) }
        #expect(bk_task_state(fresh) == 0, "从没进过体的任务读作「未起」")

        #expect(waitForTaskState(waiter.handle, 2), "体在未决的目标上让出 ⇒ 读作「等待中」")

        /// ⚠️ 次序**不可换**：先让等待者真的让出，再绑策略，最后才决出目标。
        /// 反过来会把 `bk_task_await` 推上「已决 ⇒ 直线取值」那条路 —— 那条路上没有队列，
        /// 判据就测不到它要测的东西。
        policy.nextAnswer = nil
        #expect(bindPolicy(policy, handle: waiter.handle) == 0, "绑定应当被接受")
        _bkTaskResolveOk(target, 1)

        #expect(waitForTaskState(waiter.handle, 1), "决出 ⇒ 入队 ⇒ 读作「可跑」")
        #expect(policy.acceptedCount == 1, "入队须经策略层的「收下」：\(policy.acceptedCount)")
        #expect(policy.acceptedHandle == waiter.handle, "交给策略的句柄应当就是这件任务")
        #expect(bk_task_state(target) == 3, "已决的目标读作「已决」")

        /// 驳回性：策略答「没有下一个」⇒ 挑选循环**问过**、但**不推进**它。
        Thread.sleep(forTimeInterval: 0.2)
        #expect(policy.pickCalls >= 1, "挑选循环须问过策略：\(policy.pickCalls)")
        #expect(bk_task_state(waiter.handle) == 1, "策略答「没有下一个」⇒ 停在「可跑」，不得被推进")

        /// 收尾：把它推进掉 —— 否则它留在队列里，会被**后续**判据触发的挑选循环撞上，
        /// 而那一刻本判据的 §env 已经不在了。做法是让策略改口，再用**新的一次入队**请一趟挑选。
        // ⚠️ 触发用的那件任务**不释放 env 也不释放句柄**：它可能仍停在队列里，
        // 释放后再被推进就是悬垂。代价是这一条判据留下 16 字节与一个未推进的任务，
        // 而两者都无害（测试进程结束即回收；没有绑定就走降级那条路）。
        policy.nextAnswer = waiter.handle
        let flushTarget = _bkTaskMake()
        let flushWaiter = spawnQ4Waiter(target: flushTarget)
        _ = flushWaiter
        // ⚠️ **必须等它真的让出**再决出它的目标：`spawn` 只是起线程，体还没跑到登记等待者那一步；
        // 此时决出会得到一个**空快照** ⇒ 没有入队 ⇒ 挑选循环从不启动 ⇒ 收尾落空。
        #expect(waitForTaskState(flushWaiter.handle, 2), "触发用的那件须先让出")
        _bkTaskResolveOk(flushTarget, 1)
        #expect(waitForTaskState(waiter.handle, 3), "收尾：策略改口之后它被推进一次 ⇒ 决出")

        _ = bk_task_bind_sched(waiter.handle, nil)
    }

    @Test("⭐ 推进由策略的答案决定：答出句柄 ⇒ 推进一次 ⇒ 决出（与「答空」互为反证）")
    func thePolicyAnswerDecidesWhetherTheTaskAdvances() throws {
        /// 意图：与上一条**只差策略答什么**（答出句柄 vs 答空），结论必须相反。
        /// ⚠️ 只看「答出 ⇒ 它跑起来了」这一半，「策略被问了」与「谁来问都一样」在读数上
        /// **同形** —— 两条合起来才说明「推不推进」是**策略**说了算。
        let policy = Q4PolicyState()
        let target = _bkTaskMake()
        let waiter = spawnQ4Waiter(target: target)
        defer {
            bk_handle_release(waiter.handle)
            bk_handle_release(target)
        }
        #expect(waitForTaskState(waiter.handle, 2), "体在未决的目标上让出 ⇒ 读作「等待中」")

        policy.nextAnswer = waiter.handle
        #expect(bindPolicy(policy, handle: waiter.handle) == 0, "绑定应当被接受")
        _bkTaskResolveOk(target, 1)

        #expect(policy.acceptedCount == 1, "入队须经策略层的「收下」")
        #expect(waitForTaskState(waiter.handle, 3), "策略给出句柄 ⇒ 推进它一次 ⇒ 决出")

        _ = bk_task_bind_sched(waiter.handle, nil)
    }
}

// MARK: - `DE-6b` 让出族判据用的帧与体
//
// ⚠️ 这一族刻意**不用** `SpawnProbe` 那种 Swift 对象当 `env`：本族要验的是「帧里的字在让出前后
// **留在原地**」，那是一段**裸缓冲**的事 —— 对象字段的布局不归这个判据管，混用会让「帧」这个词
// 指两样东西。故这里的 `env` 是一块自己 `allocate` 的裸帧，字段偏移如下。

/// 裸帧的字段偏移（字节）。`resumePoint` 在 **0** 不是随意选的：那是发射层约定的**续跑点**位置。
private enum YieldFrameSlot {
    static let resumePoint = 0
    static let childWord = 8
    static let entries = 16
    static let slotAWord = 24
    static let slotBWord = 32
    static let slotsReplayed = 40
    static let frameIdentity = 48
    static let lastStatus = 56
    static let outUntouched = 64
    static let bytes = 72
}

private func yieldFrameGet(_ f: UnsafeMutableRawPointer, _ offset: Int) -> Int64 {
    f.load(fromByteOffset: offset, as: Int64.self)
}

private func yieldFramePut(_ f: UnsafeMutableRawPointer, _ offset: Int, _ value: Int64) {
    f.storeBytes(of: value, toByteOffset: offset, as: Int64.self)
}

/// 指针 ↔ 不透明字（帧里存句柄用的是**位型**，与运行时三槽同一条约定）。
private func yieldWord(_ p: UnsafeMutableRawPointer?) -> Int64 {
    guard let p else { return 0 }
    return Int64(bitPattern: UInt64(UInt(bitPattern: p)))
}

private func yieldPointer(_ word: Int64) -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: Int(word)))
}

/// `bk_task_await` 的 `out` 搬到体 wrapper 的三槽（与发射层 wrapper 同一件事）。
private func yieldCopySlots(_ from: UnsafeMutableRawPointer, _ to: UnsafeMutableRawPointer) {
    for offset in stride(from: 0, to: 24, by: 8) {
        to.storeBytes(of: from.load(fromByteOffset: offset, as: Int64.self), toByteOffset: offset, as: Int64.self)
    }
}

/// 被等待的子任务：**进来就停**，直到判据放行为止 —— 让「让出」这件事在判据里是**确定的**，
/// 而不是「子任务恰好还没跑完」的巧合。
///
/// ⚠️ 它是一份文件级单例、供一个用例使用，而本 suite 标了 `.serialized` ⇒ 不存在两个用例同时
/// 借它的问题。若日后要再加一个用它的用例，须先把它改成按用例构造。
private final class YieldChildProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private let bkYieldChildProbe = YieldChildProbe()

private func bkYieldChildBody(
    _ code: UnsafeMutableRawPointer?, _ env: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let out else { return 0 }
    if let env {
        let probe = Unmanaged<YieldChildProbe>.fromOpaque(env).takeUnretainedValue()
        probe.entered.signal()
        _ = probe.release.wait(timeout: .now() + 5)
    }
    out.storeBytes(of: Int64(0), toByteOffset: 0, as: Int64.self)
    out.storeBytes(of: Int64(42), toByteOffset: 8, as: Int64.self)
    out.storeBytes(of: Int64(0), toByteOffset: 16, as: Int64.self)
    return 0
}

/// 让出方：**照发射层将要发出的形状**手写一遍 —— 派发 → 可让出地等 → 让出（返非 0）→ 被续跑后
/// 重新等（这次已决）→ 决出。
///
/// ⭐ 为什么手写而不是等发射层：本件的职责是钉**运行时的续跑协议**。若它也依赖发射层，那么
/// 「协议错」与「发射层错」会一起变红，没有判据能把两者分开。
private func bkYieldOuterBody(
    _ code: UnsafeMutableRawPointer?, _ env: UnsafeMutableRawPointer?, _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let env, let out else { return 0 }
    // 体内取帧必须拿回派发点那一块 —— 「帧」这个词在两处指的必须是同一块内存。
    yieldFramePut(env, YieldFrameSlot.frameIdentity, bk_task_frame(0) == env ? 1 : 0)

    if yieldFrameGet(env, YieldFrameSlot.resumePoint) == 0 {
        let kid = bk_task_spawn(
            bkYieldChildBodyPtr(), nil, Unmanaged.passUnretained(bkYieldChildProbe).toOpaque(), 0, 0)
        yieldFramePut(env, YieldFrameSlot.childWord, yieldWord(kid))
        // 让出前先取两个槽：续跑时再取一次，地址必须相同。
        yieldFramePut(env, YieldFrameSlot.slotAWord, yieldWord(bk_task_slot(8)))
        yieldFramePut(env, YieldFrameSlot.slotBWord, yieldWord(bk_task_slot(8)))

        let o = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { o.deallocate() }
        for offset in stride(from: 0, to: 24, by: 8) {
            o.storeBytes(of: Int64(-7), toByteOffset: offset, as: Int64.self)
        }
        let status = bk_task_await(kid, o)
        yieldFramePut(env, YieldFrameSlot.entries, 1)
        yieldFramePut(env, YieldFrameSlot.lastStatus, Int64(status))
        guard status == 2 else {
            // 只有 L1 缺席时才会来这里（合规降级）：那时不许让出，直接取值。
            yieldCopySlots(o, out)
            return 0
        }
        let untouched =
            (0..<3).allSatisfy { o.load(fromByteOffset: $0 * 8, as: Int64.self) == -7 }
        yieldFramePut(env, YieldFrameSlot.outUntouched, untouched ? 1 : 0)
        yieldFramePut(env, YieldFrameSlot.resumePoint, 1)
        return 2
    }

    let a = bk_task_slot(8)
    let b = bk_task_slot(8)
    let replayed =
        yieldWord(a) == yieldFrameGet(env, YieldFrameSlot.slotAWord)
        && yieldWord(b) == yieldFrameGet(env, YieldFrameSlot.slotBWord)
    yieldFramePut(env, YieldFrameSlot.slotsReplayed, replayed ? 1 : 0)

    let o = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
    defer { o.deallocate() }
    let status = bk_task_await(yieldPointer(yieldFrameGet(env, YieldFrameSlot.childWord)), o)
    yieldFramePut(env, YieldFrameSlot.lastStatus, Int64(status))
    yieldFramePut(env, YieldFrameSlot.entries, 2)
    yieldFramePut(env, YieldFrameSlot.resumePoint, 0)
    yieldCopySlots(o, out)
    return 0
}

private func bkYieldOuterBodyPtr() -> UnsafeMutableRawPointer {
    unsafeBitCast(bkYieldOuterBody as BkTestBody, to: UnsafeMutableRawPointer.self)
}

private func bkYieldChildBodyPtr() -> UnsafeMutableRawPointer {
    unsafeBitCast(bkYieldChildBody as BkTestBody, to: UnsafeMutableRawPointer.self)
}

// MARK: - `B-3` 判据用的体观测面
//
// ⚠️ C 函数指针**不能捕获上下文**，所以体的观测面只能经 `env` 传 ——
// 那正是 `DE-1` §3.1 里 `env` 参数的**本来用途**（闭包捕获环境），不是为测试新开的口子。

/// 体运行时的观测箱（`env` 指向它）。
private final class SpawnProbe: @unchecked Sendable {
    let lock = NSLock()
    var bodyRan = false
    var bodyOffCallerThread = false
    /// `0` = 跑完（写三槽）· 非 `0` = 让出（**不写**）。
    var status: Int32 = 0
    var payload: Int64 = 0
    /// 体已开始执行。
    let entered = DispatchSemaphore(value: 0)
    /// 测试放行体继续（用于证明 `spawn` 没阻塞调用方）。
    let release = DispatchSemaphore(value: 0)
    var callerThread: Thread?
}

/// 任务体的最小 wrapper（`B-3` 的两态形状：`0` = 跑完 · 非 `0` = 让出）。
private func bkTestBody(
    _ code: UnsafeMutableRawPointer?, _ env: UnsafeMutableRawPointer?,
    _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let env, let out else { return 0 }
    let probe = Unmanaged<SpawnProbe>.fromOpaque(env).takeUnretainedValue()
    probe.lock.lock()
    probe.bodyRan = true
    probe.bodyOffCallerThread = Thread.current !== probe.callerThread
    let status = probe.status
    let payload = probe.payload
    probe.lock.unlock()

    probe.entered.signal()
    _ = probe.release.wait(timeout: .now() + 3)

    guard status == 0 else { return status }
    out.storeBytes(of: Int64(0), toByteOffset: 0, as: Int64.self)
    out.storeBytes(of: payload, toByteOffset: 8, as: Int64.self)
    out.storeBytes(of: Int64(0), toByteOffset: 16, as: Int64.self)
    return 0
}

private typealias BkTestBody = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32

/// 体的地址，按 `DE-1` §3.1 的 `wrapper` 参数形态（不透明 `ptr`）交给运行时。
private func bkTestBodyPtr() -> UnsafeMutableRawPointer {
    unsafeBitCast(bkTestBody as BkTestBody, to: UnsafeMutableRawPointer.self)
}

// MARK: - `Q-4` 调度驱动面判据用的替身策略与体
//
// ⚠️ **为什么这里用替身而不是 Pini 语料**：本段要证的是**驱动面**（谁在什么时候被交出去、
// 谁被挑中），而那不是「策略用什么语言写的」的函数。判据侧自造策略能把驱动面单独钉住，
// ⛔ 不受语言面那两处**已知阻塞**牵动（语言面上「两个任务等同一个未来」写不出来；
// 「用户替换调度器」在发射腿上另有一处既有缺口）。⇒ 那两处**各是各的账**，
// 不得把本条全绿读成它们做成了。

/// 替身策略的状态。
///
/// `@unchecked Sendable` 的依据：所有字段都在 `lock` 下读写，而 `lock` 只在**两个 C 函数**里
/// 被持有 —— 它们不做任何重入调用。
private final class Q4PolicyState: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [UnsafeMutableRawPointer] = []
    private var picks = 0
    private var answer: UnsafeMutableRawPointer?

    /// 「收下」收到的第一个句柄 —— 本判据要问的正是「入队到底经没经过策略」。
    var acceptedHandle: UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return handles.first
    }
    var acceptedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return handles.count
    }
    var pickCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return picks
    }
    /// 「选择下一个任务」的答案，`nil` = 空队列。⛔ 判据**自己**决定答什么 —— 那就是被测的输入。
    var nextAnswer: UnsafeMutableRawPointer? {
        get { lock.lock(); defer { lock.unlock() }; return answer }
        set { lock.lock(); answer = newValue; lock.unlock() }
    }

    fileprivate func noteAccepted(_ h: UnsafeMutableRawPointer?) {
        guard let h else { return }
        lock.lock(); handles.append(h); lock.unlock()
    }
    fileprivate func notePick() -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        picks += 1
        let a = answer
        // ⭐ **一次性答案**：答过就清。否则挑选循环会拿同一个句柄反复问，而那个句柄早已出队
        // ⇒ 运行时会把它读成「从未发出去过的句柄」并判为缺陷（那条路是**响亮报错**，不是静默）。
        answer = nil
        return a
    }
}

/// 「收下」的替身（`(策略实例, 任务句柄) -> ()`）—— 记下入队的句柄。
private func q4AcceptBody(_ sched: UnsafeMutableRawPointer?, _ task: UnsafeMutableRawPointer?) {
    guard let sched else { return }
    Unmanaged<Q4PolicyState>.fromOpaque(sched).takeUnretainedValue().noteAccepted(task)
}

/// 「选择下一个任务」的替身（`(策略实例) -> 任务句柄`）—— 答出来之前设定的那个句柄。
private func q4PickBody(_ sched: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let sched else { return nil }
    return Unmanaged<Q4PolicyState>.fromOpaque(sched).takeUnretainedValue().notePick()
}

private typealias Q4AcceptFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void
private typealias Q4PickFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

/// 一个「在给定目标上让出一次」的最小体：首跑让出、续跑跑完并写三槽。
///
/// ⚠️ `env` 由**调用方**给（⛔ 不是运行时的帧）：本判据要往它里面记「第几次进入」与「等谁」，
/// 而它因此**不归运行时释放** —— 这正是「只释放登记过的帧」那条规矩的用法，
/// 也是进程内判据能自己造体的原因。
private func q4WaiterBody(
    _ code: UnsafeMutableRawPointer?, _ env: UnsafeMutableRawPointer?,
    _ out: UnsafeMutableRawPointer?
) -> Int32 {
    guard let env, let out else { return 0 }
    if env.load(fromByteOffset: 0, as: Int64.self) == 0 {
        env.storeBytes(of: Int64(1), toByteOffset: 0, as: Int64.self)
        let target = env.load(fromByteOffset: 8, as: UnsafeMutableRawPointer?.self)
        // `2` = 真让出 ⇒ 原样把它报给运行时（⛔ 不许改写 `out`）。
        return bk_task_await(target, out) == 2 ? 2 : 0
    }
    out.storeBytes(of: Int64(0), toByteOffset: 0, as: Int64.self)
    out.storeBytes(of: Int64(7), toByteOffset: 8, as: Int64.self)
    out.storeBytes(of: Int64(0), toByteOffset: 16, as: Int64.self)
    return 0
}

private func q4WaiterBodyPtr() -> UnsafeMutableRawPointer {
    unsafeBitCast(q4WaiterBody as BkTestBody, to: UnsafeMutableRawPointer.self)
}

/// 把替身策略绑给运行时（三个机器字的记录）。
///
/// ⚠️ 记录里的**第一个字是策略实例**，本判据给的是那个替身对象本身 —— 运行时把它原样回传给
/// 两个入口，故 `q4AcceptBody` / `q4PickBody` 才拿得到自己的状态。
private func bindPolicy(_ state: Q4PolicyState, handle: UnsafeMutableRawPointer) -> Int32 {
    var words: [UnsafeMutableRawPointer?] = [
        Unmanaged.passUnretained(state).toOpaque(),
        unsafeBitCast(q4AcceptBody as Q4AcceptFn, to: UnsafeMutableRawPointer.self),
        unsafeBitCast(q4PickBody as Q4PickFn, to: UnsafeMutableRawPointer.self),
    ]
    return words.withUnsafeMutableBufferPointer { buf in
        bk_task_bind_sched(handle, buf.baseAddress.map { UnsafeMutableRawPointer($0) })
    }
}

/// 轮询等某任务读到指定状态。**有上限** —— 判据不作无界等待（本仓既有的墙钟纪律）。
private func waitForTaskState(
    _ h: UnsafeMutableRawPointer?, _ want: Int32, seconds: Double = 2.0
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if bk_task_state(h) == want { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return false
}

/// 造一个「等某个未决目标」的等待者，返回它的句柄与它那块 env（调用方负责收）。
private func spawnQ4Waiter(
    target: UnsafeMutableRawPointer
) -> (handle: UnsafeMutableRawPointer, env: UnsafeMutableRawPointer) {
    let env = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    env.storeBytes(of: Int64(0), toByteOffset: 0, as: Int64.self)
    env.storeBytes(of: target, toByteOffset: 8, as: UnsafeMutableRawPointer?.self)
    let h = bk_task_spawn(q4WaiterBodyPtr(), nil, env, 0, 0)
    return (h, env)
}
