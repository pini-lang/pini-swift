import XCTest
@testable import PiniCore

/// T1（批次 A）：诊断体系测试——错误码映射、severity、跨度、ErrorFormatter 渲染（中文 + 下划线 + 建议）。
final class DiagnosticTests: XCTestCase {

    /// 测试默认中文渲染断言（产品默认 en，由 CLI/单例默认决定；测试内固定 zh 保证断言稳定）。
    override func setUp() {
        super.setUp()
        DiagnosticResources.shared.setLanguage(.zh)
    }
    override func tearDown() {
        DiagnosticResources.shared.setLanguage(.en)
        super.tearDown()
    }

    // MARK: - 诊断码映射

    /// 意图：语义错误的 code/severity 映射正确（E3 段）。
    func testSemanticErrorDiagnosticCode()  throws {
        let loc = SourceLocation(line: 3, column: 11, fileName: "t.pini")
        let err = SemanticError.undefinedVariable(name: "contnr", location: loc)
        XCTAssertEqual(err.diagnosticCode, "E3-001")
        XCTAssertEqual(err.diagnosticSeverity, .error)
        XCTAssertEqual(err.diagnosticLocation, loc)
        XCTAssertNil(err.suggestion)
    }

    /// 意图：运行时错误映射到 E5 段；位置保留（含文件名）。
    func testRuntimeErrorDiagnosticLocation()  throws {
        let loc = SourceLocation(line: 2, column: 5, fileName: "a.pini")
        let err = RuntimeError.divisionByZero(location: loc)
        XCTAssertEqual(err.diagnosticCode, "E5-004")
        XCTAssertEqual(err.diagnosticLocation.fileName, "a.pini")
        XCTAssertEqual(err.diagnosticLocation.line, 2)
    }

    /// 意图：语法/类型/IRGen 错误段前缀正确。
    func testErrorDomainSegments()  throws {
        let loc = SourceLocation(line: 1, column: 1, fileName: "t.pini")
        XCTAssertEqual(ParserError.missingIndent(location: loc).diagnosticCode, "E2-003")
        XCTAssertEqual(TypeError.cannotInfer(location: loc).diagnosticCode, "E4-003")
        XCTAssertEqual(IRGenError.unsupportedFeature("x", loc).diagnosticCode, "E6-004")
        XCTAssertEqual(LexerError.unterminatedString(loc).diagnosticCode, "E1-002")
        XCTAssertEqual(PiniError.io(details: "x").diagnosticCode, "E0-106")
    }

    // MARK: - 跨度

    /// 意图：SourceLocation 带 end 后，span 推导出多字符跨度；单点位置退化为 1。
    func testSourceSpanFromLocation()  throws {
        let single = SourceLocation(line: 1, column: 5, fileName: "t.pini")
        XCTAssertEqual(SourceSpan(location: single).endColumn, 5, "单点位置 end 默认 = 起点")

        let ranged = SourceLocation(line: 1, column: 5, endLine: 1, endColumn: 10, fileName: "t.pini")
        let span = SourceSpan(location: ranged)
        XCTAssertEqual(span.startColumn, 5)
        XCTAssertEqual(span.endColumn, 10)
    }

    // MARK: - ErrorFormatter 渲染

