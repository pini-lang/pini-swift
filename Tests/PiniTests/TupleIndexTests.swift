import XCTest
import PiniCore
import Foundation

/// 元组位置访问 `.0` / `.1`（草稿 A2，2026-08-23 批次 1 · 1.1）。
/// 驱动链路：Lexer → Parser → TypeChecker → Interpreter，与项目真实公共入口同构。
final class TupleIndexTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "tuple-index.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "tuple-index.pini")
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

    // MARK: - 位置访问运行语义

    /// 意图：元组字面量按位置索引 `.0` 取首元素，运行输出 10。
    func testTupleLiteralIndexZero() throws {
        let source = """
        main|func() -> ()
            print((10, 20).0,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10")
    }

    /// 意图：元组字面量按位置索引 `.1` 取次元素，运行输出 20。
    func testTupleLiteralIndexOne() throws {
        let source = """
        main|func() -> ()
            print((10, 20).1,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "20")
    }

    /// 意图：多返回值函数结果可直接 `.0` / `.1` 取分量（对应草稿 `some_thing_error().0` 场景）。
    func testMultiReturnFunctionIndex() throws {
        let source = """
        除余|func(a: I32, b: I32) -> (I32, I32,)
            return (a / b, a % b,)
        main|func() -> ()
            var r = 除余(a: 7, b: 3)
            print(r.0,)
            print(r.1,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2\n1")
    }

    /// 意图：后缀链可嵌套（((1, 2), 3).0.1 → 2），证明 `.0` 后接 `.1` 复合访问。
    func testNestedTupleChainedIndex() throws {
        let source = """
        main|func() -> ()
            print(((1, 2), 3).0.1,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    /// 意图：越界索引（2 元组取 .2）应抛运行错误，不得静默越界。
    func testOutOfBoundsIndexThrows() {
        let source = """
        main|func() -> ()
            print((10, 20).2,)
            return
        """
        XCTAssertThrowsError(try runProgram(source), "越界元组索引应抛错") { error in
            guard case RuntimeError.invalidOperation(_, _) = error else {
                XCTFail("应为 invalidOperation，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 类型检查

    /// 意图：类型检查认可合法位置索引（(I32, String).1 → String），不抛错。
    func testTypeCheckValidIndex() throws {
        let source = """
        main|func() -> ()
            var s: String = (42, "hello").1
            print(s,)
            return
        """
        XCTAssertNoThrow(try checkModule(source), "合法元组索引不应抛错")
    }

    /// 意图：类型检查拒绝越界位置索引（空元组取 .0），抛类型错误。
    func testTypeCheckOutOfBounds() {
        let source = """
        main|func() -> ()
            var x: I32 = ().0
            return
        """
        XCTAssertThrowsError(try checkModule(source), "越界元组索引应抛类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为类型错误，实际: \(error)")
                return
            }
        }
    }
}
