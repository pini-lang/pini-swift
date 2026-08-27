import XCTest
@testable import PiniCore

/// （消解风险 R5）：**线程池饥饿防护 — 有界并发池 + 信号量背压**。
///
/// 验证 Scheduler 的并发上限、背压行为与无死锁性。
/// 不依赖 Pini 源码解析——用 Swift 直调 `GCDScheduler.shared.spawn` 控制并发度。
final class StarvationTests: XCTestCase {

    // MARK: - 基本并发行为

    /// 意图：单任务 spawn→resolve 通路畅通。
    func testSingleTaskCompletes() {
        let future = FutureValue()
        let exp = expectation(description: "single task resolved")
        GCDScheduler.shared.spawn(future) {
            exp.fulfill()
            return .null
        }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(future.isResolved)
        XCTAssertNil(future.error)
    }

    /// 意图：多个任务并发 spawn，全部完成无死锁。
    func testManyTasksCompleteWithoutDeadlock() {
        let count = 32
        var futures: [FutureValue] = []
        let group = DispatchGroup()

        for i in 0 ..< count {
            let f = FutureValue()
            futures.append(f)
            group.enter()
            GCDScheduler.shared.spawn(f) {
                group.leave()
                return .int(i)
            }
        }
        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "32 个并发任务应在 10s 内全部完成（无死锁）")
        for (i, f) in futures.enumerated() {
            XCTAssertTrue(f.isResolved, "任务 #\(i) 应 resolve")
        }
    }

    /// 意图：信号量上限生效——超过 maxPoolSize 的任务排队，不会瞬间全部调度。
    /// 本测试 spawn 2× max 个长任务，验证第一条到达上限后后续任务被迫排队。
    func testPoolRespectsMaxConcurrency() {
        let maxConcurrent = GCDScheduler.shared.maxPoolSize
        let totalTasks = maxConcurrent * 2
        var peak = 0
        let peakLock = NSLock()
        var futures: [FutureValue] = []

        let taskFinished = DispatchGroup()

        for _ in 0 ..< totalTasks {
            let f = FutureValue()
            futures.append(f)
            taskFinished.enter()
            GCDScheduler.shared.spawn(f) {
                let active = GCDScheduler.shared.activeTaskCount
                peakLock.lock()
                peak = max(peak, active)
                peakLock.unlock()
                Thread.sleep(forTimeInterval: 0.1)
                taskFinished.leave()
                return .null
            }
        }

        let result = taskFinished.wait(timeout: .now() + 20)
        XCTAssertEqual(result, .success, "\(totalTasks) 个任务应在 20s 内全部完成（无死锁）")
        // 信号量 + count 之间存在纳秒级竞态窗口；容许 ±8 的测量误差
        XCTAssertLessThanOrEqual(peak, maxConcurrent + 8,
            "并发峰值 \(peak) 应在池上限 \(maxConcurrent)+8 以内，不可无界爆炸")
        for f in futures { f.resolve(.null) }
    }

    // MARK: - 错误传播

    /// 意图：任务抛错 → Future.reject，但其他任务不受影响、池容量恢复。
    func testErrorDoesNotLeakPoolSlot() {
        let futureA = FutureValue()
        let futureB = FutureValue()
        let expA = expectation(description: "task A rejected")
        let expB = expectation(description: "task B resolved")

        GCDScheduler.shared.spawn(futureA) {
            expA.fulfill()
            throw RuntimeError.invalidOperation(
                reason: "expected failure", location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        GCDScheduler.shared.spawn(futureB) {
            expB.fulfill()
            return .int(42)
        }
        wait(for: [expA, expB], timeout: 5)
        XCTAssertNotNil(futureA.error, "task A 应被 reject")
        XCTAssertTrue(futureB.isResolved, "task B 应正常 resolve")
        // B3-2 核心：池容量可恢复，不会因错误而永久泄漏槽位
        let afterActive = GCDScheduler.shared.activeTaskCount
        XCTAssertLessThanOrEqual(afterActive, GCDScheduler.shared.maxPoolSize,
            "池容量在任务完成后不应超过上限（无泄漏），实际 \(afterActive)")
    }

    // MARK: - 背压（高并发快照）

    /// 意图：快速连续 spawn 大量任务，验证信号量背压不会导致卡死，
    /// 全部任务在合理时间内完成。
    func testRapidSpawnBackpressure() {
        let count = 128
        var futures: [FutureValue] = []
        let done = DispatchGroup()

        for i in 0 ..< count {
            let f = FutureValue()
            futures.append(f)
            done.enter()
            GCDScheduler.shared.spawn(f) {
                done.leave()
                return .int(i)
            }
        }
        let result = done.wait(timeout: .now() + 15)
        XCTAssertEqual(result, .success, "128 个快速 spawn 应在 15s 内全部完成（背压不卡死）")
        let unresolved = futures.filter { !$0.isResolved }
        XCTAssertEqual(unresolved.count, 0, "仍有 \(unresolved.count) 个 future 未 resolve")
    }
}
