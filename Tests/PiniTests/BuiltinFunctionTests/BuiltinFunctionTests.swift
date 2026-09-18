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
            let interpreter = ProgramRunner()
            try interpreter.run(module: module)
        } catch {
            fflush(stdout)
            pipe.fileHandleForWriting.closeFile()
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
        let source = try loadPiniFixture("testPrintIntegerWithNewline", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "42\n", "print 应输出整数并附加换行符")
    }

    /// 意图：验证 print 输出字符串
    /// 推进性测量：输出为 "Hello\n"
    func testPrintString() throws {
        let source = try loadPiniFixture("testPrintString", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "Hello\n", "print 应输出字符串内容")
    }

    /// 意图：验证 print 输出元组，使用方括号包裹
    /// 推进性测量：输出为 "[1, 2, 3]\n"
    func testPrintTuple() throws {
        let source = try loadPiniFixture("testPrintTuple", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "[1, 2, 3]\n", "print 应以方括号包裹元组元素")
    }

    // MARK: - typeOf 幽灵函数

    /// 意图：验证 typeOf 未被注册为内置函数（规范未定义、解释器未实现）
    /// 推进性测量：SemanticAnalyzer 应拒绝 typeOf 调用
    /// 驳回性测量：typeOf 不应静默通过语义分析
    func testTypeOfIsNotRegisteredInSemanticAnalyzer() throws {
        let source = try loadPiniFixture("testTypeOfIsNotRegisteredInSemanticAnalyzer", filePath: #filePath)
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
        let source = try loadPiniFixture("testLenReturnsTupleLength", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n", "len 应返回元组元素数量")
    }

    /// 意图：验证 len 对空元组返回 0
    /// 推进性测量：len(()) 返回 0
    func testLenReturnsZeroForEmptyTuple() throws {
        let source = try loadPiniFixture("testLenReturnsZeroForEmptyTuple", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n", "空元组长度应为 0")
    }

    /// 意图：验证 len 对字符串返回字符数（P1-1 泛化：len 支持 tuple/array/dict/set/string）
    /// 推进性测量：len("abc") 返回 3
    func testLenReturnsStringLength() throws {
        let source = try loadPiniFixture("testLenReturnsStringLength", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n", "len 应返回字符串字符数")
    }

    /// 意图：验证 len 对整数抛出错误
    /// 推进性测量：调用应抛出 RuntimeError
    func testLenThrowsForInteger() throws {
        let source = try loadPiniFixture("testLenThrowsForInteger", filePath: #filePath)
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
        let source = try loadPiniFixture("testPrintEnumCaseWithoutAssociatedValues", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "red\n", "无关联值枚举应仅输出 caseName")
    }

    /// 意图：验证 print 对有命名参数的枚举用例输出关联值
    /// 推进性测量：输出为 "圆(5.0)\n"
    func testPrintEnumCaseWithNamedAssociatedValues() throws {
        let source = try loadPiniFixture("testPrintEnumCaseWithNamedAssociatedValues", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "圆(5.0)\n", "命名参数枚举应输出 圆(5.0)")
    }

    /// 意图：验证 print 对多个命名参数的枚举用例输出全部关联值
    /// 推进性测量：输出为 "矩形(3.0, 4.0)\n"
    func testPrintEnumCaseWithMultipleNamedValues() throws {
        let source = try loadPiniFixture("testPrintEnumCaseWithMultipleNamedValues", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "矩形(3.0, 4.0)\n", "多参数枚举应输出全部关联值")
    }

    /// 意图：验证 print 对未命名关联值的枚举用例输出值列表
    /// 推进性测量：输出为 "成功(42)\n"
    func testPrintEnumCaseWithUnnamedAssociatedValues() throws {
        let source = try loadPiniFixture("testPrintEnumCaseWithUnnamedAssociatedValues", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "成功(42)\n", "未命名参数枚举应输出 成功(42)")
    }

    // MARK: - 边界与缺陷基线（自 P1 验收壳迁入）

    /// len 对空串与空数组应返回 0
    func testLenEmpty() throws {
        let source = try loadPiniFixture("testLenEmpty", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n0\n", "len 对空串/空数组应返回 0")
    }

    /// print 无参数应仅输出一个换行
    /// 意图：验证 print() 无参调用仅输出一个换行符
    /// 推进性测量：捕获输出与 "\n" 相等
    func testPrintNoArgs() throws {
        let source = try loadPiniFixture("testPrintNoArgs", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "\n", "print() 无参应仅输出换行")
    }

    // MARK: - G41 assert 内建（test 块，R2：参数由实现设计——`assert(条件: Bool,)` / `assert(条件: Bool, 消息: String,)`）

    /// 意图：assert(true) 与 assert(true, 消息) 均不中断程序（通过路径零副作用）。
    func testAssertTruePasses() throws {
        let source = try loadPiniFixture("testAssertTruePasses", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "ok\n", "assert(true) 不应中断程序")
    }

    /// 意图：assert(false) 抛 RuntimeError.assertionFailed，消息缺省 "assert failed"。
    func testAssertFalseThrows() throws {
        let source = try loadPiniFixture("testAssertFalseThrows", filePath: #filePath)
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
        let source = try loadPiniFixture("testAssertFalseWithMessage", filePath: #filePath)
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
        let source = try loadPiniFixture("testAssertNonBoolConditionThrows", filePath: #filePath)
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
        let source = try loadPiniFixture("testIsLetterUnicode", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "true\ntrue\n", "ASCII 与中文字母均应判定为字母")
    }

    /// 意图：is_letter 对非字母（数字/下划线）返回 false——IDENT 首字符判定边界。
    /// 驳回性测量：输出 "false\nfalse\n"（1、_）。
    ///
    /// ⚠️ 原「空串」一行已随 `P0d` 作废：`is_letter` 的参数面改为 `Char`，而
    /// `Char` 恒为 1 个字素 ⇒「空串」在该签名下**不可表达**。不变式因此由
    /// **类型系统**守（比原先「谓词对空串返回 false」更强），不是覆盖缩水。
    func testIsLetterRejectsNonLetters() throws {
        let source = try loadPiniFixture("testIsLetterRejectsNonLetters", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "false\nfalse\n", "数字/下划线均不应判定为字母")
    }

    // MARK: - is_ascii_digit（ADR-019 D4）

    /// 意图：is_ascii_digit 对 ASCII 数字 [0-9] 返回 true——INT 字面量扫描判定。
    /// 推进性测量：输出 "true\ntrue\ntrue\n"（0、9、5）。
    func testIsAsciiDigitAcceptsDigits() throws {
        let source = try loadPiniFixture("testIsAsciiDigitAcceptsDigits", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "true\ntrue\ntrue\n", "ASCII 数字应判定为 digit")
    }

    /// 意图：is_ascii_digit 拒绝非 ASCII 数字字符——含带数值的汉字 三（numeric property
    /// 但非 [0-9]）、字母、下划线；INT 字面量严格 ASCII 的边界锚（ADR-019 D3 对照）。
    /// 驳回性测量：输出 "false\nfalse\nfalse\n"（三、a、_）。
    ///
    /// ⚠️ 原「空串」一行已随 `P0d` 作废（参数面 `String` → `Char`，空串不可表达）。
    func testIsAsciiDigitRejectsNonDigits() throws {
        let source = try loadPiniFixture("testIsAsciiDigitRejectsNonDigits", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "false\nfalse\nfalse\n", "汉字/字母/下划线均不应判定为 digit")
    }

    // MARK: - is_number（ADR-019 D4 / D3）

    /// 意图：is_number 按 Unicode numeric property 判定——含 三（Lo 类带数值汉字，
    /// 严格超集 \p{N} 的裁决锚，ADR-019 D3）与 〇（Nl 类）。
    /// 推进性测量：输出 "true\ntrue\ntrue\ntrue\n"（0、三、〇、½）。
    func testIsNumberAcceptsNumericProperty() throws {
        let source = try loadPiniFixture("testIsNumberAcceptsNumericProperty", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "true\ntrue\ntrue\ntrue\n", "numeric property 字符均应判定为 number")
    }

    /// 意图：is_number 对无 numeric property 的字符返回 false——与 is_letter 的
    /// 互斥锚（字 为字母但无数值）、下划线。
    /// 驳回性测量：输出 "false\nfalse\nfalse\n"（字、a、_）。
    ///
    /// ⚠️ 原「空串」一行已随 `P0d` 作废（参数面 `String` → `Char`，空串不可表达）。
    func testIsNumberRejectsNonNumeric() throws {
        let source = try loadPiniFixture("testIsNumberRejectsNonNumeric", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "false\nfalse\nfalse\n", "非 numeric property 字符不应判定为 number")
    }

    // MARK: - chars（ADR-019 性能项：grapheme 预切）

    /// 意图：chars 按 grapheme cluster 预切字符数组——中文/ASCII 混排与 len 一致；
    /// 元素类型为 `Char`（`P0d`），故拼接还原仍成立（`Char + Char` 结果取 `String` 面）。
    /// 推进性测量：输出 "3\na\ntrue\n"。
    func testCharsSplitsGraphemes() throws {
        let source = try loadPiniFixture("testCharsSplitsGraphemes", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\na\ntrue\n", "chars 应按 grapheme 切分且可还原")
    }

    /// 意图：chars 对星外平面字符（𝐀，U+1D400，代理对）保持单个 grapheme——
    /// 与 split("") 的 UTF-16 劈开行为形成回归锚（ADR-019 D1 grapheme 模型）。
    /// 推进性测量：输出 "1\ntrue\n"（𝐀 切分后长度 1，且仍为字母）。
    func testCharsKeepsAstralPlaneGraphemes() throws {
        let source = try loadPiniFixture("testCharsKeepsAstralPlaneGraphemes", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "1\ntrue\n", "代理对字符不应被劈开，且可参与字符判定")
    }

    /// 意图：chars 对空串返回空数组——len 恒等边界。
    /// 驳回性测量：输出 "0\n"。
    ///
    /// ⚠️ 本条**不受** `P0d` 影响：`chars` 的参数面**保持** `String`（其契约正是把
    /// 串切开），改的只是**元素**类型。空串仍是它的一等输入。
    func testCharsEmptyString() throws {
        let source = try loadPiniFixture("testCharsEmptyString", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "0\n", "空串应切出空数组")
    }

    // MARK: - ord / chr（词法门禁 H1：码点原语）

    /// 意图：ord 取首 Unicode scalar 码点值——ASCII 与中文（ADR-019 D1 grapheme
    /// 模型下多 scalar grapheme 取首 scalar）。
    /// 推进性测量：输出 "65\n23383\n"。
    ///
    /// ⚠️ 原「空串哨兵 -1」已随 `P0d` 作废：`ord` 的参数面改为 `Char`，而 `Char`
    /// 恒为 1 个字素 ⇒「空串」在该签名下**不可表达**，哨兵失去输入来源。
    func testOrdCodepoints() throws {
        let source = try loadPiniFixture("testOrdCodepoints", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "65\n23383\n", "ord 应返回首 scalar 码点")
    }

    /// 意图：chr 合法码点还原字符。
    /// 推进性测量：输出 "A\n字\n"（65、23383）。
    func testChrCodepoints() throws {
        let source = try loadPiniFixture("testChrCodepoints", filePath: #filePath)
        let output = try runProgram(source)
        XCTAssertEqual(output, "A\n字\n", "chr 合法码点应还原字符")
    }

    /// 意图：chr 越界 = **panic**（`E5-005`），不再是「返回空串哨兵」。
    ///
    /// `P0d` 的边界裁决：`chr` 的返回面改为 `Char`，而 `Char` 恒为 1 个字素
    /// ⇒ 它**没有**任何值可以表示「没有字符」⇒ 空串哨兵不可表达，改走既有的
    /// indexOutOfRange 通道（与 `s[i]` 越界同族，**不新增诊断码**）。
    ///
    /// 三个越界形态各自独立成源：任一个都会 panic ⇒ 不能共处一份夹具
    /// （原先它们共处一份，正因为它们都「返回空串」；这一形态已不存在）。
    func testChrOutOfRangePanics() throws {
        for code in ["-1", "1114112", "55296"] {
            let source = "main|func() -> ():\n    print(chr(\(code)))\n    return"
            XCTAssertThrowsError(
                try runProgram(source),
                "chr(\(code)) 越界应 panic（负值 / 超 scalar 上限 / 代理区）"
            )
        }
    }
}
