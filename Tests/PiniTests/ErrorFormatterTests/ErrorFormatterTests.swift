import XCTest
import PiniCore

/// 错误格式化器测试
final class ErrorFormatterTests: XCTestCase {

    /// 测试固定 zh 渲染（产品默认 en；测试断言中文文案，tearDown 恢复 en 避免污染后续）。
    override func setUp() {
        super.setUp()
        DiagnosticResources.shared.setLanguage(.zh)
    }
    override func tearDown() {
        DiagnosticResources.shared.setLanguage(.en)
        super.tearDown()
    }

    /// 意图：格式化器应生成包含源码行和位置标记的错误报告
    func testFormatErrorWithSourceLine()  throws {
        let source = "var x = 1 + \"hello\"\nvar y = 2\n"
        let loc = SourceLocation(line: 1, column: 11, fileName: "test.pini")
        let result = ErrorFormatter.format(
            errorType: "Type Mismatch",
            message: "expected I32, got String",
            location: loc,
            source: source
        )

        let expected = try loadPiniFixture("testFormatErrorWithSourceLine", filePath: #filePath)

        XCTAssertEqual(result, expected)
    }

    /// 意图：格式化器应正确处理多行源码中的错误定位
    func testFormatErrorInMiddleOfMultiLineSource() {
        let source = "main() -> ()\n    print(x)\n    return\n"
        let loc = SourceLocation(line: 2, column: 11, fileName: "test.pini")
        let result = ErrorFormatter.format(
            errorType: "Undefined Variable",
            message: "undefined variable 'x'",
            location: loc,
            source: source
        )

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines.contains("      print(x)"), "应包含出错的源码行（前缀 2 空格 + 源码 4 空格缩进）")
        XCTAssertTrue(lines.contains("            ~"), "应有位置标记（前缀 2 空格 + 列位置偏移）")
        XCTAssertTrue(result.contains("Undefined Variable"), "应有错误类型")
        XCTAssertTrue(result.contains("undefined variable 'x'"), "应有错误描述")
        XCTAssertTrue(result.contains("test.pini:2:11"), "应有位置信息")
    }

    /// 意图：行号为 0 或超出范围时应退化为无源码行格式
    func testFormatErrorWithInvalidLineNumber() {
        let source = "var x = 1\n"
        let loc = SourceLocation(line: 0, column: 0, fileName: "test.pini")
        let result = ErrorFormatter.format(
            errorType: "Runtime Error",
            message: "something went wrong",
            location: loc,
            source: source
        )

        XCTAssertTrue(result.contains("Error: Runtime Error"))
        XCTAssertTrue(result.contains("something went wrong"))
    }

    /// 意图：列号为 0 时标记应放在行首
    func testFormatErrorWithZeroColumn() {
        let source = "bad line\n"
        let loc = SourceLocation(line: 1, column: 0, fileName: "test.pini")
        let result = ErrorFormatter.format(
            errorType: "Parse Error",
            message: "unexpected token",
            location: loc,
            source: source
        )

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        // 列号 0 时应在开头标记
        XCTAssertTrue(lines.contains("  bad line"), "应包含出错的源码行")
    }

    /// 意图：格式化 Lexer 错误应使用正确的错误类型标签（T11：中文统一）
    func testFormatLexerError() {
        let source = "var x = @\n"
        let loc = SourceLocation(line: 1, column: 9, fileName: "lex.bk")
        let error = PiniError.lexer(details: "invalid character '@'", location: loc)
        let result = ErrorFormatter.formatPiniError(error, source: source)

        XCTAssertTrue(result.contains("词法错误"))
        XCTAssertTrue(result.contains("invalid character '@'"), "PiniError 为包装错误，details 原样保留")
        XCTAssertTrue(result.contains("lex.bk:1:9"))
    }

    /// 意图：格式化 Parser 错误应使用正确的错误类型标签（T11：中文统一）
    func testFormatParserError() {
        let source = "var x = \n"
        let loc = SourceLocation(line: 1, column: 7, fileName: "parse.bk")
        let error = ParserError.invalidExpression(reason: "expected expression", location: loc)
        let result = ErrorFormatter.formatParserError(error, source: source)

        XCTAssertTrue(result.contains("语法错误"))
        XCTAssertTrue(result.contains("无效表达式：expected expression"))
        XCTAssertTrue(result.contains("parse.bk:1:7"))
    }
}