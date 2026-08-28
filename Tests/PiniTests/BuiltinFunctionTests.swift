import XCTest
import PiniCore
import Foundation

/// 内置函数行为测试
/// 覆盖 print/len 的正常路径、边界路径与错误路径
final class BuiltinFunctionTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "builtin.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "builtin.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        do {
            let interpreter = Interpreter()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - print 基础行为

    /// 意图：验证 print 输出整数后附加换行符
    /// 推进性测量：输出为 "42\n"
    /// 驳回性测量：输出不为空、不为 "42"（无换行）
    func testPrintIntegerWithNewline() throws {
        let source = """
main|func() -> ()
    print(42)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "42\n", "print 应输出整数并附加换行符")
    }

    /// 意图：验证 print 输出字符串
    /// 推进性测量：输出为 "Hello\n"
    func testPrintString() throws {
        let source = """
main|func() -> ()
    print("Hello")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "Hello\n", "print 应输出字符串内容")
    }

    /// 意图：验证 print 输出元组，使用方括号包裹
    /// 推进性测量：输出为 "[1, 2, 3]\n"
    func testPrintTuple() throws {
        let source = """
main|func() -> ()
    print((1, 2, 3,))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "[1, 2, 3]\n", "print 应以方括号包裹元组元素")
    }

    // MARK: - typeOf 幽灵函数

    /// 意图：验证 typeOf 未被注册为内置函数（规范未定义、解释器未实现）
    /// 推进性测量：SemanticAnalyzer 应拒绝 typeOf 调用
    /// 驳回性测量：typeOf 不应静默通过语义分析
    func testTypeOfIsNotRegisteredInSemanticAnalyzer() throws {
        let source = """
main|func() -> ()
    typeOf(42)
    return
"""
        let lexer = Lexer(source: source, fileName: "builtin.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "builtin.pini")
        let module = try parser.parseModule()

        let analyzer = SemanticAnalyzer()
        XCTAssertThrowsError(try analyzer.analyze(module: module), "typeOf 未注册，语义分析应报错") { error in
            guard case SemanticError.undefinedFunction(let name, _) = error else {
                XCTFail("应为 SemanticError.undefinedFunction，实际: \(error)")
                return
            }
            XCTAssertEqual(name, "typeOf", "报错的函数名应为 typeOf")
        }
    }

    // MARK: - len 行为

    /// 意图：验证 len 返回元组元素数量
    /// 推进性测量：len((1, 2, 3,)) 返回 3
    func testLenReturnsTupleLength() throws {
        let source = """
main|func() -> ()
    print(len((1, 2, 3,)))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n", "len 应返回元组元素数量")
    }

    /// 意图：验证 len 对空元组返回 0
    /// 推进性测量：len(()) 返回 0
    func testLenReturnsZeroForEmptyTuple() throws {
        let source = """
main|func() -> ()
    print(len(()))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n", "空元组长度应为 0")
    }

    /// 意图：验证 len 对字符串返回字符数（P1-1 泛化：len 支持 tuple/array/dict/set/string）
    /// 推进性测量：len("abc") 返回 3
    func testLenReturnsStringLength() throws {
        let source = """
main|func() -> ()
    print(len("abc"))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n", "len 应返回字符串字符数")
    }

    /// 意图：验证 len 对整数抛出错误
    /// 推进性测量：调用应抛出 RuntimeError
    func testLenThrowsForInteger() throws {
        let source = """
main|func() -> ()
    print(len(42))
    return
"""
        XCTAssertThrowsError(try runProgram(source), "len 对整数应抛出错误") { error in
            guard case RuntimeError.invalidOperation = error else {
                XCTFail("应为 RuntimeError.invalidOperation，实际: \(error)")
                return
            }
        }
    }

    // MARK: - print 枚举值

    /// 意图：验证 print 对无关联值的枚举用例输出 caseName
    /// 推进性测量：输出为 "red\n"
    func testPrintEnumCaseWithoutAssociatedValues() throws {
        let source = """
[颜色]
red
green
blue

main|func() -> ()
    var c = red
    print(c)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "red\n", "无关联值枚举应仅输出 caseName")
    }

    /// 意图：验证 print 对有命名参数的枚举用例输出关联值
    /// 推进性测量：输出为 "圆(5.0)\n"
    func testPrintEnumCaseWithNamedAssociatedValues() throws {
        let source = """
[形状]
圆(F64,)

main|func() -> ()
    var c = 圆(5.0,)
    print(c)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "圆(5.0)\n", "命名参数枚举应输出 圆(5.0)")
    }

    /// 意图：验证 print 对多个命名参数的枚举用例输出全部关联值
    /// 推进性测量：输出为 "矩形(3.0, 4.0)\n"
    func testPrintEnumCaseWithMultipleNamedValues() throws {
        let source = """
[形状]
矩形(F64, F64,)

main|func() -> ()
    var r = 矩形(3.0, 4.0,)
    print(r)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "矩形(3.0, 4.0)\n", "多参数枚举应输出全部关联值")
    }

    /// 意图：验证 print 对未命名关联值的枚举用例输出值列表
    /// 推进性测量：输出为 "成功(42)\n"
    func testPrintEnumCaseWithUnnamedAssociatedValues() throws {
        let source = """
[结果]
成功(I32,)

main|func() -> ()
    var r = 成功(42)
    print(r)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "成功(42)\n", "未命名参数枚举应输出 成功(42)")
    }

    // MARK: - 边界与缺陷基线（自 P1 验收壳迁入）

    /// len 对空串与空数组应返回 0
    func testLenEmpty() throws {
        let source = """
main|func() -> ()
    print(len(""))
    print(len([]))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n0\n", "len 对空串/空数组应返回 0")
    }

    /// print 无参数应仅输出一个换行
    /// 意图：验证 print() 无参调用仅输出一个换行符
    /// 推进性测量：捕获输出与 "\n" 相等
    func testPrintNoArgs() throws {
        let source = """
main|func() -> ()
    print()
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "\n", "print() 无参应仅输出换行")
    }

    // MARK: - G41 assert 内建（test 块，R2：参数由实现设计——`assert(条件: Bool,)` / `assert(条件: Bool, 消息: String,)`）

    /// 意图：assert(true) 与 assert(true, 消息) 均不中断程序（通过路径零副作用）。
    func testAssertTruePasses() throws {
        let source = """
main|func() -> ()
    assert(true)
    assert(true, "应该通过")
    print("ok")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "ok\n", "assert(true) 不应中断程序")
    }

    /// 意图：assert(false) 抛 RuntimeError.assertionFailed，消息缺省 "assert failed"。
    func testAssertFalseThrows() throws {
        let source = """
main|func() -> ()
    assert(false)
    return
"""
        XCTAssertThrowsError(try runProgram(source), "assert(false) 应抛断言失败") { error in
            guard case RuntimeError.assertionFailed(let message, _) = error else {
                XCTFail("应为 assertionFailed，实际: \(error)")
                return
            }
            XCTAssertEqual(message, "assert failed", "缺省消息应为 assert failed")
        }
    }

    /// 意图：assert(false, 消息) 抛 assertionFailed 且携带自定义消息。
    func testAssertFalseWithMessage() throws {
        let source = """
main|func() -> ()
    assert(false, "参数必须为正数")
    return
"""
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.assertionFailed(let message, _) = error else {
                XCTFail("应为 assertionFailed，实际: \(error)")
                return
            }
            XCTAssertEqual(message, "参数必须为正数", "应携带自定义消息")
        }
    }

    /// 意图：assert 条件非 Bool 时报 invalidOperation（类型守卫：条件必须为 Bool）。
    func testAssertNonBoolConditionThrows() throws {
        let source = """
main|func() -> ()
    assert(1)
    return
"""
        XCTAssertThrowsError(try runProgram(source), "assert 条件非 Bool 应报错") { error in
            guard case RuntimeError.invalidOperation(let reason, _) = error else {
                XCTFail("应为 invalidOperation，实际: \(error)")
                return
            }
            XCTAssertTrue(reason.contains("Bool"), "错误信息应提示条件需为 Bool，实际: \(reason)")
        }
    }

    // MARK: - is_letter（lexer 字符谓词，G45）

    /// 意图：is_letter 按 Unicode 字母（UCD L 类）判定——ASCII 字母与中文均 true。
    /// 推进性测量：输出 "true\ntrue\n"（h、字）。
    func testIsLetterUnicode() throws {
        let source = """
main|func() -> ()
    print(is_letter("h"))
    print(is_letter("字"))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "true\ntrue\n", "ASCII 与中文字母均应判定为字母")
    }

    /// 意图：is_letter 对非字母（数字/下划线/空串）返回 false——IDENT 首字符判定边界。
    /// 驳回性测量：输出 "false\nfalse\nfalse\n"（1、_、空串）。
    func testIsLetterRejectsNonLetters() throws {
        let source = """
main|func() -> ()
    print(is_letter("1"))
    print(is_letter("_"))
    print(is_letter(""))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "false\nfalse\nfalse\n", "数字/下划线/空串均不应判定为字母")
    }
}
