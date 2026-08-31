import XCTest
import PiniCore
import Foundation

/// 调用深度护栏测试
/// 意图：无限递归以可诊断错误终止，而非进程崩溃（探针信度承重，见自举缺口 G-P9 证据）
final class StackGuardTests: XCTestCase {
    /// 意图：无限递归触发深度护栏，抛出 invalidOperation 而非 SIGSEGV
    /// 推进性测量：抛出 RuntimeError.invalidOperation 且原因含「调用深度」
    /// 驳回性测量：其他错误类型或无错误均不合格
    func testInfiniteRecursionRaisesDepthGuard() throws {
        let source = try loadPiniFixture("testInfiniteRecursionRaisesDepthGuard", filePath: #filePath)
        XCTAssertThrowsError(try runSource(source)) { error in
            guard case RuntimeError.invalidOperation(let reason, _) = error else {
                return XCTFail("expected invalidOperation, got \(error)")
            }
            XCTAssertTrue(reason.contains("调用深度"), reason)
        }
    }

    /// 意图：正常深度的合法递归不受护栏影响
    /// 推进性测量：递归 60 层的求和照常完成
    /// 驳回性测量：护栏误伤合法递归（抛错或结果错误）均不合格
    func testNormalRecursionStillWorks() throws {
        let source = try loadPiniFixture("testNormalRecursionStillWorks", filePath: #filePath)
        let out = try runSource(source)
        XCTAssertTrue(out.contains("1830"), out)
    }

    /// stdout 捕获助手。EOF 纪律：读取前必须先恢复 fd 1 并关闭管道写端，
    /// 否则 fd 1 持有的写端副本让 readDataToEndOfFile 永远等不到 EOF（死锁）。
    private func runSource(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "stackguard.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "stackguard.pini")
        let module = try parser.parseModule()
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        var thrown: Error? = nil
        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let e = thrown {
            throw e
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
