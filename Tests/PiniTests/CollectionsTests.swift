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

    // Intent: 验证数组下标越界返回 nil（P2-C 安全通道越界可空，与字典缺失键一致）—— 迁移性测量：
    // 原实现越界抛 RuntimeError.invalidOperation，P2-C 改为统一返回 nil。
    func testArraySubscriptOutOfRangeReturnsNull() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30]
    print(a[99])
    return
"""
        XCTAssertEqual(try runProgram(source), "null\n")
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

    // Intent: 验证数组负索引尾部计数（P2-A：a[-1]=末元素，a[-len]=首元素）—— 推进性测量
    func testArrayNegativeIndex() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30]
    print(a[-1])
    print(a[-3])
    return
"""
        XCTAssertEqual(try runProgram(source), "30\n10\n")
    }

    // Intent: 验证字符串负索引尾部计数（P2-A：s[-1]=末字符）—— 推进性测量
    func testStringNegativeIndex() throws {
        let source = """
main|func() -> ()
    print("hello"[-1])
    print("hello"[-5])
    return
"""
        XCTAssertEqual(try runProgram(source), "o\nh\n")
    }

    // Intent: 验证越界下负索引仍返回 nil（P2-A + P2-C：-k 超过长度即越界）—— 驳回性测量
    func testNegativeIndexBeyondBoundsReturnsNull() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30]
    print(a[-4])
    var s = "hi"
    print(s[-3])
    return
"""
        XCTAssertEqual(try runProgram(source), "null\nnull\n")
    }

    // MARK: - 切片语法（P2-B）

    // Intent: 验证数组四种切片形态 a[i:j]/a[i:]/a[:j]/a[:]（Python 风半开区间）—— 推进性测量
    func testArraySliceForms() throws {
        let source = """
main|func() -> ()
    var a = [10, 20, 30, 40]
    print(a[1:3])
    print(a[1:])
    print(a[:3])
    print(a[:])
    return
"""
        XCTAssertEqual(try runProgram(source), "[20, 30]\n[20, 30, 40]\n[10, 20, 30]\n[10, 20, 30, 40]\n")
    }

    // Intent: 验证字符串切片形态与负索引尾部计数（P2-A + P2-B）—— 推进性测量
    func testStringSliceAndNegative() throws {
        let source = """
main|func() -> ()
    print("hello"[1:4])
    print("hello"[1:])
    print("hello"[:-1])
    print("hello"[-3:])
    return
"""
        XCTAssertEqual(try runProgram(source), "ell\nello\nhell\nllo\n")
    }

    // Intent: 验证切片越界夹紧、hi<lo 返回空（Python 一致）—— 驳回性测量
    func testSliceClampAndEmpty() throws {
        let source = """
main|func() -> ()
    print([1, 2, 3][1:99])
    print([1, 2, 3][3:1])
    print("abc"[-9:9])
    return
"""
        XCTAssertEqual(try runProgram(source), "[2, 3]\n[]\nabc\n")
    }

    // Intent: 验证字符串下标越界返回 nil（P2-C 安全通道越界可空，与数组下标一致）—— 迁移性测量
    func testStringSubscriptOutOfRangeReturnsNull() throws {
        let source = """
main|func() -> ()
    var s = "hello"
    print(s[99])
    return
"""
        XCTAssertEqual(try runProgram(source), "null\n")
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

    // MARK: - append（G45/G46，自举 lexer 前置：函数式返回新数组）

    /// 意图：append 为函数式成员方法——返回追加后的新数组，原数组不变（COW 值语义）。
    /// 推进性测量：输出 "[1, 2, 3]\n[1, 2, 3, 4]\n"（a 不变，b 追加）。
    func testArrayAppendFunctionalReturnsNewArray() throws {
        let source = """
main|func() -> ()
    var a = [1, 2, 3]
    var b = a.append(4)
    print(a)
    print(b)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "[1, 2, 3]\n[1, 2, 3, 4]\n", "append 应返回新数组且原数组不变")
    }

    // MARK: - last / pop（G45/G46，S1.3 栈操作：IndentTracker 依赖）

    /// 意图：last 读取栈顶（函数式），pop 返回 (新数组, 栈顶) 元组——缩进栈的 peek/pop。
    /// 推进性测量：输出 "3\n3\n[1, 2]\n"（last=3；pop 解构 top=3、b=[1,2]）。
    func testArrayLastAndPopStackSemantics() throws {
        let source = """
main|func() -> ()
    var a = [1, 2, 3]
    print(a.last())
    var (b, top) = a.pop()
    print(top)
    print(b)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "3\n3\n[1, 2]\n", "last 应返回栈顶，pop 应返回新数组与栈顶")
    }

    /// 意图：空数组 last/pop 返回 null（不崩溃）——安全模型先例（对齐字典缺失键 null）。
    /// 推进性测量：输出 "null\n[]\n"（[].last()=null；[].pop() 解构 x=null、e=[]）。
    func testArrayLastPopOnEmptyReturnsNull() throws {
        let source = """
main|func() -> ()
    print([].last())
    var (e, x) = [].pop()
    print(x)
    print(e)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output, "null\nnull\n[]\n", "空数组 last 应返回 null，pop 解构为 (空数组, null)")
    }
}
