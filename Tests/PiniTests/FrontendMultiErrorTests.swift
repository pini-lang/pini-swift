import XCTest
import PiniCore

/// 多错误同报：CLI（`pini check` / `parse` / `run` …）接线所依赖的
/// 收集链路（解析收集 + 语义收集）的独立验证。目标：单文件一次性报出多个错误。
final class FrontendMultiErrorTests: XCTestCase {

    private func parse(_ source: String) -> ParseResult {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return parser.parseModuleCollectingErrors()
    }

    private func analyze(_ module: Module) -> [SemanticError] {
        let analyzer = SemanticAnalyzer()
        return analyzer.analyzeCollecting(module: module)
    }

    // MARK: - 解析阶段：多个语法错误一次性收集

    /// 意图：验证解析阶段一次性收集多个语法错误——源码含 3 处非法 token，断言 errors.count >= 3（CLI check/parse 收集链路依赖此行为）。
    func testParsePhaseCollectsMultipleErrors() {
        let source = """
        [Bad1|notakw
        [Bad2|notakw
        [Bad3|notakw
        main|func() -> ()
            return
        """
        let result = parse(source)
        XCTAssertGreaterThanOrEqual(result.errors.count, 3,
                                    "解析阶段应一次性收集多个错误，实际: \(result.errors)")
    }

    // MARK: - 语义阶段：多个重声明一次性收集（呼应 P2-3 同趟报告）

    /// 意图：验证语义阶段一次性收集多个重声明——foo/bar 各重复声明一次，断言解析无错且 semErrors >= 2，逐个断言均为 redeclaredSymbol（呼应 P2-3 同趟报告）。
    func testSemanticPhaseCollectsMultipleRedeclarations() {
        let source = """
        foo|func() -> ()
            return
        foo|func() -> ()
            return
        bar|func() -> ()
            return
        bar|func() -> ()
            return
        main|func() -> ()
            return
        """
        let result = parse(source)
        XCTAssertTrue(result.errors.isEmpty, "重声明是合法语法，解析阶段不应报错")
        let semErrors = analyze(result.module)
        XCTAssertGreaterThanOrEqual(semErrors.count, 2,
                                    "多个重声明应被一次性收集，实际: \(semErrors)")
        for e in semErrors {
            guard case .redeclaredSymbol = e else {
                XCTFail("期望 redeclaredSymbol，实际: \(e)")
                return
            }
        }
    }

    // MARK: - 回归：无错误时两阶段皆空

    /// 意图：回归验证合法程序两阶段皆空——单函数 + main，断言解析错误为空且语义分析结果为空（防止误报）。
    func testNoErrorsWhenValid() {
        let source = """
        foo|func() -> ()
            return
        main|func() -> ()
            return
        """
        let result = parse(source)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(analyze(result.module).isEmpty)
    }
}
