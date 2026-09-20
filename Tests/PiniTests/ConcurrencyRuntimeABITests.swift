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
/// **符号 → 判据对照**（8/8 全覆盖）：
///
/// | 符号 | 判据 |
/// |---|---|
/// | `bk_capabilities` | 能力位与位定义 |
/// | `bk_task_join` | join 三态 · join 真的阻塞 |
/// | `bk_task_join_within` | 超时归约 |
/// | `bk_task_join_all` | fail-fast · 全 ok 聚合 |
/// | `bk_task_cancel` | 检查点 · 沿树传播 · 认父时刻 |
/// | `bk_task_is_cancelled` | 检查点 |
/// | `bk_task_detach` | 剪枝阴性对照 |
/// | `bk_scope_close` | 有界 override（翻 / 不覆盖 / 不计未完成） |
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

    @Test("能力位自述：位定义与解释器腿一致，L2 永不宣称，且本腿不越权宣称 L1")
    func capabilitiesAgreeWithTheInterpreterLeg() throws {
        /// 意图：`bk_capabilities()` 的**位定义**必须与解释器腿同源 —— 两腿各定一套的话，
        /// `DE-4` 的契约参照就没有共同基准（`DE-1` §3.4 定案表的原话）。
        /// 断言的是**子集关系**（本腿 ⊂ 解释器腿）：这条**将来仍成立**（相等也是子集），
        /// 所以它不是一次性判据。
        /// ⛔ L2 缺席是**裁定 29** 的直接后果（登记不实现）—— 任何后端都不许宣称它。
        /// ⭐ **L1 今天必须缺席**：走乙之下「让出」是异步体的 `return`、由发射层接住，
        /// 而那件尚未落地（`DE-3c`）。**在它落地之前宣称 L1 就是发假绿** —— 这条断言会在
        /// `DE-3c` 真的接通让出时变红，而那正是它该变红的时刻（届时须一并改 `_bkCapabilities`）。
        let actual = bk_capabilities()
        let oracle = ConcurrencyCapabilities.resolve(threadsAvailable: true)
        #expect(actual & 4 == 0, "L2 永不许宣称（裁定 29），实际位图 \(actual)")
        #expect(actual & 1 == 1, "L0 应在场，实际位图 \(actual)")
        #expect(actual & ~oracle.bitmap == 0, "本腿置了位定义之外的位：\(actual) 对 \(oracle.bitmap)")
        #expect(actual & 2 == 0, "L1 今天的诚实值是「未接线」（DE-3c 接通后本条须一并改）")
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
}
