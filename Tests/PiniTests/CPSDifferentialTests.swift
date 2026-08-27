import XCTest
@testable import PiniCore
import Foundation

/// 同步/CPS 差分测试：同一 `.pini` 程序分别经**同步路径**（`suspendMode=false`，`<=` 阻塞 join，
/// `GCDScheduler`）与**CPS 挂起路径**（`suspendMode=true` + `SuspendScheduler`，`<=` 释放线程）
/// 执行，断言 stdout **逐字节一致**——这是两路径逐语义对齐的验收（探针边界收窄后的回归护栏）。
final class CPSDifferentialTests: XCTestCase {

    /// 跑一遍并捕获 stdout（`cps: true` 走挂起路径，否则走同步路径）。
    private func runCapture(_ source: String, cps: Bool) throws -> String {
        let lexer = Lexer(source: source, fileName: "diff.pini")
        let parser = Parser(tokens: try lexer.tokenize(), fileName: "diff.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        if cps {
            let interp = Interpreter()
            interp.suspendMode = true
            interp.scheduler = SuspendScheduler(poolSize: 4)
            let fut = try interp.runSuspendable(module: module)
            let exp = expectation(description: "cps done")
            fut.whenResolved { _ in exp.fulfill() }
            wait(for: [exp], timeout: 15)
        } else {
            let interp = Interpreter()
            try interp.run(module: module)
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func assertSyncCPSMatch(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let syncOut = try runCapture(source, cps: false)
        let cpsOut = try runCapture(source, cps: true)
        XCTAssertEqual(
            syncOut, cpsOut,
            "同步输出=\(syncOut.debugDescription)\nCPS 输出=\(cpsOut.debugDescription)",
            file: file, line: line
        )
    }

    // MARK: - 基础 join

    /// 意图：基础 `<=` join——同一程序同步/CPS 双跑 stdout 逐字节一致（挂起语义对齐基线；
    /// 推进性：两路径均产出；驳回性：任一路径输出漂移即失败）。
    func testDiffBasicJoin() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            var r = await child()
            print(r)
            return ok(0)
        """)
    }

    /// 意图：`<=` 出现在 call 实参内部（`print(await child())`）——两路径一致（CPS 副作用
    /// 不重跑的对齐验证：若 CPS 重跑语句会重复打印，差分必然失败）。
    func testDiffJoinInsideCallArg() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            print("before")
            print(await child())
            print("after")
            return ok(0)
        """)
    }

    /// 意图：outer→inner（体内 `<=`）→leaf 调用链挂起——两路径一致（CPS 精确恢复、不重跑
    /// outer 已执行语句的对齐验证）。
    func testDiffCallChain() throws {
        try assertSyncCPSMatch("""
        leaf|func() => (I32,)
            sleep(10)
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
        """)
    }

    /// 意图：joinAll 聚合挂起——两路径一致（joinAll 显式 resolve 的调度器无关性验证：
    /// SuspendScheduler 下聚合若依赖「返回即 resolve」会永不 resolve，差分必然失败）。
    func testDiffJoinAll() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(1)

        main|func() => (I32,)
            var c1 = child()
            var c2 = child()
            var r = await joinAll([c1, c2])
            print(r)
            return ok(0)
        """)
    }

    // MARK: - 控制流内挂起（探针边界收窄）

    /// 意图：if 块体内 `<=` 挂起——两路径一致（CPS 在控制流分支内挂起/恢复的对齐验证）。
    func testDiffIfBodyJoin() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            if true:
                var r = await child()
                print(r)
            return ok(0)
        """)
    }

    /// 意图：while 循环体内 `<=` 挂起（多轮迭代）——两路径一致（CPS 循环帧跨迭代持久、
    /// 条件重估/step 语义的对齐验证）。
    func testDiffWhileBodyJoin() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            var i = 0
            while i < 2:
                var r = await child()
                print(r)
                i = i + 1
            return ok(0)
        """)
    }

    /// 意图：for-in 循环体内 `<=` 挂起 + `break`——两路径一致（CPS `loopStack` 帧路由
    /// break 的对齐验证：break 若逃逸 driver 会挂起，差分必然失败）。
    func testDiffForBodyJoinWithBreak() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            for (v,) in [1, 2, 3, 4]:
                var r = await child()
                print(v, r)
                if v == 2:
                    break
            return ok(0)
        """)
    }

    /// 意图：match 的 scrutinee 内 `<=`（`match (await child()):`）——两路径一致（CPS 在 match
    /// 值表达式内挂起的对齐验证）。
    func testDiffMatchJoinInValue() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            match (await child()):
                case ok(v):
                    print("ok", v)
                case err(e):
                    print("err")
            return ok(0)
        """)
    }

    /// 意图：match case 块体内 `<=` 挂起——两路径一致（CPS 在 caseEnv 内挂起/恢复的
    /// 对齐验证）。
    func testDiffMatchJoinInBody() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            match ok(1):
                case ok(v):
                    var r = await child()
                    print(v, r)
                case err(e):
                    print("err")
            return ok(0)
        """)
    }

    /// 意图：try 表达式内 `<=`（成功路径）——两路径一致（CPS 在 try 表达式内挂起的对齐验证）。
    func testDiffTryJoinInExpression() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32, String,)
            return (0, "",)

        main|func() => (I32,)
            try (await child()):
                print("try-ok")
            except e:
                print("except:", e)
            return ok(0)
        """)
    }

    /// 意图：try 表达式内 `<=`（错误路径，走 `except` 分支）——两路径一致（CPS 错误元组
    /// 提取与 except 分支的对齐验证）。
    func testDiffTryJoinInExpressionErrorPath() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32, String,)
            return (0, "boom",)

        main|func() => (I32,)
            try (await child()):
                print("try-ok")
            except e:
                print("except:", e)
            return ok(0)
        """)
    }

    // MARK: - labeled 实参 / 方法调用 / defer

    /// 意图：labeled 实参重排后调用（`add(b: 20, a: 22)`）——两路径一致（CPS `dispatchCallK`
    /// 复用同步重排逻辑的对齐验证）。
    func testDiffLabeledArgs() throws {
        try assertSyncCPSMatch("""
        add|func(a: I32, b: I32) -> (I32,)
            return a + b

        main|func() => (I32,)
            var r = add(b: 20, a: 22)
            print(r)
            return ok(0)
        """)
    }

    /// 意图：`<=` join 后继续执行成员方法调用（`s.upper()`）——两路径一致（CPS 恢复后
    /// 成员分派语义的对齐验证）。
    func testDiffMemberMethodAfterJoin() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            var r = await child()
            var s = "hello"
            print(s.upper())
            print(r)
            return ok(0)
        """)
    }

    /// 意图：函数体级 `defer` + 挂起 + return——两路径一致（CPS 下 defer 在 return 边界
    /// 执行、不影响返回值的对齐验证）。
    func testDiffDefer() throws {
        try assertSyncCPSMatch("""
        child|func() => (I32,)
            sleep(10)
            return ok(7)

        main|func() => (I32,)
            defer print("cleanup")
            var r = await child()
            print(r)
            return ok(0)
        """)
    }
}
