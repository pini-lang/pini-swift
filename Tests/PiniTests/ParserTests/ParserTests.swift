import XCTest
import PiniCore
import Foundation

final class ParserTests: XCTestCase {
    private func parse(source: String, fileName: String = "test.pini") throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return try parser.parseModule()
    }

    /// 意图：验证空源码解析为不含任何声明的空 Module。
    func testParseEmptyModule() throws {
        let module = try parse(source: "")
        XCTAssertEqual(module.declarations.count, 0, "空模块不应有声明")
    }

    /// 意图：验证最小函数声明 main() -> () 解析成功：应得到唯一的、带函数体的 main 声明。
    func testParseSimpleFunction() throws {
        let source = try loadPiniFixture("testParseSimpleFunction", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 1, "应只有一个声明")
        if case .funcDecl(let funcDecl) = module.declarations[0] {
            XCTAssertEqual(funcDecl.name, "main", "函数名应为 main")
            XCTAssertNotNil(funcDecl.body, "函数应有体")
        } else {
            XCTFail("应为函数声明")
        }
    }

    // MARK: - P3-2 `?` 可选类型糖（前缀 ?T = Optional<T>，spec G31 / G31）

    /// 提取 main 函数体内名为 `name` 的变量声明的类型标注。
    private func varType(in module: Module, name: String) -> TypeAnnotation? {
        for decl in module.declarations {
            if case .funcDecl(let f) = decl, f.name == "main" {
                for stmt in f.body?.statements ?? [] {
                    if case .varDecl(let vName, let type, _, _, _) = stmt, vName == name {
                        return type
                    }
                }
            }
        }
        return nil
    }

    /// 意图：验证 ?I32 可选类型糖解析为 Optional<I32> 泛型标注（?T = Optional<T>）。
    func testParseQuestionTypeSimple() throws {
        let module = try parse(source: try loadPiniFixture("testParseQuestionTypeSimple", filePath: #filePath) as String)
        let type = try XCTUnwrap(varType(in: module, name: "x"),
                                "应能从 main 函数体取到变量 x 的类型标注")
        guard case .generic(let name, let params, _) = type else {
            XCTFail("?I32 应解析为 generic，实际：\(type)"); return
        }
        XCTAssertEqual(name, "Optional", "?I32 应映射为 Optional 泛型")
        XCTAssertEqual(params.count, 1, "Optional 应有 1 个类型参数")
        if case .simple(let inner, _) = params[0] {
            XCTAssertEqual(inner, "I32", "内层应为 I32")
        } else {
            XCTFail("Optional 内层应为 simple(I32)，实际：\(params[0])")
        }
    }

    /// 意图：验证嵌套 ??I32 解析为双层 Optional<Optional<I32>>，最内层为 I32。
    func testParseQuestionTypeNested() throws {
        let module = try parse(source: try loadPiniFixture("testParseQuestionTypeNested", filePath: #filePath) as String)
        let type = try XCTUnwrap(varType(in: module, name: "x"),
                                "应能从 main 函数体取到变量 x 的类型标注")
        guard case .generic(let name, let params, _) = type else {
            XCTFail("??I32 应解析为 generic，实际：\(type)"); return
        }
        XCTAssertEqual(name, "Optional", "外层应为 Optional")
        XCTAssertEqual(params.count, 1)
        guard case .generic(let innerName, let innerParams, _) = params[0] else {
            XCTFail("内层应为 Optional 泛型，实际：\(params[0])"); return
        }
        XCTAssertEqual(innerName, "Optional", "内层应为 Optional")
        if case .simple(let innermost, _) = innerParams[0] {
            XCTAssertEqual(innermost, "I32", "最内层应为 I32")
        } else {
            XCTFail("最内层应为 simple(I32)")
        }
    }

    /// 意图：回归保护——验证手写 Optional<I32> 泛型仍按原样解析，不受 ? 糖影响。
    func testParseOptionalGenericUnchanged() throws {
        // 回归保护：手写 Optional<I32> 仍按原样解析，不受 ? 糖影响
        let module = try parse(source: try loadPiniFixture("testParseOptionalGenericUnchanged", filePath: #filePath) as String)
        let type = try XCTUnwrap(varType(in: module, name: "x"))
        guard case .generic(let name, let params, _) = type else {
            XCTFail("Optional<I32> 应解析为 generic，实际：\(type)"); return
        }
        XCTAssertEqual(name, "Optional")
        XCTAssertEqual(params.count, 1)
        if case .simple(let inner, _) = params[0] {
            XCTAssertEqual(inner, "I32")
        } else {
            XCTFail("内层应为 simple(I32)")
        }
    }


    /// 意图：验证顶层函数体无缩进时也能解析出两条语句（print、return）。
    /// 意图（任务 #13 反转）：函数体强制缩进已采纳——非缩进顶级函数体须报错
    /// 推进性测量：未缩进的 `main() -> ()` 体抛出 invalidStatement
    /// 驳回性测量：非缩进体被静默接受（旧内容态行为）
    func testParseTopLevelFunctionBodyWithoutIndentRejected() throws {
        let source = try loadPiniFixture("testParseTopLevelFunctionBodyWithoutIndentRejected", filePath: #filePath)
        XCTAssertThrowsError(try parse(source: source), "函数体必须缩进至少一层") { error in
            guard case ParserError.invalidStatement(let reason, _) = error else {
                XCTFail("应为 invalidStatement，实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("缩进"), "报错应提示缩进，实际: \(reason)")
        }
    }

    /// 意图：缩进体顶级函数正确解析为独立声明（替代旧内容态多声明累积）
    func testParseTopLevelFunctionBodyWithMultipleDecls() throws {
        let source = try loadPiniFixture("testParseTopLevelFunctionBodyWithMultipleDecls", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 2, "应有两个函数声明")
        if case .funcDecl(let f1) = module.declarations[0] {
            XCTAssertEqual(f1.name, "main")
            XCTAssertEqual(f1.body?.statements.count, 2, "main 体应有两条语句")
        }
        if case .funcDecl(let f2) = module.declarations[1] {
            XCTAssertEqual(f2.name, "other")
        }
    }

    /// 意图：验证带尾逗号的参数列表 add(a, b,) 解析出 a、b 两个参数。
    func testParseFunctionWithParameters() throws {
        let source = try loadPiniFixture("testParseFunctionWithParameters", filePath: #filePath)
        let module = try parse(source: source)

        if case .funcDecl(let funcDecl) = module.declarations[0] {
            XCTAssertEqual(funcDecl.params.count, 2, "应有两个参数")
            XCTAssertEqual(funcDecl.params[0].name, "a")
            XCTAssertEqual(funcDecl.params[1].name, "b")
        } else {
            XCTFail("应为函数声明")
        }
    }

    /// 意图：验证 (名称) 结构体声明解析出名称与两个字段（x、y）。
    func testParseStructDecl() throws {
        let source = try loadPiniFixture("testParseStructDecl", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 1)
        if case .structDecl(let structDecl) = module.declarations[0] {
            XCTAssertEqual(structDecl.name, "点")
            XCTAssertEqual(structDecl.fields.count, 2, "应有两个字段")
        }
    }

    /// 意图：验证 {名称} 对象声明解析出名称与一个字段（数值）。
    func testParseObjectDecl() throws {
        let source = try loadPiniFixture("testParseObjectDecl", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 1)
        if case .objectDecl(let objectDecl) = module.declarations[0] {
            XCTAssertEqual(objectDecl.name, "计数对象")
            XCTAssertEqual(objectDecl.fields.count, 1)
        }
    }

    /// 意图：验证 [名称] 枚举声明解析出名称与两个 case（圆、矩形）。
    func testParseEnumDecl() throws {
        let source = try loadPiniFixture("testParseEnumDecl", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 1)
        if case .enumDecl(let enumDecl) = module.declarations[0] {
            XCTAssertEqual(enumDecl.name, "形状")
            XCTAssertEqual(enumDecl.cases.count, 2)
        }
    }

    /// 意图：验证对象方法（名称|self() -> ()）解析并归入 objectDecl.methods。
    func testParseMethodDefaultAssumption() throws {
        let source = try loadPiniFixture("testParseMethodDefaultAssumption", filePath: #filePath)
        let module = try parse(source: source)

        XCTAssertEqual(module.declarations.count, 3)
        guard case .objectDecl(let objectDecl) = module.declarations[0] else { XCTFail("应为对象"); return }
        XCTAssertEqual(objectDecl.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("第二个声明应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "计数对象")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "增加")
    }

    /// 意图：验证 x + y 解析为 binary 表达式：左右操作数分别为 x、y，运算符为 +。
    func testParseExpressionBinary() throws {
        let source = try loadPiniFixture("testParseExpressionBinary", filePath: #filePath)
        let module = try parse(source: source)

        if case .funcDecl(let funcDecl) = module.declarations[0], let body = funcDecl.body {
            if case .expressionStmt(expr: let expr, _) = body.statements[0] {
                if case .binary(let left, let op, let right, _) = expr {
                    if case .identifier("x", _) = left {
                    } else { XCTFail("左操作数应为 x") }
                    if case .identifier("y", _) = right {
                    } else { XCTFail("右操作数应为 y") }
                    XCTAssertEqual(op, BinaryOperator.plus, "操作符应为 +")
                } else {
                    XCTFail("应为二元表达式")
                }
            }
        }
    }

    /// 意图：验证 if 块的缩进子块被解析，thenBlock 含一条语句。
    func testParseControlBlockIndentation() throws {
        let source = try loadPiniFixture("testParseControlBlockIndentation", filePath: #filePath)
        let module = try parse(source: source)

        if case .funcDecl(let funcDecl) = module.declarations[0], let body = funcDecl.body {
            if case .ifStatement(_, let thenBlock, _, _, _, _) = body.statements[0] {
                XCTAssertEqual(thenBlock.statements.count, 1, "if 块应有一条语句")
            }
        }
    }

    /// 意图：验证 `outer|while` 的标签解析到 whileStatement 的 label "outer"（ADR-014：标签语法逆转 ADR-013）。
    func testParseWhileWithLabel() throws {
        let source = try loadPiniFixture("testParseWhileWithLabel", filePath: #filePath)
        let module = try parse(source: source)

        if case .funcDecl(let funcDecl) = module.declarations[0], let body = funcDecl.body {
            if case .whileStatement(_, let whileBody, _, let label, _) = body.statements[0] {
                XCTAssertEqual(label, "outer", "while 标签应为 outer")
                XCTAssertEqual(whileBody.statements.count, 1, "while 体应有一条 print 语句")
            } else {
                XCTFail("应为带标签的 while 语句")
            }
        }
    }

    /// 意图：验证 while 后的 step: 块被解析，且含一条 print 语句。
    func testParseWhileWithStep() throws {
        let source = try loadPiniFixture("testParseWhileWithStep", filePath: #filePath)
        let module = try parse(source: source)

        if case .funcDecl(let funcDecl) = module.declarations[0], let body = funcDecl.body {
            if case .whileStatement(_, _, let step, _, _) = body.statements[0] {
                XCTAssertNotNil(step, "while 后的 step 块应被解析")
                XCTAssertEqual(step?.statements.count, 1, "step 块应含一条 print 语句")
            } else {
                XCTFail("应为带 step 的 while")
            }
        } else {
            XCTFail("应为函数声明且含体")
        }
    }

    /// 意图：验证无 step 语法时 while 的 step 字段保持为 nil。
    func testParseWhileWithoutStepKeepsNil() throws {
        let source = try loadPiniFixture("testParseWhileWithoutStepKeepsNil", filePath: #filePath)
        let module = try parse(source: source)
        if case .funcDecl(let funcDecl) = module.declarations[0], let body = funcDecl.body {
            if case .whileStatement(_, _, let step, _, _) = body.statements[0] {
                XCTAssertNil(step, "无 step 语法时 step 应为 nil")
            } else {
                XCTFail("应为 while")
            }
        } else {
            XCTFail("应为函数声明且含体")
        }
    }

    /// 意图：验证带返回类型 (I32,) 的函数字面量表达式可解析，模块仅一个声明。
    func testParseFuncLiteralWithReturnType() throws {
        let source = try loadPiniFixture("testParseFuncLiteralWithReturnType", filePath: #filePath)
        let module = try parse(source: source)
        XCTAssertEqual(module.declarations.count, 1)
    }

    /// 意图：验证不完整语法 {main( 在解析时抛出错误。
    func testParseInvalidSyntax() throws {
        let source = "{main("
        XCTAssertThrowsError(try parse(source: source), "不完整的语法应抛出错误")
    }

    // MARK: - P2-1 `nil` 关键字（spec G30 / G30）

    /// 意图：验证 nil 表达式映射为 .member(.identifier("Optional"), "none")，与 Optional.none 同构、零新增 case。
    func testParseNilAsOptionalNoneMember() throws {
        // `nil` 在表达式位置应映射为与 `Optional.none` 完全同构的
        // `.member(.identifier("Optional"), "none")` AST（零新增 Expression case）。
        let source = try loadPiniFixture("testParseNilAsOptionalNoneMember", filePath: #filePath)
        let module = try parse(source: source)
        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let body = funcDecl.body else {
            XCTFail("应为带体的函数声明"); return
        }
        guard case .varDecl(_, _, let initializer, _, _) = body.statements[0] else {
            XCTFail("首条语句应为 varDecl"); return
        }
        guard case .member(let object, let name, _) = initializer else {
            XCTFail("nil 应解析为 .member，实际：\(String(describing: initializer))"); return
        }
        guard case .identifier(let typeName, _) = object else {
            XCTFail("member object 应为 Optional 标识符"); return
        }
        XCTAssertEqual(typeName, "Optional", "nil 应解析为 Optional.none")
        XCTAssertEqual(name, "none", "nil 应解析为 Optional.none")
    }

    /// 意图：验证 match case nil: 映射为 .enumCase("none")，与 case none 同构。
    func testParseMatchCaseNil() throws {
        // `match case nil:` 应映射为 `.enumCase("none")`（与 `case none:` 同构）。
        let source = try loadPiniFixture("testParseMatchCaseNil", filePath: #filePath)
        let module = try parse(source: source)
        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let body = funcDecl.body else {
            XCTFail("应为带体的函数声明"); return
        }
        // 第二条语句是 match
        guard case .matchStatement(_, let cases, _) = body.statements[1] else {
            XCTFail("第二条语句应为 match"); return
        }
        XCTAssertEqual(cases.count, 1, "应恰好一个 case")
        guard case .enumCase(let name) = cases[0].pattern else {
            XCTFail("case nil 应解析为 .enumCase"); return
        }
        XCTAssertEqual(name, "none", "case nil 应映射为 .enumCase(\"none\")")
    }
}
