import XCTest
import PiniCore
import Foundation

/// #46-E G41（test 块）：`测试函数块 |test` 显式声明的语法/语义基底测试。
///
/// 草稿：`测试函数块必须显示声明|test(形式参数元组,)->(返回元组,)`。
/// 实现路径：test 块 = 函数声明带 `|test` 修饰符（modifiers 含 "test"），
/// 花括号 `{名称|test}(签名)` 与裸函数 `名称|test(签名)` 两种形式（与 `|func` 同机制）。
///
/// 本文件只锁语法层 + 语义层接受性（R1 已拍板：pini test 子命令；
/// R4 已拍板：允许参数注入——参数形态在子命令实现侧消费）。
final class TestBlockTests: XCTestCase {
    private func parse(source: String, fileName: String = "test.pini") throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: fileName)
        return try parser.parseModule()
    }

    /// 提取模块中第一个带 `|test` 修饰符的函数声明。
    private func firstTestFunc(in module: Module) -> FuncDecl? {
        for decl in module.declarations {
            if case .funcDecl(let f) = decl, f.modifiers.contains("test") {
                return f
            }
        }
        return nil
    }

    /// 意图：裸函数形式 `名称|test(参数元组,) -> (返回元组,)` 解析出 modifiers=["test"] 的函数声明。
    func testParseTestBlockBareForm() throws {
        let module = try parse(source: """
裸测试|test() -> ()
    return

main() -> ()
    return
""")
        let f = try XCTUnwrap(firstTestFunc(in: module), "应解析出带 |test 修饰符的函数")
        XCTAssertEqual(f.name, "裸测试")
        XCTAssertTrue(f.modifiers.contains("test"), "modifiers 应含 test，实际 \(f.modifiers)")
        XCTAssertNotNil(f.body, "测试函数应有体")
    }

    /// 意图：花括号形式 `{名称|test}(参数元组,) -> (返回元组,)` 同样解析出 modifiers 含 "test"。
    func testParseTestBlockBraceForm() throws {
        let module = try parse(source: """
{加法测试|test}() -> ()
    return

main() -> ()
    return
""")
        let f = try XCTUnwrap(firstTestFunc(in: module), "应解析出带 |test 修饰符的函数")
        XCTAssertEqual(f.name, "加法测试")
        XCTAssertTrue(f.modifiers.contains("test"))
    }

    /// 意图：`|test` 允许声明参数（R4 已拍板：允许参数注入）——参数照常解析进 params。
    func testTestBlockAllowsParams() throws {
        let module = try parse(source: """
参数测试|test(x: I32, 消息: String,) -> ()
    return

main() -> ()
    return
""")
        let f = try XCTUnwrap(firstTestFunc(in: module))
        XCTAssertEqual(f.params.count, 2, "测试函数参数应照常解析")
        XCTAssertEqual(f.params[0].name, "x")
        XCTAssertEqual(f.params[1].name, "消息")
    }

    /// 意图：语义层接受 `|test` 函数（check 不报错）——test 是合法函数修饰符，可被 main 之外的入口消费。
    func testSemanticCheckAcceptsTestBlock() throws {
        let module = try parse(source: """
裸测试|test() -> ()
    return

main() -> ()
    return
""")
        // 解析 + 语义/类型检查不抛错即通过（check 路径等价于 runCheckCommand 的检查流程）。
        let analyzer = SemanticAnalyzer()
        XCTAssertNoThrow(try analyzer.analyze(module: module), "|test 函数应通过语义检查")
    }

    // MARK: - G41 R1/R4：Interpreter.runTests（pini test 的运行时执行入口）

    /// 意图：runTests 收集全部顶级 |test 函数并逐一执行；assert 全通过时全部 passed。
    func testRunTestsAllPass() throws {
        let module = try parse(source: """
加法测试|test() -> ()
    assert(1 + 1 == 2, "加法错误")
    return

字符串测试|test() -> ()
    assert(len("abc") == 3)
    return

main() -> ()
    return
""")
        let interpreter = Interpreter()
        let results = try interpreter.runTests(module: module)
        XCTAssertEqual(results.count, 2, "应收集到 2 个测试函数")
        XCTAssertTrue(results.allSatisfy(\.passed), "全部应通过，实际 \(results.map { ($0.name, $0.message) })")
        XCTAssertEqual(results.map(\.name), ["加法测试", "字符串测试"])
    }

    /// 意图：某测试断言失败记为失败（携带消息），不影响其余测试执行（失败不中断）。
    func testRunTestsCapturesFailure() throws {
        let module = try parse(source: """
应通过|test() -> ()
    assert(true)
    return

应失败|test() -> ()
    assert(2 + 2 == 5, "2+2 应等于 4")
    return
""")
        let interpreter = Interpreter()
        let results = try interpreter.runTests(module: module)
        XCTAssertEqual(results.count, 2)
        let failed = results.first { !$0.passed }
        XCTAssertNotNil(failed, "应存在失败测试")
        XCTAssertEqual(failed?.name, "应失败")
        XCTAssertTrue(failed?.message.contains("2+2 应等于 4") == true,
                      "失败消息应含自定义断言消息，实际 \(failed?.message ?? "")")
        XCTAssertTrue(results.filter(\.passed).count == 1, "应通过 1 个、失败 1 个")
    }

    /// 意图：R4 参数注入——带参数的 |test 函数按类型注入零值（String→""、I32→0），函数可正常执行。
    func testRunTestsInjectsZeroValueParams() throws {
        let module = try parse(source: """
参数测试|test(名称: String, 计数: I32,) -> ()
    assert(len(名称) == 0, "String 参数应注入空串")
    assert(计数 == 0, "I32 参数应注入 0")
    return
""")
        let interpreter = Interpreter()
        let results = try interpreter.runTests(module: module)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].passed, "零值注入后测试应通过，实际 \(results[0].message)")
    }
}
