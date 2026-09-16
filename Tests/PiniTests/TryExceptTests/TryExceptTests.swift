import XCTest
import PiniCore
import Foundation

/// ADR-032 迁移批 M2：try-else（Result-only，spec『try-else 错误传播』节）语义测试。
/// 原 try/except 元组错误位模型测试已随迁移改写；`^` 右值糖为定义性脱糖
/// （`^e` ≡ `try e else err: return err`），其行为面在本文件末尾锁定。
final class TryExceptTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "try_test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "try_test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = ProgramRunner()
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

    /// 意图：try-else 表达式位 ok 路径求值为 Result 载荷（`try ok(5) else e: return` → 5）
    func testTryOkYieldsPayload() throws {
        let source = try loadPiniFixture("testTryOkYieldsPayload", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "5",
                       "ok 路径应输出载荷 5")
    }

    /// 意图：ok 路径跳过 handler，顺序执行后续语句（result = 1）
    func testTryOkSkipsHandler() throws {
        let source = try loadPiniFixture("testTryOkSkipsHandler", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1",
                       "ok 路径不应进入 handler")
    }

    /// 意图：err 路径经 handler 控制流转移（return），成功路径语句不执行
    func testTryErrSkipsSuccessPath() throws {
        let source = try loadPiniFixture("testTryErrSkipsSuccessPath", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "err 路径经 handler return，print 不应执行")
    }

    /// 意图：err("") 也是 err——Result 语义无「空串视为成功」特判（旧元组模型行为退役）
    func testTryErrEmptyStringStillError() throws {
        let source = try loadPiniFixture("testTryErrEmptyStringStillError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "handler",
                       "err(\"\") 应进入 handler（无空串特判）")
    }

    /// 意图：handler 内 errorVar 绑定到错误值（print(e) 输出 "my error msg"）
    func testHandlerErrorVarBinding() throws {
        let source = try loadPiniFixture("testHandlerErrorVarBinding", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "my error msg",
                       "errorVar 应绑定到错误值")
    }

    /// 意图：单行 handler `pass`（仅语句位）显式吞掉错误后继续执行后续语句
    func testPassSwallowsError() throws {
        let source = try loadPiniFixture("testPassSwallowsError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "after",
                       "pass 吞错后应继续执行")
    }

    /// 意图：`^ok(7)` 脱糖后 ok 路径求值载荷 7
    func testCaretOkYieldsPayload() throws {
        let source = try loadPiniFixture("testCaretOkYieldsPayload", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "7",
                       "^ok(7) 应输出 7")
    }

    /// 意图：`^err(9)` 脱糖后 err 分支经 handler `return err` 把错误值作为函数返回值带出
    /// （替代旧 UnwrapErrSignal 注入返回元组末槽）
    func testCaretErrReturnsFromFunction() throws {
        let source = try loadPiniFixture("testCaretErrReturnsFromFunction", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("9"), "^err(9) 应使 caller 返回 9（got: \(output)）")
    }
}
