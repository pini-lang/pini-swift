import XCTest
@testable import PiniCore

/// G-P1（自举探针批次 4）：F64 值构造
final class FloatValueTests: XCTestCase {

    /// 意图：F64(int) 参与浮点算术——此前 E5-003 混合算术拒绝
    /// 推进性测量：F64(3) + 0.5 输出 3.5
    /// 驳回性测量：E5-003 / 类型报错均不合格
    func testF64ConvertsIntAndJoinsFloatArithmetic() throws {
        let source = """
main|func() -> ()
    var n = 3
    var f = F64(n)
    print(f + 0.5)
    print(F64(7))
    print(F64(2.5))
    return
"""
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("3.5"), out)
        XCTAssertTrue(out.contains("7.0"), out)
        XCTAssertTrue(out.contains("2.5"), out)
    }

    /// 意图：非数值参数干净报错
    /// 推进性测量：抛 RuntimeError.invalidOperation
    /// 驳回性测量：静默返回或崩溃均不合格
    func testF64RejectsNonNumeric() {
        let source = """
main|func() -> ()
    var f = F64("x")
    print(f)
    return
"""
        XCTAssertThrowsError(try runProgram(source), "F64 非数值参数应报错")
    }

    // MARK: - 执行助手（fd 恢复先于 read，防 EOF 死锁）

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "f64.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "f64.pini")
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
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
