import XCTest
import PiniCore
import Foundation

/// `^` 右值糖（ADR-032：定义性脱糖 `^e` ≡ `try e else err: return err`）。
/// 覆盖：`^ok(v)` 解包得 v、`^err(e)` 经 handler return 把错误值作为函数返回值带出、非 Result 值报错。
final class ResultUnwrapTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "result-unwrap.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "result-unwrap.pini")
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
            pipe.fileHandleForWriting.closeFile()
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

    private func checkModule(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "check.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "check.pini")
        let module = try parser.parseModule()

        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)

        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - ok 解包

    /// 意图：`^ok(42)` 解包得载荷 42，运行输出 42。
    func testOkUnwrapValue() throws {
        let source = try loadPiniFixture("testOkUnwrapValue", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    /// 意图：`^` 可出现在表达式位置（print 实参内），且解包后参与后续运算。
    func testOkUnwrapInExpression() throws {
        let source = try loadPiniFixture("testOkUnwrapInExpression", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    // MARK: - err 控制返回（ADR-032：脱糖至 try-else，错误值经 handler return 带出）

    /// 意图（ADR-032）：`^err(e)` ≡ `try err(e) else err: return err`——错误值作为
    /// 函数返回值带出（旧「注入返回元组末槽」机制已退役）。输出 boom。
    func testErrControlReturnToLastSlot() throws {
        let source = try loadPiniFixture("testErrControlReturnToLastSlot", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "boom")
    }

    /// 意图（ADR-032）：err 路径经 handler 控制流转移，函数体后续语句不执行。
    func testErrStopsFunctionBody() throws {
        let source = try loadPiniFixture("testErrStopsFunctionBody", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "提前失败")
    }

    // MARK: - 错误路径

    /// 意图：`^` 作用于非 Result 值（如 I32）应抛类型错误（运行时兜底）。
    func testUnwrapNonResultThrows()  throws {
        let source = try loadPiniFixture("testUnwrapNonResultThrows", filePath: #filePath)
        XCTAssertThrowsError(try runProgram(source), "非 Result 值解包应抛错") { error in
            guard case RuntimeError.typeMismatch(_, _, _) = error else {
                XCTFail("应为 typeMismatch，实际: \(error)")
                return
            }
        }
    }

    /// 意图：`^` 静态检查——作用于 Result 值不抛错。
    func testTypeCheckValidUnwrap() throws {
        let source = try loadPiniFixture("testTypeCheckValidUnwrap", filePath: #filePath)
        XCTAssertNoThrow(try checkModule(source), "合法解包不应抛错")
    }
}
