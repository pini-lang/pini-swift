import Foundation
import PiniRuntime
import Testing

/// ADR-001 `P2a` 运行时符号 `bk_given_get` 的判据（契约 §2.46 的**实现面**）。
///
/// **为什么单独一件**：`GivenUsingTests` 钉的是语言面（AST / 降载 / 诊断），本件钉的是
/// **运行时符号的并发与重入语义** —— 两者的失败形态不同，混在一起会让「谁红了」无从定位。
///
/// ⚠️ **本批的节点不可达**（无降载规则）⇒ 这四条判据**不是**端到端验收，而是对
/// 「照抄来的 once 骨架在本场景下仍然成立」的直接测量。把语言侧打通的验收属 `P2b`。
///
/// ⚠️ **`.serialized` 不是风格选择**：C 函数指针不能捕获上下文 ⇒ 要写入的值与调用计数
/// 只能走**文件级状态**，而 Swift Testing 默认**并行执行测试** ⇒ 并行会让探针互相污染，
/// 判据变成随机通过。串行是这个设计成立的前提。
@Suite(.serialized)
struct GivenInstanceRuntimeTests {

    // MARK: - 探针状态（C 函数指针不能捕获上下文 ⇒ 一切上下文走文件级）

    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        private var _calls = 0
        private var _addresses: Set<UInt> = []
        /// 当前的初始化函数要写入的值（测试内设定；闭包读它而不捕获它）。
        var currentValue: Int32 = 0
        /// 重入探针用：`outer` 的初始化函数内部要取用**另一个**类型的默认实例。
        var reentrantSlot: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        var reentrantFn: UnsafeMutableRawPointer?

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            _calls = 0
            _addresses.removeAll()
        }
        func bump() {
            lock.lock()
            defer { lock.unlock() }
            _calls += 1
        }
        func record(_ ptr: UnsafeMutableRawPointer) {
            lock.lock()
            defer { lock.unlock() }
            _addresses.insert(UInt(bitPattern: ptr))
        }
        func snapshot() -> (calls: Int, distinctAddresses: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (_calls, _addresses.count)
        }
    }

    private static let probe = Probe()

    /// 符合契约 ABI（`ptr (ptr out) -> ptr`）的初始化函数。
    ///
    /// ⚠️ **只读静态状态、不读任何局部量** —— 读局部量就是捕获上下文，而
    /// `@convention(c)` 闭包不允许捕获（第一次写法正是栽在这里，编译器当场拦下）。
    private func makeInitializer() -> UnsafeMutableRawPointer {
        let fn: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer = { out in
            Self.probe.bump()
            out.storeBytes(of: Self.probe.currentValue, as: Int32.self)
            return out
        }
        return unsafeBitCast(fn, to: UnsafeMutableRawPointer.self)
    }

    private func makeSlot() -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
        let slot = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
        slot.initialize(to: nil)
        return slot
    }

    // MARK: - 判据

    @Test("多次取用：初始化函数恰一次，且每次返回同一地址")
    func materializesOnceWithStableAddress() throws {
        /// 意图：`惰性物化、恰一次、地址稳定` 是契约写明的三条语义 —— 一次调用全量测到。
        /// 「恰一次」是**计数**判据，「地址稳定」是**身份**判据，两者都要：
        /// 「每次新建但内容相同」能满足前者内容上的期待而违反后者。
        Self.probe.reset()
        Self.probe.currentValue = 41
        let slot = makeSlot()
        defer { slot.deallocate() }
        let fn = makeInitializer()

        let first = bk_given_get(slot, fn, MemoryLayout<Int32>.size)
        let second = bk_given_get(slot, fn, MemoryLayout<Int32>.size)
        let third = bk_given_get(slot, fn, MemoryLayout<Int32>.size)

        #expect(first == second, "第二次取用应返回同一地址")
        #expect(second == third, "第三次取用应返回同一地址")
        #expect(first.load(as: Int32.self) == 41, "取到的应是初始化函数写入的值")
        #expect(Self.probe.snapshot().calls == 1, "初始化函数应恰跑一次，实际 \(Self.probe.snapshot().calls) 次")
    }

    @Test("两个存放位各自物化：地址不共享（阴性对照）")
    func distinctSlotsDoNotShareAnInstance() throws {
        /// 意图：与上一条成对 —— 上一条只证明「同一 slot 地址稳定」，若缓存被做成
        /// **全局单例**也会通过；本条用两个不同 slot 证明缓存是**跟着存放位走的**
        /// （发射层每类型一个静态槽位 ⇒ 语义上必须每槽一份）。
        Self.probe.reset()
        let slotA = makeSlot()
        let fnA = makeInitializer()
        let slotB = makeSlot()
        let fnB = makeInitializer()
        defer { slotA.deallocate(); slotB.deallocate() }

        // ⚠️ 值必须在**取用之前**设定：两个初始化函数是同一个闭包体，它在**调用时刻**
        // 读 `currentValue`，而不是在自己被造出来时绑定。真实发射层里每个类型有**自己的
        // 具名函数**、各写各的常量的，所以这个形态只是测试脚手架的简化。
        Self.probe.currentValue = 1
        let a = bk_given_get(slotA, fnA, MemoryLayout<Int32>.size)
        Self.probe.currentValue = 2
        let b = bk_given_get(slotB, fnB, MemoryLayout<Int32>.size)

        #expect(a != b, "不同存放位不得共用同一个实例地址")
        #expect(a.load(as: Int32.self) == 1, "A 槽的值应为 1")
        #expect(b.load(as: Int32.self) == 2, "B 槽的值应为 2")
        #expect(Self.probe.snapshot().calls == 2, "两个槽各物化一次，实际 \(Self.probe.snapshot().calls) 次")
    }

    @Test("并发取用：初始化函数仍恰一次，且全部拿到同一地址（自旋栅栏）")
    func concurrentMaterializationStaysOnce() throws {
        /// 意图：两级锁的存在理由 —— 若只有盒内锁，两个线程会各建一个盒，
        /// 于是一个类型物化出**两份**实例（地址不稳定）；本条钉的就是这个。
        ///
        /// ⚠️ **判据形态经过两轮加固，这一版的形态不是随手写的**：
        /// ① 初版 `concurrentPerform(64)` 单轮 ⇒ 实测**抓不住**「去掉全局锁」的变异；
        /// ② 改成信号量栅栏 + 40 轮 ⇒ **仍然抓不住**：竞态窗口 = 「判空 + 分配」，约 100ns，
        ///    而信号量唤醒线程的散布是**微秒级** —— 比窗口宽一个量级，冲不进去；
        /// ③ 本版 = **自旋栅栏**（线程不挂起、停在 CPU 上等令）+ 显式队列 + 主线程也参与。
        ///    自旋把同时性压到纳秒级，才真正让 32 个线程在同一个窗口里判空。
        ///
        /// ⚠️ 线程数取 `activeProcessorCount`：自旋线程数超过核数会让它们**轮流**上 CPU，
        /// 反而失去同时性。同理自旋带次数上限 —— 卡住时退化为普通等待而不是空转到底。
        let cores = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let rounds = 60
        let queues = (0..<cores).map { DispatchQueue(label: "p2a-given-probe-\($0)") }
        var badRounds: [Int] = []
        for round in 0..<rounds {
            Self.probe.reset()
            Self.probe.currentValue = 7
            let slot = makeSlot()
            let fn = makeInitializer()
            let gate = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            gate.pointee = 0
            let done = DispatchGroup()
            for i in 0..<cores {
                done.enter()
                queues[i].async {
                    // 自旋就位：不挂起 ⇒ 发令后同时进入取用。上限防止意外空转。
                    var spins = 0
                    while gate.pointee == 0 && spins < 500_000_000 { spins += 1 }
                    Self.probe.record(bk_given_get(slot, fn, MemoryLayout<Int32>.size))
                    done.leave()
                }
            }
            usleep(3_000)  // 让所有自旋线程先起来（3ms 远大于线程启动开销）
            gate.pointee = 1
            Self.probe.record(bk_given_get(slot, fn, MemoryLayout<Int32>.size))  // 主线程也冲
            done.wait()
            let snap = Self.probe.snapshot()
            if snap.distinctAddresses != 1 || snap.calls != 1 {
                badRounds.append(round)
            }
            gate.deallocate()
            slot.deallocate()
        }
        #expect(
            badRounds.isEmpty,
            "以下轮次出现「多份实例」或「重复物化」（共 \(badRounds.count)/\(rounds) 轮）：\(badRounds.prefix(8))"
        )
    }

    @Test("重入取用不自死锁：初始化函数内再取另一个类型的默认实例")
    func reentrantMaterializationDoesNotDeadlock() throws {
        /// 意图：钉住实现里那条**注释所声明的约束** —— 「不得持全局锁调 `init_fn`」。
        /// 各字段的初值自己可能取用另一个类型的默认实例；持锁调用就是一次**可复现的自死锁**。
        /// 判据形态 = **带超时的等待**：死锁表现为超时失败，而不是把测试进程挂住。
        ///
        /// ⚠️ **这个形态只有在「本测试独占全局锁」时才干净**：若实现真的持锁调 `init_fn`，
        /// 那把锁就被**永久持有** ⇒ 同一进程里后续任何取用默认实例的测试都会卡住，
        /// 整份套件表现为**挂死**（实测：变异 M2 下进程被超时杀掉，退出码 137）。
        /// 换言之，超时判据是第一道信号，挂死是第二道 —— 两者都响，但第二道不好看。
        /// 如实登记于此，不假装它是个干净的失败。
        Self.probe.reset()
        let outerSlot = makeSlot()
        let innerSlot = makeSlot()
        defer { outerSlot.deallocate(); innerSlot.deallocate() }
        Self.probe.currentValue = 9
        Self.probe.reentrantSlot = innerSlot
        Self.probe.reentrantFn = makeInitializer()
        defer {
            Self.probe.reentrantSlot = nil
            Self.probe.reentrantFn = nil
        }

        Self.probe.currentValue = 5
        let outerFn: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer = { out in
            Self.probe.bump()
            // 重入：取用另一个类型的默认实例 —— 这正是「持锁调用」会死锁的那一步。
            if let s = Self.probe.reentrantSlot, let f = Self.probe.reentrantFn {
                _ = bk_given_get(s, f, MemoryLayout<Int32>.size)
            }
            out.storeBytes(of: 5, as: Int32.self)
            return out
        }
        let outerFnPtr = unsafeBitCast(outerFn, to: UnsafeMutableRawPointer.self)

        var observed: UnsafeMutableRawPointer?
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            observed = bk_given_get(outerSlot, outerFnPtr, MemoryLayout<Int32>.size)
            finished.signal()
        }
        let ok = finished.wait(timeout: .now() + 5) == .success

        #expect(ok, "重入取用发生死锁（超时）—— 说明实现持全局锁调用了初始化函数")
        guard ok else { return }  // 死锁时以下断言都无意义
        #expect(observed != nil, "重入路径应正常返回")
        #expect(observed?.load(as: Int32.self) == 5, "外层实例的值应为 5")
        #expect(innerSlot.pointee != nil, "内层实例也应被物化（重入确实发生了）")
        #expect(innerSlot.pointee != outerSlot.pointee, "内外两个存放位不得是同一个实例")
    }
}
