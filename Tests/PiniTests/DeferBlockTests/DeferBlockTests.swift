import XCTest
import PiniCore
import Foundation

/// defer 块形式（G51④/P0，2026-08-31 落地）：
///   `defer:` + 缩进体——双形态的另一支（相邻单行语句为宿主现行形态）。
///   块体作为一个 defer 项入 defer 栈，包含块退出时按书写序执行；
///   跨 defer 项的 LIFO 由 defer 栈保证（G39 语义）。
/// 驱动链路与 CLI `pini run` 同构：stdout 捕获。
final class DeferBlockTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let outPipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

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
        outPipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func runFixture(_ name: String) throws -> String {
        let out = try runProgram(try loadPiniFixture(name, filePath: #filePath) as String)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 意图：块形式与单行 defer 混排——LIFO 顺序 body → single2 → b1 → b2 → single
    ///（块体内部按书写序，块作为整体参与 LIFO）。
    func testDeferBlockLIFO() throws {
        XCTAssertEqual(try runFixture("testDeferBlockLIFO"),
                       "body\nsingle2\nb1\nb2\nsingle",
                       "defer 块应作为单个 defer 项参与 LIFO，体内部按书写序")
    }

    /// 意图：嵌套控制块内的 defer 块——在该控制块退出时触发（非函数退出）。
    func testDeferBlockNestedExit() throws {
        XCTAssertEqual(try runFixture("testDeferBlockNestedExit"),
                       "inner-bodyinner-defer",
                       "defer 块应在包含块退出时执行")
    }

    /// 意图：函数级 defer 块——函数体退出时执行、调用点之后恢复主流程。
    func testDeferBlockInFuncExit() throws {
        XCTAssertEqual(try runFixture("testDeferBlockInFuncExit"),
                       "work\ncleanup-1\ncleanup-2\nafter",
                       "函数内 defer 块在函数退出前按书写序执行")
    }
}
