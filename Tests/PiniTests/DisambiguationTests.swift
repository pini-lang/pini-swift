import XCTest
@testable import PiniCore

final class DisambiguationTests: XCTestCase {

    /// 意图：ParseContext 枚举应存在两个 case
    func testParseContextCases() {
        let typePos = ParseContext.typePosition
        let valuePos = ParseContext.valuePosition

        XCTAssertNotEqual(typePos, valuePos, "两个上下文 case 应不相等")
    }

    /// 意图：genericConstruct 节点应能构造且相等比较
    func testGenericConstructExpression() {
        let loc = SourceLocation(line: 1, column: 1, fileName: "test.pini")
        let intType = TypeAnnotation.simple(name: "I32", location: loc)
        let expr1 = Expression.genericConstruct(
            typeName: "容器",
            typeArgs: [intType],
            arguments: [],
            location: loc
        )
        let expr2 = Expression.genericConstruct(
            typeName: "容器",
            typeArgs: [intType],
            arguments: [],
            location: loc
        )
        let expr3 = Expression.genericConstruct(
            typeName: "容器",
            typeArgs: [TypeAnnotation.simple(name: "String", location: loc)],
            arguments: [],
            location: loc
        )

        XCTAssertEqual(expr1, expr2, "相同泛型构造应相等")
        XCTAssertNotEqual(expr1, expr3, "不同类型参数不应相等")
    }

    /// 意图：前瞻判定应识别 容器<I32>() 为泛型构造调用
    func testLookaheadGenericConstructWithCall() throws {
        let source = try loadPiniFixture("testLookaheadGenericConstructWithCall", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0] else {
            XCTFail("应为函数声明")
            return
        }
        guard let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .genericConstruct(let typeName, let typeArgs, let args, _) = initializer else {
            XCTFail("应为 genericConstruct 节点")
            return
        }
        XCTAssertEqual(typeName, "容器")
        XCTAssertEqual(typeArgs.count, 1)
        if case .simple(let name, _) = typeArgs[0] {
            XCTAssertEqual(name, "I32")
        } else {
            XCTFail("类型参数应为 I32")
        }
        XCTAssertTrue(args.isEmpty, "无参构造应无参数")
    }

