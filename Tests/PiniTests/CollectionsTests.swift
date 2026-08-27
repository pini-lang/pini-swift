import XCTest
import PiniCore
import Foundation

/// 集合类型测试（P1-1）：数组 / 字典 / 集合字面量、下标、len 泛化、print 格式化
/// 范围边界：不含 for-in 迭代、不含集合方法（push/append/contains 等，属 P1-4）
final class CollectionsTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "collections.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "collections.pini")
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

    /// 校验集合代码能通过语义分析 + 类型检查（MVP 放行策略：集合字面量/下标不深查元素类型）
    private func checkProgram(_ source: String) throws {
        let lexer = Lexer(source: source, fileName: "collections.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "collections.pini")
        let module = try parser.parseModule()
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
    }

    // MARK: - 数组

    // Intent: 验证数组字面量经解释器打印为 "[1, 2, 3]" 形式（推进性测量：输出等于该字符串）
    func testArrayLiteralPrint() throws {
        let source = """
main|func() -> ()
    print([1, 2, 3])
    return
"""
        XCTAssertEqual(try runProgram(source), "[1, 2, 3]\n")
    }

    // Intent: 验证空数组字面量 [] 打印为 "[]"
    func testEmptyArrayLiteralPrint() throws {
        let source = """
main|func() -> ()
    print([])
    return
"""
        XCTAssertEqual(try runProgram(source), "[]\n")
    }

    // Intent: 验证数组下标访问返回对应索引元素（推进性测量：a[1] == 20）
    func testArraySubscript() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30]
    print(a[1])
    return
"""
        XCTAssertEqual(try runProgram(source), "20\n")
    }

    // Intent: 验证嵌套数组字面量正确打印（推进性测量：[[1, 2], [3, 4]]）
    func testNestedArrayLiteralPrint() throws {
        let source = """
main|func() -> ()
    print([[1, 2], [3, 4]])
    return
"""
        XCTAssertEqual(try runProgram(source), "[[1, 2], [3, 4]]\n")
    }

    // Intent: 验证数组下标越界抛出 RuntimeError.invalidOperation（驳回性测量：错误类型必须精确匹配，而非其它错误）
    func testArraySubscriptOutOfRangeThrows() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30]
    print(a[99])
    return
"""
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.invalidOperation = error else {
                XCTFail("应为 RuntimeError.invalidOperation，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 字典

    // Intent: 验证字典字面量打印为 "{k: v}" 形式（推进性测量：[1: "a", 2: "b"] -> {1: a, 2: b}）
    func testDictionaryLiteralPrint() throws {
        let source = """
main|func() -> ()
    print([1: "a", 2: "b"])
    return
"""
        XCTAssertEqual(try runProgram(source), "{1: a, 2: b}\n")
    }

    // Intent: 验证字典下标访问返回对应键的值（推进性测量：d[2] == "y"）
    func testDictionarySubscript() throws {
        let source = """
main|func() -> ()
    var d = [1: "x", 2: "y"]
    print(d[2])
    return
"""
        XCTAssertEqual(try runProgram(source), "y\n")
    }

    // Intent: 验证字典缺失键下标返回 null（而非抛错）—— 驳回性测量：越界访问不应崩溃
    func testDictionarySubscriptMissingKeyReturnsNull() throws {
        let source = """
main|func() -> ()
    var d = [1: "x", 2: "y"]
    var r = d[9]
    print(r)
    return
"""
        XCTAssertEqual(try runProgram(source), "null\n")
    }

    // MARK: - 集合

    // Intent: 验证集合字面量保序去重（推进性测量：{3, 1, 2, 1} -> {3, 1, 2}）
    func testSetLiteralPrintWithDedup() throws {
        let source = """
main|func() -> ()
    print({3, 1, 2, 1})
    return
"""
        // 保序去重：{3, 1, 2}
        XCTAssertEqual(try runProgram(source), "{3, 1, 2}\n")
    }

    // MARK: - len 泛化

    // Intent: 验证 len 对数组返回元素个数（推进性测量：len([1,2,3,4]) == 4）
    func testLenArray() throws {
        let source = """
main|func() -> ()
    print(len([1, 2, 3, 4]))
    return
"""
        XCTAssertEqual(try runProgram(source), "4\n")
    }

    // Intent: 验证 len 对字典返回键值对个数（推进性测量：len([1:"a",2:"b"]) == 2）
    func testLenDictionary() throws {
        let source = """
main|func() -> ()
    print(len([1: "a", 2: "b"]))
    return
"""
        XCTAssertEqual(try runProgram(source), "2\n")
    }

    // Intent: 验证 len 对集合返回去重后元素个数（推进性测量：len({7,8,9}) == 3）
    func testLenSet() throws {
        let source = """
main|func() -> ()
    print(len({7, 8, 9}))
    return
"""
        XCTAssertEqual(try runProgram(source), "3\n")
    }

    // Intent: 验证 len 对字符串返回字符数（推进性测量：len("hello") == 5）
    func testLenString() throws {
        let source = """
main|func() -> ()
    print(len("hello"))
    return
"""
        XCTAssertEqual(try runProgram(source), "5\n")
    }

    // MARK: - 字符串下标

    // Intent: 验证字符串下标访问返回对应字符（推进性测量："hello"[1] == "e"）
    func testStringSubscript() throws {
        let source = """
main|func() -> ()
    print("hello"[1])
    return
"""
        XCTAssertEqual(try runProgram(source), "e\n")
    }

    // Intent: 验证字符串下标越界抛出 RuntimeError.invalidOperation（与数组下标越界行为一致）—— 驳回性测量
    func testStringSubscriptOutOfRangeThrows() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s[99])
    return
"""
        XCTAssertThrowsError(try runProgram(source)) { error in
            guard case RuntimeError.invalidOperation = error else {
                XCTFail("应为 RuntimeError.invalidOperation，实际: \(error)")
                return
            }
        }
    }

    // MARK: - 类型检查放行

    // Intent: 验证集合字面量/下标能通过语义分析 + 类型检查（MVP 放行策略：不深查元素类型），作为集成/放行测量
    func testCollectionsPassSemanticAndTypeCheck() throws {
        let source = """
main|func() -> ()
    var a = [1, 2, 3]
    var d = [1: "a", 2: "b"]
    var s = {1, 2, 3}
    var x = a[0]
    var y = d[1]
    print(x)
    print(y)
    return
"""
        XCTAssertNoThrow(try checkProgram(source))
    }
}
