import XCTest
@testable import PiniCore

/// G-P7（自举探针批次 3）：`pini parse` 投影补齐——step 块 / 字段初始化器 /
/// import-export 此前不渲染（宿主 AST 持有数据但投影丢弃）。
/// 本文件断言 AST 持有性；CLI 渲染（main.swift describeAST）已由探针实证，
/// CLI 属独立 target，不在单测面内。
final class ParseProjectionTests: XCTestCase {

    /// 意图：AST 持有 while step 块、字段初始化器、import/export（投影补齐的数据前提）
    /// 推进性测量：三者均被 AST 持有
    /// 驳回性测量：任一缺失即不合格
    func testASTHoldsStepFieldInitAndImports() throws {
        let source = try loadPiniFixture("testASTHoldsStepFieldInitAndImports", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "testASTHoldsStepFieldInitAndImports.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "testASTHoldsStepFieldInitAndImports.pini")
        let module = try parser.parseModule()

        XCTAssertFalse(module.imports.isEmpty, "import 应进入 Module.imports")
        XCTAssertEqual(module.imports.first?.alias, "std")

        let structDecl = module.declarations.first(where: { decl in
            if case .structDecl = decl { return true }
            return false
        })
        guard case .structDecl(let sd)? = structDecl else {
            return XCTFail("struct pt 应在顶层声明中")
        }
        guard case .integerLiteral(let v, _)? = sd.fields.first?.initializer else {
            return XCTFail("字段初始化器应被 AST 持有")
        }
        XCTAssertEqual(v, 5)

        let mainDecl = module.declarations.first(where: { decl in
            if case .funcDecl(let f) = decl { return f.name == "main" }
            return false
        })
        guard case .funcDecl(let f)? = mainDecl else {
            return XCTFail("main 应在顶层声明中")
        }
        var foundWhileWithStep = false
        for stmt in f.body!.statements {
            if case .whileStatement(_, _, let step, _, _) = stmt, step != nil {
                foundWhileWithStep = true
            }
        }
        XCTAssertTrue(foundWhileWithStep, "while 的 step 块应被 AST 持有")
    }
}
