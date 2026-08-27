import XCTest
import PiniCore

/// panic-mode 恢复：解析错误不再只停留在顶级声明粒度，
/// 单个声明体内（INDENT 块 / 函数体 / 控制块）出现多处语句级错误时，
/// 也能一次性收集并继续解析，使「单文件多错同报」深入到函数体内部。
///
/// 设计：保留旧 `parseModule() throws` 语义不变（遇首个错即抛，回归防护）；
/// 收集模式下 `parseBlock` / `parseControlBlock` 的语句循环
/// 改用 `parseStatementWithRecovery`，出错后跳过到下一行边界（不吞 DEDENT/EOF）继续。
/// 坏语句用行首分隔符 `)` / `]`（parsePrimary 立即抛错、不贪吃后续行）以保证确定性。
///
/// 关键判别（修复前 vs 修复后）：修复前错误逃出函数体，模块级 resync 把函数体残余行
/// 当成新的顶级声明重解析，产生伪 `.statement` 声明（declarations > 1）；修复后函数体
/// 就地恢复，仅保留原生 `main` 函数（declarations == 1），且仍收集函数体内多处错误。
/// 任务 #13 起函数体强制缩进：顶级函数体一律 INDENT 块（不再有内容态）。
final class ParserBodyRecoveryTests: XCTestCase {

    private func collect(_ source: String) -> ParseResult {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return parser.parseModuleCollectingErrors()
    }

    private func legacyParse(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 判别 P2-4.2 修复效果：模块应仅含一个声明，且该声明必须是名为 `main` 的
    /// `funcDecl`——既证明原生函数被保全，也证明未产生伪顶级 `.statement` 声明。
    /// 修复前错误逃出函数体，模块级 resync 把函数体残余行当成新顶级声明重解析，
    /// 此处会落到 `default`（伪 statement）分支而失败。
    private func assertSingleMainFunc(_ result: ParseResult,
                                      file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(
            result.module.declarations.count, 1,
            "应仅保留 main 函数，实际 \(result.module.declarations.count) 个声明，errors=\(result.errors)",
            file: file, line: line
        )
        guard let decl = result.module.declarations.first else { return }
        switch decl {
        case .funcDecl(let f):
            XCTAssertEqual(f.name, "main",
                           "保留的应为 main 函数，实际 \(f.name)", file: file, line: line)
        default:
            XCTFail("保留的应是 funcDecl，实际是 \(decl)，errors=\(result.errors)",
                    file: file, line: line)
        }
    }

    // MARK: - 收集模式：声明体内多错同报 + 结构保全（P2-4.2 核心）

    /// INDENT 块体内两处坏语句（`)` / `]`）应被一次性收集，
    /// 且合法的 `main` 函数仍被解析进 module、不产生伪顶级声明（declarations == 1）。
    /// 意图：验证 INDENT 块体内两处坏语句被一次性收集（errors ≥ 2），且 main 函数被保全、无伪顶级声明。
    func testCollectsMultipleStatementErrorsInIndentedBody() {
        let source = """
        main|func() -> ()
            x = 1
            )bad
            y = 2
            ]bad
            return
        """
        let result = collect(source)
        XCTAssertGreaterThanOrEqual(
            result.errors.count, 2,
            "INDENT 块体内应一次性收集多个语句级错误，实际 errors=\(result.errors)"
        )
        assertSingleMainFunc(result)
    }

    /// 顶级函数内容态（无 INDENT，语句在顶格）体内两处坏语句也应被一次性收集，
    /// 且不得产生伪顶级声明。
    /// 意图：验证顶级函数内容态（无 INDENT）体内两处坏语句被一次性收集，且无伪顶级声明。
    func testCollectsMultipleStatementErrorsInTopLevelBody() {
        let source = """
        main|func() -> ()
            )bad
            y = 2
            ]bad
            return
        """
        let result = collect(source)
        XCTAssertGreaterThanOrEqual(
            result.errors.count, 2,
            "顶级函数体内应一次性收集多个语句级错误，实际 errors=\(result.errors)"
        )
        assertSingleMainFunc(result)
    }

    /// 控制块（if 体）内两处坏语句应被一次性收集，且 if 结构本身被解析进 module、无伪声明。
    /// 意图：验证控制块（if 体）内两处坏语句被一次性收集，且 if 结构被解析进 module、无伪声明。
    func testCollectsMultipleStatementErrorsInControlBlock() {
        let source = """
        main|func() -> ()
            if x > 0:
                a = 1
                )bad
                b = 2
                ]bad
            return
        """
        let result = collect(source)
        XCTAssertGreaterThanOrEqual(
            result.errors.count, 2,
            "控制块体内应一次性收集多个语句级错误，实际 errors=\(result.errors)"
        )
        assertSingleMainFunc(result)
    }

    // MARK: - 回归防护：旧入口语义不变（遇首个错即抛）

    /// 同一含函数体内错误的来源走旧 `parseModule()` 仍应在首个错误处抛出（行为不变）。
    /// 意图：验证同一含函数体内错误的来源走旧 parseModule() 仍应在首个错误处抛出 ParserError（回归防护）。
    func testLegacyParseModuleThrowsFirstErrorInBody() {
        let source = """
        main|func() -> ()
            x = 1
            )bad
            y = 2
            ]bad
            return
        """
        XCTAssertThrowsError(try legacyParse(source),
                             "旧 parseModule() 应在首个错误处抛出") { error in
            XCTAssertTrue(error is ParserError,
                          "应抛 ParserError，实际: \(type(of: error))")
        }
    }
}
