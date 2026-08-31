import XCTest
import PiniCore

/// 重声明检测（Redeclaration Detection）
///
/// 交互端即语义分析的真实公共链路：
///   源码 → Lexer.tokenize() → Parser.parseModule() → SemanticAnalyzer.analyze(module:)
/// 断言「同一作用域内重复定义同名符号」会被捕获为 `SemanticError.redeclaredSymbol`。
///
/// 行为清单（垂直切片，逐条 RED→GREEN）：
///   3.1 顶级同名符号重声明（函数 / 结构体）
///   3.2 同作用域局部变量重声明（嵌套作用域遮蔽属正常，不报错）
///   3.3 类型（struct/object）成员名冲突（字段-字段 / 字段-方法 / 方法-方法）
final class SemanticRedeclarationTests: XCTestCase {

    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 断言源码经语义分析后抛出 redeclaredSymbol(name:)，且名字匹配。
    private func assertRedeclared(_ source: String, name expected: String, _ message: String = "") {
        let module = try! parseModule(source)
        let analyzer = SemanticAnalyzer()
        XCTAssertThrowsError(try analyzer.analyze(module: module), message) { error in
            guard case SemanticError.redeclaredSymbol(name: expected, _) = error else {
                XCTFail("应为 redeclaredSymbol(name: \"\(expected)\")，实际: \(error)")
                return
            }
        }
    }

    // MARK: - P2-3.1 顶级重声明

    /// 同名顶级函数重复定义 → redeclaredSymbol("foo")
    /// 意图：验证重复定义同名顶级函数 foo 被语义分析捕获为 redeclaredSymbol("foo")。
    func testRedeclaredTopLevelFunction()  throws {
        assertRedeclared(
            try loadPiniFixture("testRedeclaredTopLevelFunction", filePath: #filePath) as String,
            name: "foo",
            "重复定义同名顶级函数应抛错"
        )
    }

    /// 同名顶级结构体重复定义 → redeclaredSymbol("Point")
    /// 意图：验证重复定义同名顶级结构体 Point 被语义分析捕获为 redeclaredSymbol("Point")。
    func testRedeclaredTopLevelStruct()  throws {
        assertRedeclared(
            try loadPiniFixture("testRedeclaredTopLevelStruct", filePath: #filePath) as String,
            name: "Point",
            "重复定义同名顶级结构体应抛错"
        )
    }

    /// 反向：不同名顶级声明应被正常接受
    /// 意图：反向验证不同名顶级声明 foo/bar 不被误报为重声明，analyze 正常通过（XCTAssertNoThrow）。
    func testDistinctTopLevelNamesAccepted()  throws {
        let source = try loadPiniFixture("testDistinctTopLevelNamesAccepted", filePath: #filePath)
        let module = try! parseModule(source)
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module), "不同名声明不应抛错")
    }

    // MARK: - P2-3.2 同作用域局部变量重声明

    /// 同一函数作用域内 `var x` 重复绑定 → redeclaredSymbol("x")
    /// 意图：验证同一函数作用域内 var x 重复绑定被语义分析捕获为 redeclaredSymbol("x")。
    func testRedeclaredLocalVariableInSameScope()  throws {
        assertRedeclared(
            try loadPiniFixture("testRedeclaredLocalVariableInSameScope", filePath: #filePath) as String,
            name: "x",
            "同作用域重复绑定局部变量应抛错"
        )
    }

    /// 反向：嵌套作用域中的遮蔽（shadowing）属正常，不应报错
    /// 意图：反向验证嵌套作用域的遮蔽（if 块内 var x）属正常，analyze 不抛 redeclaredSymbol。
    func testShadowingInNestedScopeAllowed()  throws {
        let source = try loadPiniFixture("testShadowingInNestedScopeAllowed", filePath: #filePath)
        let module = try! parseModule(source)
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module), "嵌套作用域遮蔽不应报错")
    }

    // MARK: - P2-3.3 类型成员名冲突

    /// 结构体重复字段名 → redeclaredSymbol("x")
    /// 意图：验证结构体内重复字段名 x 被语义分析捕获为 redeclaredSymbol("x")。
    func testStructDuplicateField()  throws {
        assertRedeclared(
            try loadPiniFixture("testStructDuplicateField", filePath: #filePath) as String,
            name: "x",
            "结构体内重复字段名应抛错"
        )
    }

    /// 结构体字段与方法同名冲突 → redeclaredSymbol("x")
    /// 意图：验证结构体字段与方法同名冲突（x: I32 与 x|self()）被语义分析捕获为 redeclaredSymbol("x")。
    func testStructFieldMethodConflict()  throws {
        assertRedeclared(
            try loadPiniFixture("testStructFieldMethodConflict", filePath: #filePath) as String,
            name: "x",
            "字段与方法同名应抛错"
        )
    }

    /// 对象块重复字段名 → redeclaredSymbol("x")
    /// 意图：验证对象块内重复字段名 x 被语义分析捕获为 redeclaredSymbol("x")。
    func testObjectDuplicateField()  throws {
        assertRedeclared(
            try loadPiniFixture("testObjectDuplicateField", filePath: #filePath) as String,
            name: "x",
            "对象块内重复字段名应抛错"
        )
    }

    // MARK: - P5-5 HIGH-1 枚举 case 命名空间化

    /// 跨枚举同名 case（形状.圆 与 几何.圆）允许共存，不应报 redeclaredSymbol。
    /// 这是 HIGH-1 的核心验收点：case 名按枚举隔离，不再全局唯一。
    /// 意图：验证跨枚举同名 case（形状.圆 与 几何.圆）按枚举命名空间隔离共存，analyze 不抛 redeclaredSymbol（HIGH-1 核心验收点）。
    func testCrossEnumSameCaseNameAllowed()  throws {
        let source = try loadPiniFixture("testCrossEnumSameCaseNameAllowed", filePath: #filePath)
        let module = try! parseModule(source)
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module),
                         "跨枚举同名 case 应允许共存（HIGH-1 命名空间化）")
    }

    /// 反向：同一枚举内重复 case 名仍应报 redeclaredSymbol（命名空间隔离不放松同枚举内唯一性）。
    /// 意图：反向验证同一枚举内重复 case 名圆 仍被捕获为 redeclaredSymbol（命名空间隔离不放松同枚举内唯一性）。
    func testSameEnumDuplicateCaseNameRejected()  throws {
        assertRedeclared(
            try loadPiniFixture("testSameEnumDuplicateCaseNameRejected", filePath: #filePath) as String,
            name: "圆",
            "同一枚举内重复 case 名应抛错"
        )
    }
}
