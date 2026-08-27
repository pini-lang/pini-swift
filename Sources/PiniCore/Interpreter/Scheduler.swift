import Foundation

/// 并发调度脊柱的抽象边界（ADR-009 阶段 A）。
///
/// `Scheduler` 协议是「派发任务」这一动作的唯一契约边界：调用方（解释器）
/// 只依赖 `spawn`，不感知底层是 GCD、pthread 还是未来的 work-stealing executor。
///
/// 设计意图（前瞻，非过度设计）：
/// - `spawn` 的契约是稳定的——「可挂起 await」（阶段 B）由 `SuspendScheduler` 后端实现
/// （已落地，见 SuspendScheduler.swift），调用点（`Interpreter` 的两处 `spawn`）与任务契约不变。
/// - 本协议不含任何 GCD 专有类型，便于将来跨平台后端接入（见 ADR-008）。
protocol Scheduler {
 /// 派发 `work` 执行；`work` 返回即 `future` 被 `resolve`/`reject`。
 /// 具体实现决定「工作跑在哪、如何背压、如何观测」，调用方不感知。
 func spawn(_ future: FutureValue, work: @escaping () throws -> Value)

 /// 当前并发活跃任务数（可观测、可诊断）。供饥饿/背压诊断使用。
 var activeTaskCount: Int { get }
}

/// P5 B3-2 更新：有界并发池 + 信号量背压（GCD 后端）。
///
/// 将异步函数体派发到 GCD 有界并发池，防止线程爆炸与线程池饥饿（R5）。
/// `await`/`wait` 在同步/阻塞路径下**阻塞**当前任务线程（见 `FutureValue.wait`）；挂起路径
/// （suspend 模式）由 `SuspendScheduler` 实现「挂起 await（释放 OS 线程）」，
/// 而 `Scheduler` 协议与调用点保持不变（两后端并存，见 ADR-009 ）。
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
 func spawn(_ future: FutureValue, work: @escaping () throws -> Value) {
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
 let value = try work()
 future.resolve(value)
 } catch {
 future.reject(GCDScheduler.coerce(error))
 }
 }
 }

 /// 当前并发的活跃任务数（可观测、可诊断）。
 var activeTaskCount: Int {
 countLock.lock()
 let c = activeCount
 countLock.unlock()
 return c
 }

 private static func emergencyMsg(_ active: Int) -> String? {
 let chans = shared.maxPoolSize
 let ratio = Double(active) / Double(chans)
 guard ratio >= watermarkWarning else { return nil }
 return "[scheduler] ⚠️ 高并发水位：\(active)/\(chans) 活跃任务 (\(Int(ratio * 100))% 池容)"
 }

 private static func coerce(_ error: Error) -> RuntimeError {
 if let re = error as? RuntimeError { return re }
 return RuntimeError.invalidOperation(
 reason: "异步任务执行失败: \(error.localizedDescription)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
}
