import XCTest
@testable import PiniCore
import Foundation

/// B-0 spike（Strategy B：自建 trampoline / 续体，零 Swift 并发运行时依赖）。
///
/// 验证：用纯 Swift 5.9 的「`FutureValue.whenResolved(续体)`」实现非阻塞的挂起-恢复，
/// 不触碰 swift-tools-version 的并发运行时（保持 Package.swift 的「无平台限制 / Swift 5.9+」声明）。
///
/// 关键说明：本测试直接驱动 `FutureValue` 的 resolve→续体回调 路径（即 `<=` 将复用的机制），
/// **不经由 `.pini` 求值器**——求值器的 CPS 化拼接是 B-2 的工作；本 spike 仅证明原语成立、
/// 非阻塞、且在 Swift 5.9 / 无平台限制下可编译。
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
    func testWhenResolvedFastPath() {
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
    func testWhenResolvedReject() {
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
    func testFanOutNonBlocking() {
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

    // MARK: - B-2 探针：`<=` 真正挂起（经 .pini 求值器）

    /// 意图：B-2 的「单步挂起」——父 `<=` 等待子任务时**释放 OS 线程**而非阻塞；
    /// 子 resolve 后父经续体恢复，得到正确结果。这是把 B-0 的 `whenResolved` 原语
    /// 真正接进 `.pini` 求值器（`runSuspendableBody` 可恢复执行器）的端到端证明。
    func testSuspendAwaitReleasesThread() throws {
        let src = """
        child|func() => (I32,)
            sleep(20)
            return ok(7)

        main|func() => (I32,)
            var c = child()
            var r = await c
            return r
        """
        let lexer = Lexer(source: src, fileName: "suspend.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "suspend.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 4)
        let fut = try interp.runSuspendable(module: module)
        // 注意：挂起续体以 `[weak self]` 捕获解释器，解释器必须在本方法作用域内保持存活；
        // 若解释器先被释放，resume 续体将静默失效 → future 永不 resolve。

        let exp = expectation(description: "main resolved")
        var resolved: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { resolved = v }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        guard case .enumValue(let ev) = resolved else {
            return XCTFail("expected Result enum, got \(String(describing: resolved))")
        }
        XCTAssertEqual(ev.caseName, "ok", "main 应经续体恢复并返回 ok")
        guard case .int(let n)? = ev.associatedValues.first else {
            return XCTFail("expected int payload")
        }
        XCTAssertEqual(n, 7, "挂起-恢复后子任务结果应正确传递")
    }

    /// 意图：**有界池下的线程释放证明**。硬上限 2 线程、100 个父任务各 spawn 一个子并 `<=` 它。
    /// 若 `<=` 仍阻塞（未挂起），2 个线程会被占满等待子任务、而子任务永远抢不到线程 → 死锁；
    /// 挂起模式下线程被及时释放复用，100 组全部完成。这正是 B-2 的核心价值。
    func testBoundedPoolCompletesHighFanout() throws {
        let src = """
        worker|func() => (I32,)
            sleep(10)
            return ok(1)

        main|func() => (I32,)
            var w = worker()
            var r = await w
            return r
        """
        let lexer = Lexer(source: src, fileName: "fanout.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "fanout.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 2)   // 硬上限 2 线程
        try interp.prepareSuspend(module)
        guard let main = interp.mainFunctionValue() else {
            return XCTFail("main not found")
        }

        let n = 100
        let exp = expectation(description: "all mains resolved")
        exp.expectedFulfillmentCount = n
        var completed = 0
        let lock = NSLock()
        for _ in 0..<n {
            let fut = interp.runSuspendableEntry(main)
            fut.whenResolved { r in
                if case .success = r {
                    lock.lock(); completed += 1; lock.unlock()
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
        XCTAssertEqual(completed, n, "挂起模式应在有界线程池(2)下完成全部任务，而非因阻塞死锁")
    }

    // MARK: - B-3 探针：挂起点 = 取消检查点

    /// 意图：**挂起中的任务被取消 → 在 resume 边界立即终结**（协作式取消）。
    /// `mid` 挂起在 `leaf` 上，且 `leaf` 已被 `detach`（脱离取消树、不受树传播影响）——
    /// 只有「本任务被取消 → `onCancel` 唤醒 resume → 入口 `checkCancellation` 抛 `CancelError`」
    /// 这条路径能让 `mid` 在 `leaf` 完成前终结。若取消不唤醒挂起任务，`mid` 须等 leaf 的 500ms 才
    /// 在 `<=` 恢复处看到取消；本测试断言 main 在 **400ms 内**拿到 `err(CancelError)`，即证明
    /// 取消在 resume 边界**即时**生效（时序差异是 B-3 与「只靠 awaited 未来驱动」的关键区别）。
    func testCancelSuspendedTaskTerminatesAtResumeBoundary() throws {
        let src = """
        leaf|func() => (I32,)
            sleep(500)
            return ok(9)

        mid|func() => (I32,)
            var l = leaf()
            detach l
            var r = await l
            return r

        main|func() => (I32,)
            var m = mid()
            sleep(30)
            m.cancel()
            var r = await m
            return r
        """
        let lexer = Lexer(source: src, fileName: "cancel-suspend.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "cancel-suspend.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 4)

        let start = Date()
        let fut = try interp.runSuspendable(module: module)
        let exp = expectation(description: "main resolved")
        var resolved: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { resolved = v }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        let elapsed = Date().timeIntervalSince(start)

        guard case .enumValue(let ev) = resolved else {
            return XCTFail("expected Result enum, got \(String(describing: resolved))")
        }
        XCTAssertEqual(ev.caseName, "err", "被取消的挂起任务应以 err 终结：实际=\(String(describing: resolved))")
        XCTAssertTrue(
            ev.associatedValues.first.map { Interpreter.isCancelErrorValue($0) } ?? false,
            "err 载荷应为 CancelError：实际=\(String(describing: resolved))"
        )
        XCTAssertLessThan(
            elapsed, 0.4,
            "取消应在 resume 边界即时生效（<400ms），而非等 leaf 的 500ms 自然完成：实际=\(elapsed)s"
        )
    }

    /// 意图：suspend 模式下「取消正在 sleep 的子任务」——sleep 分片检查点先于任何挂起生效。
    /// 子任务被取消后立即以 `err(CancelError)` 终结，父 `<=` 得到可 match 的错误值。
    func testCancelSleepingChildInSuspendMode() throws {
        let src = """
        child|func() => (I32,)
            sleep(500)
            return ok(7)

        main|func() => (I32,)
            var c = child()
            c.cancel()
            var r = await c
            return r
        """
        let lexer = Lexer(source: src, fileName: "cancel-sleep.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "cancel-sleep.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 4)
        let fut = try interp.runSuspendable(module: module)

        let exp = expectation(description: "main resolved")
        var resolved: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { resolved = v }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        guard case .enumValue(let ev) = resolved else {
            return XCTFail("expected Result enum, got \(String(describing: resolved))")
        }
        XCTAssertEqual(ev.caseName, "err", "被取消的 sleep 子任务应以 err 终结：实际=\(String(describing: resolved))")
        XCTAssertTrue(
            ev.associatedValues.first.map { Interpreter.isCancelErrorValue($0) } ?? false,
            "err 载荷应为 CancelError：实际=\(String(describing: resolved))"
        )
    }

    // MARK: - 完整版 B-1：五项上下文跨挂起捕获/还原（4.1(3) MUST）

    /// 意图：挂起模式下 `defer` 与同步路径语义一致——函数体级 defer scope 在任务首次进入时
    /// push、终结（return）时 pop 执行；挂起-恢复全程经 `deferStack` 快照/还原，不再抛
    /// 「defer 必须在块作用域内使用」（探针版因未 push scope 而会抛）。
    func testDeferRunsAtFunctionExitInSuspendMode() throws {
        let src = """
        child|func() => (I32,)
            sleep(20)
            return ok(7)

        main|func() => (I32,)
            defer print("cleanup")
            var c = child()
            var r = await c
            return r
        """
        let lexer = Lexer(source: src, fileName: "defer-suspend.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "defer-suspend.pini")
        let module = try parser.parseModule()

        // 捕获 stdout（defer 里的 print 走 stdout）。
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 4)
        let fut = try interp.runSuspendable(module: module)

        let exp = expectation(description: "main resolved")
        var resolved: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { resolved = v }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        // 必须在 readDataToEndOfFile 之前关闭写端并还原 stdout，否则读会永远阻塞等 EOF。
        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard case .enumValue(let ev) = resolved else {
            return XCTFail("expected Result enum, got \(String(describing: resolved))")
        }
        XCTAssertEqual(ev.caseName, "ok", "defer 不应改变函数返回值：实际=\(String(describing: resolved))")
        XCTAssertNotEqual(ev.caseName, "err", "defer 执行不得把返回值翻成 err（defer 只做清理，不改变函数结果）")
        XCTAssertTrue(out.contains("cleanup"), "函数体级 defer 应在 return 边界执行：实际输出=\(out)")
    }

    /// 意图：多任务共享解释器 + 有界池，每个任务体内都有 defer + 挂起 + return——证明
    /// `deferStack` 跨挂起**每任务隔离**（线程复用时不串台）：若还原/快照有误，某任务会
    /// pop 到他人 scope 或抛「defer 必须在块作用域内使用」→ future 以 err 终结 → okCount 不齐。
    func testDeferPerTaskIsolatedInSuspendMode() throws {
        let src = """
        child|func() => (I32,)
            sleep(10)
            return ok(1)

        main|func() => (I32,)
            defer print("cleanup")
            var c = child()
            var r = await c
            return r
        """
        let lexer = Lexer(source: src, fileName: "defer-many.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "defer-many.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 2)   // 硬上限 2 线程 → 线程必然复用
        try interp.prepareSuspend(module)
        guard let main = interp.mainFunctionValue() else {
            return XCTFail("main not found")
        }

        let n = 50
        let exp = expectation(description: "all mains resolved")
        exp.expectedFulfillmentCount = n
        var okCount = 0
        let lock = NSLock()
        for _ in 0..<n {
            let fut = interp.runSuspendableEntry(main)
            fut.whenResolved { r in
                if case .success(let v) = r {
                    if case .enumValue(let ev) = v, ev.caseName == "ok" {
                        lock.lock(); okCount += 1; lock.unlock()
                    }
                }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
        XCTAssertEqual(okCount, n, "每个任务应各自 pop 自己的 defer scope（deferStack 跨挂起每任务隔离），全部以 ok 完成：\(okCount)/\(n)")
    }

    // MARK: - B-4 探针：自研固定线程池（work-stealing executor 简化版）

    /// 意图：B-4 的核心承诺是「固定少量 OS 线程」。在池 `poolSize=2` 上跑 200 组
    /// spawn+`<=`，记录所有 future 完成回调（在池线程上触发）出现的**不同线程**——
    /// 断言 ≤ 2：自研池只创建 2 个专用线程，挂起/恢复全在这 2 个线程上轮转，
    /// 绝不额外借线程（若 `<=` 阻塞会死锁，若线程无界会 >2）。
    func testFixedPoolUsesBoundedThreadCount() throws {
        let src = """
        child|func() => (I32,)
            sleep(10)
            return ok(1)

        main|func() => (I32,)
            var c = child()
            var r = await c
            return r
        """
        let lexer = Lexer(source: src, fileName: "pool-threads.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "pool-threads.pini")
        let module = try parser.parseModule()

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 2)
        try interp.prepareSuspend(module)
        guard let main = interp.mainFunctionValue() else {
            return XCTFail("main not found")
        }

        let n = 200
        let exp = expectation(description: "all mains resolved")
        exp.expectedFulfillmentCount = n
        var seenThreads = Set<ObjectIdentifier>()
        var okCount = 0
        let lock = NSLock()
        for _ in 0..<n {
            let fut = interp.runSuspendableEntry(main)
            fut.whenResolved { r in
                lock.lock()
                seenThreads.insert(ObjectIdentifier(Thread.current))
                if case .success(let v) = r {
                    if case .enumValue(let ev) = v, ev.caseName == "ok" { okCount += 1 }
                }
                lock.unlock()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)

        XCTAssertEqual(okCount, n, "200 组 spawn+`<=` 应全部以 ok 完成：\(okCount)/\(n)")
        XCTAssertLessThanOrEqual(
            seenThreads.count, 2,
            "自研固定池只允许 2 个专用线程出现，实际出现 \(seenThreads.count) 个不同线程"
        )
    }

    // MARK: - 完整 CPS 化（B-2 完整版）：任意深度挂起 / 副作用不重跑 / 调用链挂起

    /// 意图：`<=` 出现在 **call 实参内部**（`print(await child())`），挂起-恢复后**只执行一次**。
    /// 语句游标重跑模型会把整条 `print(await child())` 重跑 → "before"/"after"/"ok(7)" 各打两遍；
    /// CPS 模型精确恢复，各恰一次。这是「任意表达式深度挂起 + 副作用零重复」的验收标准。
    func testJoinInsideCallArgumentRunsSideEffectOnce() throws {
        let src = """
        child|func() => (I32,)
            sleep(20)
            return ok(7)

        main|func() => (I32,)
            print("before")
            print(await child())
            print("after")
            return ok(0)
        """
        let lexer = Lexer(source: src, fileName: "cps-arg.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "cps-arg.pini")
        let module = try parser.parseModule()

        let out = try captureSuspendStdout { interp in
            try interp.runSuspendable(module: module)
        }
        XCTAssertEqual(out.filter { $0 == "before" }.count, 1, "before 应恰打印 1 次：实际=\(out)")
        XCTAssertEqual(out.filter { $0 == "ok(7)" }.count, 1, "ok(7) 应恰打印 1 次（挂起后不重跑 print）：实际=\(out)")
        XCTAssertEqual(out.filter { $0 == "after" }.count, 1, "after 应恰打印 1 次：实际=\(out)")
    }

    /// 意图：**函数调用链挂起**——`outer` 同步调用 `inner`，`inner` 内部 `<=` 挂起；
    /// 恢复后 `outer` 继续（不重跑已执行的 "outer-1"），`inner` 从挂起点精确续跑。
    /// 这是「同步子调用内部挂起」的验收标准（语句重跑模型会重跑整个 `inner()` 与 outer 语句）。
    func testSyncCallChainSuspendResumesExactly() throws {
        let src = """
        leaf|func() => (I32,)
            sleep(20)
            return ok(5)

        inner|func() -> (I32,)
            var l = leaf()
            var r = wait l
            return r

        outer|func() => (I32,)
            print("outer-1")
            var v = inner()
            print("outer-2")
            return v

        main|func() => (I32,)
            var r = await outer()
            print(r)
            return ok(0)
        """
        let lexer = Lexer(source: src, fileName: "cps-chain.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "cps-chain.pini")
        let module = try parser.parseModule()

        let out = try captureSuspendStdout { interp in
            try interp.runSuspendable(module: module)
        }
        XCTAssertEqual(out.filter { $0 == "outer-1" }.count, 1, "outer 已执行语句不得重跑：实际=\(out)")
        XCTAssertEqual(out.filter { $0 == "outer-2" }.count, 1, "inner 挂起恢复后 outer 应继续执行：实际=\(out)")
        XCTAssertEqual(out.filter { $0 == "ok(5)" }.count, 1, "调用链结果应精确传递：实际=\(out)")
    }

    // MARK: - B-4 完整版：严格 work-stealing + 「不 resume」背压

    /// 意图：**work-stealing 确实发生**——main（占住 worker0）spawn 5 个子任务（入其本地队列）
    /// 后 sleep 400ms；worker1 空闲，必须**窃取** worker0 本地队列的任务才能推进。
    /// 若窃取未实现（单队列/各取各的），子任务会等 worker0 睡完才执行，或直接不执行。
    func testWorkStealingOccurs() throws {
        let src = """
        child|func() => (I32,)
            sleep(10)
            return ok(1)

        main|func() => (I32,)
            var c1 = child()
            var c2 = child()
            var c3 = child()
            var c4 = child()
            var c5 = child()
            sleep(400)
            return ok(0)
        """
        let lexer = Lexer(source: src, fileName: "steal.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "steal.pini")
        let module = try parser.parseModule()

        let scheduler = SuspendScheduler(poolSize: 2)
        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = scheduler
        let fut = try interp.runSuspendable(module: module)

        let exp = expectation(description: "main resolved")
        var resolved: Value?
        fut.whenResolved { r in
            if case .success(let v) = r { resolved = v }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        XCTAssertNotNil(resolved, "main 应完成（子任务被空闲线程窃取执行，未被父返回取消）")
        XCTAssertGreaterThan(
            scheduler.stealCount, 0,
            "空闲线程应窃取其他 worker 本地队列任务（worker1 窃取 worker0 的 5 个子任务）"
        )
    }

    /// 意图：**「不 resume」背压生效**——`maxPending=8` 下派发 1000 个任务（每个 2ms），
    /// 观测在途任务数（`activeTaskCount`）峰值 ≤ 8。背压不阻塞调用方（spawn 立即返回），
    /// 超出的任务留在待调度池，任务完成腾出预算后按序调度。
    func testBackpressureBoundsInflight() throws {
        let maxPending = 8
        let scheduler = SuspendScheduler(poolSize: 2, maxPending: maxPending)
        let n = 1000
        let exp = expectation(description: "all tasks done")
        exp.expectedFulfillmentCount = n

        var done = false
        let lock = NSLock()
        var peak = 0

        // 观测线程：采样 inflight 峰值。
        let sampler = Thread {
            while true {
                lock.lock()
                let d = done
                lock.unlock()
                if d { return }
                let c = scheduler.activeTaskCount
                lock.lock()
                if c > peak { peak = c }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        sampler.start()

        for _ in 0..<n {
            let f = FutureValue()
            scheduler.spawn(f) {
                Thread.sleep(forTimeInterval: 0.002)
                f.resolve(.null)
                return .null
            }
            f.whenResolved { _ in exp.fulfill() }
        }
        wait(for: [exp], timeout: 30)

        lock.lock()
        done = true
        let p = peak
        lock.unlock()

        XCTAssertLessThanOrEqual(
            p, maxPending,
            "「不 resume」背压应把在途任务数限制在 maxPending=\(maxPending)：实际峰值=\(p)"
        )
    }

    // MARK: - 助手

    /// 挂起模式运行 + 捕获 stdout（逐行）。interp 在本函数内保持存活（挂起续体弱引用解释器）。
    private func captureSuspendStdout(_ body: (Interpreter) throws -> FutureValue) throws -> [String] {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interp = Interpreter()
        interp.suspendMode = true
        interp.scheduler = SuspendScheduler(poolSize: 4)
        let fut = try body(interp)

        let exp = expectation(description: "resolved")
        fut.whenResolved { _ in exp.fulfill() }
        wait(for: [exp], timeout: 10)

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.split(separator: "\n").map(String.init)
    }
}
