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

    /// 意图：验证 import 块解析——别名/包路径正确暂存；裸语句形态被拒。
    func testParseSingleImport() {
        let result = parse("[test|import]\nfoo = \"./foo\"\n")
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.imports.map { $0.alias }, ["foo"])
        XCTAssertEqual(result.module.imports.map { $0.packagePath }, ["./foo"])
    }

    /// 意图：块头名须为当前文件名（D-1 自识性标签）——不匹配报错。
    func testImportHeaderMustBeCurrentFileName() {
        let result = parse("[wrong|import]\nfoo = \"./foo\"\n")
        XCTAssertFalse(result.errors.isEmpty, "块头名与文件名不符应报错")
        XCTAssertTrue(result.errors.contains { error in
            if case ParserError.invalidDeclaration(let reason, _) = error {
                return reason.contains("当前文件名")
            }
            return false
        }, "错误应提示当前文件名要求，实际: \(result.errors)")
    }

    /// 意图：顶级裸 import 语句已移除（G52 批 1）——解析报错并提示块形式。
    func testBareImportRemoved() {
        let result = parse("import foo\n")
        XCTAssertFalse(result.errors.isEmpty, "裸 import 应报错")
        XCTAssertTrue(result.errors.contains { error in
            if case ParserError.invalidDeclaration(let reason, _) = error {
                return reason.contains("块形式")
            }
            return false
        }, "错误应提示块形式迁移，实际: \(result.errors)")
    }

    /// 意图：验证 export 块解析——重命名项正确暂存。
    func testParseSingleExport() {
        let result = parse("[test|export]\nBar = Bar\n")
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.exports.first?.renames.first?.alias, "Bar")
        XCTAssertEqual(result.module.exports.first?.renames.first?.symbol, "Bar")
    }

    /// 意图：验证 import/export 与普通顶层声明共存时互不干扰：imports/exports 正确暂存，普通声明仍在 declarations。
    func testParseImportAndExportWithProgram() throws {
        let src = try loadPiniFixture("testParseImportAndExportWithProgram", filePath: #filePath)
        let result = parse(src, fileName: "testParseImportAndExportWithProgram.pini")
        XCTAssertTrue(result.errors.isEmpty, "解析应无错误：\(result.errors)")
        XCTAssertEqual(result.module.imports.map { $0.alias }, ["math"])
        XCTAssertEqual(result.module.exports.first?.renames.map { $0.alias }, ["helper"])
        // 普通顶层声明仍在 declarations 中（import/export 已路由出去）
        XCTAssertEqual(result.module.declarations.count, 2)
    }

    /// 意图：验证 import/export 不进 declarations（由 Module 单独暂存），declarations 保持为空。
    func testImportExportNotInDeclarations() {
        let result = parse("[test|import]\nfoo = \"./foo\"\n\n[test|export]\nBar = Bar\n")
        XCTAssertTrue(result.module.declarations.isEmpty,
                      "import/export 块不应进入 declarations，应由 Module 单独暂存")
        XCTAssertEqual(result.module.imports.count, 1)
        XCTAssertEqual(result.module.exports.count, 1)
    }

    /// 意图：验证 import 块缺项时，收集模式正常报告解析错误（错误路径，不应崩溃）。
    func testImportRequiresModuleName() {
        let result = parse("[test|import]\n")
        // import 后缺模块名 → 解析错误（不应崩溃，且收集模式正常报告）
        XCTAssertFalse(result.errors.isEmpty)
    }
}
