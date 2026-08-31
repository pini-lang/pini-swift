import XCTest
import PiniCore
import Foundation

/// 命名元组标签与 `.名称` 访问（草稿 A2，2026-08-23 批次 1 · 1.3，决策 D1=做命名标签）。
/// 覆盖：类型注解命名元组 `(a: I32, b: String,)`、字面量命名元素 `(a: 1, b: "x",)`、
/// `.名称` 标签访问、`.0` 位置访问与命名元组的兼容、未知标签静态拦截。
final class TupleNamedTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "tuple-named.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "tuple-named.pini")
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

    // MARK: - .名称 标签访问

    /// 意图：命名元组类型注解 `(a: I32, b: String,)` 绑定位置字面量，`.a` 按标签取首元素。
    func testNamedTypeAnnotationLabelAccess() throws {
        let source = try loadPiniFixture("testNamedTypeAnnotationLabelAccess", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1\nhello")
    }

    /// 意图：字面量命名元组 `(a: 1, b: "x",)` 自描述标签，`.b` 按标签取元素。
    func testNamedLiteralLabelAccess() throws {
        let source = try loadPiniFixture("testNamedLiteralLabelAccess", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "1\nx")
    }

    /// 意图：多返回值函数声明命名返回元组 `-> (商: I32, 余: I32,)`，`r.商` 取对应分量。
    func testNamedMultiReturnLabelAccess() throws {
        let source = try loadPiniFixture("testNamedMultiReturnLabelAccess", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2\n1")
    }

    /// 意图：命名元组上 `.0` 位置访问与标签访问并存（标签是元数据的附加层，位置语义不变）。
    func testNamedTuplePositionalIndexStillWorks() throws {
        let source = try loadPiniFixture("testNamedTuplePositionalIndexStillWorks", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "10\n20")
    }

    // MARK: - 静态校验

    /// 意图：`.名称` 访问不存在的标签（`t.不存在`）应抛静态类型错误（unknownMember）。
    func testUnknownLabelStaticError()  throws {
        let source = try loadPiniFixture("testUnknownLabelStaticError", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "未知标签应抛静态错误") { error in
            // unknownMember 或 mismatch 均视为已拦截
            switch error {
            case is TypeError:
                break
            default:
                XCTFail("应为 TypeError，实际: \(error)")
            }
        }
    }

    /// 意图：`.名称` 访问位置元组（无标签）应抛静态类型错误。
    func testLabelAccessOnPositionalTupleStaticError()  throws {
        let source = try loadPiniFixture("testLabelAccessOnPositionalTupleStaticError", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "位置元组上 .名称 应抛静态错误") { error in
            switch error {
            case is TypeError:
                break
            default:
                XCTFail("应为 TypeError，实际: \(error)")
            }
        }
    }
}
