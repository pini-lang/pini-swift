import XCTest
import PiniCore

/// 遮蔽 Xcode 26+ XCTest 传递导出的 `Testing.Expression`（swift-testing），
/// 使本文件内 `Expression` 无歧义地指向 `PiniCore.Expression`。
private typealias Expression = PiniCore.Expression

/// EBNF↔Parser 一致性测试（T5 收尾，spec v0 A 附录的自动化门禁）
///
/// 目的：把 spec 附录 A（形式文法 EBNF，唯一载体）
/// 描述的语法事实，固化为可回归的 XCTest——保证"规范所述 = 解析器所为"。
/// 覆盖四类：①词法一致性 ②运算符优先级/结合性 ③记号消歧规则 ④关键产生式覆盖。
/// 对应 spec v0 A.6 验证记录；意图候选项（G35–G39，未采纳）不在本测试范围。
final class GrammarConsistencyTests: XCTestCase {

    // MARK: - 私有 helper

    private func lex(_ source: String, fileName: String = "grammar.pini") throws -> [Token] {
        try Lexer(source: source, fileName: fileName).tokenize()
    }

    /// 过滤布局 token（NEWLINE/INDENT/DEDENT/EOF），便于词法断言。
    private func meaningfulTokens(_ source: String) throws -> [Token] {
        try lex(source).filter { token in
            switch token {
            case .newline, .indent, .dedent, .eof: return false
            default: return true
            }
        }
    }

    private func parse(_ source: String, fileName: String = "grammar.pini") throws -> Module {
        let parser = Parser(tokens: try lex(source, fileName: fileName), fileName: fileName)
        return try parser.parseModule()
    }

    /// 提取模块顶层全部表达式语句。
    private func exprStmts(_ module: Module) -> [Expression] {
        var result: [Expression] = []
        for decl in module.declarations {
            if case .statement(let stmt) = decl, case .expressionStmt(let expr, _) = stmt {
                result.append(expr)
            }
        }
        return result
    }

    private func firstExprStmt(_ module: Module) throws -> Expression {
        for decl in module.declarations {
            if case .statement(let stmt) = decl, case .expressionStmt(let expr, _) = stmt {
                return expr
            }
        }
        throw ConsistencyError.noExpressionStmt
    }

    private func firstFuncBody(_ module: Module) throws -> [Statement] {
        for decl in module.declarations {
            if case .funcDecl(let f) = decl, let body = f.body {
                return body.statements
            }
        }
        throw ConsistencyError.noFuncBody
    }

    /// 按名取函数体（模块内首个 funcDecl 不是目标函数时使用，如 `f` 声明先于 `main`）。
    private func funcBody(named name: String, in module: Module) throws -> [Statement] {
        for decl in module.declarations {
            if case .funcDecl(let f) = decl, f.name == name, let body = f.body {
                return body.statements
            }
        }
        throw ConsistencyError.noFuncBody
    }

    private func firstStmt(_ module: Module) throws -> Statement {
        let body = try firstFuncBody(module)
        guard let first = body.first else { throw ConsistencyError.noStatement }
        return first
    }

    private enum ConsistencyError: Error {
        case noExpressionStmt
        case noFuncBody
        case noStatement
    }

    /// 结构等价比较（忽略 SourceLocation）——Expression 的 Equatable 含 location，
    /// 无法直接用于跨源码比对。
    private func structurallyEqual(_ a: Expression, _ b: Expression) -> Bool {
        switch (a, b) {
        case (.identifier(let n1, _), .identifier(let n2, _)):
            return n1 == n2
        case (.integerLiteral(let v1, _), .integerLiteral(let v2, _)):
            return v1 == v2
        case (.floatLiteral(let v1, _), .floatLiteral(let v2, _)):
            return v1 == v2
        case (.stringLiteral(let v1, _), .stringLiteral(let v2, _)):
            return v1 == v2
        case (.boolLiteral(let v1, _), .boolLiteral(let v2, _)):
            return v1 == v2
        case (.stringInterpolation(let s1, _), .stringInterpolation(let s2, _)):
            return s1.count == s2.count
                && zip(s1, s2).allSatisfy { $0 == $1 }
        case (.binary(let l1, let o1, let r1, _), .binary(let l2, let o2, let r2, _)):
            return o1 == o2 && structurallyEqual(l1, l2) && structurallyEqual(r1, r2)
        case (.unary(let o1, let op1, _), .unary(let o2, let op2, _)):
            return o1 == o2 && structurallyEqual(op1, op2)
        case (.call(let c1, let a1, _), .call(let c2, let a2, _)):
            return structurallyEqual(c1, c2)
                && a1.count == a2.count
                && zip(a1, a2).allSatisfy { $0.label == $1.label && structurallyEqual($0.expression, $1.expression) }
        case (.member(let o1, let n1, _), .member(let o2, let n2, _)):
            return structurallyEqual(o1, o2) && n1 == n2
        case (.subscript(let c1, let i1, _), .subscript(let c2, let i2, _)):
            return structurallyEqual(c1, c2) && structurallyEqual(i1, i2)
        case (.tuple(_, let e1, _), .tuple(_, let e2, _)):
            return e1.count == e2.count && zip(e1, e2).allSatisfy { structurallyEqual($0, $1) }
        case (.arrayLiteral(let e1, _), .arrayLiteral(let e2, _)):
            return e1.count == e2.count && zip(e1, e2).allSatisfy { structurallyEqual($0, $1) }
        case (.funcLiteral(let d1, _), .funcLiteral(let d2, _)):
            return d1 == d2
        case (.genericConstruct(let t1, let ta1, let a1, _), .genericConstruct(let t2, let ta2, let a2, _)):
            return t1 == t2 && ta1.count == ta2.count
                && zip(ta1, ta2).allSatisfy { $0.isStructurallyEquivalent(to: $1) }
                && a1.count == a2.count
                && zip(a1, a2).allSatisfy { $0.label == $1.label && structurallyEqual($0.expression, $1.expression) }
        case (.join(let e1, _), .join(let e2, _)):
            return structurallyEqual(e1, e2)
        case (.selfKeyword, .selfKeyword), (.selfTypeKeyword, .selfTypeKeyword):
            return true
        default:
            return false
        }
    }

    private func assertExpr(_ actual: Expression, equals expected: Expression,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(structurallyEqual(actual, expected),
                      "表达式结构不一致：期望 \(expected)，实际 \(actual)",
                      file: file, line: line)
    }

