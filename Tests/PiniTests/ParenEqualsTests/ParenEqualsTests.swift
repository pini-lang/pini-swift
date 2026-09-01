import XCTest
import PiniCore
import Foundation

/// 批 3（proposal-paren-equals-binding-2026-09-01）：括号内记法收口。
///
/// 记法原则：**`=` = 值的注入方向**（实参标签 / 字典条目 / 元组标签 / 默认参数）；
/// **`:` = 类型与块的标注方向 + 值的取出方向**（类型标注 / 块开启 / match 具名绑定）。
/// 旧记法 `f(a: 1)` / `[k: v]` / `(a: 1,)` 已废弃，宿主报错并给出迁移提示。
final class ParenEqualsTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "test.pini")
        let module = try parser.parseModule()

        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        setvbuf(stdout, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        let interpreter = Interpreter()
        try interpreter.run(module: module)

        fflush(stdout)
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseError(_ source: String) -> String? {
        do {
            let tokens = try Lexer(source: source, fileName: "test.pini").tokenize()
            _ = try Parser(tokens: tokens, fileName: "test.pini").parseModule()
            return nil
        } catch let e as ParserError {
            return String(describing: e)
        } catch {
            return "other: \(error)"
        }
    }

    // MARK: - 新记法（注入方向用 =）

    /// 意图：调用点带标签实参用 `=`
    func testLabeledCallArgumentUsesEquals() throws {
        let src = """
        取值|func(a: I32, b: I32) -> (I32,):
            return a + b
        main|func() -> ():
            print(取值(a = 1, b = 2))
            return
        """
        XCTAssertEqual(try runProgram(src), "3")
    }

    /// 意图：位置实参不受影响（混用标签与位置亦可）
    func testPositionalArgumentsUnaffected() throws {
        let src = """
        取值|func(a: I32, b: I32) -> (I32,):
            return a + b
        main|func() -> ():
            print(取值(1, 2))
            print(取值(b = 5, a = 1))
            return
        """
        XCTAssertEqual(try runProgram(src), "3\n6")
    }

    /// 意图：字典字面量条目用 `=`（D-2 立场 A）
    func testDictionaryLiteralUsesEquals() throws {
        let src = """
        main|func() -> ():
            var ages = ["Alice" = 30, "Bob" = 25]
            print(ages["Alice"])
            print(ages.get("ZZZ"))
            return
        """
        XCTAssertEqual(try runProgram(src), "30\nnone")
    }

    /// 意图：标签元组字面量用 `=`（D-4）
    func testLabeledTupleUsesEquals() throws {
        let src = """
        main|func() -> ():
            var t = (x = 1, y = 2,)
            print(t.x)
            print(t.y)
            return
        """
        XCTAssertEqual(try runProgram(src), "1\n2")
    }

    /// 意图：枚举具名构造用 `=`（D-3；G54 具名关联的构造位）
    func testEnumNamedConstructionUsesEquals() throws {
        let src = """
        [形状]
            圆(半径: F64,)
            方(边长: F64,)
        取半径|func(s: 形状,) -> (F64,):
            match s:
                case 圆(半径: r):
                    return r
                case 方(边长: _ ):
                    return 0
            return 0
        main|func() -> ():
            print(取半径(圆(半径 = 2)))
            return
        """
        XCTAssertEqual(try runProgram(src), "2")
    }

    /// 意图（D-5 回归锁）：match 具名绑定**保留** `:`（取出方向）
    func testMatchNamedBindingKeepsColon() throws {
        let src = """
        [E]
            值(v: I32,)
        main|func() -> ():
            match 值(v = 7):
                case 值(v: x):
                    print(x)
            return
        """
        XCTAssertEqual(try runProgram(src), "7")
    }

    // MARK: - 废弃（旧记法报错并提示）

    /// 意图：旧实参标签 `f(a: 1)` 报错并给出迁移提示（D-1）
    func testDeprecatedColonArgumentRejected() {
        let msg = parseError("""
        f|func(a: I32,) -> (I32,):
            return a
        main|func() -> ():
            print(f(a: 1))
            return
        """)
        XCTAssertNotNil(msg, "旧记法应报错")
        XCTAssertTrue(msg?.contains("实参标签须用") == true, "应给出迁移提示，实际：\(msg ?? "")")
    }

    /// 意图：旧字典条目 `[k: v]` 报错并给出迁移提示（D-2）
    func testDeprecatedColonDictionaryRejected() {
        let msg = parseError("""
        main|func() -> ():
            var d = ["a": 1]
            print(d["a"])
            return
        """)
        XCTAssertTrue(msg?.contains("字典条目须用") == true, "应给出迁移提示，实际：\(msg ?? "")")
    }

    /// 意图：旧元组标签 `(a: 1,)` 报错并给出迁移提示（D-4）
    func testDeprecatedColonTupleLabelRejected() {
        let msg = parseError("""
        main|func() -> ():
            var t = (a: 1,)
            print(t.a)
            return
        """)
        XCTAssertTrue(msg?.contains("元组标签须用") == true, "应给出迁移提示，实际：\(msg ?? "")")
    }

    /// 意图：类型标注与块开启的 `:` 不受影响（D-7 / H-4 回归锁）
    func testColonTypeAndBlockUnaffected() throws {
        let src = """
        (P)
            x: I32
        main|func() -> ():
            var n: I32 = 加(a = 4, b = 0)
            if n > 1:
                print(n)
            else:
                print(0)
            return
        加|func(a: I32, b: I32,) -> (I32,):
            return a + b
        """
        XCTAssertEqual(try runProgram(src), "4")
    }

    /// 意图：`==`（相等）与 `=`（标签）在括号内不混淆
    func testEqualsVersusEqualityUnaffected() throws {
        let src = """
        同|func(a: I32, b: I32,) -> (Bool,):
            return a == b
        main|func() -> ():
            print(同(a = 1, b = 2))
            return
        """
        XCTAssertEqual(try runProgram(src), "false")
    }
}
