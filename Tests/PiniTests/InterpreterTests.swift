import XCTest
import PiniCore
import Foundation

final class InterpreterTests: XCTestCase {
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
            // 抛出异常前恢复 stdout，避免后续测试输出写入 pipe 导致 SIGPIPE
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        // 成功路径：先关闭 pipe 写端并恢复 stdout，再读取（需写端关闭以触发 EOF）
        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// 意图：带返回类型标注 (I32,) 的 func 字面量应可绑定到变量并调用，f(41) 正确输出 42
    func testFuncLiteralWithReturnType() throws {
        let source = try loadPiniFixture("testFuncLiteralWithReturnType", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    /// 意图：显式标注函数类型 (I32,)->(I32,) 的变量应能接收 func 字面量，g(41) 正确输出 42
    func testFuncLiteralWithTypeAnnotation() throws {
        let source = try loadPiniFixture("testFuncLiteralWithTypeAnnotation", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    /// 意图：if/else 应依条件选择分支，x=10 满足 x>5 时输出"大于5"
    func testIfElse() throws {
        let source = try loadPiniFixture("testIfElse", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "大于5")
    }

    /// 意图：while 循环应依条件重复执行，i 从 0 到 2 依次输出 0、1、2
    func testWhileLoop() throws {
        let source = try loadPiniFixture("testWhileLoop", filePath: #filePath)
        let output = try runProgram(source)
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["0", "1", "2"])
    }

    /// 意图：match 语句应命中与枚举值 s=圆 对应的 case 分支，输出"圆形"
    func testMatchCase() throws {
        let source = try loadPiniFixture("testMatchCase", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "圆形")
    }

    /// 意图：前缀自增运算符应使变量加 1
    func testUnaryPrefixIncrement() throws {
        let source = try loadPiniFixture("testUnaryPrefixIncrement", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "6", "++x 应使 x 从 5 变为 6")
    }

    /// 意图：前缀自减运算符应使变量减 1
    func testUnaryPrefixDecrement() throws {
        let source = try loadPiniFixture("testUnaryPrefixDecrement", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "4", "--x 应使 x 从 5 变为 4")
    }

    /// 意图：一元正号对正数无影响
    func testUnaryPlus() throws {
        let source = try loadPiniFixture("testUnaryPlus", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "5", "+5 应为 5")
    }

    /// 意图：按位取反应正确计算
    func testUnaryBitwiseNot() throws {
        let source = try loadPiniFixture("testUnaryBitwiseNot", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "-1", "~0 应为 -1")
    }
}
