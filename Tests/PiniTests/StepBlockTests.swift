import XCTest
import PiniCore
import Foundation

/// step 块执行语义测试（P1-3 解释器层 + P1-6 补全）
final class StepBlockTests: XCTestCase {
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

    /// step 在每个循环体正常结束后执行一次
    /// 意图：验证 step 在 while 每轮循环体正常结束后执行一次，3 轮各输出一次 "S"，得到 "0S1S2S"
    func testStepExecutesAfterEachIteration() throws {
        let source = """
main() -> ()
    var i = 0
    while i < 3:
        print(i)
        i = i + 1
    step:
        print("S")
    return
"""
        let output = try runProgram(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0S1S2S", "step 应在每轮末尾执行一次")
    }

    /// continue 后也应执行 step（类 C for 的步进语义）
    /// 意图：验证 continue 提前结束本轮后 step 仍照常执行（类 C for 步进语义），得到 "0C1C2C"
    func testStepExecutesOnContinue() throws {
        let source = """
main() -> ()
    var i = 0
    while i < 3:
        print(i)
        i = i + 1
        continue
    step:
        print("C")
    return
"""
        let output = try runProgram(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0C1C2C", "continue 后也应执行 step")
    }

    /// break 应跳过 step
    /// 意图：验证 break 跳出循环时跳过 step：i 等于 3 时中断，输出 "0B1B2" 而非再追加 "B"
    func testStepSkippedOnBreak() throws {
        let source = """
main() -> ()
    var i = 0
    while i < 5:
        print(i)
        i = i + 1
        if i == 3:
            break
    step:
        print("B")
    return
"""
        let output = try runProgram(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "0B1B2", "break 应跳过 step")
    }

    /// 嵌套 while 的 step 应向前就近匹配各自 while
    /// 意图：验证嵌套 while 中内层 step 就近匹配内层 while、外层 step 匹配外层，输出 "ininSininSoutSininSininSoutS"
    func testNestedWhileStepScoping() throws {
        // 使用字符串数组精确控制缩进，避免 Swift 多行字符串的缩进剥离破坏嵌套层级
        let source = [
            "main() -> ()",
            "    var i = 0",
            "    while i < 2:",
            "        var j = 0",
            "        while j < 2:",
            "            print(\"in\")",
            "            j = j + 1",
            "        step:",
            "            print(\"inS\")",
            "        i = i + 1",
            "    step:",
            "        print(\"outS\")",
            "    return",
        ].joined(separator: "\n")
        let output = try runProgram(source).components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertEqual(output, "ininSininSoutSininSininSoutS",
                       "内层 step 就近匹配内层 while，外层 step 匹配外层")
    }

    private func checkCollecting(_ source: String) -> [TypeError] {
        let lexer = Lexer(source: source, fileName: "step_test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "step_test.pini")
        let module = try! parser.parseModule()
        return TypeChecker().checkCollecting(module: module)
    }

    /// 验证 step 块内的类型错误也会被审计（P1-4：step 块纳入 TypeChecker）。
    /// 若在 P1-4 之前（step 被忽略），step 块内的 `let z = 0; z = 1` 不会被捕获。
    /// 意图：验证 step 块内的类型错误（对 let 变量重新赋值）也会被 TypeChecker 捕获并出现在错误列表中
    func testStepBlockTypeErrorsAreChecked() throws {
        let source = [
            "main() -> ()",
            "    var i = 0",
            "    while i < 3:",
            "        print(i)",
            "        i = i + 1",
            "    step:",
            "        let z = 0",
            "        z = 1",
            "    return",
        ].joined(separator: "\n")
        let errors = checkCollecting(source)
        XCTAssertFalse(errors.isEmpty, "step 块内对 let 变量的重新赋值应被 TypeChecker 捕获")
    }
}