    /// 意图：前瞻判定应将 a < b 识别为比较运算（非泛型构造）
    func testLookaheadComparisonNotGenericConstruct() throws {
        let source = try loadPiniFixture("testLookaheadComparisonNotGenericConstruct", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .binary(_, let op, _, _) = initializer else {
            XCTFail("应为 binary 节点（比较运算）")
            return
        }
        XCTAssertEqual(op, .lessThan, "应识别为 lessThan 运算符")
    }

    private func parseModule(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        return try parser.parseModule()
    }

    /// 意图：泛型构造调用应能带参数
    func testGenericConstructWithArguments() throws {
        let source = try loadPiniFixture("testGenericConstructWithArguments", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .genericConstruct(let typeName, let typeArgs, let args, _) = initializer else {
            XCTFail("应为 genericConstruct 节点")
            return
        }
        XCTAssertEqual(typeName, "容器")
        XCTAssertEqual(typeArgs.count, 1)
        XCTAssertEqual(args.count, 1, "应有一个参数")
        if case .integerLiteral(let v, _) = args[0].expression {
            XCTAssertEqual(v, 42)
        } else {
            XCTFail("参数应为整数字面量 42")
        }
    }

    /// 意图：多类型参数的泛型构造调用
    func testGenericConstructMultipleTypeArgs() throws {
        let source = try loadPiniFixture("testGenericConstructMultipleTypeArgs", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .genericConstruct(let typeName, let typeArgs, _, _) = initializer else {
            XCTFail("应为 genericConstruct 节点")
            return
        }
        XCTAssertEqual(typeName, "映射")
        XCTAssertEqual(typeArgs.count, 2, "应有两个类型参数")
        if case .simple(let n1, _) = typeArgs[0] {
            XCTAssertEqual(n1, "String")
        } else {
            XCTFail("第一个类型参数应为 String")
        }
        if case .simple(let n2, _) = typeArgs[1] {
            XCTAssertEqual(n2, "I32")
        } else {
            XCTFail("第二个类型参数应为 I32")
        }
    }

    /// 意图：a < b > c 应识别为链式比较而非泛型构造
    func testChainedComparisonNotGenericConstruct() throws {
        let source = try loadPiniFixture("testChainedComparisonNotGenericConstruct", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .binary(let left, let op1, _, _) = initializer else {
            XCTFail("应为 binary 节点")
            return
        }
        // 应是 (a < b) > c 或 a < (b > c)——按优先级左结合，应为 (a < b) > c
        XCTAssertEqual(op1, .greaterThan, "外层应为 greaterThan")
        // 左侧应是 a < b
        if case .binary(_, let op2, _, _) = left {
            XCTAssertEqual(op2, .lessThan, "内层应为 lessThan")
        } else {
            XCTFail("左操作数应为 binary")
        }
    }

    /// 意图：容器<I32> 后跟非 ( 非 . 应回退为比较运算
    func testGenericLookaheadFallbackOnNoCallSuffix() throws {
        // 容器 < I32 > 5 —— > 后跟整数，不是 ( 或 .，应回退为比较
        let source = try loadPiniFixture("testGenericLookaheadFallbackOnNoCallSuffix", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .binary(_, let op, _, _) = initializer else {
            XCTFail("应回退为 binary 节点")
            return
        }
        // 应是 (容器 < I32) > 5
        XCTAssertEqual(op, .greaterThan, "应识别为 greaterThan")
    }

    /// 意图：未闭合的 < 应回退为比较运算
    func testUnclosedAngleBracketFallback() throws {
        // a < b + c —— < 后无 > 闭合，应回退为比较
        let source = try loadPiniFixture("testUnclosedAngleBracketFallback", filePath: #filePath)
        let module = try parseModule(source)

        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(_, _, let initializer, _, _) = stmt,
              case .binary(_, let op, _, _) = initializer else {
            XCTFail("应为 binary 节点（比较运算）")
            return
        }
        // a < (b + c) —— + 优先级高于 <，故为 a < (b+c)
        XCTAssertEqual(op, .lessThan, "应识别为 lessThan")
    }

    /// 意图：类型标注位置的泛型类型应正确解析（var x: 容器<I32>）
    func testGenericInTypeAnnotation() throws {
        let source = try loadPiniFixture("testGenericInTypeAnnotation", filePath: #filePath)
        let module = try parseModule(source)

        // 第一个声明应为结构声明
        guard case .structDecl(let structDecl) = module.declarations[0] else {
            XCTFail("应为结构声明")
            return
        }
        XCTAssertEqual(structDecl.name, "容器")
        XCTAssertEqual(structDecl.genericParams.count, 1, "应有一个泛型参数")

        // 第二个声明应为函数声明
        guard case .funcDecl(let funcDecl) = module.declarations[1],
              let stmt = funcDecl.body?.statements.first,
              case .varDecl(let varName, let typeAnnotation, let initializer, _, _) = stmt else {
            XCTFail("应为变量声明")
            return
        }
        XCTAssertEqual(varName, "c")
        // 类型标注应为 generic 类型
        guard let typeAnn = typeAnnotation,
              case .generic(let typeName, let params, _) = typeAnn else {
            XCTFail("类型标注应为 generic 类型")
            return
        }
        XCTAssertEqual(typeName, "容器")
        XCTAssertEqual(params.count, 1)

        // 初始值应为 genericConstruct
        guard case .genericConstruct(let initTypeName, _, _, _) = initializer else {
            XCTFail("初始值应为 genericConstruct")
            return
        }
        XCTAssertEqual(initTypeName, "容器")
    }

    /// 意图：字段声明的类型标注中的泛型应正确解析
    func testGenericInFieldTypeAnnotation() throws {
        let source = try loadPiniFixture("testGenericInFieldTypeAnnotation", filePath: #filePath)
        let module = try parseModule(source)

        // 第二个声明（包装器）的字段类型应为 generic
        guard case .structDecl(let wrapperDecl) = module.declarations[1],
              let field = wrapperDecl.fields.first,
              case .generic(let fieldName, let params, _) = field.typeAnnotation else {
            XCTFail("字段类型应为 generic")
            return
        }
        XCTAssertEqual(field.name, "内部")
        XCTAssertEqual(fieldName, "容器")
        XCTAssertEqual(params.count, 1)
        if case .simple(let n, _) = params[0] {
            XCTAssertEqual(n, "I32")
        } else {
            XCTFail("类型参数应为 I32")
        }
    }

    /// 意图：内容态中行首 ( 应被识别为新结构声明开始
    func testLineStartParenIsNewDecl() throws {
        let source = try loadPiniFixture("testLineStartParenIsNewDecl", filePath: #filePath)
        let module = try parseModule(source)

        // 应有两个声明：main 函数 + 计数器结构
        XCTAssertEqual(module.declarations.count, 2, "应有两个声明")
        guard case .funcDecl = module.declarations[0] else {
            XCTFail("第一个应为函数声明")
            return
        }
        guard case .structDecl(let s) = module.declarations[1] else {
            XCTFail("第二个应为结构声明")
            return
        }
        XCTAssertEqual(s.name, "计数器")
    }

    /// 意图：内容态中行首 [ 应被识别为新枚举/对象声明开始
    func testLineStartBracketIsNewDecl() throws {
        let source = try loadPiniFixture("testLineStartBracketIsNewDecl", filePath: #filePath)
        let module = try parseModule(source)

        XCTAssertEqual(module.declarations.count, 2, "应有两个声明")
        guard case .funcDecl = module.declarations[0] else {
            XCTFail("第一个应为函数声明")
            return
        }
        guard case .enumDecl(let e) = module.declarations[1] else {
            XCTFail("第二个应为枚举声明")
            return
        }
        XCTAssertEqual(e.name, "形状")
    }

    /// 意图：表达式中的 ( 不是声明头（函数调用）
    func testParenInExpressionNotDecl() throws {
        let source = try loadPiniFixture("testParenInExpressionNotDecl", filePath: #filePath)
        let module = try parseModule(source)

        XCTAssertEqual(module.declarations.count, 1, "应只有一个声明")
        guard case .funcDecl(let funcDecl) = module.declarations[0],
              let stmt = funcDecl.body?.statements.first,
              case .expressionStmt(let expr, _) = stmt,
              case .call(let callee, let args, _) = expr else {
            XCTFail("应为调用表达式")
            return
        }
        guard case .identifier(let calleeName, _) = callee else {
            XCTFail("被调用者应为标识符")
            return
        }
        XCTAssertEqual(calleeName, "print")
        XCTAssertEqual(args.count, 1)
    }
}
