import XCTest
import PiniCore

/// 错误收集基础设施：Parser 由『遇错即抛』升级为『可累积多错』。
/// 验收钥匙：单文件可一次性报出多个错误（roadmap P2 关门项）。
///
/// 设计：保留旧入口 `parseModule() throws` 语义不变（遇首个错即抛，回归防护）；
/// 新增 `parseModuleCollectingErrors() -> ParseResult`（module + errors）开启收集模式，
/// 在顶级声明循环内 catch 每个 `ParserError` 并 resync 到下一行继续，从而真实收集多错。
/// 声明头语法：struct `(Name)`、object `{Obj}`、裸函数 `name|func(...)`、方括号 `[Name|kw]`。
final class ParserErrorCollectionTests: XCTestCase {

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

    // MARK: - 收集模式：多错同报（P2-4.1 核心）

    /// 三个方括号声明头 `[Name|非法修饰符]` 各自在 header 阶段抛 invalidDeclaration；
    /// 收集模式应捕获 ≥ 2 个错误，且不抛异常（证明单文件多错同报能力）。
    /// 意图：验证收集模式一次性捕获 ≥ 2 个顶级声明头错误且不抛异常，resync 后合法 main 函数仍被解析进 module。
    func testCollectingErrorsCapturesMultipleTopLevelErrors()  throws {
        let source = try loadPiniFixture("testCollectingErrorsCapturesMultipleTopLevelErrors", filePath: #filePath)
        let result = collect(source)
        XCTAssertGreaterThanOrEqual(
            result.errors.count, 2,
            "收集模式应一次性捕获多个顶级声明错误，实际 errors=\(result.errors)"
        )
        // 合法的 main 函数仍应被解析进 module（证明 resync 后继续解析）
        XCTAssertFalse(result.module.declarations.isEmpty,
                       "resync 后应继续解析后续合法声明")
    }

    /// 合法源在收集模式下不产生任何错误，且 module 含预期声明。
    /// 意图：验证合法源在收集模式下不产生任何解析错误，且 module 含预期的 2 个声明。
    func testCollectingErrorsEmptyForValidSource()  throws {
        let source = try loadPiniFixture("testCollectingErrorsEmptyForValidSource", filePath: #filePath)
        let result = collect(source)
        XCTAssertTrue(result.errors.isEmpty,
                      "合法源不应有解析错误，实际 errors=\(result.errors)")
        XCTAssertEqual(result.module.declarations.count, 2)
    }

    // MARK: - 回归防护：旧入口语义不变（遇首个错即抛）

    /// 同一来源走旧 `parseModule()` 仍应在首个错误处抛出（行为不变）。
    /// 意图：验证同一来源走旧 parseModule() 仍应在首个错误处抛出 ParserError（行为不变）。
    func testLegacyParseModuleStillThrowsOnFirstError()  throws {
        let source = try loadPiniFixture("testLegacyParseModuleStillThrowsOnFirstError", filePath: #filePath)
        XCTAssertThrowsError(try legacyParse(source),
                             "旧 parseModule() 应在首个错误处抛出") { error in
            XCTAssertTrue(error is ParserError,
                          "应抛 ParserError，实际: \(type(of: error))")
        }
    }
}
