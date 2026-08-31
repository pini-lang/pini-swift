import XCTest
import PiniCore

/// 匿名函数 funcLiteral（spec G29：lambda → func + 块体）类型推断与调用点校验。
/// 驱动链路：Lexer → Parser → TypeChecker.checkCollecting(module:)，与 CLI `pini check` 同构。
final class FuncLiteralTests: XCTestCase {

    private func parse(_ source: String, fileName: String = "func_literal_test.pini") throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return try parser.parseModule()
    }

    private func checkCollecting(_ source: String) -> [TypeError] {
        let module = try! parse(source)
        return TypeChecker().checkCollecting(module: module)
    }

    private func firstFuncLiteral(in source: String) throws -> PiniCore.Expression {
        let module = try parse(source)
        for decl in module.declarations {
            guard case .funcDecl(let f) = decl else { continue }
            for stmt in f.body?.statements ?? [] {
                if case .varDecl(_, _, let init_, _, _) = stmt, let i = init_ {
                    return i
                }
            }
        }
        throw FuncLiteralTestError.notFound
    }

    enum FuncLiteralTestError: Error { case notFound }

    /// L1：参数标注被消费——`func (n: I32,) -> (I32,): return n` 应推断 (I32) -> (I32)。
    /// 意图：验证参数标注被消费——`func (n: I32,)` 的推断结果应为 (I32) -> (I32) 而非回退通配。
    func testFuncLiteralParamAnnotationConsumed() throws {
        let lit = try firstFuncLiteral(in: try loadPiniFixture("testFuncLiteralParamAnnotationConsumed", filePath: #filePath) as String)
        let inferred = TypeInference().infer(expression: lit)
        XCTAssertEqual(inferred?.describe(), "(I32) -> (I32)", "参数标注 I32 应被消费，而非回退通配")
    }

    /// 无标注时自底向上：`func (n,) -> (I32,): return n + 1` 应推断 (I32) -> (I32)。
    /// 意图：验证无标注时自底向上推断——体 `n + 1` 经运算符定型，断言结果应为 (I32) -> (I32)。
    func testFuncLiteralBottomUpNoAnnotation() throws {
        let lit = try firstFuncLiteral(in: try loadPiniFixture("testFuncLiteralBottomUpNoAnnotation", filePath: #filePath) as String)
        let inferred = TypeInference().infer(expression: lit)
        XCTAssertEqual(inferred?.describe(), "(I32) -> (I32)", "无标注时运算符自底向上应推出 (I32) -> (I32)")
    }

    /// L1 核心：`func (n: I32,)` 传 String 实参，check 应报 type mismatch。
    /// 意图：验证调用点校验拒绝错误类型——I32 形参变量 f 传 String 实参，断言收集到 mismatch 诊断。
    func testFuncLiteralCallSiteValidationRejectsWrongType()  throws {
        let diagnostics = checkCollecting(try loadPiniFixture("testFuncLiteralCallSiteValidationRejectsWrongType", filePath: #filePath) as String)
        XCTAssertTrue(diagnostics.contains { if case .mismatch = $0 { return true } else { return false } },
                      "函数类型变量调用传错类型应报 mismatch，实际：\(diagnostics)")
    }

    /// L1 对照：传对类型应无诊断。
    /// 意图：验证调用点校验通过正确类型——f(42) 实参匹配 I32，断言无任何诊断。
    func testFuncLiteralCallSiteValidationPassesCorrectType()  throws {
        let diagnostics = checkCollecting(try loadPiniFixture("testFuncLiteralCallSiteValidationPassesCorrectType", filePath: #filePath) as String)
        XCTAssertTrue(diagnostics.isEmpty, "传对类型应无诊断，实际：\(diagnostics)")
    }

    /// 自顶向下：无标注、体仅用参数名、提供期望 (I32) -> (I32) 时应定型为该签名。
    /// 意图：验证自顶向下定型——无标注、体仅用参数名 n，提供期望 (I32) -> (I32) 时应灌入该签名。
    func testFuncLiteralTopDownFromExpected() throws {
        let loc = SourceLocation(line: 0, column: 0, fileName: "test.pini")
        let decl = FuncDecl(
            name: "<anon>", modifiers: [], genericParams: [],
            params: [Parameter(name: "n")],
            returnTypes: [], isAsync: false,
            body: Block(statements: [.expressionStmt(expr: .identifier(name: "n", location: loc), location: loc)], location: loc),
            location: loc
        )
        let lit = Expression.funcLiteral(decl: decl, location: loc)
        let expected = TypeAnnotation.function(
            params: [.simple(name: "I32", location: loc)],
            returns: [.simple(name: "I32", location: loc)],
            captured: [],
            location: loc
        )
        let inferred = TypeInference().infer(expression: lit, expected: expected)
        XCTAssertEqual(inferred?.describe(), "(I32) -> (I32)", "期望类型自顶向下应灌入 (I32) -> (I32)")
    }

    /// 回归：无标注、无期望类型时退化为带通配 _ 的函数类型（不崩溃、不误报）。
    /// 意图：回归验证无标注无期望时退化为带通配 `_` 的函数类型——断言推断结果非 nil 且形参/返回各 1 个，不崩溃不误报。
    func testFuncLiteralFallbackWildcard() throws {
        let loc = SourceLocation(line: 0, column: 0, fileName: "test.pini")
        let decl = FuncDecl(
            name: "<anon>", modifiers: [], genericParams: [],
            params: [Parameter(name: "n")],
            returnTypes: [], isAsync: false,
            body: Block(statements: [.expressionStmt(expr: .identifier(name: "n", location: loc), location: loc)], location: loc),
            location: loc
        )
        let lit = Expression.funcLiteral(decl: decl, location: loc)
        let inferred = TypeInference().infer(expression: lit)
        XCTAssertNotNil(inferred, "匿名函数至少应退化为函数类型而非 nil")
        if case .function(let params, let returns, _, _) = inferred! {
            XCTAssertEqual(params.count, 1)
            XCTAssertEqual(returns.count, 1)
        } else {
            XCTFail("退化结果应为函数类型")
        }
    }

    /// 体内部检查：参数标注 String 但体做 `n + 1`，应报类型不一致（标注权威）。
    /// 意图：验证体内部检查——参数标注 String 但体做 `n + 1` 算术，断言报类型不一致（标注权威）。
    func testFuncLiteralBodyAnnotationConflict()  throws {
        let diagnostics = checkCollecting(try loadPiniFixture("testFuncLiteralBodyAnnotationConflict", filePath: #filePath) as String)
        XCTAssertTrue(diagnostics.contains { if case .mismatch = $0 { return true } else { return false } },
                      "标注 String 但体做算术应报类型不一致，实际：\(diagnostics)")
    }

    /// 体内部检查：返回类型标注 I32 但 `return "hello"`，应报返回类型不一致。
    /// 意图：验证返回类型不一致——体 `return "hello"` 与返回标注 (I32,) 冲突，断言报类型不一致。
    func testFuncLiteralBodyReturnTypeMismatch()  throws {
        let diagnostics = checkCollecting(try loadPiniFixture("testFuncLiteralBodyReturnTypeMismatch", filePath: #filePath) as String)
        XCTAssertTrue(diagnostics.contains { if case .mismatch = $0 { return true } else { return false } },
                      "return String 与标注 I32 应报不一致，实际：\(diagnostics)")
    }

    /// 体内部检查：无标注参数靠推断，不应因 body 检查误报。
    /// 意图：回归验证无标注参数靠推断不误报——`n + 1` 推断成功且调用 f(41) 合法，断言无任何诊断。
    func testFuncLiteralBodyNoAnnotationNoFalsePositive()  throws {
        let diagnostics = checkCollecting(try loadPiniFixture("testFuncLiteralBodyNoAnnotationNoFalsePositive", filePath: #filePath) as String)
        XCTAssertTrue(diagnostics.isEmpty, "无标注参数靠推断不应误报，实际：\(diagnostics)")
    }
}
