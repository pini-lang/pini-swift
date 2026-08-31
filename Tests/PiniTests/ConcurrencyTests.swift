import XCTest
@testable import PiniCore
import Foundation

/// 并发基座验证（立场 B 形态，契约见 Pini草稿.md（异步函数块））。
/// 断言 `=>` 函数体在 worker 线程异步执行、调用方立即拿到 pending Future、
/// `<=` 前缀 join 阻塞至完成并返回 `Result<T, Error>`（错误即数据，不抛出）。
final class ConcurrencyTests: XCTestCase {

    // MARK: - Scheduler / FutureValue 单元（直接证明「real async」）

    /// 意图：Scheduler.spawn 后 Future 立即处于 pending（真实异步而非同步 resolve），wait 阻塞至体完成并返回 .int(42)——直接证明「real async」调度语义。
    func testSchedulerSpawnReturnsPendingThenResolves() throws {
        let fut = FutureValue()
        var ran = false
        GCDScheduler.shared.spawn(fut) {
            Thread.sleep(forTimeInterval: 0.05)
            ran = true
            return Value.int(42)
        }
        // 调用返回后应处于 pending（体尚未完成）——这是真实异步的核心证据
        XCTAssertFalse(fut.isResolved, "spawn 后 Future 应处于 pending（真实异步，非立即 resolve）")
        let v = try fut.wait()
        XCTAssertTrue(ran, "wait 返回前体应已执行")
        XCTAssertEqual(v, .int(42))
    }

    /// 意图：FutureValue.reject 后 Future 转为已决且 error 携带原因（错误即数据）——验证拒绝原因可经 reject 路径向等待方传播。
    func testFutureValueRejectPropagatesError() {
        let fut = FutureValue()
        let err = RuntimeError.invalidOperation(reason: "boom", location: SourceLocation(line: 0, column: 0, fileName: ""))
        fut.reject(err)
        XCTAssertTrue(fut.isResolved)
        XCTAssertNotNil(fut.error)
    }

    // MARK: - 解释器：`=>` 派发 + `<=` join 求值

    /// 意图：`=>` 函数体 `return ok(v)` 后，`<=` join 得到 `ok(99)`，match 取回 99。
    /// 推进性测量：输出精确为 "99"。
    func testAsyncFuncViaJoinGetsValue() throws {
        let source = try loadPiniFixture("testAsyncFuncViaJoinGetsValue", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "99")
    }

    /// 意图：`return err(Error("..."))` 以数据形式抵达调用方（无异常、无 catch）。
    /// 推进性测量：输出精确为 "失败: 网络超时"。
    func testErrIsDeliveredAsData() throws {
        let source = try loadPiniFixture("testErrIsDeliveredAsData", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "失败: 网络超时")
    }