    /// 意图：语义错误渲染含错误码、源码行、下划线（单字符）、中文消息。
    func testFormatDiagnosticSemanticError()  throws {
        let source = try loadPiniFixture("testFormatDiagnosticSemanticError", filePath: #filePath)
        let loc = SourceLocation(line: 2, column: 11, fileName: "t.pini")
        let err = SemanticError.undefinedVariable(name: "contnr", location: loc)
        let out = ErrorFormatter.formatDiagnostic(err, source: source)
        XCTAssertTrue(out.contains("语义错误 [E3-001]"), "应含错误类型与码，实际：\(out)")
        XCTAssertTrue(out.contains("at t.pini:2:11"))
        XCTAssertTrue(out.contains("print(contnr)"))
        XCTAssertTrue(out.contains("~"), "应含下划线标记")
        XCTAssertTrue(out.contains("未定义变量 'contnr'"), "应含中文消息")
    }

    /// 意图：多字符跨度渲染为 `~~~`（长度 = end - start），非单字符。
    func testFormatDiagnosticMultiCharSpan() {
        let source = "let abc = 1\n"
        let loc = SourceLocation(line: 1, column: 5, endLine: 1, endColumn: 8, fileName: "t.pini")
        let err = TypeError.cannotInfer(location: loc)
        let out = ErrorFormatter.formatDiagnostic(err, source: source)
        XCTAssertTrue(out.contains("~~~"), "多字符跨度应渲染为 ~~~，实际：\(out)")
    }

    /// 意图：位置为 0:0（如运行时错误无精确位置）时省略 at 行；warning severity 前缀为 Warning。
    func testFormatDiagnosticOmitsZeroLocation() {
        let source = ""
        let loc = SourceLocation(line: 0, column: 0, fileName: "")
        let err = RuntimeError.divisionByZero(location: loc)
        let out = ErrorFormatter.formatDiagnostic(err, source: source)
        XCTAssertFalse(out.contains("at :0:0"), "0:0 位置应省略 at 行")
        XCTAssertTrue(out.contains("运行时错误 [E5-004]"))
        XCTAssertTrue(out.contains("除以零"))
    }

    /// 意图：suggestion 渲染为 help 行；colorize 时含 ANSI 红色前缀。
    func testFormatDiagnosticSuggestionAndColor() {
        let source = "let abc = 1\n"
        let loc = SourceLocation(line: 1, column: 5, fileName: "t.pini")
        let out = ErrorFormatter.format(
            errorType: "语义错误", message: "未定义变量 'abx'", location: loc, source: source,
            code: "E3-001", suggestion: "你是想说 'abc' 吗？")
        XCTAssertTrue(out.contains("help: 你是想说 'abc' 吗？"))

        let colored = ErrorFormatter.format(
            errorType: "语义错误", message: "x", location: loc, source: source,
            code: "E3-001", colorize: true)
        XCTAssertTrue(colored.contains("\u{1B}[31m"), "colorize 应含 ANSI 红色")
        XCTAssertFalse(out.contains("\u{1B}["), "默认不 colorize")
    }

    /// 意图：旧 format* 入口（CLI check 多文件路径）转发到诊断驱动渲染（含错误码）。
    func testLegacyFormatEntryForwardsToDiagnostic() {
        let loc = SourceLocation(line: 1, column: 3, fileName: "t.pini")
        let err = SemanticError.undefinedFunction(name: "f", location: loc)
        let out = ErrorFormatter.formatSemanticError(err, source: "f()")
        XCTAssertTrue(out.contains("语义错误 [E3-002]"))
        XCTAssertTrue(out.contains("未定义函数 'f'"))
    }

    // MARK: - TOML 语言资源（T11，DiagnosticResources）

    /// 意图：zh 资源模板 + 参数填充（错误 payload 的 label → 占位替换）。
    func testDiagnosticResourcesTemplateFill() {
        let msg = DiagnosticResources.shared.message(code: "E3-001", args: ["name": "contnr"], fallback: "fallback")
        XCTAssertEqual(msg, "未定义变量 'contnr'")
        let tm = DiagnosticResources.shared.message(code: "E4-001", args: ["expected": "I32", "got": "String"], fallback: "f")
        XCTAssertEqual(tm, "类型不匹配：期望 I32，实际得到 String")
    }

    /// 意图：无资源条目时回退 fallback（硬编码兜底）。
    func testDiagnosticResourcesFallback() {
        let msg = DiagnosticResources.shared.message(code: "E9-999", args: [:], fallback: "兜底消息")
        XCTAssertEqual(msg, "兜底消息")
    }

    /// 意图：建议模板占位未满足（如 closest 未提供）时返回 nil（不渲染残缺 help 行）。
    func testDiagnosticResourcesSuggestionHiddenWhenPlaceholderUnmet() {
        XCTAssertNil(DiagnosticResources.shared.suggestion(code: "E3-001", args: ["name": "x"]), "closest 未提供 → 隐藏建议")
        let filled = DiagnosticResources.shared.suggestion(code: "E3-001", args: ["name": "x", "closest": "counter"])
        XCTAssertEqual(filled, "你是想说 'counter' 吗？")
    }

    /// 意图：--lang 切换消息/标签（默认 en；zh 可选；无资源码走 fallback）。
    func testDiagnosticResourcesLanguageSwitch() {
        defer { DiagnosticResources.shared.setLanguage(.en) }
        XCTAssertEqual(DiagnosticResources.shared.label(key: "semantic", fallback: "x"), "语义错误", "setUp 已设 zh")
        DiagnosticResources.shared.setLanguage(.en)
        XCTAssertEqual(DiagnosticResources.shared.label(key: "semantic", fallback: "x"), "Semantic Error")
        let msg = DiagnosticResources.shared.message(code: "E3-001", args: ["name": "x"], fallback: "f")
        XCTAssertEqual(msg, "undefined variable 'x'")
        // 回 zh 后消息/标签切换
        DiagnosticResources.shared.setLanguage(.zh)
        XCTAssertEqual(DiagnosticResources.shared.message(code: "E4-010", args: ["variableName": "x"], fallback: "f"),
                       "不能对 'let' 不可变变量 'x' 重新赋值")
        XCTAssertEqual(DiagnosticResources.shared.label(key: "type", fallback: "x"), "类型错误")
    }

    /// 意图：ErrorFormatter 消息经资源渲染（诊断驱动），与硬编码文案一致。
    func testFormatDiagnosticMessageFromResources() {
        let source = "main|func() -> ()\n    print(contnr)\n"
        let loc = SourceLocation(line: 2, column: 11, fileName: "t.pini")
        let err = SemanticError.undefinedVariable(name: "contnr", location: loc)
        let out = ErrorFormatter.formatDiagnostic(err, source: source)
        XCTAssertTrue(out.contains("未定义变量 'contnr'"), "消息应来自 TOML 资源模板")
    }
}
