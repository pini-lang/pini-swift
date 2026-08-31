import XCTest
@testable import PiniCore

/// REPL 单元测试：验证解析与表达式 wrap 逻辑。
final class ReplTests: XCTestCase {

    // MARK: - 表达式 wrap

    /// 意图：验证表达式 wrap 进 main|func 后能解析出唯一函数声明。
    func testExpressionWrap()  throws {
        let source = "main|func() -> ()\n    print(1 + 2)\n    return\n"
        let module = parseOrFail(source)
        XCTAssertEqual(module.declarations.count, 1)
    }

    // MARK: - 续行检测

    /// 意图：验证以 : 结尾的函数头需触发续行，单行输入解析失败返回 nil。
    func testFunctionHeaderWithoutBodyNeedsContinuation()  throws {
        // 以 `:` 结尾的行 → 应触发续行；单行解析应失败
        let result = tryParse("main|func() -> ():")
        XCTAssertNil(result, "仅有函数头应解析失败（需要续行）")
    }

    /// 意图：验证带缩进函数体的完整函数声明能解析成功（非 nil）。
    func testFunctionWithBodyParses()  throws {
        let module = tryParse(try loadPiniFixture("testFunctionWithBodyParses", filePath: #filePath) as String)
        // 带 INDENT 块的完整函数应能解析
        XCTAssertNotNil(module, "完整函数声明应能解析成功")
    }

    // MARK: - 声明识别

    /// 意图：验证非声明开头的输入按表达式模式识别，wrap 后能解析出至少一个声明。
    func testExpressionIsRecognized() {
        // 非声明开头 → 表达式模式
        let source = "main|func() -> ()\n    print(1 + 2 * 3)\n    return\n"
        let module = parseOrFail(source)
        XCTAssertGreaterThan(module.declarations.count, 0)
    }

    /// 意图：验证模拟 REPL 将裸表达式 1 + 2 * 3 wrap 进 print 后解析出唯一声明。
    func testBareExpressionWrapper() {
        // 模拟 REPL 的表达式 wrap 逻辑
        let expr = "1 + 2 * 3"
        let wrapped = "main|func() -> ()\n    print(\(expr))\n    return\n"
        let module = parseOrFail(wrapped)
        XCTAssertEqual(module.declarations.count, 1)
    }

    // MARK: - 错误恢复

    /// 意图：验证无法解析的无效输入 @#$% 返回 nil 而非崩溃。
    func testMalformedInputReturnsNil() {
        let result = tryParse("@#$%")
        XCTAssertNil(result, "无效输入应返回 nil")
    }

    /// 意图：验证空输入返回含零声明的空 Module。
    func testEmptyInputReturnsEmptyModule() {
        let result = tryParse("")!
        XCTAssertEqual(result.declarations.count, 0, "空输入应返回空 Module")
    }
}

// MARK: - 辅助

private func parseOrFail(_ source: String) -> Module {
    let module = tryParse(source)
    XCTAssertNotNil(module, "预期解析成功:\n\(source)")
    return module!
}

private func tryParse(_ source: String) -> Module? {
    let lexer = Lexer(source: source, fileName: "<repl_test>")
    guard let tokens = try? lexer.tokenize() else { return nil }
    let parser = Parser(tokens: tokens, fileName: "<repl_test>")
    guard case let result = parser.parseModuleCollectingErrors(),
          result.errors.isEmpty else { return nil }
    return result.module
}
