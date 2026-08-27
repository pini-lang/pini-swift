import Foundation

/// 阶段 B（B-4 完整版）挂起后端：**严格 work-stealing + 「不 resume」有界背压**。
///
/// 线程模型：固定 `poolSize` 个专用 OS 线程；每线程一个**本地任务队列**（LIFO）。
/// `spawn` 时若当前线程是 pool worker，任务入其**本地**队列（局部性：子任务/续体优先在本线程跑，
/// 缓存友好）；否则入全局兜底队列。取任务顺序：本地 → **窃取**其他 worker 本地队列尾部
/// （`stealCount` 可观测）→ 全局 → `NSCondition` 等待。
///
/// 背压（ADR 「不 resume continuation」）：`inflight`（已派发、未完成执行的任务数）达到
/// `maxPending` 时，新任务进入**待调度池**（`waiting`）——**不 wake worker、不占线程、不阻塞调用方**；
/// 任务完成（含挂起提前返回）腾出预算后，从 `waiting` 按序移入队列。区别于 GCDScheduler 的
/// 「信号量阻塞调用方」——背压不阻塞，而是延迟调度续体（真正的「不 resume」）。
///
/// 生命周期：`Pool` 为独立引用类型（cond/locals/global/waiting/inflight/stopping），线程闭包
/// 强持有它、scheduler 不反向持有——无循环引用/无 UB；`deinit` 置 `stopping` + `broadcast` 优雅退出。
final class SuspendScheduler: Scheduler {

 private final class Pool {
 let cond = NSCondition()
 let workerIndex = ThreadLocal<Int>()
 var locals: [[() -> Void]]
 var global: [() -> Void] = []
 var waiting: [() -> Void] = []
 var inflight = 0
 var stopping = false
 var stealCount = 0
 let poolSize: Int
 let maxPending: Int

 init(poolSize: Int, maxPending: Int) {
 self.poolSize = poolSize
 self.maxPending = maxPending
 self.locals = Array(repeating: [], count: poolSize)
 }

 /// 入队（调用方持锁）。本地优先：当前线程是 pool worker → 入其本地（LIFO 取尾部）。
 private func enqueueLocked(_ task: @escaping () -> Void) {
 inflight += 1
 if let i = workerIndex.value, i >= 0, i < poolSize {
 locals[i].append(task)
 } else {
 global.append(task)
 }
 cond.signal()
 }

 /// 背压：预算未满直接入队；已满进待调度池（不 resume）。
 private func scheduleLocked(_ task: @escaping () -> Void) {
 if inflight < maxPending {
 enqueueLocked(task)
 } else {
 waiting.append(task)
 }
 }

 private func drainWaitingLocked() {
 while inflight < maxPending, !waiting.isEmpty {
 enqueueLocked(waiting.removeFirst())
 }
 }

 func workerLoop(_ index: Int) {
 workerIndex.value = index
 while true {
 var task: (() -> Void)?
 cond.lock()
 // 1. 本地队列（LIFO）
 if !locals[index].isEmpty {
 task = locals[index].removeLast()
 }
 // 2. work-stealing：窃取其他 worker 本地队列尾部
 if task == nil {
 for offset in 1..<poolSize {
 let victim = (index + offset) % poolSize
 if !locals[victim].isEmpty {
 task = locals[victim].removeLast()
 stealCount += 1
 break
 }
 }
 }
 // 3. 全局兜底
 if task == nil, !global.isEmpty {
 task = global.removeFirst()
 }
 if task == nil {
 if stopping { cond.unlock(); return }
 cond.wait()
 cond.unlock()
 continue
 }
 cond.unlock()

 task?()

 // 任务完成（含挂起提前返回）→ 腾出预算 → 调度 waiting 中续体。
 cond.lock()
 inflight -= 1
 drainWaitingLocked()
 cond.unlock()
 }
 }

 func spawn(_ task: @escaping () -> Void) {
 cond.lock()
 scheduleLocked(task)
 cond.unlock()
 }

 var activeTaskCount: Int {
 cond.lock(); defer { cond.unlock() }
 return inflight
 }
 var stealCountValue: Int {
 cond.lock(); defer { cond.unlock() }
 return stealCount
 }
 }

 private let pool: Pool
 private var threads: [Thread] = []
 let poolSize: Int
 let maxPending: Int

 init(poolSize: Int = 4, maxPending: Int? = nil) {
 let p = max(1, poolSize)
 let mp = max(1, maxPending ?? p * 8)
 self.poolSize = p
 self.maxPending = mp
 let pool = Pool(poolSize: p, maxPending: mp)
 self.pool = pool
 for i in 0..<p {
 let t = Thread { pool.workerLoop(i) }
 t.name = "pini.suspend"
 t.start()
 threads.append(t)
 }
 }

 deinit {
 pool.cond.lock()
 pool.stopping = true
 pool.cond.broadcast()
 pool.cond.unlock()
 }

 func spawn(_ future: FutureValue, work: @escaping () throws -> Value) {
 let q = pool
 q.spawn {
 _ = try? work()
 }
 }

 var activeTaskCount: Int { pool.activeTaskCount }

 /// work-stealing 观测（测试断言窃取确实发生）。
 var stealCount: Int { pool.stealCountValue }
}
