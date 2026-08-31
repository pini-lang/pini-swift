import XCTest
import PiniCore

/// capture 声明（H-1/A1 裁决落地，2026-08-31）：
///   语法：`capture 标识符`，每行恰一个，仅匿名函数缩进体顶层语句位，散落多条。
///   语义（偏弱纯定位）：①先 capture 后使用（E3-008）；②目标须为创建点外层
///   局部变量（E3-009）；③位置合法性（E2-007，解析器强制）。
/// 驱动链路与 CLI `pini check` 同构：Lexer → Parser → SemanticAnalyzer.analyze。
final class CaptureStmtTests: XCTestCase {

    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 断言语义分析通过（无捕获违规）。
    private func assertCaptureOK(_ source: String, _ message: String = "") {
        let module = try! parseModule(source)
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module), message)
    }

    // MARK: - 正向

    /// 意图：capture 先于使用 → 语义分析通过（运行期行为由 CLI 冒烟覆盖：f(5)=15）。
    func testCaptureBeforeUse() throws {
        assertCaptureOK(
            try loadPiniFixture("testCaptureBeforeUse", filePath: #filePath) as String,
            "capture 先于使用应通过语义分析"
        )
    }

    /// 意图：多条 capture 散落分布、按声明序分段可用 → 通过。
    func testCaptureScatteredLines() throws {
        assertCaptureOK(
            try loadPiniFixture("testCaptureScatteredLines", filePath: #filePath) as String,
            "散落多条 capture 应通过语义分析"
        )
    }

    /// 意图：capture 声明按语句序聚合进 FuncDecl.captured（含 `_` 前缀标识符）。
    func testCapturedAggregation() throws {
        let module = try parseModule(try loadPiniFixture("testCapturedAggregation", filePath: #filePath) as String)
        var captured: [String] = []
        for decl in module.declarations {
            guard case .funcDecl(let f) = decl else { continue }
            for stmt in f.body?.statements ?? [] {
                if case .varDecl(_, _, let initExpr, _, _) = stmt,
                   let initExpr,
                   case .funcLiteral(let lit, _) = initExpr {
                    captured = lit.captured
                }
            }
        }
        XCTAssertEqual(captured, ["base", "_cache"], "capture 声明应按语句序聚合（含 `_` 前缀标识符）")
    }

    // MARK: - ① 先 capture 后使用

    /// 意图：体内引用外层局部但 capture 行尚未在语句序上出现 → E3-008。
    func testCaptureUseBeforeDeclaration() throws {
        let module = try parseModule(try loadPiniFixture("testCaptureUseBeforeDeclaration", filePath: #filePath) as String)
        let analyzer = SemanticAnalyzer()
        XCTAssertThrowsError(try analyzer.analyze(module: module)) { error in
            guard case SemanticError.captureWithoutDeclaration(let name, _) = error else {
                XCTFail("应为 captureWithoutDeclaration，实际: \(error)")
                return
            }
            XCTAssertEqual(name, "base")
        }
    }

    // MARK: - ② 捕获一致性

    private func assertInvalidTarget(_ fixture: String, name expected: String, _ message: String = "") {
        let module = try! parseModule(try! loadPiniFixture(fixture, filePath: #filePath) as String)
        let analyzer = SemanticAnalyzer()
        XCTAssertThrowsError(try analyzer.analyze(module: module), message) { error in
            guard case SemanticError.invalidCaptureTarget(let name, _, _) = error else {
                XCTFail("应为 invalidCaptureTarget，实际: \(error)")
                return
            }
            XCTAssertEqual(name, expected)
        }
    }

    /// 意图：capture 体内已声明局部 → E3-009。
    func testCaptureOfInternalLocal() {
        assertInvalidTarget("testCaptureOfInternalLocal", name: "inner")
    }

    /// 意图：capture 本匿名函数参数 → E3-009。
    func testCaptureOfParam() {
        assertInvalidTarget("testCaptureOfParam", name: "x")
    }

    /// 意图：capture 创建点不可见名 → E3-009。
    func testCaptureOfUndefinedName() {
        assertInvalidTarget("testCaptureOfUndefinedName", name: "no_such")
    }

    /// 意图：capture 内建函数名 → E3-009（函数按名引用，非「捕获的外部对象」）。
    func testCaptureOfBuiltinFunction() {
        assertInvalidTarget("testCaptureOfBuiltinFunction", name: "print")
    }

    // MARK: - ③ 位置合法性（解析器强制）

    private func assertParseError(_ fixture: String, _ message: String = "") {
        XCTAssertThrowsError(
            try parseModule(try loadPiniFixture(fixture, filePath: #filePath) as String),
            message
        ) { error in
            guard case ParserError.invalidStatement = error else {
                XCTFail("应为 invalidStatement（E2-007），实际: \(error)")
                return
            }
        }
    }

    /// 意图：匿名体内嵌套控制块中的 capture → E2-007。
    func testCaptureInNestedBlock() {
        assertParseError("testCaptureInNestedBlock")
    }

    /// 意图：具名函数体内的 capture → E2-007。
    func testCaptureInNamedFuncBody() {
        assertParseError("testCaptureInNamedFuncBody")
    }

    /// 意图：顶级 capture → E2-007。
    func testCaptureAtTopLevel() {
        assertParseError("testCaptureAtTopLevel")
    }

    /// 意图：`capture a, b` 逗号清单 → E2-007（每行恰一个）。
    func testCaptureCommaList() {
        assertParseError("testCaptureCommaList")
    }

    /// 意图：废除的签名前形态 `func capture base (...)` → 解析错误
    ///（错误码随切入点而异：签名位为 E2-001 unexpectedToken）。
    func testPreSignatureCaptureForm() {
        XCTAssertThrowsError(
            try parseModule(try loadPiniFixture("testPreSignatureCaptureForm", filePath: #filePath) as String)
        ) { error in
            guard error is ParserError else {
                XCTFail("应为解析错误，实际: \(error)")
                return
            }
        }
    }
}