    // MARK: - 1. 词法一致性（spec 9.1）

    /// 意图：验证 16/2/8 进制前缀字面量 0x1F、0b101、0o17 分别解析为整数 31、5、15。
    func testLexHexBinaryOctalPrefix() throws {
        let tokens = try meaningfulTokens("0x1F 0b101 0o17")
        XCTAssertEqual(tokens.count, 3)
        if case .integerLiteral(let v, _) = tokens[0] { XCTAssertEqual(v, 31) } else { XCTFail("0x1F 应为整数 31") }
        if case .integerLiteral(let v, _) = tokens[1] { XCTAssertEqual(v, 5) } else { XCTFail("0b101 应为 5") }
        if case .integerLiteral(let v, _) = tokens[2] { XCTAssertEqual(v, 15) } else { XCTFail("0o17 应为 15") }
    }

    /// 意图：验证科学计数法浮点字面量 3.14e-2 解析为 floatLiteral 且值约为 0.0314。
    func testLexScientificFloat() throws {
        let tokens = try meaningfulTokens("3.14e-2")
        XCTAssertEqual(tokens.count, 1)
        if case .floatLiteral(let v, _) = tokens[0] { XCTAssertEqual(v, 0.0314, accuracy: 1e-9) } else { XCTFail("应为浮点") }
    }

    /// 意图：验证字符串字面量中转义序列 \n、\t、\" 正确展开为实际字符。
    func testLexStringEscapes() throws {
        let source = "\"a\\nb\\t\\\"c\\\"\""
        let tokens = try meaningfulTokens(source)
        XCTAssertEqual(tokens.count, 1)
        if case .stringLiteral(let v, _) = tokens[0] {
            XCTAssertEqual(v, "a\nb\t\"c\"")
        } else {
            XCTFail("应为字符串字面量")
        }
    }

    /// 意图：验证插值字符串 "x\(1)y" 切分为 [.literal("x"), .expression("1"), .literal("y")] 三段。
    func testLexInterpolatedString() throws {
        let tokens = try meaningfulTokens("\"x\\(1)y\"")
        XCTAssertEqual(tokens.count, 1)
        guard case .interpolatedString(let segments, _) = tokens[0] else {
            XCTFail("应为插值字符串"); return
        }
        XCTAssertEqual(segments, [.literal("x"), .expression("1"), .literal("y")])
    }

    /// 意图：验证运算符最长匹配：<<= 整体取为 leftShiftAssign、<= 为 lessThanOrEqual、<< 为 leftShift。
    func testLexOperatorLongestMatch() throws {
        // 最长匹配：`<<=` 优先于 `<<` 优先于 `<`；`<=` 与 `<` 区分
        let tokens = try meaningfulTokens("a <<= b <= c << d")
        XCTAssertEqual(tokens.count, 7)
        guard case .identifier = tokens[0] else { XCTFail("a") ; return }
        guard case .leftShiftAssign = tokens[1] else { XCTFail("<<= 应为 leftShiftAssign"); return }
        guard case .identifier = tokens[2] else { XCTFail("b"); return }
        guard case .lessThanOrEqual = tokens[3] else { XCTFail("<= 应为 lessThanOrEqual"); return }
        guard case .identifier = tokens[4] else { XCTFail("c"); return }
        guard case .leftShift = tokens[5] else { XCTFail("<< 应为 leftShift"); return }
    }

    /// 意图：验证缩进栈在进入嵌套块时产生 INDENT、退出时产生 DEDENT。
    func testLexIndentDedentStack() throws {
        let tokens = try lex("if x:\n    y\nz")
        let kinds = tokens.map { token -> String in
            switch token {
            case .indent: return "INDENT"
            case .dedent: return "DEDENT"
            case .newline: return "NL"
            default: return "?"
            }
        }
        XCTAssertTrue(kinds.contains("INDENT"), "应产生 indent")
        XCTAssertTrue(kinds.contains("DEDENT"), "应产生 dedent")
    }

    /// 意图：验证 ; 行注释被跳过，注释后仅剩 identifier x 与 EOF 两个 token。
    func testLexSemicolonComment() throws {
        let tokens = try lex("; 注释\nx")
        XCTAssertEqual(tokens.count, 2, "注释行应被跳过，仅剩 identifier + EOF")
        guard case .identifier("x", _) = tokens[0] else { XCTFail("注释后应为 identifier x"); return }
        guard case .eof = tokens[1] else { XCTFail("末尾应为 EOF"); return }
    }

    /// 意图：验证 # 文档注释行被跳过，注释后仅剩 identifier x 与 EOF 两个 token。
    func testLexHashDocComment() throws {
        // G35：EBNF COMMENT 产生式增加 `#` 文档注释（行首=文档注释，行中=退化行注释）
        let tokens = try lex("# 文档注释\nx")
        XCTAssertEqual(tokens.count, 2, "`#` 注释行应被跳过，仅剩 identifier + EOF")
        guard case .identifier("x", _) = tokens[0] else { XCTFail("注释后应为 identifier x"); return }
        guard case .eof = tokens[1] else { XCTFail("末尾应为 EOF"); return }
    }

    // MARK: - 2. 运算符优先级/结合性（spec 9.3）

