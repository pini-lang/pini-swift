import XCTest
@testable import PiniCore
import Foundation

/// 结构化取消基座（立场 B 12：统一 `Future` 树 = 派发树 = 取消树）。
///
/// 覆盖三层：
/// 1. `FutureValue` 单元——取消标志 / 递归传播 / 打断阻塞中的 `wait()` / 取消优先于迟到结果；
/// 2. 语言层——`t.cancel()` 成员调用、join 取消任务得 `err(CancelError)`；
/// 3. 判别——内建谓词 `isCancel(e)` 区分「被取消」与「业务错误」（Q5 表示法 A）。
final class CancellationTests: XCTestCase {

    // MARK: - FutureValue 单元：取消标志与递归传播

    /// 意图：取消后 `wait()` 立即以 taskCancelled 结束，不再阻塞等待结果。
    func testCancelMakesWaitThrowCancelled() {
        let fut = FutureValue()
        XCTAssertFalse(fut.isCancelled)
        fut.cancel()
        XCTAssertTrue(fut.isCancelled)
        XCTAssertThrowsError(try fut.wait()) { error in
            guard case RuntimeError.taskCancelled = error else {
                return XCTFail("取消后 wait 应抛 taskCancelled，实际: \(error)")
            }
        }
    }

    /// 意图：取消沿 parent → children 递归下发，整棵子树一并停止（「层层下发」本意）。
    /// 推进性测量：取消祖父后，子与孙均为 cancelled。
    func testCancelPropagatesRecursivelyToDescendants() {
        let root = FutureValue()
        let child = FutureValue()
        let grandchild = FutureValue()
        root.addChild(child)
        child.addChild(grandchild)

        XCTAssertEqual(child.parent === root, true, "addChild 应建立父链接")
        XCTAssertEqual(grandchild.parent === child, true)

        root.cancel()
        XCTAssertTrue(root.isCancelled)
        XCTAssertTrue(child.isCancelled, "子任务应被递归取消")
        XCTAssertTrue(grandchild.isCancelled, "孙任务应被递归取消")
    }

    /// 意图：父已取消后再登记的子任务立即被取消——避免「取消后仍有新任务漏网」。
    func testAddChildAfterCancelCancelsImmediately() {
        let root = FutureValue()
        root.cancel()
        let late = FutureValue()
        root.addChild(late)
        XCTAssertTrue(late.isCancelled, "父已取消时新登记的子任务应立即取消")
    }

    /// 意图：取消可打入**阻塞中**的 join——否则 `wait t` 会一直挂到任务自然结束，取消形同虚设。
    /// 推进性测量：cancel 后 wait 在 2s 内返回（任务体自身要跑 5s）。
    func testCancelUnblocksPendingWait() {
        let fut = FutureValue()
        GCDScheduler.shared.spawn(fut) {
            Thread.sleep(forTimeInterval: 5)
            return Value.int(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { fut.cancel() }

        let started = Date()
        XCTAssertThrowsError(try fut.wait())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2.0, "取消应立即唤醒阻塞的 wait，实际耗时 \(elapsed)s")
    }

    /// 意图：取消优先于迟到的结果——worker 在检查点之前已算完并 resolve 时，
    /// join 仍恒得取消错误，保证「取消后结果确定」而非按线程时序竞态。
    func testCancelTakesPrecedenceOverLateResolve() {
        let fut = FutureValue()
        fut.cancel()
        fut.resolve(.int(7))
        XCTAssertThrowsError(try fut.wait()) { error in
            guard case RuntimeError.taskCancelled = error else {
                return XCTFail("取消应优先于迟到 resolve，实际: \(error)")
            }
        }
    }

    // MARK: - 语言层：t.cancel() 与 err(CancelError)

    /// 意图：`t.cancel()` 后 join 该任务得到 `err`，且 `isCancel(e)` 为真。
    /// 推进性测量：输出精确为 "true"。
    func testCancelledTaskJoinsAsCancelError() throws {
        let source = try loadPiniFixture("testCancelledTaskJoinsAsCancelError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    /// 意图：取消错误自带可读 message，与业务错误共享 `.message` 读取形态。
    /// 推进性测量：输出精确为 "任务已被取消"。
    func testCancelErrorCarriesReadableMessage() throws {
        let source = try loadPiniFixture("testCancelErrorCarriesReadableMessage", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "任务已被取消")
    }

    /// 意图：业务错误不得被误判为取消——`isCancel` 必须按类型判别而非「凡 err 皆取消」。
    /// 推进性测量：输出精确为 "false\n业务失败"。
    func testBusinessErrorIsNotCancel() throws {
        let source = try loadPiniFixture("testBusinessErrorIsNotCancel", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "false\n业务失败")
    }

    /// 意图：`CancelError("...")` 可由用户显式构造并放入 `err(...)`——
    /// 证明类型层把它当作 `Error` 位置的合法值（白名单子类型），而非只在运行时能用。
    /// 推进性测量：静态检查零错误，且运行时输出 "true"。
    func testUserConstructedCancelErrorIsAcceptedWhereErrorExpected() throws {
        let source = try loadPiniFixture("testUserConstructedCancelErrorIsAcceptedWhereErrorExpected", filePath: #filePath)
        XCTAssertTrue(checkCollecting(source).isEmpty,
                      "CancelError 应可出现在期望 Error 的位置；实际: \(checkCollecting(source))")
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    // MARK: - 静态层：cancel / isCancel 签名登记

    /// 意图：`t.cancel()` 是 Future 的已知成员，不得报 unknownMember；
    /// 且 `isCancel(e)` 返回 Bool（可直接用于条件）。
    func testCancelAndIsCancelAreStaticallyKnown() throws {
        let source = try loadPiniFixture("testCancelAndIsCancelAreStaticallyKnown", filePath: #filePath)
        XCTAssertTrue(checkCollecting(source).isEmpty,
                      "cancel/isCancel 应已在类型层登记；实际: \(checkCollecting(source))")
    }

    // MARK: - Helpers

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