    /// 意图：异步体内抛出的运行时错误（除零）不逃逸为异常，而归约为 `err(Error(...))`。
    /// 推进性测量：进入 err 分支且错误文本含「除以零」。
    func testRuntimeErrorInAsyncBodyBecomesErrValue() throws {
        let source = try loadPiniFixture("testRuntimeErrorInAsyncBodyBecomesErrValue", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(
            output.contains("除以零"),
            "异步体内运行时错误应归约为 err(Error(...))，实际输出: \(output)"
        )
    }

    /// 意图：`<=` 作用于非 Future 值应在类型层被拒（契约 3.3 收紧了早期 await 的透传行为）。
    /// 推进性测量：checkCollecting 报出期望 Future<T, Error> 的 mismatch。
    func testJoinOnNonFutureIsTypeError() throws {
        let source = try loadPiniFixture("testJoinOnNonFutureIsTypeError", filePath: #filePath)
        let diagnostics = checkCollecting(source)
        let hasMismatch = diagnostics.contains { diag in
            if case TypeError.mismatch(let expected, _, _) = diag {
                return expected.contains("Future")
            }
            return false
        }
        XCTAssertTrue(hasMismatch, "对非 Future 值 join 应报类型错误，实际诊断: \(diagnostics)")
    }

    /// 意图：`=>` 匿名函数的返回值（非 Result）经 join 自动归一为 ok。
    /// 推进性测量：输出精确为 "77"。
    func testAsyncFuncLiteralViaJoin() throws {
        let source = try loadPiniFixture("testAsyncFuncLiteralViaJoin", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "77")
    }

    /// 意图：连续两次 join，后一个任务消费前一个的结果。
    /// 推进性测量：输出精确为 "2"。
    func testChainedJoinExpressions() throws {
        let source = try loadPiniFixture("testChainedJoinExpressions", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    /// 意图：多个 `=>` 任务各自 join，结果互不串扰。
    /// 推进性测量：输出精确为 "10\n20"。
    func testAsyncFuncMultipleReturns() throws {
        let source = try loadPiniFixture("testAsyncFuncMultipleReturns", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok(10)\nok(20)")
    }

    /// 意图：`=>` 体内部再 join 另一个 `=>` 任务（嵌套并发），外层 join 得到最终值。
    /// 推进性测量：输出精确为 "11"。
    func testAsyncFuncNestedCall() throws {
        let source = try loadPiniFixture("testAsyncFuncNestedCall", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "11")
    }

    /// 意图：`=> ()` 无值并发进程可被 join（结果归一为 ok(null)），语句位裸 join 合法。
    /// 推进性测量：输出精确为 "hi"。
    func testAsyncFuncReturnWithoutValue() throws {
        let source = try loadPiniFixture("testAsyncFuncReturnWithoutValue", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }

    /// 意图（D1 同族竞态回归）：多个 `=>` 任务并发地对同一泛型类型做首次实例化，
    /// 触发 `typeFields`/`typeMethods`/`typeTraits`/`typeDefs` 的懒登记写；修复前此处因共享
    /// Dictionary 并发读写 UB 可间歇性进程级崩溃（信号 4/6/11）。修复后须稳定通过。
    /// 推进性测量：多次运行均输出 "done"。
    func testConcurrentGenericTypeInstantiationIsRaceFree() throws {
        let source = try loadPiniFixture("testConcurrentGenericTypeInstantiationIsRaceFree", filePath: #filePath)
        // 多次运行以放大间歇性竞态的命中概率（修复前约半数运行会进程级崩溃）。
        for _ in 1...30 {
            let output = try runProgram(source)
            XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        }
    }

    /// 意图：sleep 内建可在 worker 线程的异步体内正常阻塞。
    /// 推进性测量：输出精确为 "5"。
    func testSleepBuiltinRunsInsideAsyncBody() throws {
        let source = try loadPiniFixture("testSleepBuiltinRunsInsideAsyncBody", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "5")
    }

    // MARK: - 真并发（交错 + 无死锁 + 状态隔离）

    /// 两个并发任务并行执行（墙钟时间显著小于串行之和）→ 证明真并发而非「末尾才并行」。
    /// 意图：两个 sleep(60) 的 `=>` 任务并发执行（墙钟 <110ms，显著小于串行 ≈120ms）证明真并发；join 后各得 ok(1)。
    func testConcurrentTasksOverlapInTime() throws {
        let source = try loadPiniFixture("testConcurrentTasksOverlapInTime", filePath: #filePath)
        let start = Date()
        let output = try runProgramWithTimeout(source)
        let elapsed = Date().timeIntervalSince(start)
        // 两个 60ms 任务若串行 ≈120ms；真并发 ≈60ms。留足余量（<110ms）判定并发。
        XCTAssertLessThan(elapsed, 0.11, "两个并发任务应重叠执行（墙钟 < 110ms），实测 \(elapsed)s 表明疑似串行")
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok(1)\nok(1)")
    }

    /// 两个并发任务各自产出独立结果，join 后值正确 —— 证明 currentEnv 线程本地隔离、无状态污染。
    /// 意图：并发任务各自维护独立局部状态（make(100)=4950、make(7)=21 互不串扰）——证明 currentEnv 线程本地隔离、无状态污染。
    func testConcurrentTasksNoStateCorruption() throws {
        let source = try loadPiniFixture("testConcurrentTasksNoStateCorruption", filePath: #filePath)
        let output = try runProgramWithTimeout(source)
        // make(100) = 0+1+…+99 = 4950；make(7) = 0+…+6 = 21
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "ok(4950)\nok(21)")
    }

    /// 无死锁硬验收：并发程序必须在超时内完成，否则测试失败（而非挂起整个套件）。
    /// 意图：并发 join 必须无死锁——ping/pong 两任务在 8s 超时内完成并输出 ok(10)/ok(20)，超时即测试失败而非挂起套件。
    func testNoDeadlockWithConcurrentJoin() throws {
        let source = try loadPiniFixture("testNoDeadlockWithConcurrentJoin", filePath: #filePath)
        let out = try runProgramWithTimeout(source, timeout: 8)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "ok(10)\nok(20)")
    }

    // MARK: - 符号消歧回归护栏（`<=` 前缀 join 不得破坏中缀比较）

    /// 意图：同一程序内 `<=` 既作中缀比较又作前缀 join，二者互不干扰。
    /// 推进性测量：输出精确为 "true\nok(3)"。
    func testJoinAndComparisonCoexist() throws {
        let source = try loadPiniFixture("testJoinAndComparisonCoexist", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "true\nok(3)")
    }

    // MARK: - 静态精度：`Result<T, Error>` 类型下推

    /// 意图：`match (wait fut)` 的 `case ok(v)` 中，`v` 精确得到 payload 类型（此处 I32），
    /// 而非退化为 Any / 未知——否则错误即数据的 ok 分支将失去静态保护。
    /// 推进性测量：`v + "abc"` 报 mismatch(expected: I32, got: String)。
    func testMatchOkBindingCarriesPayloadType() throws {
        let source = try loadPiniFixture("testMatchOkBindingCarriesPayloadType", filePath: #filePath)
        let errors = checkCollecting(source)
        XCTAssertTrue(
            errors.contains { "\($0)".contains("I32") && "\($0)".contains("String") },
            "ok(v) 绑定应带 payload 类型 I32，与 String 相加须报错；实际: \(errors)"
        )
    }

    /// 意图：`case err(e)` 中 `e` 为内建 `Error` 类型，其 `message` 字段可读且为 String。
    /// 推进性测量：`"失败: " + e.message` 静态无错（与 testErrIsDeliveredAsData 的运行时结果互证）。
    func testMatchErrBindingIsBuiltinErrorType() throws {
        let source = try loadPiniFixture("testMatchErrBindingIsBuiltinErrorType", filePath: #filePath)
        XCTAssertTrue(checkCollecting(source).isEmpty,
                      "err(e) 绑定应为内建 Error（message: String），拼接不应报错")
    }

    /// 意图：`=>` 函数体内 `return ok(...)` 的实参须与声明 payload 类型一致——
    /// 期望类型下推不得退化为「只要是 Result 用例就放行」。
    /// 推进性测量：`=> (I32,)` 函数中 `return ok("x")` 报 mismatch。
    func testAsyncBodyOkPayloadTypeIsEnforced() throws {
        let source = try loadPiniFixture("testAsyncBodyOkPayloadTypeIsEnforced", filePath: #filePath)
        let errors = checkCollecting(source)
        XCTAssertTrue(
            errors.contains { "\($0)".contains("I32") && "\($0)".contains("String") },
            "ok(\"x\") 应与 payload I32 冲突；实际: \(errors)"
        )
    }

    /// 意图：`err(...)` 的实参须为错误类型；传入非 Error 值应被静态拦截。
    /// 推进性测量：`return err(42)` 报 mismatch(expected: Error, got: I32)。
    func testAsyncBodyErrPayloadTypeIsEnforced() throws {
        let source = try loadPiniFixture("testAsyncBodyErrPayloadTypeIsEnforced", filePath: #filePath)
        let errors = checkCollecting(source)
        XCTAssertTrue(
            errors.contains { "\($0)".contains("Error") && "\($0)".contains("I32") },
            "err(42) 应与错误类型 Error 冲突；实际: \(errors)"
        )
    }

    // MARK: - Helpers

    /// 在后台线程运行程序并在超时内等待完成；超时则抛出（证明无死锁，避免测试套件挂起）。
    private func runProgramWithTimeout(_ source: String, timeout: TimeInterval = 10) throws -> String {
        var captured: String?
        var capturedErr: Error?
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            do { captured = try self.runProgram(source) }
            catch { capturedErr = error }
            group.leave()
        }
        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            throw NSError(
                domain: "ConcurrencyTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "程序在 \(timeout)s 内未完成（疑似死锁）"]
            )
        }
        if let err = capturedErr { throw err }
        return captured ?? ""
    }

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
