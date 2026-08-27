import XCTest
import PiniCore

/// 返回类型一致性：函数声明的返回类型 vs 实际 return 语句返回的类型。
/// 驱动链路：Lexer → Parser → TypeChecker.check(module:)，与项目真实公共入口同构。
///
/// 范围（本切片）：
/// - 单返回（如 `-> (I32,)`）的精确比对；多返回/元组推迟至 P2-2。
/// - 非 void 函数中出现裸 `return`（返回 void）→ 报错。
/// - void 函数（`-> ()`）带值返回不卡（运行时合法，见解释器 returnStatement 处理）。
final class ReturnTypeConsistencyTests: XCTestCase {

    private func parseAndCheck(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 返回类型名不符

    /// 声明返回 String，实际返回 I32 → mismatch(expected: "String", got: "I32")
    /// 意图：验证声明返回 String 实际返回 I32 时抛 mismatch(expected: "String", got: "I32")。
    func testReturnTypeMismatch() {
        let source = """
        bad|func() -> (String,)
            return 1
        main|func() -> ()
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "返回类型不符应抛错") { error in
            guard case TypeError.mismatch(expected: "String", got: "I32", _) = error else {
                XCTFail("应为 mismatch(expected: \"String\", got: \"I32\")，实际: \(error)")
                return
            }
        }
    }

    /// 反向：声明返回 I32，实际返回 I32 → 不抛错
    /// 意图：验证声明 I32 实际返回 I32 时类型吻合，不抛错。
    func testReturnTypeMatch() {
        let source = """
        ok|func() -> (I32,)
            return 1
        main|func() -> ()
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "返回类型吻合不应抛错")
    }

    // MARK: - 裸 return 进入非 void 函数

    /// 声明返回 I32，但函数体内是裸 return（无值）→ mismatch(expected: "I32", got: "()")
    /// 意图：验证非 void 函数内裸 return（无值）触发 mismatch(expected: "I32", got: "()")。
    func testBareReturnInNonVoidFunction() {
        let source = """
        bad|func() -> (I32,)
            return
        main|func() -> ()
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "非 void 函数裸 return 应抛错") { error in
            guard case TypeError.mismatch(expected: "I32", got: "()", _) = error else {
                XCTFail("应为 mismatch(expected: \"I32\", got: \"()\")，实际: \(error)")
                return
            }
        }
    }

    /// 裸 return 出现在分支内也应被捕获（嵌套收集）
    /// 意图：验证裸 return 出现在 if/else 分支内同样被收集并报 mismatch(expected: "I32", got: "()")。
    func testBareReturnInBranchOfNonVoidFunction() {
        let source = """
        bad|func() -> (I32,)
            if true:
                return 1
            else:
                return
        main|func() -> ()
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "分支内裸 return 应抛错") { error in
            guard case TypeError.mismatch(expected: "I32", got: "()", _) = error else {
                XCTFail("应为 mismatch(expected: \"I32\", got: \"()\")，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 边界：void 与多返回

    /// void 函数带值返回不卡（运行时允许，解释器 returnStatement 有值即返回）
    /// 意图：验证 void 函数带值返回不报错（运行时合法路径）。
    func testVoidFunctionAllowsValueReturn() {
        let source = """
        v|func() -> ()
            return 1
        main|func() -> ()
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "void 函数带值返回不应抛错")
    }

    /// 多返回（元组）推迟至 P2-2，本切片不应误报
    /// 意图：验证多返回类型比对推迟至 P2-2，本切片不误报。
    func testMultiReturnDeferredToP2_2() {
        let source = """
        m|func() -> (I32, String,)
            return (1, "x")
        main|func() -> ()
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "多返回比对属 P2-2，本切片不应报错")
    }

    // MARK: - P2-2：元组返回 / 多返回（原推迟项已落地）

    /// 单返回为嵌套元组类型 (I32, String)（语法 -> ( (I32, String), )）；return (1, "x") 吻合 → 不抛错
    /// 意图：验证嵌套元组返回类型 (I32, String) 与 return (1, "x") 吻合时不抛错。
    func testTupleReturnMatch() {
        let source = """
        ok|func() -> ( (I32, String), )
            return (1, "x")
        main|func() -> ()
            return
        """
        XCTAssertNoThrow(try parseAndCheck(source), "元组返回类型吻合不应抛错")
    }

    /// 元组返回第二分量不符 → mismatch(expected: "(I32, String)", got: "(I32, I32)")
    /// 意图：验证元组返回第二分量不符时抛 mismatch(expected: "(I32, String)", got: "(I32, I32)")。
    func testTupleReturnMismatch() {
        let source = """
        bad|func() -> ( (I32, String), )
            return (1, 2)
        main|func() -> ()
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "元组返回类型不符应抛错") { error in
            guard case TypeError.mismatch(expected: "(I32, String)", got: "(I32, I32)", _) = error else {
                XCTFail("应为 mismatch(expected: \"(I32, String)\", got: \"(I32, I32)\")，实际: \(error)")
                return
            }
        }
    }

    /// 多返回 (I32, String) 第二分量不符 → mismatch（实际 (I32, I32)）
    /// 意图：验证多返回 (I32, String) 第二分量不符时抛 mismatch。
    func testMultiReturnTypeMismatch() {
        let source = """
        bad|func() -> (I32, String,)
            return (1, 2)
        main|func() -> ()
            return
        """
        XCTAssertThrowsError(try parseAndCheck(source), "多返回类型不符应抛错") { error in
            guard case TypeError.mismatch(_, _, _) = error else {
                XCTFail("应为 mismatch，实际: \(error)")
                return
            }
        }
    }
}
