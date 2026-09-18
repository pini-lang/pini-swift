import XCTest
@testable import PiniCore
import Foundation

/// B-0 spike（Strategy B：自建 trampoline / 续体，零 Swift 并发运行时依赖）——
/// **值层原语那一半**。
///
/// 验证：用纯 Swift 5.9 的「`FutureValue.whenResolved(续体)`」实现非阻塞的挂起-恢复，
/// 不触碰 swift-tools-version 的并发运行时（保持 Package.swift 的「无平台限制 / Swift 5.9+」声明）。
///
/// 关键说明：本测试直接驱动 `FutureValue` 的 resolve→续体回调 路径（即 `<=` 复用的机制），
/// **不经由 `.pini` 求值器**。
///
/// WHAT `G-6c` REMOVED HERE, AND WHY IT WAS A DECISION
///
/// This file used to carry eleven more cases driving the whole suspension stack
/// built on the AST walk: `suspendMode`, `runSuspendable`, and a hand-written
/// pool with work-stealing and back-pressure. That stack retired — the walk it
/// was built on is gone, and the capability it offered (releasing the OS thread
/// across an `await`) was never reachable from a published program anyway, since
/// the flag selecting it had no assignment point in `Sources/`. The four cases
/// below are the ones that never depended on any of it: the `FutureValue`
/// primitives themselves, which both the executor and the runtime rely on.
///
/// ⚠️ **The cost, stated rather than absorbed**: the suspension semantics
/// (`<=` releasing a thread, cancelling a suspended task at the resume boundary,
/// work-stealing, back-pressure) now have **no test witness at all**. They are
/// not "covered elsewhere" — the witness retired with the mechanism. See the
/// blocker-queue and retirement carriers for the per-case terminal ledger.
final class SuspendRuntimeTests: XCTestCase {

    /// 意图：先登记续体、后 resolve——resolve 时续体回调得到正确值（验证续体唤醒链路）；
    /// 登记阶段不得同步阻塞等待（非阻塞是 Strategy B 挂起的前提，推进性；`got` 仍为 nil
    /// 即驳回性：登记不得立即完成回调）。
    func testWhenResolvedDeliversValue() {
        let fut = FutureValue()
        let exp = expectation(description: "resumed")
        var got: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { got = v }
            exp.fulfill()
        }
        XCTAssertNil(got, "登记续体不应同步阻塞等待（非阻塞是 Strategy B 挂起的前提）")
        GCDScheduler.shared.spawn(fut) { Value.int(42) }
        wait(for: [exp], timeout: 5)
        guard case .int(42) = got else { return XCTFail("expected int 42, got \(String(describing: got))") }
    }

    /// 意图：已 resolved 的 fast-path——登记续体**立即同步回调**、不等待（推进性：回调值
    /// 正确；驳回性：登记后 `got` 不得仍为 nil，即不得延迟到未来某刻才唤醒）。
    func testWhenResolvedFastPath()  throws {
        let fut = FutureValue()
        fut.resolve(Value.int(7))
        let exp = expectation(description: "resumed")
        var got: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { got = v }
            exp.fulfill()
        }
        XCTAssertNotNil(got, "已决 future 登记续体应立即同步回调（fast-path 不挂起）")
        guard case .int(7) = got else { return XCTFail("expected int 7, got \(String(describing: got))") }
        wait(for: [exp], timeout: 5)
    }

    /// 意图：reject 路径——future 以错误终结时，续体回调得到 `.failure`（错误经回调显式
    /// 上抛而非静默丢弃；推进性：failure 到达；驳回性：不得错误地以成功分支吞掉错误）。
    func testWhenResolvedReject()  throws {
        let fut = FutureValue()
        let exp = expectation(description: "resumed")
        var failed = false
        fut.whenResolved { r in
            if case .failure = r { failed = true }
            exp.fulfill()
        }
        fut.reject(RuntimeError.invalidOperation(
            reason: "boom",
            location: SourceLocation(line: 0, column: 0, fileName: "")
        ))
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(failed, "reject 应以 .failure 上抛")
    }

    /// 意图：扇出非阻塞——从单一上下文登记 256 个续体并全部被唤醒（推进性：完成数=n；
    /// 驳回性：`whenResolved` 仅登记续体即返回、不阻塞占满线程——若阻塞则 GCD 池被等待者
    /// 占满、worker 抢不到线程而超时）。
    func testFanOutNonBlocking()  throws {
        let n = 256
        let exp = expectation(description: "all resumed")
        exp.expectedFulfillmentCount = n
        var completed = 0
        let lock = NSLock()
        for _ in 0..<n {
            let f = FutureValue()
            GCDScheduler.shared.spawn(f) { Value.int(1) }
            f.whenResolved { _ in
                lock.lock(); completed += 1; lock.unlock()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(completed, n, "256 个续体应全部被 resolve 唤醒：\(completed)/\(n)")
    }
}
