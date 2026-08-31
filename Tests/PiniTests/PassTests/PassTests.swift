import XCTest
import PiniCore
import Foundation

final class PassTests: XCTestCase {

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
        let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 词法：pass 被识别为关键字
    /// 意图：验证 pass 被词法识别为 .keyword(.pass) 关键字 token。
    func testPassIsKeyword() throws {
        let lexer = Lexer(source: "pass", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        XCTAssertTrue(tokens.contains { if case .keyword(.pass, _) = $0 { true } else { false } },
                      "pass 应被词法识别为关键字")
    }

    // 占位：独立 pass 语句是无副作用 no-op
    /// 意图：验证独立 pass 语句是无副作用 no-op，运行不产生任何输出。
    func testPassStandaloneNoop() throws {
        let out = try runProgram("main() -> ()\n    pass\n    return\n")
        XCTAssertEqual(out, "", "独立 pass 不产生任何输出")
    }

    // 占位：if/else 分支体用 pass
    /// 意图：验证 pass 充当 if 分支占位不阻塞 else 分支，运行输出 else-branch。
    func testPassInIfElse() throws {
        let out = try runProgram(
            "main() -> ()\n" +
            "    if 1 > 2:\n" +
            "        pass\n" +
            "    else:\n" +
            "        print(\"else-branch\")\n" +
            "    return\n"
        )
        XCTAssertEqual(out, "else-branch")
    }

    // 占位：while 循环体内 pass（验证不破坏循环控制流）
    /// 意图：验证 while 循环体内 pass 不破坏循环控制流，迭代完成后输出 3。
    func testPassInWhileBody() throws {
        let out = try runProgram(
            "main() -> ()\n" +
            "    var i = 0\n" +
            "    while i < 3:\n" +
            "        i = i + 1\n" +
            "        pass\n" +
            "    print(i)\n" +
            "    return\n"
        )
        XCTAssertEqual(out, "3")
    }

    // 桩函数：函数体仅 pass，调用不崩溃、返回空值
    /// 意图：验证仅含 pass 的桩函数可被正常调用不崩溃，调用后继续输出 after-stub。
    func testPassStubFunction() throws {
        let out = try runProgram(
            "空() -> ()\n" +
            "    pass\n" +
            "main() -> ()\n" +
            "    空()\n" +
            "    print(\"after-stub\")\n" +
            "    return\n"
        )
        XCTAssertEqual(out, "after-stub")
    }
}
