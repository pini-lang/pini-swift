import XCTest
@testable import PiniCore

/// P5-4（HIGH-2）：`match` 支持标量 / 字面量 / 通配 `_` 模式（此前 `match` 仅匹配枚举值，
/// 标量主体整段被跳过、落入 default 或不执行，模式匹配能力被严重削弱）。
final class MatchScalarPatternTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "matchescalar.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "matchescalar.pini")
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

    /// 整数字面量模式匹配。
    /// 意图：验证 `match` 按整数字面量模式命中对应 case；x=2 应命中 `case 2` 输出"二"而非其他分支。
    func testIntLiteralPattern() throws {
        let source = """
main|func() -> ()
    var x = 2
    match x:
        case 1:
            print("一")
        case 2:
            print("二")
        case 3:
            print("三")
    return
"""
        XCTAssertEqual(try runProgram(source), "二\n", "整数模式应命中对应 case")
    }

    /// 字符串字面量模式匹配。
    /// 意图：验证 `match` 按字符串字面量模式命中对应 case；s="b" 应命中 `case "b"` 输出"B"。
    func testStringLiteralPattern() throws {
        let source = """
main|func() -> ()
    var s = "b"
    match s:
        case "a":
            print("A")
        case "b":
            print("B")
    return
"""
        XCTAssertEqual(try runProgram(source), "B\n", "字符串模式应命中对应 case")
    }

    /// 布尔字面量模式匹配。
    /// 意图：验证 `match` 按布尔字面量模式命中对应 case；f=true 应命中 `case true` 输出"真"。
    func testBoolLiteralPattern() throws {
        let source = """
main|func() -> ()
    var f = true
    match f:
        case true:
            print("真")
        case false:
            print("假")
    return
"""
        XCTAssertEqual(try runProgram(source), "真\n", "布尔模式应命中对应 case")
    }

    /// 浮点字面量模式匹配。
    /// 意图：验证 `match` 按浮点字面量模式命中对应 case；y=2.5 应命中 `case 2.5` 输出"二点五"。
    func testFloatLiteralPattern() throws {
        let source = """
main|func() -> ()
    var y = 2.5
    match y:
        case 1.0:
            print("一")
        case 2.5:
            print("二点五")
    return
"""
        XCTAssertEqual(try runProgram(source), "二点五\n", "浮点模式应命中对应 case")
    }

    /// 通配 `_` 模式匹配任意值（含标量）。
    /// 意图：验证通配 `_` 模式可兜底任意标量值；x=99 无对应整数字面量 case 时应落入 `case _` 输出"其他"。
    func testWildcardPatternMatchesAnyScalar() throws {
        let source = """
main|func() -> ()
    var x = 99
    match x:
        case 1:
            print("一")
        case _:
            print("其他")
    return
"""
        XCTAssertEqual(try runProgram(source), "其他\n", "通配 `_` 应兜底任意标量值")
    }

    /// 通配 `_` 模式也能兜底枚举值（与枚举 case 名模式并存）。
    /// 意图：验证通配 `_` 模式可兜底枚举值；s=三角形 未命中 `case 圆` 时应落入 `case _` 输出"其他形状"。
    func testWildcardPatternMatchesEnum() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆")
        case _:
            print("其他形状")
    return
"""
        XCTAssertEqual(try runProgram(source), "其他形状\n", "通配 `_` 应兜底任意枚举值")
    }

    /// 标量主体无模式命中且无 `_`/default → 静默跳过（MED-1 仅覆盖枚举值，标量保持静默）。
    /// 意图：验证标量主体无模式命中且无 `_`/default 时静默跳过不抛错；x=5 应跳过 match 直接执行后续 print("结束")。
    func testScalarNoMatchSilent() throws {
        let source = """
main|func() -> ()
    var x = 5
    match x:
        case 1:
            print("一")
    print("结束")
    return
"""
        XCTAssertEqual(try runProgram(source), "结束\n", "标量未命中且无兜底时应静默跳过，不抛错")
    }
}
