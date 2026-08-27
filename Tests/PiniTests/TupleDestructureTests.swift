import XCTest
import PiniCore
import Foundation

/// 元组解构 `var (t, e) = rhs`（草稿 A1，2026-08-23 批次 1 · 1.2）。
/// 驱动链路：Lexer → Parser → SemanticAnalyzer → TypeChecker → Interpreter，与项目真实公共入口同构。
final class TupleDestructureTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "tuple-destructure.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "tuple-destructure.pini")
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

    // MARK: - 解构运行语义

    /// 意图：`var (t, e) = (1, "hello")` 将右值元组逐分量绑定，运行输出 1 / hello。
    func testBasicDestructure() throws {
        let source = """
        main|func() -> ()
            var (t, e) = (1, "hello")
            print(t,)
            print(e,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1\nhello")
    }

    /// 意图：多返回值函数结果可直接解构（对应草稿 `var (t, e) = some_thing_error()` 场景）。
    func testMultiReturnDestructure() throws {
        let source = """
        除余|func(a: I32, b: I32) -> (I32, I32,)
            return (a / b, a % b,)
        main|func() -> ()
            var (商, 余) = 除余(a: 7, b: 3)
            print(商,)
            print(余,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2\n1")
    }

    /// 意图：`let (a, b) = ...` 不可变解构同样成立，且解构出的变量可参与表达式。
    func testLetImmutableDestructure() throws {
        let source = """
        main|func() -> ()
            let (a, b) = (10, 20)
            print(a + b,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "30")
    }

    /// 意图：`_` 占位忽略对应分量（与 for-in 模式元组一致），输出 1 / 3。
    func testUnderscorePlaceholder() throws {
        let source = """
        main|func() -> ()
            var (a, _, b) = (1, 2, 3)
            print(a,)
            print(b,)
            return
        """
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1\n3")
    }

    // MARK: - 静态与运行时校验

    /// 意图：解构分量个数与右值元组不匹配（3 绑 2）应抛类型错误。
    func testTypeCheckCountMismatch() {
        let source = """
        main|func() -> ()
            var (a, b, c) = (1, 2)
            return
        """
        XCTAssertThrowsError(try checkModule(source), "分量个数不匹配应抛类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch，实际: \(error)")
                return
            }
        }
    }

    /// 意图：解构非元组右值（I32 对元组）应抛类型错误。
    func testTypeCheckNonTupleRight() {
        let source = """
        main|func() -> ()
            var (a, b) = 42
            return
        """
        XCTAssertThrowsError(try checkModule(source), "右值非元组应抛类型错误") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch，实际: \(error)")
                return
            }
        }
    }

    /// 意图：运行时对类型推断不可达路径的兜底——右值运行值非元组时抛运行错误。
    func testRuntimeNonTupleRightThrows() {
        let source = """
        main|func() -> ()
            var (a, b) = 42
            print(a,)
            return
        """
        XCTAssertThrowsError(try runProgram(source), "右值运行值非元组应抛错") { error in
            guard case RuntimeError.typeMismatch(_, _, _) = error else {
                XCTFail("应为 typeMismatch，实际: \(error)")
                return
            }
        }
    }
}
