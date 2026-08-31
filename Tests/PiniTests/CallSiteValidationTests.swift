import XCTest
import PiniCore

/// 调用点校验：参数个数 + 参数类型（顶级函数 / 内建）。
/// 驱动链路：Lexer → Parser → TypeChecker.check(module:)，与项目真实公共入口同构。
final class CallSiteValidationTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 参数个数（P2-1.1）

    /// 实参多于形参 → argumentCountMismatch(expected: 1, got: 2)
    /// 意图：实参多于形参（2 对 1）应抛 argumentCountMismatch(expected: 1, got: 2)，验证调用点参数个数校验。
    func testArgumentCountMismatch() throws {
        let source = try loadPiniFixture("testArgumentCountMismatch", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "实参多于形参应抛错") { error in
            guard case TypeError.argumentCountMismatch(expected: 1, got: 2, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 1, got: 2)，实际: \(error)")
                return
            }
        }
    }

    /// 实参少于形参 → argumentCountMismatch(expected: 2, got: 1)
    /// 意图：实参少于形参（1 对 2）应抛 argumentCountMismatch(expected: 2, got: 1)，覆盖参数不足的错误路径。
    func testArgumentCountTooFew() throws {
        let source = try loadPiniFixture("testArgumentCountTooFew", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "实参少于形参应抛错") { error in
            guard case TypeError.argumentCountMismatch(expected: 2, got: 1, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 2, got: 1)，实际: \(error)")
                return
            }
        }
    }

    /// 反向：个数吻合不应抛错
    /// 意图：参数个数完全吻合（1 对 1）时 check 不抛错，反向验证个数校验无误报。
    func testArgumentCountExactMatch() throws {
        let source = try loadPiniFixture("testArgumentCountExactMatch", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "参数个数吻合不应抛错")
    }

    // MARK: - 参数类型（P2-1.2）

    /// I32 形参传入 String → mismatch(expected: "I32", got: "String")
    /// 意图：I32 形参传入 String 实参应抛 mismatch(expected: "I32", got: "String")，验证调用点实参类型约束。
    func testArgumentTypeMismatch() throws {
        let source = try loadPiniFixture("testArgumentTypeMismatch", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "类型不符应抛错") { error in
            guard case TypeError.mismatch(expected: "I32", got: "String", _) = error else {
                XCTFail("应为 mismatch(expected: \"I32\", got: \"String\")，实际: \(error)")
                return
            }
        }
    }

    /// 反向：同类型实参不应抛错
    /// 意图：同类型实参（42 对 I32）时 check 不抛错，反向验证类型比对无误报。
    func testArgumentTypeMatch() throws {
        let source = try loadPiniFixture("testArgumentTypeMatch", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "同类型实参不应抛错")
    }

    // MARK: - 边界：变参与未标注参数

    /// print 为变参：多参数不应误报个数错误
    /// 意图：print 为变参——传 (1, "a", true) 三个不同型参不应误报个数/类型错误，验证变参内建调用放行。
    func testVariadicPrintAcceptsManyArgs() throws {
        let source = try loadPiniFixture("testVariadicPrintAcceptsManyArgs", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "变参 print 多参数不应抛错")
    }

    /// 未标注类型的形参不施加类型约束（仅校验个数）
    /// 意图：未标注类型的形参不施加类型约束（仅校验个数）——foo(1, "x") 对 foo(a, b) 不抛错。
    func testUntypedParamNoTypeConstraint() throws {
        let source = try loadPiniFixture("testUntypedParamNoTypeConstraint", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "未标注类型参数不应施加类型约束（仅校验个数）")
    }
}
