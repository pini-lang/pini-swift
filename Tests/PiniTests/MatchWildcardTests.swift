import XCTest
@testable import PiniCore

/// match `case _:` 通配兜底（D3①/G28 更新，2026-08-23 取代 P2 通配子块/default）：
/// 通配块体与 default 概念一次性移除，兜底统一为 `case _:`（无 case 命中时执行）。
final class MatchWildcardTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "wildcard.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "wildcard.pini")
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

    /// 无 case 命中 → `case _:` 通配兜底执行，其后的 match 外语句照常执行。
    /// 意图：验证无 case 命中时 `case _:` 作为兜底执行；s=三角形 应输出"兜底"，再落到 match 后语句输出"结束"。
    func testWildcardBlockExecutesOnNoCaseMatch() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆形")
        case 矩形:
            print("矩形")
        case _:
            print("兜底")
    print("结束")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "兜底\n结束",
                       "无 case 命中时应执行 case _: 兜底，再落到 match 之后的语句")
    }

    /// 有 case 命中 → `case _:` 通配不应执行（仅命中分支 + 后续语句）。
    /// 意图：验证有 case 命中时 `case _:` 被跳过；s=圆 应只命中 `case 圆` 输出"圆形"再输出"结束"，不得输出"兜底"。
    func testWildcardBlockSkippedOnCaseMatch() throws {
        let source = """
[形状]
圆
矩形

main|func() -> ()
    var s = 圆
    match s:
        case 圆:
            print("圆形")
        case 矩形:
            print("矩形")
        case _:
            print("兜底")
    print("结束")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "圆形\n结束",
                       "命中 case 时 case _: 必须跳过，否则会重复执行兜底逻辑")
    }

    /// `case _: pass` 作通配兜底（no-op 占位）应被正常解析且不报错。
    /// 意图：验证 `case _: pass` 是 no-op；s=三角形 无 case 命中时直接落到后续语句输出"结束"。
    func testPassAsWildcardBlockNoop() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆形")
        case _:
            pass
    print("结束")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "结束",
                       "case _: pass 应是 no-op，无 case 命中时直接落到后续语句")
    }

    /// 兜底优先级（D3①）：`case _:` 即唯一通配兜底；枚举覆盖不全但无 `case _:` 时应报 nonExhaustiveMatch。
    /// 意图：s=三角形（覆盖不全）且无 case _: 时，语义层应报 nonExhaustiveMatch（R1 总是开启）。
    func testWildcardTakesOverDefault() throws {
        let source = """
[形状]
圆
矩形
三角形

main|func() -> ()
    var s = 三角形
    match s:
        case 圆:
            print("圆形")
        case 矩形:
            print("矩形")
        case _:
            print("兜底")
    print("结束")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "兜底\n结束",
                       "case _: 兜底优先级与旧通配子块一致")
    }
}
