import XCTest
import PiniCore
import Foundation

/// 标准库行为测试
/// 字符串方法以成员方法形式（s.upper()）提供；数学库以自由函数形式（abs(x)）提供。
/// 全部走真实解释器公共接口（runProgram 捕获 stdout），不 mock 内部实现。
final class StdlibTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "stdlib.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "stdlib.pini")
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

    // MARK: - TDD#1 字符串 upper / lower

    /// 意图：字符串成员方法 upper()/lower() 返回大小写转换后的新字符串
    /// 推进性测量：输出为 "HELLO\nhello\n"
    func testStringUpperLower() throws {
        let source = """
main|func() -> ()
    var s = "Hello"
    print(s.upper())
    print(s.lower())
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "HELLO\nhello\n", "upper/lower 应返回大小写转换后的字符串")
        // 驳回性测量：必须真正改变大小写，不得原样返回
        XCTAssertNotEqual(output, "Hello\nHello\n", "upper/lower 不得原样返回输入")
    }

    // MARK: - TDD#2 字符串 contains

    /// 意图：字符串成员方法 contains(sub) 返回 Bool，表示 sub 是否为子串
    /// 推进性测量：包含返回 true，不包含返回 false
    func testStringContains() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    if s.contains("ell"):
        print("yes")
    if s.contains("xyz"):
        print("no")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "yes\n", "contains 应在子串存在时返回 true，否则 false")
        // 驳回性测量：不包含子串时不应误触发 yes 分支
        XCTAssertFalse(output.contains("no"), "contains 不存在子串时不应打印 no")
    }

    // MARK: - TDD#3 字符串 substring

    /// 意图：字符串成员方法 substring(start, end) 返回半开区间 [start, end) 切片
    /// 推进性测量："hello".substring(1, 4) == "ell"
    func testStringSubstring() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s.substring(1, 4))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "ell\n", "substring 应返回 [start, end) 区间的切片")
        // 驳回性测量：必须返回切片而非原串
        XCTAssertNotEqual(output, "hello\n", "substring 不得返回原串")
    }

    // MARK: - TDD#4 字符串 split

    /// 意图：字符串成员方法 split(sep) 按分隔符切分为字符串数组
    /// 推进性测量："a,b,c".split(",") == ["a", "b", "c"]
    func testStringSplit() throws {
        let source = """
main|func() -> ()
    var s = "a,b,c"
    print(s.split(","))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "[a, b, c]\n", "split 应按分隔符切分为字符串数组")
        // 驳回性测量：必须返回数组表示而非原分隔串
        XCTAssertNotEqual(output, "a,b,c\n", "split 不得返回原分隔串")
    }

    // MARK: - TDD#5 数组 join

    /// 意图：数组成员方法 join(sep) 用分隔符连接字符串数组
    /// 推进性测量：["a", "b", "c"].join("-") == "a-b-c"
    func testArrayJoin() throws {
        let source = """
main|func() -> ()
    var arr = ["a", "b", "c"]
    print(arr.join("-"))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "a-b-c\n", "join 应用分隔符连接数组元素")
        // 驳回性测量：必须用分隔符连接而非直接拼接
        XCTAssertNotEqual(output, "abc\n", "join 不得直接拼接元素")
    }

    // MARK: - TDD#6 数学 abs（自由函数）

    /// 意图：自由函数 abs(x) 返回绝对值，Int 保持 Int、Float 保持 Float
    /// 推进性测量：abs(-5) == 5，abs(-2.5) == 2.5
    func testMathAbs() throws {
        let source = """
main|func() -> ()
    print(abs(-5))
    print(abs(-2.5))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "5\n2.5\n", "abs 应返回绝对值并保持数值类型")
        // 驳回性测量：必须翻转符号返回绝对值
        XCTAssertNotEqual(output, "-5\n-2.5\n", "abs 必须翻转符号")
    }

    // MARK: - TDD#7 数学 min / max（自由函数）

    /// 意图：自由函数 min(a,b)/max(a,b) 返回较小/较大值（同类型数值）
    /// 推进性测量：min(3, 7) == 3，max(3, 7) == 7
    func testMathMinMax() throws {
        let source = """
main|func() -> ()
    print(min(3, 7))
    print(max(3, 7))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n7\n", "min/max 应返回较小/较大值")
        // 驳回性测量：顺序必须正确（非反序）
        XCTAssertNotEqual(output, "7\n3\n", "min/max 顺序不得反")
    }

    // MARK: - TDD#8 数学 sqrt（自由函数）

    /// 意图：自由函数 sqrt(x) 返回 Float 平方根
    /// 推进性测量：sqrt(16.0) == 4.0
    func testMathSqrt() throws {
        let source = """
main|func() -> ()
    print(sqrt(16.0))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "4.0\n", "sqrt 应返回平方根（Float）")
        // 驳回性测量：必须返回平方根而非原值
        XCTAssertNotEqual(output, "16.0\n", "sqrt 不得返回原值")
    }

    // MARK: - TDD#9 三角函数 sin / cos / tan（自由函数，弧度制）

    /// 意图：自由函数 sin/cos/tan(x) 返回 Float（弧度制）
    /// 推进性测量：sin(0.0)==0.0，cos(0.0)==1.0，tan(0.0)==0.0
    func testMathTrig() throws {
        let source = """
main|func() -> ()
    print(sin(0.0))
    print(cos(0.0))
    print(tan(0.0))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "0.0\n1.0\n0.0\n", "sin/cos/tan 应以弧度计算三角函数")
        // 驳回性测量：sin/cos/tan 在 0 处的顺序必须正确
        XCTAssertNotEqual(output, "1.0\n0.0\n1.0\n", "sin/cos/tan 顺序不得反")
    }

    // MARK: - 边界与缺陷基线（自 P1 验收壳迁入）

    /// 缺陷 D1：abs(Int.min) 触发 Swift 整数溢出 trap（进程 abort）。
    /// 验收期望：不崩溃，明确抛出整数溢出错误（而非 trap）。
    /// 意图：验证 abs(Int.min) 不触发 Swift 整数溢出 trap，而是抛整数溢出错误（runProgram 抛错而非进程 abort）。
    func testAbsIntMinDoesNotCrash() {
        // 用运算构造 Int.min（避免大字面量在词法层溢出掩盖 abs 缺陷）
        let source = """
main|func() -> ()
    var x = -9223372036854775807
    var m = x - 1
    print(abs(m))
    return
"""
        XCTAssertThrowsError(try runProgram(source), "abs(Int.min) 应抛整数溢出错误，而非崩溃")
    }

    /// 缺陷 D2：substring 负索引导致 String 下标越界崩溃。
    /// 验收期望：负索引安全夹紧到 0，substring(-1, 3) == "hel"。
    /// 意图：验证 substring(-1, 3) 负索引安全夹紧到 0，输出 "hel" 而非越界崩溃。
    func testSubstringNegativeIndexClamped() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s.substring(-1, 3))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "hel\n", "substring 负索引应夹紧到 0")
    }

    /// 缺陷 D3：substring start>end 导致 range 反向越界崩溃。
    /// 验收期望：start>end 返回空串 ""，不崩溃。
    /// 意图：验证 substring(3, 1) start>end 反向区间返回空串（仅换行），不崩溃。
    func testSubstringStartGreaterThanEnd() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s.substring(3, 1))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "\n", "substring start>end 应返回空串（仅换行）")
    }

    /// substring 正向越界应夹紧到字符串末尾（不崩溃）
    /// 意图：验证 substring(2, 100) 正向越界夹紧到字符串末尾，输出 "llo" 不崩溃。
    func testSubstringForwardClamp() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s.substring(2, 100))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "llo\n", "substring 正向越界应夹紧到末尾")
    }

    /// join 应对非字符串元素做 stringify 后用分隔符连接
    /// 意图：验证 join 对非字符串元素（Int）先 stringify 再以分隔符连接，输出 "1-2-3"。
    func testJoinWithNonStringElements() throws {
        let source = """
main|func() -> ()
    var a = [1, 2, 3]
    print(a.join("-"))
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "1-2-3\n", "join 应将元素 stringify 后以分隔符连接")
    }

    /// min/max 不接受 Int 与 Float 混合，应保持抛错（同类型数值才合法）
    /// 意图：验证 min/max 不接受 Int 与 Float 混合参数，runProgram 抛错而非返回结果（同类型数值才合法）。
    func testMinMaxMixedTypesThrows() {
        let source = """
main|func() -> ()
    print(min(1, 2.0))
    return
"""
        XCTAssertThrowsError(try runProgram(source), "min/max 混合 Int/Float 应抛错")
    }
}
