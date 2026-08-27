import XCTest
@testable import PiniCore

/// Parser 对 `import` / `export` 顶层声明的解析与暂存。
/// 不 enforce、不解析符号——仅验证「能解析通过」且 `Module` 正确携带原始声明。
final class ImportExportTests: XCTestCase {

    private func parse(_ source: String, fileName: String = "test.pini") -> ParseResult {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try! lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return parser.parseModuleCollectingErrors()
    }

    /// 意图：验证单个 import 顶层声明解析无错误，moduleName 正确暂存为 foo。
    func testParseSingleImport() {
        let result = parse("import foo\n")
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.imports.map { $0.moduleName }, ["foo"])
    }

    /// 意图：验证单个 export 顶层声明解析无错误，symbolName 正确暂存为 Bar。
    func testParseSingleExport() {
        let result = parse("export Bar\n")
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.exports.map { $0.symbolName }, ["Bar"])
    }

    /// 意图：验证 import/export 与普通顶层声明共存时互不干扰：imports/exports 正确暂存，普通声明仍在 declarations。
    func testParseImportAndExportWithProgram() {
        let src = """
        import math
        export helper

        let helper = 1
        let main = 0
        """
        let result = parse(src)
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.imports.map { $0.moduleName }, ["math"])
        XCTAssertEqual(result.module.exports.map { $0.symbolName }, ["helper"])
        // 普通顶层声明仍在 declarations 中（import/export 已路由出去）
        XCTAssertEqual(result.module.declarations.count, 2)
    }

    /// 意图：验证 import/export 不进 declarations（由 Module 单独暂存），declarations 保持为空。
    func testImportExportNotInDeclarations() {
        let result = parse("import foo\nexport Bar\n")
        XCTAssertTrue(result.module.declarations.isEmpty,
                      "import/export 不应进入 declarations，应由 Module 单独暂存")
        XCTAssertEqual(result.module.imports.count, 1)
        XCTAssertEqual(result.module.exports.count, 1)
    }

    /// 意图：验证 import 后缺模块名时，收集模式正常报告解析错误（错误路径，不应崩溃）。
    func testImportRequiresModuleName() {
        let result = parse("import\n")
        // import 后缺模块名 → 解析错误（不应崩溃，且收集模式正常报告）
        XCTAssertFalse(result.errors.isEmpty)
    }
}
