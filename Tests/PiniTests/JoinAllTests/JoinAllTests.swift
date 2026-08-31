import XCTest
@testable import PiniCore
import Foundation

/// （Q3）：多任务汇合内建 `joinAll([...])` → `Future<[T], Error>`。
///
/// 契约依据 `Pini草稿.md（异步函数块）` 3.6 / 5：
/// `joinAll(xs)` ⇒ `xs : [Future<T, Error>]`，结果 `Future<[T], Error>`，再 `<=` 一次完成多任务等待。
///
/// 覆盖：顺序收集 / 真并行 / fail-fast + 取消其余 / 聚合节点取消联动 / 空集 / 静态可见性 / 非法元素。
final class JoinAllTests: XCTestCase {

    /// 意图：全部成功时按**入参顺序**收集结果（而非完成顺序），否则调用方无法按位取用。
    func testJoinAllCollectsResultsInArgumentOrder() throws {
        let source = try loadPiniFixture("testJoinAllCollectsResultsInArgumentOrder", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("[1, 2, 3]"),
                      "结果应按入参顺序而非完成顺序排列，实际输出: \(output)")
    }

    /// 意图：`joinAll` 汇合的是**已在运行**的任务（`=>` 调用即派发），因此总耗时接近最慢者而非累加。
    /// 推进性测量：3 × 150ms 任务，串行需 ~450ms，并行应 < 400ms。
    func testJoinAllWaitsInParallelNotSerially() throws {
        let source = try loadPiniFixture("testJoinAllWaitsInParallelNotSerially", filePath: #filePath)
        let start = Date()
        let output = try runProgram(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("[1, 2, 3]"))
        XCTAssertLessThan(elapsed, 0.4, "joinAll 应等待已并行运行的任务，而非串行叠加耗时")
    }

    /// 意图：fail-fast——任一成员 `err` 即整体 `err`，错误原样透传（错误即数据，不被包装吞掉）。
    func testJoinAllFailsFastWithMemberError() throws {
        let source = try loadPiniFixture("testJoinAllFailsFastWithMemberError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("成员失败"), "成员错误应原样透传给聚合结果，实际输出: \(output)")
        XCTAssertFalse(output.contains("不应成功"))
    }

    /// 意图：某成员失败后，其余仍在跑的成员应被取消——无人等待的任务不该继续烧线程。
    /// 推进性测量：慢成员自然耗时 3s，整体应在 3s 内结束且其尾部打印不出现。
    func testJoinAllCancelsRemainingMembersAfterFailure() throws {
        let source = try loadPiniFixture("testJoinAllCancelsRemainingMembersAfterFailure", filePath: #filePath)
        let start = Date()
        let output = try runProgram(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("先失败"))
        XCTAssertFalse(output.contains("慢成员不该跑完"), "fail-fast 后其余成员应被取消，实际输出: \(output)")
        XCTAssertLessThan(elapsed, 3.0)
    }

    /// 意图：取消聚合节点应联动取消全部成员（成员不在聚合的子表中，靠 onCancel 联动），
    /// 且 join 聚合得 `err(CancelError)`。
    func testCancellingAggregateCancelsAllMembers() throws {
        let source = try loadPiniFixture("testCancellingAggregateCancelsAllMembers", filePath: #filePath)
        let start = Date()
        let output = try runProgram(source)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(output.contains("聚合已取消"), "取消聚合应归约为 err(CancelError)，实际输出: \(output)")
        XCTAssertFalse(output.contains("成员不该跑完"), "聚合取消应联动取消全部成员，实际输出: \(output)")
        XCTAssertLessThan(elapsed, 3.0)
    }

    /// 意图：空集合是合法输入，结果为 `ok([])`（边界不特判、不崩溃）。
    func testJoinAllOnEmptyArrayReturnsEmptyOk() throws {
        let source = try loadPiniFixture("testJoinAllOnEmptyArrayReturnsEmptyOk", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("[]"), "空集合应汇合为 ok([])，实际输出: \(output)")
    }

    /// 意图：`joinAll` 在语义层与类型层均已登记——未登记会退化为 undefinedVariable / 未知函数。
    func testJoinAllIsStaticallyKnown() throws {
        let source = try loadPiniFixture("testJoinAllIsStaticallyKnown", filePath: #filePath)
        XCTAssertTrue(checkCollecting(source).isEmpty,
                      "joinAll 应已在类型层登记；实际: \(checkCollecting(source))")
    }

    /// 意图：非 Future 元素在运行时被明确拒绝（类型层因数组元素类型不可推断而放行，运行时兜底）。
    func testJoinAllRejectsNonFutureElements() throws {
        let source = try loadPiniFixture("testJoinAllRejectsNonFutureElements", filePath: #filePath)
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.typeMismatch = error else {
                return XCTFail("非 Future 元素应报类型不匹配，实际: \(error)")
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
