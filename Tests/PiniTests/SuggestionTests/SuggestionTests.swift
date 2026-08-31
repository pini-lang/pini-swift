import XCTest
@testable import PiniCore

/// T1/B1+B2（2026-08-24）：did-you-mean 建议引擎与未使用变量 warning 检测。
final class SuggestionTests: XCTestCase {

    // MARK: - SuggestionEngine（B1）

    /// 意图：Levenshtein 距离正确（经典 kitten/sitting = 3）。
    func testLevenshteinDistance()  throws {
        XCTAssertEqual(SuggestionEngine.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(SuggestionEngine.levenshtein("counter", "contnr"), 2)
        XCTAssertEqual(SuggestionEngine.levenshtein("abc", "abc"), 0)
    }

    /// 意图：suggest 返回距离最短候选；排除完全相等；超阈值返回 nil。
    func testSuggestPicksNearest()  throws {
        let candidates = ["counter", "used", "total"]
        XCTAssertEqual(SuggestionEngine.suggest(target: "contnr", candidates: candidates), "counter")
        XCTAssertNil(SuggestionEngine.suggest(target: "counter", candidates: candidates), "与 target 相等应排除")
        XCTAssertNil(SuggestionEngine.suggest(target: "zzzzz", candidates: candidates, maxDistance: 2), "距离超阈值")
        XCTAssertNil(SuggestionEngine.suggest(target: "x", candidates: []), "空候选")
    }

    /// 意图：中文标识符同样按字符级编辑距离工作。
    func testSuggestChineseIdentifiers()  throws {
        XCTAssertEqual(SuggestionEngine.suggest(target: "计数", candidates: ["计数器", "数值", "总量"]), "计数器")
    }

    /// 意图：标识符提取基于词法 token——排除字符串字面量与注释内容，去重。
    func testIdentifiersFromSourceExcludeStringsAndComments()  throws {
        let source = try loadPiniFixture("testIdentifiersFromSourceExcludeStringsAndComments", filePath: #filePath)
        let ids = SuggestionEngine.identifiers(in: source)
        XCTAssertTrue(ids.contains("counter"), "真实变量应提取")
        XCTAssertTrue(ids.contains("s"))
        XCTAssertFalse(ids.contains("let"), "关键字不是 identifier")
        XCTAssertFalse(ids.contains("var"), "关键字不是 identifier")
        XCTAssertEqual(ids.filter { $0 == "counter" }.count, 1, "去重")
    }

    /// 意图：did-you-mean 集成——undefined 变量渲染含 `help: Did you mean`。
    func testFormatDiagnosticIncludesSuggestion()  throws {
        let source = "main|func() -> ():\n    var counter = 1\n    print(contnr)\n    return\n"
        let loc = SourceLocation(line: 3, column: 11, fileName: "t.pini")
        let err = SemanticError.undefinedVariable(name: "contnr", location: loc)
        let out = ErrorFormatter.formatDiagnostic(err, source: source, language: .en)
        XCTAssertTrue(out.contains("Did you mean 'counter'?"), "应输出 did-you-mean 建议，实际：\(out)")
    }

    // MARK: - 未使用变量 warning（B2）

    private func analyzeWarnings(_ source: String) -> [SemanticWarning] {
        let tokens = (try? Lexer(source: source, fileName: "t.pini").tokenize()) ?? []
        let parser = Parser(tokens: tokens, fileName: "t.pini")
        let result = parser.parseModuleCollectingErrors()
        let analyzer = SemanticAnalyzer()
        _ = analyzer.analyzeCollecting(module: result.module)
        return analyzer.warnings
    }

    /// 意图：未使用的局部 var 发 warning（E7-001）。
    func testUnusedLocalVariableWarns()  throws {
        let source = try loadPiniFixture("testUnusedLocalVariableWarns", filePath: #filePath)
        let warnings = analyzeWarnings(source)
        XCTAssertEqual(warnings.count, 1)
        guard case .unusedVariable(let name, _) = warnings[0] else {
            return XCTFail("应为 unusedVariable，实际 \(warnings[0])")
        }
        XCTAssertEqual(name, "unused")
        XCTAssertEqual(warnings[0].diagnosticCode, "E7-001")
        XCTAssertEqual(warnings[0].diagnosticSeverity, .warning)
    }

    /// 意图：已使用的局部变量不警告。
    func testUsedLocalVariableNoWarn()  throws {
        let source = try loadPiniFixture("testUsedLocalVariableNoWarn", filePath: #filePath)
        XCTAssertTrue(analyzeWarnings(source).isEmpty)
    }

    /// 意图：未使用的参数不警告（B2 排除参数）。
    func testUnusedParameterNoWarn()  throws {
        let source = try loadPiniFixture("testUnusedParameterNoWarn", filePath: #filePath)
        XCTAssertTrue(analyzeWarnings(source).isEmpty)
    }

    /// 意图：`_`/`_xxx` 前缀变量忽略（语言惯例）。
    func testUnderscorePrefixedNoWarn()  throws {
        let source = try loadPiniFixture("testUnderscorePrefixedNoWarn", filePath: #filePath)
        XCTAssertTrue(analyzeWarnings(source).isEmpty)
    }

    /// 意图：for 模式绑定变量不警告（可能仅关心集合长度）。
    func testForPatternVariableNoWarn()  throws {
        let source = try loadPiniFixture("testForPatternVariableNoWarn", filePath: #filePath)
        XCTAssertTrue(analyzeWarnings(source).isEmpty)
    }

    /// 意图：方法内字段/self 不警告（B2 排除字段；字段在函数作用域非 body 作用域）。
    func testFieldAndSelfNoWarn()  throws {
        let source = try loadPiniFixture("testFieldAndSelfNoWarn", filePath: #filePath)
        XCTAssertTrue(analyzeWarnings(source).isEmpty)
    }
}
