import XCTest
import PiniCore

/// 调用点元组类型等价比对：实参元组逐分量与形参元组比较。
/// 驱动链路：Lexer → Parser → TypeChecker.check(module:)，与项目真实公共入口同构。
final class CallSiteTupleTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 元组分量类型不符

    /// 形参 (I32, String)，实参 (1, 2) → mismatch(expected: "(I32, String)", got: "(I32, I32)")
    /// 意图：元组实参第二分量类型不符（I32 对 String）应抛 mismatch(expected: "(I32, String)", got: "(I32, I32)")，验证实参元组逐分量与形参比对。
    func testTupleArgumentTypeMismatch() {
        let source = """
        takesPair|func(p: (I32, String),) -> ()
            return
        main|func() -> ()
            takesPair(p: (1, 2))
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "元组实参第二分量类型不符应抛错") { error in
            guard case TypeError.mismatch(expected: "(I32, String)", got: "(I32, I32)", _) = error else {
                XCTFail("应为 mismatch(expected: \"(I32, String)\", got: \"(I32, I32)\")，实际: \(error)")
                return
            }
        }
    }

    /// 形参 (I32, String)，实参 (1, "x") → 不抛错
    /// 意图：元组实参各分量与形参类型吻合（(1, "x") 对 (I32, String)）时 check 不抛错，反向验证类型比对无误报。
    func testTupleArgumentTypeMatch() {
        let source = """
        takesPair|func(p: (I32, String),) -> ()
            return
        main|func() -> ()
            takesPair(p: (1, "x"))
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "元组实参类型吻合不应抛错")
    }

    // MARK: - 元组分量个数不符

    /// 形参 (I32, String)，实参 (1, 2, 3) → 分量个数不符
    /// 意图：元组实参分量个数多于形参（3 对 2）应抛 mismatch(expected: "(I32, String)", got: "(I32, I32, I32)")，验证分量个数不符被拦截。
    func testTupleArgumentCountMismatch() {
        let source = """
        takesPair|func(p: (I32, String),) -> ()
            return
        main|func() -> ()
            takesPair(p: (1, 2, 3))
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "元组实参分量个数不符应抛错") { error in
            guard case TypeError.mismatch(expected: "(I32, String)", got: "(I32, I32, I32)", _) = error else {
                XCTFail("应为 mismatch(expected: \"(I32, String)\", got: \"(I32, I32, I32)\")，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 嵌套元组

    /// 内层第二分量不同 → mismatch（证明递归分量比较生效）
    /// 意图：嵌套元组内层分量不符（(1, "x") 对 (I32, I32)）应抛 mismatch，证明分量比对递归进入嵌套层级。
    func testNestedTupleMismatch() {
        let source = """
        f|func(p: ((I32, I32), String),) -> ()
            return
        main|func() -> ()
            f(p: ((1, "x"), "y"))
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "嵌套元组内层分量不符应抛错") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch，实际: \(error)")
                return
            }
        }
    }

    /// 嵌套元组吻合 → 不抛错
    /// 意图：嵌套元组各层分量均吻合（((1, 2), "y") 对 ((I32, I32), String)）时 check 不抛错，反向验证嵌套递归比较无误报。
    func testNestedTupleMatch() {
        let source = """
        f|func(p: ((I32, I32), String),) -> ()
            return
        main|func() -> ()
            f(p: ((1, 2), "y"))
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "嵌套元组实参吻合不应抛错")
    }
}
