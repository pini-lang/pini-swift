import XCTest
import PiniCore

/// 成员方法调用点校验：struct/object 成员方法实参个数 + 类型比对。
/// 驱动链路：Lexer → Parser → TypeChecker.check(module:)，与真实入口同构。
final class MemberMethodCallTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 实参类型（P2-1.4）

    /// 成员方法实参类型不符 → TypeError.mismatch（RED→GREEN）
    /// 意图：验证成员方法实参类型校验；传 String 给 I32 形参应抛 TypeError.mismatch(expected: I32, got: String)（RED→GREEN）。
    func testMemberMethodArgumentTypeMismatch()  throws {
        let source = try loadPiniFixture("testMemberMethodArgumentTypeMismatch", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "成员方法实参类型不符应抛错") { error in
            guard case TypeError.mismatch(expected: "I32", got: "String", _) = error else {
                XCTFail("应为 mismatch(expected: I32, got: String)，实际: \(error)")
                return
            }
        }
    }

    /// 成员方法实参个数不符 → TypeError.argumentCountMismatch（RED→GREEN）
    /// 意图：验证成员方法实参个数校验；需 2 个实参只传 1 个应抛 TypeError.argumentCountMismatch(expected: 2, got: 1)（RED→GREEN）。
    func testMemberMethodArgumentCountMismatch()  throws {
        let source = try loadPiniFixture("testMemberMethodArgumentCountMismatch", filePath: #filePath)
        XCTAssertThrowsError(try parseAndCheck(source), "成员方法实参个数不符应抛错") { error in
            guard case TypeError.argumentCountMismatch(expected: 2, got: 1, _) = error else {
                XCTFail("应为 argumentCountMismatch(expected: 2, got: 1)，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 合法调用（GREEN 基线）

    /// 意图：验证合法 struct 成员方法调用（类型、个数均匹配）通过类型检查不抛错（GREEN 基线）。
    func testMemberMethodCallValidNoError()  throws {
        let source = try loadPiniFixture("testMemberMethodCallValidNoError", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "合法成员方法调用不应报错")
    }

    /// 意图：验证 object 无参成员方法合法调用通过类型检查不抛错（GREEN 基线）。
    func testObjectMemberMethodCallValidNoError()  throws {
        let source = try loadPiniFixture("testObjectMemberMethodCallValidNoError", filePath: #filePath)
        XCTAssertNoThrow(try parseAndCheck(source), "object 成员方法调用不应报错")
    }

    // MARK: - 泛型构造类型推断（genericConstruct → .generic）

    /// 意图：验证泛型构造表达式 genericConstruct 被推断为专用化 .generic 类型；Box<I32> 应得到 name="Box"、类型实参 1 个且为 I32。
    func testGenericConstructInferredAsSpecializedType() {
        let infer = TypeInference()
        let loc = SourceLocation(line: 1, column: 1, fileName: "t.pini")
        let expr = Expression.genericConstruct(
            typeName: "Box",
            typeArgs: [.simple(name: "I32", location: loc)],
            arguments: [],
            location: loc
        )
        guard let t = infer.infer(expression: expr) else {
            XCTFail("genericConstruct 应推断出 .generic 类型")
            return
        }
        guard case .generic(let name, let params, _) = t else {
            XCTFail("应为 .generic，实际: \(t)")
            return
        }
        XCTAssertEqual(name, "Box")
        XCTAssertEqual(params.count, 1)
        if case .simple(let p, _) = params[0] { XCTAssertEqual(p, "I32") }
    }
}
