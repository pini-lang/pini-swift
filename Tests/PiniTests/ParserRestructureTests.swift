import XCTest
@testable import PiniCore
import Foundation

/// 语法映射重组测试
///
/// 验证提案002引入的新语法：
/// - 对象声明：`{name}`（取代 `[name|object]`）
/// - 裸函数方法：`name|self(params,) -> (ret,)`（取代 `{name|self}(params,) -> (ret,)`）
/// - 顶级裸函数：`name(params,) -> (ret,)`（取代 `{name}(params,) -> (ret,)`）
final class ParserRestructureTests: XCTestCase {
    /// 捕获 stdout 的端到端运行辅助函数
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    // MARK: - Task 1: 花括号对象声明解析

    /// Intent: 验证 `{name}` 形式的对象声明能被解析为 objectDecl，并正确读取字段
    func testObjectDeclWithBraces() throws {
        let source = try loadPiniFixture("testObjectDeclWithBraces", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        // Advancing: 应解析为 objectDecl
        guard case .objectDecl(let obj) = module.declarations.first else {
            XCTFail("Expected objectDecl, got \(String(describing: module.declarations.first))")
            return
        }
        XCTAssertEqual(obj.name, "计数器")
        XCTAssertEqual(obj.fields.count, 1)
        XCTAssertEqual(obj.fields[0].name, "数值")
        // Dismissing: 不应被误判为 funcDecl
        XCTAssertEqual(obj.methods.count, 0)
    }

    // MARK: - Task 2: 对象内裸函数方法

    /// Intent: 验证对象内容态中裸函数形式 `name|self(params,) -> (ret,)` 能被解析为方法
    func testObjectMethodBareSyntax() throws {
        let source = try loadPiniFixture("testObjectMethodBareSyntax", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        guard case .objectDecl(let obj) = module.declarations.first else {
            XCTFail("Expected objectDecl, got \(String(describing: module.declarations.first))")
            return
        }
        // Advancing: 方法在 {{计数器}} 扩展块（ADR-016 规则 3.2 类型体禁方法）
        XCTAssertEqual(obj.methods.count, 0, "类型体内不再承载方法（规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("第二个声明应为扩展块")
            return
        }
        XCTAssertEqual(ext.methods.count, 2)
        XCTAssertEqual(ext.methods[0].name, "增加")
        XCTAssertEqual(ext.methods[0].modifiers, ["self"])
        XCTAssertEqual(ext.methods[1].name, "获取值")
        XCTAssertEqual(ext.methods[1].modifiers, ["self"])
        // Dismissing: 字段仍应为 1 个
        XCTAssertEqual(obj.fields.count, 1)
    }

    // MARK: - Task 3: 顶级裸函数声明

    /// Intent: 验证顶级裸函数 `name(params,) -> (ret,)` 能被解析为 funcDecl，
    /// 且多个顶级裸函数不会互相吞并（parseTopLevelFunctionBody 正确终止）
    func testTopLevelBareFunctionDecl() throws {
        let source = try loadPiniFixture("testTopLevelBareFunctionDecl", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        // Advancing: 应解析出两个顶级声明
        XCTAssertEqual(module.declarations.count, 2)
        guard case .funcDecl(let addFn) = module.declarations[0] else {
            XCTFail("Expected funcDecl for 加法, got \(module.declarations[0])")
            return
        }
        XCTAssertEqual(addFn.name, "加法")
        XCTAssertEqual(addFn.params.count, 2)
        XCTAssertEqual(addFn.returnTypes.count, 1)
        XCTAssertNotNil(addFn.body)
        // Dismissing: 第二个顶级函数 main 不应被加法吞并
        guard case .funcDecl(let mainFn) = module.declarations[1] else {
            XCTFail("Expected funcDecl for main, got \(module.declarations[1])")
            return
        }
        XCTAssertEqual(mainFn.name, "main")
    }

    // MARK: - Task 4: 枚举/结构内的裸函数方法

    /// Intent: 验证枚举内容态中裸函数方法 `name|self(params,) -> (ret,)` 能被解析，
    /// 且枚举用例（如 `北`、`圆(F64,)`）不会被误判为方法
    func testEnumExtensionMethodBareSyntax() throws {
        let source = try loadPiniFixture("testEnumExtensionMethodBareSyntax", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        guard case .enumDecl(let enumDecl) = module.declarations.first else {
            XCTFail("Expected enumDecl, got \(String(describing: module.declarations.first))")
            return
        }
        // Advancing: 用例在枚举体；方法在 [[方向]] 扩展块（ADR-016 规则 3.2）
        XCTAssertEqual(enumDecl.cases.count, 4)
        XCTAssertEqual(enumDecl.cases[0].name, "北")
        XCTAssertEqual(enumDecl.methods.count, 0, "类型体内不再承载方法（规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("第二个声明应为扩展块")
            return
        }
        XCTAssertEqual(ext.targetType, "方向")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "描述")
        XCTAssertEqual(ext.methods[0].modifiers, ["self"])
    }

    /// Intent: 验证带关联值的枚举用例不会被误判为裸函数方法
    func testEnumCaseWithAssociatedValuesNotMisreadAsMethod() throws {
        let source = try loadPiniFixture("testEnumCaseWithAssociatedValuesNotMisreadAsMethod", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        guard case .enumDecl(let enumDecl) = module.declarations.first else {
            XCTFail("Expected enumDecl")
            return
        }
        // Advancing: 2 个用例；方法在 [[形状]] 扩展块（ADR-016 规则 3.2 类型体禁方法）
        XCTAssertEqual(enumDecl.cases.count, 2)
        XCTAssertEqual(enumDecl.cases[0].name, "圆")
        XCTAssertEqual(enumDecl.cases[0].associatedParams.count, 1)
        XCTAssertEqual(enumDecl.cases[1].name, "矩形")
        XCTAssertEqual(enumDecl.cases[1].associatedParams.count, 2)
        XCTAssertEqual(enumDecl.methods.count, 0, "类型体内不再承载方法（规则 3.2）")
        // Dismissing: 圆/矩形 不应被当作方法；描述 落在 [[形状]] 扩展块
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("第二个声明应为扩展块")
            return
        }
        XCTAssertEqual(ext.targetType, "形状")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "描述")
    }

    /// Intent: 验证结构内容态中裸函数方法能被解析
    func testStructMethodBareSyntax() throws {
        let source = try loadPiniFixture("testStructMethodBareSyntax", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        guard case .structDecl(let structDecl) = module.declarations.first else {
            XCTFail("Expected structDecl, got \(String(describing: module.declarations.first))")
            return
        }
        // Advancing: 字段在类型体；方法在 ((点)) 扩展块（ADR-016 规则 3.2）
        XCTAssertEqual(structDecl.fields.count, 2)
        XCTAssertEqual(structDecl.methods.count, 0, "类型体内不再承载方法（规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("第二个声明应为扩展块")
            return
        }
        XCTAssertEqual(ext.targetType, "点")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "距离到")
        XCTAssertEqual(ext.methods[0].modifiers, ["self"])
    }

    // MARK: - Task 5: 语义分析器适配

    /// Intent: 验证新语法能完整通过语义分析（不抛 SemanticError）
    /// 包含：花括号对象、裸函数方法、|func 顶级函数
    func testBareFunctionSemanticAnalysis() throws {
        let source = try loadPiniFixture("testBareFunctionSemanticAnalysis", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        // Advancing: 应有 3 个顶级声明（对象 + {{计数器}} 扩展块 + 顶级函数；ADR-016）
        XCTAssertEqual(module.declarations.count, 3)
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module))
    }

    // MARK: - Task 6: 类型检查器与类型推导适配

    /// Intent: 验证新语法能完整通过类型检查（不抛 TypeError）
    /// 包含：顶级裸函数声明与调用
    func testBareFunctionTypeCheck() throws {
        let source = try loadPiniFixture("testBareFunctionTypeCheck", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
        let checker = TypeChecker()
        XCTAssertNoThrow(try checker.check(module: module))
    }

    // MARK: - Task 7: 解释器适配

    /// Intent: 验证新语法端到端运行正确：对象构造、方法调用、|func 顶级函数入口
    func testBareSyntaxObjectInterpreter() throws {
        let source = try loadPiniFixture("testBareSyntaxObjectInterpreter", filePath: #filePath)
        let output = try runProgram(source)
        // Advancing: 两次 增加 后获取值应输出 2
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    }

    // MARK: - 由 DraftV5AlignmentTests (Task A2) 迁入：[name|object] 括号形式对象声明

    /// Intent: 验证 `[name|object]` 形式能被解析为 objectDecl（而非 structDecl）
    func testBracketObjectParsesAsObjectDecl() throws {
        let source = try loadPiniFixture("testBracketObjectParsesAsObjectDecl", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 1, "应只有一个顶级声明")
        switch module.declarations[0] {
        case .objectDecl(let ref):
            XCTAssertEqual(ref.name, "计数器")
            XCTAssertEqual(ref.fields.count, 1)
            XCTAssertEqual(ref.fields[0].name, "值")
            XCTAssertTrue(ref.methods.isEmpty, "空 ObjectDecl 不应有方法")
        case .structDecl:
            XCTFail("应为 .objectDecl，误识别为 .structDecl")
        default:
            XCTFail("应为 .objectDecl，实际是: \(module.declarations[0])")
        }
    }

    /// Intent: `[name|object]` 实例化 + 字段访问 + 方法调用
    func testBracketObjectInstantiationAndFieldAccess() throws {
        let source = try loadPiniFixture("testBracketObjectInstantiationAndFieldAccess", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "42",
                       "ObjectDecl 字段访问应正确输出 42")
    }

    /// Intent: ObjectDecl 不可组合
    func testBracketObjectNotComposable() throws {
        let source = try loadPiniFixture("testBracketObjectNotComposable", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let interpreter = Interpreter()
        XCTAssertThrowsError(try interpreter.run(module: module)) { error in
            let errStr = String(describing: error)
            XCTAssertTrue(errStr.contains("引用块不可组合"),
                          "应报 '引用块不可组合'，实际: \(errStr)")
        }
    }
}