    /// 意图：验证 * 优先级高于 +：a + b * c 解析为 a + (b * c)。
    func testPrecedenceMultiplyOverPlus() throws {
        let expr = try firstExprStmt(parse("a + b * c"))
        assertExpr(expr, equals: .binary(left: .identifier(name: "a", location: .dummy),
                                         op: .plus,
                                         right: .binary(left: .identifier(name: "b", location: .dummy),
                                                        op: .multiply,
                                                        right: .identifier(name: "c", location: .dummy),
                                                        location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 == 优先级高于位运算 &：a & b == c 解析为 (a & b) == c。
    func testPrecedenceComparisonOverBitwise() throws {
        let expr = try firstExprStmt(parse("a & b == c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .bitwiseAnd,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .equal,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证位运算层在加减层之上：a << b + c 解析为 a << (b + c)。
    func testPrecedenceAdditiveOverShift() throws {
        // 位运算层在加减层之上：a << b + c ≡ a << (b + c)
        let expr = try firstExprStmt(parse("a << b + c"))
        assertExpr(expr, equals: .binary(left: .identifier(name: "a", location: .dummy),
                                         op: .leftShift,
                                         right: .binary(left: .identifier(name: "b", location: .dummy),
                                                        op: .plus,
                                                        right: .identifier(name: "c", location: .dummy),
                                                        location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 && 优先级高于 ||：a || b && c 解析为 a || (b && c)。
    func testPrecedenceAndOverOr() throws {
        let expr = try firstExprStmt(parse("a || b && c"))
        assertExpr(expr, equals: .binary(left: .identifier(name: "a", location: .dummy),
                                         op: .or,
                                         right: .binary(left: .identifier(name: "b", location: .dummy),
                                                        op: .and,
                                                        right: .identifier(name: "c", location: .dummy),
                                                        location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 - 左结合：a - b - c 解析为 (a - b) - c。
    func testAssociativityMinusLeft() throws {
        let expr = try firstExprStmt(parse("a - b - c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .minus,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .minus,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 == 与 != 同级左结合：a == b != c 解析为 (a == b) != c。
    func testAssociativityEqualityLeft() throws {
        let expr = try firstExprStmt(parse("a == b != c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .equal,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .notEqual,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证一元运算符先于二元运算符绑定：-a + b 解析为 (-a) + b。
    func testUnaryOverBinary() throws {
        let expr = try firstExprStmt(parse("-a + b"))
        assertExpr(expr, equals: .binary(left: .unary(op: .minus,
                                                      operand: .identifier(name: "a", location: .dummy),
                                                      location: .dummy),
                                         op: .plus,
                                         right: .identifier(name: "b", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 * 与 % 同级左结合：a * b % c 解析为 (a * b) % c。
    func testAssociativityMulDivLeft() throws {
        let expr = try firstExprStmt(parse("a * b % c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .multiply,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .modulo,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证 && 与 || 同级左结合：a && b || c 解析为 (a && b) || c。
    func testAssociativityAndLeft() throws {
        let expr = try firstExprStmt(parse("a && b || c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .and,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .or,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 位运算四则同级同结合性（与 C 系不同）：a & b << c ≡ (a & b) << c
    /// 意图：验证 & 与 << 同级左结合：a & b << c 解析为 (a & b) << c。
    func testBitwiseFourSiblingsSameLevel() throws {
        let expr = try firstExprStmt(parse("a & b << c"))
        assertExpr(expr, equals: .binary(left: .binary(left: .identifier(name: "a", location: .dummy),
                                                       op: .bitwiseAnd,
                                                       right: .identifier(name: "b", location: .dummy),
                                                       location: .dummy),
                                         op: .leftShift,
                                         right: .identifier(name: "c", location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证后缀下标 a[i] 优先于二元运算绑定：a[i] + 1 解析为 (a[i]) + 1。
    func testPostfixSubscriptBindsTightest() throws {
        let expr = try firstExprStmt(parse("a[i] + 1"))
        assertExpr(expr, equals: .binary(left: .subscript(expr: .identifier(name: "a", location: .dummy),
                                                          index: .identifier(name: "i", location: .dummy),
                                                          location: .dummy),
                                         op: .plus,
                                         right: .integerLiteral(value: 1, location: .dummy),
                                         location: .dummy))
    }

    /// 意图：验证调用后接成员访问构成紧密后缀链：f(x).g 解析为 member(call f(x), g)。
    func testPostfixMemberChain() throws {
        let expr = try firstExprStmt(parse("f(x).g"))
        assertExpr(expr, equals: .member(object: .call(callee: .identifier(name: "f", location: .dummy),
                                                       arguments: [CallArgument(expression: .identifier(name: "x", location: .dummy))],
                                                       location: .dummy),
                                         name: "g",
                                         location: .dummy))
    }

    // MARK: - 3. 记号消歧规则（spec 9.4）

    /// 规则 1（ADR-012）：`wait`/`await` 前缀 = join；`<=` 回归纯中缀比较
    /// 意图：验证 `wait` 前缀解析为 join（`<=` 已恢复为纯中缀比较运算符）。
    func testDisambigPrefixJoinVsInfixLessEqual() throws {
        let joinExpr = try firstExprStmt(parse("wait f()"))
        guard case .join(let inner, _) = joinExpr else {
            XCTFail("前缀 `<=` 应解析为 join，实际：\(joinExpr)"); return
        }
        assertExpr(inner, equals: .call(callee: .identifier(name: "f", location: .dummy),
                                        arguments: [], location: .dummy))

        let cmpExpr = try firstExprStmt(parse("a <= b"))
        assertExpr(cmpExpr, equals: .binary(left: .identifier(name: "a", location: .dummy),
                                            op: .lessThanOrEqual,
                                            right: .identifier(name: "b", location: .dummy),
                                            location: .dummy))
    }

    /// 规则 2：`<` 泛型构造 lookahead vs 比较
    /// 意图：验证 < 按 lookahead 消歧：Box<I32>(1) 解析为泛型构造，a < b 解析为比较运算。
    func testDisambigGenericConstructVsComparison() throws {
        let module = try parse("Box<I32>(1)\na < b")
        let exprs = exprStmts(module)
        XCTAssertEqual(exprs.count, 2)
        guard case .genericConstruct(let typeName, let typeArgs, let args, _) = exprs[0] else {
            XCTFail("`Box<I32>(1)` 应解析为 genericConstruct，实际：\(exprs[0])"); return
        }
        XCTAssertEqual(typeName, "Box")
        XCTAssertEqual(typeArgs.count, 1)
        XCTAssertTrue(typeArgs[0].isStructurallyEquivalent(to: .simple(name: "I32", location: .dummy)))
        XCTAssertEqual(args.count, 1)
        XCTAssertTrue(structurallyEqual(args[0].expression, .integerLiteral(value: 1, location: .dummy)))
        assertExpr(exprs[1], equals: .binary(left: .identifier(name: "a", location: .dummy),
                                             op: .lessThan,
                                             right: .identifier(name: "b", location: .dummy),
                                             location: .dummy))
    }

    /// 花括号函数声明已移除（G51② 裁决，2026-09-05 批③落地）：`{name}(...)` 报迁移提示；
    /// `{name}` 行首恒为对象声明糖。
    func testBraceFuncDeclRejectedWithHint() throws {
        do {
            _ = try parse(try loadPiniFixture("testBraceFuncDeclRejected", filePath: #filePath) as String)
            XCTFail("`{f|func}(...)` 应被拒绝（花括号函数声明已移除）")
        } catch let error as ParserError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("已移除"), "报错应含迁移提示，实际：\(message)")
            XCTAssertTrue(message.contains("裸声明"), "报错应指向裸声明迁移路径，实际：\(message)")
        }

        let objModule = try parse(try loadPiniFixture("testBraceObjectSugar", filePath: #filePath) as String)
        guard case .objectDecl(let o) = objModule.declarations[0] else {
            XCTFail("`{ob}` + 字段应解析为 objectDecl，实际：\(objModule.declarations[0])"); return
        }
        XCTAssertEqual(o.name, "ob")
        XCTAssertEqual(o.fields.count, 1)
    }

    /// 规则 5：`[名称|...]` 无修饰符默认枚举；`|object` 为对象
    /// 意图：验证 [名称|…] 无修饰符时默认解析为枚举声明。
    func testDisambigBracketDefaultEnum() throws {
        let enumModule = try parse(try loadPiniFixture("testDisambigBracketDefaultEnum", filePath: #filePath) as String)
        guard case .enumDecl(let e) = enumModule.declarations[0] else {
            XCTFail("`[形状]` 无修饰符应默认枚举，实际：\(enumModule.declarations[0])"); return
        }
        XCTAssertEqual(e.cases.count, 2)
    }

    /// 规则 7：match 的 `case _:` 通配（D3①/G28 更新，2026-08-23）
    /// 注：case 缩进进 match 子块；`case _:` 为通配兜底（取代旧 default 特判与 pass 通配子块）。
    /// 意图：验证 `case _:` 解析为 wildcard 模式 case。
    func testDisambigMatchWildcard() throws {
        let module = try parse(try loadPiniFixture("testDisambigMatchWildcard", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .matchStatement(_, let cases, _) = body[0] else {
            XCTFail("应为 match 语句"); return
        }
        XCTAssertEqual(cases.count, 2)
        guard case .wildcard = cases[1].pattern else {
            XCTFail("case _: 应解析为 wildcard 模式，实际：\(cases[1].pattern)"); return
        }
    }

    /// 规则 6：类型体内裸函数声明 vs 字段
    /// 意图：验证类型体内 `x: F64 = 0.0` 解析为字段、`距离|self() -> (F64,)` 解析为方法。
    func testDisambigBareFuncVsFieldInTypeBody() throws {
        let module = try parse(try loadPiniFixture("testDisambigBareFuncVsFieldInTypeBody", filePath: #filePath) as String)
        guard case .objectDecl(let o) = module.declarations[0] else { XCTFail("应为对象"); return }
        XCTAssertEqual(o.fields.count, 1, "`x: F64 = 0.0` 应为字段")
        XCTAssertEqual(o.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "点")
        XCTAssertEqual(ext.methods.count, 1, "`距离|self() -> (F64,)` 应为方法（在 {{点}} 扩展块）")
    }

    /// 规则 12（EBNF 9.2 语义）：nil ≡ Optional.none
    /// 意图：验证 nil 字面量按语义消歧为 Optional.none 成员访问表达式。
    func testDisambigNilAsOptionalNone() throws {
        let module = try parse(try loadPiniFixture("testDisambigNilAsOptionalNone", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[0], let initExpr = initializer else {
            XCTFail("应为带初始化器的变量声明"); return
        }
        assertExpr(initExpr, equals: .member(object: .identifier(name: "Optional", location: .dummy),
                                             name: "none", location: .dummy))
    }

    /// 规则 3（9.2）：`|` 作方法修饰符（`名称|self(...)`）
    /// 意图：验证 | 作为方法修饰符：{移动|self} 的方法修饰符为 ["self"]。
    func testDisambigPipeAsMethodModifier() throws {
        let module = try parse(try loadPiniFixture("testDisambigPipeAsMethodModifier", filePath: #filePath) as String)
        guard case .objectDecl(let o) = module.declarations[0] else { XCTFail("应为对象"); return }
        XCTAssertEqual(o.methods.count, 0, "类型体内不再承载方法（ADR-016 规则 3.2）")
        guard case .extensionDecl(let ext) = module.declarations[1] else { XCTFail("应为扩展块"); return }
        XCTAssertEqual(ext.targetType, "点")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].modifiers, ["self"], "`{移动|self}` 的修饰符应为 self（在 {{点}} 扩展块）")
    }

    // MARK: - 4. 关键产生式覆盖（spec 9.2）

    /// while 的 `outer|while` 标签与 `step` 步进子块（ADR-014：标签由 `scope 块标签:` 改 `标签|控制流关键字`）
    /// 意图：验证 while 支持标签前缀与 step 步进子块：whileStatement 的 label 为 outer、step 步进块被解析。
    func testProductionsWhileLabelAndStep() throws {
        let module = try parse(try loadPiniFixture("testProductionsWhileLabelAndStep", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .whileStatement(_, _, let step, let label, _) = body[0] else {
            XCTFail("应为带标签的 while 语句"); return
        }
        XCTAssertEqual(label, "outer", "`outer|while` 标签应为 outer")
        XCTAssertNotNil(step, "应解析出 step 步进块")
    }

    /// for-in 语句产生式（G36，见 spec for-in 主题）：模式元组 + step + 标签（ADR-014，无标签时 label 为 nil）
    /// 意图：验证 for-in 产生式：模式元组 [v]、step 步进块解析，无标签时 label 为 nil，迭代目标为 3 元素数组。
    func testProductionsForIn() throws {
        let module = try parse(try loadPiniFixture("testProductionsForIn", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .forStatement(let pattern, let iterable, _, let step, let label, _) = body[1] else {
            XCTFail("应为 for 语句（body[1]，body[0] 为 var acc）"); return
        }
        XCTAssertEqual(pattern, ["v"], "模式元组应为 [v]")
        XCTAssertNotNil(step, "应解析出 step 步进块")
        XCTAssertNil(label, "无标签时 label 应为 nil（ADR-014 标签语法）")
        guard case .arrayLiteral(let els, _) = iterable else {
            XCTFail("迭代目标应为数组字面量"); return
        }
        XCTAssertEqual(els.count, 3, "数组字面量应有 3 个元素")
    }

    /// for-in `_` 占位与字典两字段模式（G36）
    /// 意图：验证 for-in 模式变体：`_` 占位保留为模式元素，字典迭代模式为 [k, v]。
    func testProductionsForInPatternVariants() throws {
        let module = try parse(try loadPiniFixture("testProductionsForInPatternVariants", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .forStatement(let p1, _, _, _, _, _) = body[1] else { XCTFail("应为 for（body[1]）"); return }
        XCTAssertEqual(p1, ["_"], "`_` 占位应保留为模式元素")
        guard case .forStatement(let p2, _, _, _, _, _) = body[4] else { XCTFail("应为 for（body[4]）"); return }
        XCTAssertEqual(p2, ["k", "v"], "字典迭代模式应为 [k, v]")
    }

    /// match 模式：整数字面量 / 通配 `_` / nil→none / 枚举绑定
    /// 注：case 缩进进 match 子块（D3①/G28 更新）。
    /// 意图：验证 match 模式四类：整数字面量、通配 _、nil→enumCase none、枚举带参数绑定。
    func testProductionsMatchPatterns() throws {
        let module = try parse(try loadPiniFixture("testProductionsMatchPatterns", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .matchStatement(_, let cases, _) = body[0] else { XCTFail("应为 match"); return }
        XCTAssertEqual(cases.count, 4)
        XCTAssertEqual(cases[0].pattern, .intLiteral(1))
        XCTAssertEqual(cases[1].pattern, .wildcard)
        XCTAssertEqual(cases[2].pattern, .enumCase("none"), "`case nil:` 应映射为 enumCase none")
        XCTAssertEqual(cases[3].pattern, .enumCase("圆"))
        XCTAssertEqual(cases[3].bindings.count, 1)
        XCTAssertNil(cases[3].bindings[0].paramName, "3.15：枚举绑定位置化后不再携带具名参数名")
        XCTAssertEqual(cases[3].bindings[0].varName, "r")
    }

    /// 类型注解糖：?T / [T] / [K: V] / {T}
    /// 意图：验证类型注解糖 ?T/[T]/[K: V]/{T} 分别映射为 Optional/Array/Dictionary/Set 泛型。
    func testProductionsTypeAnnotationSugar() throws {
        let module = try parse(try loadPiniFixture("testProductionsTypeAnnotationSugar", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        let expected: [(String, TypeAnnotation)] = [
            ("a", .generic(name: "Optional", params: [.simple(name: "I32", location: .dummy)], location: .dummy)),
            ("b", .generic(name: "Array", params: [.simple(name: "String", location: .dummy)], location: .dummy)),
            ("c", .generic(name: "Dictionary",
                           params: [.simple(name: "String", location: .dummy), .simple(name: "I32", location: .dummy)],
                           location: .dummy)),
            ("d", .generic(name: "Set", params: [.simple(name: "I32", location: .dummy)], location: .dummy)),
        ]
        for (i, stmt) in body.prefix(4).enumerated() {
            guard case .varDecl(let name, let type, _, _, _) = stmt else { XCTFail("应为 varDecl"); return }
            XCTAssertEqual(name, expected[i].0)
            XCTAssertTrue(type?.isStructurallyEquivalent(to: expected[i].1) == true,
                          "变量 \(name) 类型应为 \(expected[i].1)，实际 \(String(describing: type))")
        }
    }

    /// 复合赋值折叠：`x op= y` ≡ `x = (x op y)`
    /// 意图：验证复合赋值折叠：x += 1 解析为 x = (x + 1)。
    func testProductionsCompoundAssignFold() throws {
        let module = try parse("x += 1")
        guard case .statement(let stmt) = module.declarations[0] else { XCTFail("应为语句"); return }
        guard case .assign(let target, let value, _) = stmt else {
            XCTFail("应为赋值语句，实际：\(stmt)"); return
        }
        XCTAssertEqual(target, .identifier(name: "x"), "赋值目标应为 x")
        assertExpr(value, equals: .binary(left: .identifier(name: "x", location: .dummy),
                                          op: .plus,
                                          right: .integerLiteral(value: 1, location: .dummy),
                                          location: .dummy))
    }

    /// trait 变量签名：`名称: 类型`
    /// 意图：验证 trait 变量签名「名称: 类型」解析为带返回类型的签名条目。
    func testProductionsTraitVarSignature() throws {
        let module = try parse(try loadPiniFixture("testProductionsTraitVarSignature", filePath: #filePath) as String)
        guard case .traitDecl(let t) = module.declarations[0] else { XCTFail("应为 trait"); return }
        XCTAssertEqual(t.signatures.count, 1)
        XCTAssertEqual(t.signatures[0].name, "名称")
        XCTAssertEqual(t.signatures[0].returnTypes.count, 1)
        XCTAssertTrue(t.signatures[0].returnTypes[0].isStructurallyEquivalent(to: .simple(name: "String", location: .dummy)))
    }

    /// import / export 顶级声明
    /// 意图：验证 import/export 顶级声明分别暂存进 Module 的 imports 与 exports。
    func testProductionsImportExport() throws {
        let module = try parse(try loadPiniFixture("testProductionsImportExport", filePath: #filePath) as String,
                               fileName: "testProductionsImportExport.pini")
        XCTAssertEqual(module.imports.count, 1)
        XCTAssertEqual(module.imports[0].alias, "foo")
        XCTAssertEqual(module.imports[0].packagePath, "./foo")
        XCTAssertEqual(module.exports.count, 1)
        XCTAssertEqual(module.exports[0].renames.first?.alias, "bar")
        XCTAssertEqual(module.exports[0].renames.first?.symbol, "bar")
    }

    /// 分组括号语义为零：`(a + b)` 直接返回内层表达式（不构造 paren 节点）。
    /// 注：`(` 在行首位置是结构块声明，故分组须处于非行首（变量初始化器）。
    /// 意图：验证分组括号语义为零：(a + b) 直接展开为内层二元表达式，不构造 paren 节点。
    func testProductionsParenGroupingSemanticallyEmpty() throws {
        let module = try parse(try loadPiniFixture("testProductionsParenGroupingSemanticallyEmpty", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[0], let initExpr = initializer else {
            XCTFail("应为带初始化器的变量声明"); return
        }
        assertExpr(initExpr, equals: .binary(left: .identifier(name: "a", location: .dummy),
                                             op: .plus,
                                             right: .identifier(name: "b", location: .dummy),
                                             location: .dummy))
    }
    /// 特征扩展块 `<<T>>` 产生式（2026-09-06 重新引入落地，issue-trait-extension-reintroduce）。
    /// 意图：验证行首 `<<` 经 Lexer 拆为 lessThan 对 → extensionDecl(kind: traitExt)，
    /// 且 token 流含合并态 `.rightShift` 闭合（行首消歧只覆盖开定界符）。
    /// 注：trait-body 终止性（trait 块 + 后续顶级声明）见下方
    /// testProductionsTraitBodyTerminatedByStructDecl 等三钉。
    func testProductionsTraitExtensionBlock() throws {
        // 词法层：行首 `<<` 拆 token 对 + 行尾 `>>` 维持合并
        let tokens = try meaningfulTokens("<<动物>>")
        guard tokens.count == 4 else {
            XCTFail("行首 `<<动物>>` 应为 4 个 token，实际 \(tokens.count)：\(tokens)"); return
        }
        guard case .lessThan = tokens[0], case .lessThan = tokens[1] else {
            XCTFail("行首 `<<` 应拆为两个 .lessThan"); return
        }
        guard case .rightShift = tokens[3] else {
            XCTFail("行尾 `>>` 应为合并态 .rightShift"); return
        }

        // 语法层：解析为 traitExt 扩展块 + trait-body 方法
        let module = try parse(try loadPiniFixture("testProductionsTraitExtensionBlock", filePath: #filePath) as String)
        guard case .extensionDecl(let ext) = module.declarations[0] else {
            XCTFail("`<<动物>>` 应为 extensionDecl，实际：\(module.declarations[0])"); return
        }
        XCTAssertEqual(ext.kind, .traitExt)
        XCTAssertEqual(ext.targetType, "动物")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "叫声")
    }

    /// 行内 `<<` 不受行首消歧影响：`a << 2` 维持移位二元表达式（与 §A.2 位运算互斥的另一半）。
    /// 意图：验证行首消歧不外溢——非行首 `<<` 仍合并为 leftShift token 并解析为二元移位。
    func testProductionsInlineShiftStaysBinary() throws {
        let module = try parse(try loadPiniFixture("testProductionsInlineShiftStaysBinary", filePath: #filePath) as String)
        let body = try funcBody(named: "main", in: module)
        guard case .varDecl(_, _, let initializer, _, _) = body[1], let initExpr = initializer else {
            XCTFail("`var b: I32 = a << 2` 应为带初始化器的变量声明"); return
        }
        guard case .binary(let left, let op, let right, _) = initExpr, op == .leftShift else {
            XCTFail("行内 `a << 2` 应为 binary(op: .leftShift)，实际：\(initExpr)"); return
        }
        assertExpr(left, equals: .identifier(name: "a", location: .dummy))
        assertExpr(right, equals: .integerLiteral(value: 2, location: .dummy))
    }

    /// trait-body 终止性：trait 块后接结构块（探针源 p23-trait-terminate）。
    /// 意图：验证顶格方法与后续顶级声明间无 dedent 时，trait 体循环仍能收束
    /// （修复前终止检查挂在 justDedented 分支内，`(盒)` 掉进变量签名分支报错）。
    func testProductionsTraitBodyTerminatedByStructDecl() throws {
        let module = try parse(try loadPiniFixture("testProductionsTraitBodyTerminatedByStructDecl", filePath: #filePath) as String)
        XCTAssertEqual(module.declarations.count, 2, "trait 应在结构块行终止，两声明都须解析出")
        guard case .traitDecl(let trait) = module.declarations[0] else {
            XCTFail("首声明应为 traitDecl，实际：\(module.declarations[0])"); return
        }
        XCTAssertEqual(trait.name, "显示")
        XCTAssertEqual(trait.signatures.count, 1)
        XCTAssertEqual(trait.signatures[0].name, "描述")
        XCTAssertTrue(trait.signatures[0].modifiers.contains("self"))
        guard case .structDecl(let structDecl) = module.declarations[1] else {
            XCTFail("次声明应为 structDecl，实际：\(module.declarations[1])"); return
        }
        XCTAssertEqual(structDecl.name, "盒")
    }

    /// trait-body 终止性：trait 块后接扩展块（探针源 p21-ext-constraint，修复前报 E2-002）。
    /// 意图：验证 `((类型:特征))` 行首双定界符同样收束 trait 体且扩展块正常解析。
    func testProductionsTraitBodyTerminatedByExtensionDecl() throws {
        let module = try parse(try loadPiniFixture("testProductionsTraitBodyTerminatedByExtensionDecl", filePath: #filePath) as String)
        XCTAssertEqual(module.declarations.count, 2)
        guard case .traitDecl(let trait) = module.declarations[0] else {
            XCTFail("首声明应为 traitDecl，实际：\(module.declarations[0])"); return
        }
        XCTAssertEqual(trait.signatures.count, 1)
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("次声明应为 extensionDecl，实际：\(module.declarations[1])"); return
        }
        XCTAssertEqual(ext.targetType, "盒")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].name, "取")
    }

    /// trait 多方法带体回归钉（修复前即 PASS，锁定不回归：带体方法间 dedent 由
    /// parseBlock 消费，第二方法以 justDedented=false 进入方法分支）。
    func testProductionsTraitMultipleMethodsWithBodies() throws {
        let module = try parse(try loadPiniFixture("testProductionsTraitMultipleMethodsWithBodies", filePath: #filePath) as String)
        guard case .traitDecl(let trait) = module.declarations[0] else {
            XCTFail("应为 traitDecl，实际：\(module.declarations[0])"); return
        }
        XCTAssertEqual(trait.signatures.count, 2, "两个带体方法都应收入 trait")
        XCTAssertEqual(trait.signatures.map(\.name), ["描述", "叫声"])
    }

    // MARK: - 5. 反录勘测面补钉（2026-09-05 批⑤，勘测矩阵 row 1–7；探针源 docs/spec/issue/probes-backfill-2026-09-05/）

    /// 矩阵 row 1：尾逗号七形态——形参/返回元组/调用/数组/字典/集合/类型元组（含函数类型标注）。
    /// 意图：验证全部尾逗号形态均解析通过（EBNF 各产生式未写尾逗号，实现为既成事实）。
    func testBackfillTrailingCommaSevenForms() throws {
        let module = try parse(try loadPiniFixture("testBackfillTrailingCommaSevenForms", filePath: #filePath) as String)
        guard case .funcDecl(let f) = module.declarations[0] else {
            XCTFail("应为函数声明 f"); return
        }
        XCTAssertEqual(f.params.count, 2, "形参尾逗号 `b: I32,` 不应吞参")
        XCTAssertEqual(f.returnTypes.count, 2, "返回元组尾逗号 `F64,` 不应吞返回类型")
        let body = try funcBody(named: "main", in: module)
        // main 体共 12 条语句（5 条 var/let + 6 个 print + 尾部 return）。
        // 第 6 条 `print(f(1, 2,),)`：print 1 参，内层 f 调用 2 参（调用尾逗号不吞参）。
        guard body.count == 12 else {
            XCTFail("main 体应为 12 条语句，实际 \(body.count) 条：尾逗号可能吞语句"); return
        }
        guard case .expressionStmt(let printCall, _) = body[5],
              case .call(_, let printArgs, _) = printCall,
              printArgs.count == 1,
              case .call(_, let fArgs, _) = printArgs[0].expression,
              fArgs.count == 2 else {
            XCTFail("调用尾逗号形态应解析为两层调用且参数数不变，实际：\(body[5])"); return
        }
        // 函数类型标注尾逗号：`let h: (I32,) -> (F64,) = ...` 只须解析通过（第 5 条语句）。
        guard case .varDecl(_, _, _, _, _) = body[4] else {
            XCTFail("函数类型标注尾逗号应为变量声明，实际：\(body[4])"); return
        }
    }

    /// 矩阵 row 2（双向）：调用位标签 PASS 面——`f(a = 1, b = 2)` 解析出 label。
    /// 意图：验证调用位标签用 `=` 且 label 落入 AST（规则 3.15/G57）。
    func testBackfillCallLabelEq() throws {
        let module = try parse(try loadPiniFixture("testBackfillCallLabelEq", filePath: #filePath) as String)
        let body = try funcBody(named: "main", in: module)
        guard case .expressionStmt(let printCall, _) = body[0],
              case .call(_, let printArgs, _) = printCall,
              printArgs.count == 1,
              case .call(_, let fArgs, _) = printArgs[0].expression else {
            XCTFail("应为 print(f(...)) 调用链"); return
        }
        XCTAssertEqual(fArgs.map(\.label), ["a", "b"], "标签须以 `=` 传入并落入 AST")
    }

    /// 矩阵 row 2（双向）：调用位标签拒绝面——`f(a: 1)` 报错并提示改用 `=`。
    /// 意图：验证旧写法 `f(a: 值)` 被拒绝且报错指向 `=` 迁移路径。
    func testBackfillCallLabelColonRejected() throws {
        do {
            _ = try parse(try loadPiniFixture("testBackfillCallLabelColon", filePath: #filePath) as String)
            XCTFail("`f(a: 1)` 应被拒绝（调用位标签须用 `=`）")
        } catch let error as ParserError {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("实参标签须用 `=`"), "报错应含 `=` 迁移提示，实际：\(message)")
        }
    }

    /// 矩阵 row 3：后缀 `!` 强制解包 → `Expression.unary(op: .forceUnwrap)`。
    /// 意图：验证后缀 `!` 落 AST 节点（前缀 `!` 为 .not，位置消歧）。
    func testBackfillForceUnwrap() throws {
        let module = try parse(try loadPiniFixture("testBackfillForceUnwrap", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[1], let initExpr = initializer else {
            XCTFail("`let v = x!` 应为带初始化器的变量声明"); return
        }
        guard case .unary(let op, let operand, _) = initExpr, op == .forceUnwrap else {
            XCTFail("后缀 `!` 应为 unary(op: .forceUnwrap)，实际：\(initExpr)"); return
        }
        assertExpr(operand, equals: .identifier(name: "x", location: .dummy))
    }

    /// 矩阵 row 4（双向形态）：元组解构 var 与 let → `Statement.varDestructure`。
    /// 意图：验证 `var (t, e) = rhs` / `let (t, e) = rhs` 均解析为解构声明且 isMutable 正确。
    func testBackfillTupleDestructureVarAndLet() throws {
        let varModule = try parse(try loadPiniFixture("testBackfillTupleDestructureVar", filePath: #filePath) as String)
        let varBody = try funcBody(named: "main", in: varModule)
        guard case .varDestructure(let varNames, _, _, let varMutable, _) = varBody[0] else {
            XCTFail("`var (t, e)` 应为 varDestructure，实际：\(varBody[0])"); return
        }
        XCTAssertEqual(varNames, ["t", "e"])
        XCTAssertTrue(varMutable, "var 解构 isMutable 应为 true")

        let letModule = try parse(try loadPiniFixture("testBackfillTupleDestructureLet", filePath: #filePath) as String)
        let letBody = try funcBody(named: "main", in: letModule)
        guard case .varDestructure(let letNames, _, _, let letMutable, _) = letBody[0] else {
            XCTFail("`let (t, e)` 应为 varDestructure，实际：\(letBody[0])"); return
        }
        XCTAssertEqual(letNames, ["t", "e"])
        XCTAssertFalse(letMutable, "let 解构 isMutable 应为 false")
    }

    /// 矩阵 row 5：扩展块泛型 `((取值<T>))`。
    /// 意图：验证泛型扩展解析通过（泛型参数被消费校验；合并按 targetType 名称匹配，不落 AST）。
    func testBackfillExtensionGeneric() throws {
        let module = try parse(try loadPiniFixture("testBackfillExtensionGeneric", filePath: #filePath) as String)
        guard module.declarations.count == 2 else {
            XCTFail("应为 结构声明 + 扩展块 两个顶级声明，实际 \(module.declarations.count) 个"); return
        }
        guard case .extensionDecl(let ext) = module.declarations[1] else {
            XCTFail("`((取值<T>))` 应为 extensionDecl，实际：\(module.declarations[1])"); return
        }
        XCTAssertEqual(ext.targetType, "取值")
        XCTAssertEqual(ext.methods.count, 1)
        XCTAssertEqual(ext.methods[0].modifiers, ["self"])
    }

    /// 矩阵 row 6（拒绝面）：限定 case 解构 `case 形状.圆(r):` 报 E2-001 拒绝。
    /// 意图：验证 match 模式位点号限定形态被拒（spec match-pattern 无限定形态；点号 match 模式为二期提案）。
    /// 断言只锁「拒绝」这一态——将来点号 match 模式若引入，本测试须随提案同步改写。
    func testBackfillQualifiedCasePatternRejected() throws {
        do {
            _ = try parse(try loadPiniFixture("testBackfillQualifiedCasePatternRejected", filePath: #filePath) as String)
            XCTFail("`case 形状.圆(r):` 应被拒绝（match 模式位无限定形态，E2-001）")
        } catch is ParserError {
            // 拒绝即通过；报错形态为 E2-001 expectedToken（期朢单左括号/右括号类），不锁文案。
        }
    }

    /// 矩阵 row 7（拒绝面，防将来误引入）：单类型返回糖 `-> I32` 拒绝。
    /// 意图：验证返回位只接受元组 `-> (I32,)`（草稿 A7 提案池意图未实现，spec 与实现一致）。
    func testBackfillSingleReturnSugarRejected() throws {
        do {
            _ = try parse(try loadPiniFixture("testBackfillSingleReturnSugarRejected", filePath: #filePath) as String)
            XCTFail("`-> I32` 单类型返回糖应被拒绝（返回位须为元组 `-> (I32,)`）")
        } catch is ParserError {
            // 拒绝即通过。
        }
    }

    // MARK: - try-else（ADR-032 迁移批 M2：语句位+表达式位双形态，`^` 定义性脱糖）

    /// 语句位 try-else：`try r else e: pass` → expressionStmt(tryExpression)；
    /// errorVar 绑定 e，单行 handler 限 pass（显式吞掉错误惯用法，仅语句位）。
    func testTryElseStatementPosition() throws {
        let module = try parse(try loadPiniFixture("testTryElseStatementPosition", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard body.count == 2,
              case .expressionStmt(let expr, _) = body[0],
              case .tryExpression(let operand, let errorVar, let handler, _) = expr else {
            XCTFail("语句位 try-else 应解析为 expressionStmt(tryExpression)")
            return
        }
        guard case .identifier(let name, _) = operand else {
            XCTFail("operand 应为标识符 r")
            return
        }
        XCTAssertEqual(name, "r")
        XCTAssertEqual(errorVar, "e")
        XCTAssertEqual(handler.statements.count, 1, "单行 handler 应为单条语句")
        guard case .passStatement = handler.statements[0] else {
            XCTFail("单行 handler 应为 pass 语句")
            return
        }
    }

    /// 表达式位 try-else：`let x = try f() else e: return e` → varDecl.initializer 为 tryExpression。
    func testTryElseExpressionPosition() throws {
        let module = try parse(try loadPiniFixture("testTryElseExpressionPosition", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[0],
              case .tryExpression(let operand, let errorVar, let handler, _) = initializer! else {
            XCTFail("let 初始化式应为 tryExpression")
            return
        }
        guard case .call(let callee, _, _) = operand else {
            XCTFail("operand 应为调用 f()")
            return
        }
        guard case .identifier(let fnName, _) = callee else {
            XCTFail("被调应为标识符 f")
            return
        }
        XCTAssertEqual(fnName, "f")
        XCTAssertEqual(errorVar, "e")
        XCTAssertEqual(handler.statements.count, 1)
        guard case .returnStatement(.some(let retVal), _) = handler.statements[0],
              case .identifier(let errName, _) = retVal else {
            XCTFail("handler 应为 `return e`")
            return
        }
        XCTAssertEqual(errName, "e")
    }

    /// `^` 定义性脱糖：`^f()` ≡ `try f() else err: return err`（合成名 err，单条 return err）。
    func testCaretDesugarsToTryElse() throws {
        let module = try parse(try loadPiniFixture("testCaretDesugarsToTryElse", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[0],
              case .tryExpression(let operand, let errorVar, let handler, _) = initializer! else {
            XCTFail("`^f()` 应脱糖为 tryExpression")
            return
        }
        XCTAssertEqual(errorVar, "err", "`^` 脱糖的 errorVar 应为合成名 err")
        XCTAssertEqual(handler.statements.count, 1)
        guard case .returnStatement(.some(let retVal), _) = handler.statements[0],
              case .identifier(let errName, _) = retVal else {
            XCTFail("`^` 脱糖 handler 应为 `return err`")
            return
        }
        XCTAssertEqual(errName, "err")
        _ = operand
    }

    /// 块形式 handler：冒号后换行 + 缩进块，handler 为完整块。
    func testTryElseBlockHandler() throws {
        let module = try parse(try loadPiniFixture("testTryElseBlockHandler", filePath: #filePath) as String)
        let body = try firstFuncBody(module)
        guard case .varDecl(_, _, let initializer, _, _) = body[0],
              case .tryExpression(_, _, let handler, _) = initializer! else {
            XCTFail("块形式 handler 应解析为 tryExpression")
            return
        }
        XCTAssertEqual(handler.statements.count, 1)
        guard case .returnStatement = handler.statements[0] else {
            XCTFail("块形式 handler 须以控制流语句终止（return）")
            return
        }
    }

    /// 拒绝面（D2 一步删）：旧 try 块语法 `try expr:` 无 else → 常规解析错误，无迁移提示。
    func testTryWithoutElseRejected() throws {
        do {
            _ = try parse(try loadPiniFixture("testTryWithoutElseRejected", filePath: #filePath) as String)
            XCTFail("旧 try 块语法（无 else）应被拒绝（ADR-032 D2 一步删）")
        } catch is ParserError {
            // 拒绝即通过。
        }
    }

    /// 拒绝面：单行 handler 白名单（return/break/continue/pass）——其余语句拒绝。
    func testTryElseSingleLineHandlerRestricted() throws {
        do {
            _ = try parse(try loadPiniFixture("testTryElseSingleLineHandlerRestricted", filePath: #filePath) as String)
            XCTFail("单行 handler `print(e)` 应被拒绝（白名单外）")
        } catch is ParserError {
            // 拒绝即通过。
        }
    }

    /// 词法面（D2）：`except` 退出关键字表，降级为普通标识符。
    func testExceptKeywordRetired() throws {
        let tokens = try meaningfulTokens("except")
        guard tokens.count == 1, case .identifier(let name, _) = tokens[0] else {
            XCTFail("`except` 应词法为普通标识符（不再是关键字）")
            return
        }
        XCTAssertEqual(name, "except")
    }
}

extension SourceLocation {
    /// 测试用哑元位置（结构等价比较忽略 location，此处仅用于构造期望值）。
    static var dummy: SourceLocation {
        SourceLocation(line: 0, column: 0, fileName: "<test>")
    }
}
