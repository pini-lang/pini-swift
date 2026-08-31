import XCTest
import PiniCore

/// 泛型实例化实参个数校验：genericConstruct 的 typeArgs 个数须与声明泛型形参个数一致。
/// 驱动链路：Lexer → Parser → TypeChecker.check(module:)。
final class GenericArityTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 实参个数不符

    /// 容器<T> 声明 1 个泛型形参；实例化 容器<I32, I32>() 给 2 个实参 → 报错
    /// 意图：验证实参过多被拒——容器<T> 声明 1 个形参，实例化 容器<I32, I32> 给 2 个实参，断言抛 genericArgumentCountMismatch(typeName: "容器", expected: 1, got: 2)。
    func testGenericArgumentCountMismatch() throws {
        let source = try loadPiniFixture("testGenericArgumentCountMismatch", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "泛型实参个数不符应抛错") { error in
            guard case TypeError.genericArgumentCountMismatch(typeName: "容器", expected: 1, got: 2, _) = error else {
                XCTFail("应为 genericArgumentCountMismatch(typeName: \"容器\", expected: 1, got: 2)，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 实参个数吻合

    /// 意图：验证实参个数吻合通过——容器<T> 实例化 容器<I32> 恰好 1 个实参，断言不抛错。
    func testGenericArgumentCountMatch() throws {
        let source = try loadPiniFixture("testGenericArgumentCountMatch", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "泛型实参个数吻合不应抛错")
    }

    /// 二元组泛型 Pair<A, B> 声明 2 个形参；实例化 Pair<I32>() 给 1 个实参 → 报错
    /// 意图：验证实参过少被拒——Pair<A, B> 声明 2 个形参，实例化 Pair<I32> 只给 1 个实参，断言抛 genericArgumentCountMismatch(typeName: "Pair", expected: 2, got: 1)。
    func testGenericArgumentCountTooFew() throws {
        let source = try loadPiniFixture("testGenericArgumentCountTooFew", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "泛型实参个数过少应抛错") { error in
            guard case TypeError.genericArgumentCountMismatch(typeName: "Pair", expected: 2, got: 1, _) = error else {
                XCTFail("应为 genericArgumentCountMismatch(typeName: \"Pair\", expected: 2, got: 1)，实际: \(error)")
                return
            }
        }
    }
}
