import XCTest
@testable import PiniCore

/// 类型体内禁止函数声明 + 扩展块方法显式 `self` 修饰符（ADR-016 规则 3.2/3.14）
///
/// 类型体（struct/object/enum）内任何函数声明（含 `|self`）一律报 invalidStatement，
/// 方法须移至同文件扩展块 `((T))`/`{{T}}`/`[[T]]` 并显式 `|self`（或 `|own`，G50）；
/// 扩展块内缺 `self` 的自由函数同样报错；顶级裸函数无需 `self`。
/// （由 DraftV5AlignmentTests 的 Task A5 迁入，随 ADR-016 规则 3.2 重写。）
final class MethodSelfModifierTests: XCTestCase {

    /// StructDecl 内函数声明应报错（ADR-016 规则 3.2 类型体禁函数）
    /// 意图：验证 StructDecl 内裸函数（无论有无 self 修饰符）一律抛 invalidStatement，
    /// 提示方法移至扩展块；错误位置 loc.line > 0。
    func testStructDeclMethodWithoutSelfModifierErrors() throws {
        let source = try loadPiniFixture("testStructDeclMethodWithoutSelfModifierErrors", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")

        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidStatement(let reason, let loc) = error else {
                XCTFail("应为 invalidStatement（类型体禁函数），实际: \(error)")
                return
            }
            XCTAssertGreaterThan(loc.line, 0, "应有有效错误位置")
            XCTAssertTrue(reason.contains("扩展块"), "报错应指引到扩展块，实际: \(reason)")
        }
    }

    /// StructDecl 内旧花括号语法 {name} 也应报错（ADR-016 规则 3.2）
    /// 意图：验证 StructDecl 内旧花括号 {移动} 函数声明同样抛 invalidStatement（类型体禁函数）。
    func testStructDeclOldBraceSyntaxWithoutSelfErrors() throws {
        let source = try loadPiniFixture("testStructDeclOldBraceSyntaxWithoutSelfErrors", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")

        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidStatement = error else {
                XCTFail("应为 invalidStatement（类型体禁函数），实际: \(error)")
                return
            }
        }
    }

    /// StructDecl 内 |self 裸函数合法
    /// 意图：验证 StructDecl 内 `|self` 修饰方法可正常解析；应生成 .structDecl、方法名"移动"且 modifiers 含 "self"。
    func testStructDeclMethodWithSelfModifierParses() throws {
        let source = try loadPiniFixture("testStructDeclMethodWithSelfModifierParses", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 2)
        guard case .structDecl(let sd) = module.declarations[0] else { XCTFail("应为 .structDecl"); return }
        XCTAssertEqual(sd.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("第二个声明应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "点")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "移动")
        XCTAssertTrue(ext.methods[0].modifiers.contains("self"), "modifiers 应包含 'self'")
    }

    /// StructDecl 内 |own（G50 更名自 |Self）也合法
    /// 意图：验证 StructDecl 内 `|own` 本型方法修饰符同样合法；应生成 .structDecl 且方法 modifiers 含 "own"。
    func testStructDeclMethodWithOwnModifierParses() throws {
        let source = try loadPiniFixture("testStructDeclMethodWithOwnModifierParses", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 2)
        guard case .structDecl(let sd) = module.declarations[0] else { XCTFail("应为 .structDecl"); return }
        XCTAssertEqual(sd.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("第二个声明应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "点")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertTrue(ext.methods[0].modifiers.contains("own"), "modifiers 应包含 'own'")
    }

    /// 顶级裸函数无需 self 修饰符
    /// 意图：验证顶级裸函数无需 `self` 修饰符即可解析；应生成 .funcDecl 且函数名为 main。
    func testTopLevelFuncDoesNotNeedSelf() throws {
        let source = try loadPiniFixture("testTopLevelFuncDoesNotNeedSelf", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 1)
        if case .funcDecl(let fd) = module.declarations[0] {
            XCTAssertEqual(fd.name, "main")
        } else {
            XCTFail("应为 .funcDecl")
        }
    }

    /// 顶级花括号函数 {name} 无需 self 修饰符
    /// 意图：验证顶级花括号函数 {main} 无需 `self` 修饰符即可解析；应生成 .funcDecl 且函数名为 main。
    func testTopLevelBraceFuncDoesNotNeedSelf() throws {
        let source = try loadPiniFixture("testTopLevelBraceFuncDoesNotNeedSelf", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 1)
        if case .funcDecl(let fd) = module.declarations[0] {
            XCTAssertEqual(fd.name, "main")
        } else {
            XCTFail("应为 .funcDecl")
        }
    }

    /// ObjectDecl 内函数声明应报错（ADR-016 规则 3.2 类型体禁函数）
    /// 意图：验证 ObjectDecl 内裸函数一律抛 invalidStatement（类型体禁函数）。
    func testObjectDeclMethodWithoutSelfErrors() throws {
        let source = try loadPiniFixture("testObjectDeclMethodWithoutSelfErrors", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")

        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidStatement = error else {
                XCTFail("应为 invalidStatement（类型体禁函数），实际: \(error)")
                return
            }
        }
    }

    /// ObjectDecl（[name|object] 括号形式）内函数声明应报错（ADR-016 规则 3.2）
    /// 意图：验证 ObjectDecl 括号形式 [计数器|object] 内函数声明同样抛 invalidStatement。
    func testObjectDeclBracketMethodWithoutSelfErrors() throws {
        let source = try loadPiniFixture("testObjectDeclBracketMethodWithoutSelfErrors", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")

        XCTAssertThrowsError(try parser.parseModule()) { error in
            guard case ParserError.invalidStatement = error else {
                XCTFail("应为 invalidStatement（类型体禁函数），实际: \(error)")
                return
            }
        }
    }

    /// ObjectDecl 内 |self 合法
    /// 意图：验证 ObjectDecl 内 `|self` 修饰方法可正常解析；应生成 .objectDecl、方法数 1 且 modifiers 含 "self"。
    func testObjectDeclMethodWithSelfParses() throws {
        let source = try loadPiniFixture("testObjectDeclMethodWithSelfParses", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        XCTAssertEqual(module.declarations.count, 2)
        guard case .objectDecl(let od) = module.declarations[0] else { XCTFail("应为 .objectDecl"); return }
        XCTAssertEqual(od.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("第二个声明应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "计数器")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertTrue(ext.methods[0].modifiers.contains("self"))
    }
}
