import XCTest
@testable import PiniCore
import Foundation

/// （Q5·超时）：带超时的阻塞 join 内建 `joinWithin(t, ms) -> Result<T, Error>`。
///
/// 决策记录：超时刻意做成**内建函数**而非 `<= t within Ms` 语法糖——超时属库能力，
/// 不值得占用语法预算（用户拍板）。语义上「超时归约到取消」：到点即 `t.cancel()`，
/// 返回 `err(CancelError("任务超时: Nms"))`，故 `isCancel(e)` 对超时与手动取消同为 true。
final class JoinWithinTests: XCTestCase {

    /// 意图：期限内完成时，`joinWithin` 与 `<=` 结果完全一致（超时机制不干扰正常路径）。
    func testJoinWithinReturnsResultWhenTaskFinishesInTime() throws {
        let source = try loadPiniFixture("testJoinWithinReturnsResultWhenTaskFinishesInTime", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("7"), "期限内完成应原样返回结果，实际输出: \(output)")
        XCTAssertFalse(output.contains("不应超时"))
    }

    /// 意图：超时归约为取消——返回 `err(CancelError)`，且 `isCancel(e)` 为 true、消息含时限。
    /// 推进性测量：任务自然耗时 3s，100ms 超时应立即返回（整体 < 1.5s）。
    func testJoinWithinTimesOutAsCancelError() throws {
        let source = try loadPiniFixture("testJoinWithinTimesOutAsCancelError", filePath: #filePath)
        let start = Date()
        let output = try runProgram(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("超时:"), "超时应归约为 err(CancelError)，实际输出: \(output)")
        XCTAssertTrue(output.contains("100ms"), "取消消息应携带时限，便于定位，实际输出: \(output)")
        XCTAssertLessThan(elapsed, 1.5, "超时应在时限到点即返回，而非等任务自然结束")
    }

    /// 意图：超时不只是「放弃等待」，还必须真正取消任务（否则线程池被无人等待的任务占满）。
    /// 推进性测量：超时后再等 300ms，任务尾部打印不得出现。
    func testJoinWithinCancelsTimedOutTask() throws {
        let source = try loadPiniFixture("testJoinWithinCancelsTimedOutTask", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("超时"))
        XCTAssertFalse(output.contains("任务不该跑完"), "超时应连带取消任务，实际输出: \(output)")
    }

    /// 意图：任务自身失败时，`joinWithin` 透传业务错误而非伪装成超时——两类错误必须可区分。
    func testJoinWithinPropagatesBusinessErrorNotCancel() throws {
        let source = try loadPiniFixture("testJoinWithinPropagatesBusinessErrorNotCancel", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("业务失败"), "业务错误应原样透传，实际输出: \(output)")
        XCTAssertFalse(output.contains("误判为取消"), "业务错误不得被当作取消")
    }

    /// 意图：`joinWithin` 可与 `joinAll` 组合——给聚合任务加总时限（常见「整批限时」诉求）。
    func testJoinWithinComposesWithJoinAll() throws {
        let source = try loadPiniFixture("testJoinWithinComposesWithJoinAll", filePath: #filePath)
        let start = Date()
        let output = try runProgram(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("批量超时"), "聚合任务应可加总时限，实际输出: \(output)")
        XCTAssertLessThan(elapsed, 1.5)
    }

    /// 意图：`joinWithin` 在语义层与类型层均已登记，且返回类型为 `Result<_, Error>`（可直接 match）。
    func testJoinWithinIsStaticallyKnown() throws {
        let source = try loadPiniFixture("testJoinWithinIsStaticallyKnown", filePath: #filePath)
        XCTAssertTrue(checkCollecting(source).isEmpty,
                      "joinWithin 应已在类型层登记；实际: \(checkCollecting(source))")
    }

    /// 意图：第一个实参必须是 Future——非 Future 在运行时被明确拒绝。
    func testJoinWithinRejectsNonFuture() throws {
        let source = try loadPiniFixture("testJoinWithinRejectsNonFuture", filePath: #filePath)
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.typeMismatch = error else {
                return XCTFail("非 Future 实参应报类型不匹配，实际: \(error)")
            }
        }
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
