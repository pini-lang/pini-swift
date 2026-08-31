import XCTest
import PiniCore
import Foundation

/// match 子块结构 + `case _:` 通配（草稿 A5，2026-08-23 批次 3，D3①/G28 更新）。
/// case 缩进进 match 子块；通配 `case _:`；`default:`/pass 通配子块一次性移除（R2=删除）。
final class MatchNewSyntaxTests: XCTestCase {

    // MARK: - Helpers

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "match-new.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "match-new.pini")
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

    // MARK: - 新结构合法

    /// 意图：case 缩进进 match 子块（与 match 差一级），运行正常。
    func testCaseIndentedUnderMatchValid() throws {
        let source = try loadPiniFixture("testCaseIndentedUnderMatchValid", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "南")
    }

    /// 意图：`case _:` 通配兜底捕获未命中值（等价旧 default/pass 通配子块）。
    func testCaseWildcardFallback() throws {
        let source = try loadPiniFixture("testCaseWildcardFallback", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "兜底")
    }

    /// 意图：枚举 case 绑定在新结构下仍工作（`case 圆(r,)`）。
    func testEnumCaseBindingsStillWork() throws {
        let source = try loadPiniFixture("testEnumCaseBindingsStillWork", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "6.0")
    }

    /// 意图：case 块内可嵌套 match（新结构递归成立）。
    func testNestedMatchValid() throws {
        let source = try loadPiniFixture("testNestedMatchValid", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "东内")
    }

    // MARK: - 旧写法拒绝（R2=删除）

    /// 意图：case 与 match 同级（旧结构）应报错——case 必须缩进进 match 子块。
    func testCaseSameLevelAsMatchRejected()  throws {
        let source = try loadPiniFixture("testCaseSameLevelAsMatchRejected", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "case 与 match 同级应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    /// 意图：`default:` 一次性移除——解析报「已废弃，用 case _:」专属提示。
    func testDefaultRejectedWithHint()  throws {
        let source = try loadPiniFixture("testDefaultRejectedWithHint", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "default 应报已废弃") { error in
            guard case ParserError.invalidStatement(let reason, _) = error else {
                XCTFail("应为 invalidStatement（专属提示），实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("case _:"), "提示应指向 case _:，实际: \(reason)")
        }
    }

    /// 意图：match 值后、case 前的 pass 通配子块一次性移除——报错。
    func testPassWildcardRejected()  throws {
        let source = try loadPiniFixture("testPassWildcardRejected", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "pass 通配子块应报错") { error in
            XCTAssertTrue(error is ParserError, "应为解析错误，实际: \(error)")
        }
    }

    /// 意图：match 穷尽性——枚举缺变体且无 case _: → nonExhaustiveMatch（R1 总是开启）。
    func testNonExhaustiveEnumMatchRejected()  throws {
        let source = try loadPiniFixture("testNonExhaustiveEnumMatchRejected", filePath: #filePath)
        XCTAssertThrowsError(try checkModule(source), "枚举覆盖不全应报 nonExhaustiveMatch") { error in
            guard case SemanticError.nonExhaustiveMatch(let missing, _) = error else {
                XCTFail("应为 nonExhaustiveMatch，实际: \(error)")
                return
            }
            XCTAssertTrue(missing.contains("南"), "缺失列表应含 南，实际: \(missing)")
        }
    }

    /// 意图：字面量 match 未命中且无 case _: → 静态不检查（R3），运行时静默。
    func testLiteralMatchMissIsSilent() throws {
        let source = try loadPiniFixture("testLiteralMatchMissIsSilent", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "继续")
    }
}
