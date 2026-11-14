import Foundation
import Testing
@testable import PiniHost

/// 派发出的工作块与调度器的存活期：块占的槽位要到 defer 才归还，信号量必须活到那一刻。
/// 块若弱持调度器，最后一个外部引用在体内落地就会把释放提到归还之前，libdispatch 在信号量上判客户端错误并终止进程。
struct SchedulerLifetimeTests: Sendable {

    /// 只持有引用、不解释调度行为：`drop` 就是「体内丢掉最后一个外部引用」那一步。
    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: GCDScheduler?

        init(_ scheduler: GCDScheduler) { self.stored = scheduler }

        var current: GCDScheduler? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func drop() {
            lock.lock()
            stored = nil
            lock.unlock()
        }
    }

    /// 只答「实例还在不在」：弱引用不延长存活期，故它是释放时机的观测面。
    private final class LivenessProbe: @unchecked Sendable {
        private let lock = NSLock()
        private weak var target: GCDScheduler?

        init(_ target: GCDScheduler) { self.target = target }

        var isAlive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return target != nil
        }
    }

    /// 在函数里造实例再只交出持有盒与探针：返回后本帧那份引用随之消失，体内放手才是最后一次。
    private static func makeOwner() -> (holder: Holder, probe: LivenessProbe) {
        let 调度器 = GCDScheduler.isolated()
        return (Holder(调度器), LivenessProbe(调度器))
    }

    @Test("派发返回后放掉最后一个外部引用，调度器仍在 —— 块还没跑完，它得活着")
    func theDispatchedBlockKeepsTheSchedulerAlive() throws {
        /// 意图：弱持时这一放手就把信号量连着实例送进 deinit，而块的槽位尚未归还 ⇒ libdispatch 终止进程。
        /// 闸拦的是「块提前跑完」，不是「块已经在跑」：判据不依赖工作线程何时分到这一块。
        let (持有盒, 探针) = Self.makeOwner()
        let future = FutureValue()
        let 闸 = DispatchSemaphore(value: 0)

        持有盒.current!.spawn(future) {
            闸.wait()
            return .finished(.int(1))
        }
        持有盒.drop()

        #expect(探针.isAlive, "派发返回后一放手调度器就没了：块没有保住它")
        闸.signal()
    }
}
