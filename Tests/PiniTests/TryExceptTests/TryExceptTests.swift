import XCTest
import PiniCore
import Foundation

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

    /// 意图：验证函数返回 (值, 错误串) 二元组：无错误时错误串为空，调用方正常拿到值 5
    func testFunctionReturnsNoErrorTuple() throws {
        let source = try loadPiniFixture("testFunctionReturnsNoErrorTuple", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertTrue(output.contains("5"), "Should contain 5")
    }

    /// 意图：验证 try 遇错误（divide(10,0) 返回非空错误串）时跳过主体、进入 except 分支，result 变为 2
    func testTryEntersExceptOnError() throws {
        let source = try loadPiniFixture("testTryEntersExceptOnError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2", "except should run on non-null error")
    }

    /// 意图：验证 try 无错误时执行主体（result = 1）并跳过 except 分支
    func testTrySkipsExceptOnNoError() throws {
        let source = try loadPiniFixture("testTrySkipsExceptOnNoError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1", "try block should run on no error")
    }

    /// 意图：验证空字符串错误视为成功路径：try (42, "",) 执行主体（result = 100），不进入 except
    func testTryWithEmptyStringError() throws {
        let source = try loadPiniFixture("testTryWithEmptyStringError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "100")
    }

    /// 意图：验证非空字符串错误触发错误路径：try (42, "something went wrong",) 进入 except，result 变为 -1
    func testTryEntersExceptOnNonEmptyStringError() throws {
        let source = try loadPiniFixture("testTryEntersExceptOnNonEmptyStringError", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "-1")
    }

    /// 意图：验证 except 变量绑定到错误值：except err 中 print(err) 输出 "my error msg"
    func testExceptVarBinding() throws {
        let source = try loadPiniFixture("testExceptVarBinding", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "my error msg", "except var should bind to the error value")
    }

    /// 意图：验证无 except 子句且无错误时，try 主体正常执行后继续，依次输出 "ok" 与 "after"
    func testNoExceptClauseNoError() throws {
        let source = try loadPiniFixture("testNoExceptClauseNoError", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["ok", "after"])
    }

    /// 意图：验证无 except 子句遇错误时跳过 try 主体，仅继续执行后续代码输出 "after"
    func testNoExceptClauseWithError() throws {
        let source = try loadPiniFixture("testNoExceptClauseWithError", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")
        XCTAssertEqual(lines, ["after"], "when error and no except, try block should be skipped")
    }
}
