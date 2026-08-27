import XCTest
@testable import PiniCore

/// P5-1（MED-1）：`match` 枚举值主体未匹配任何 case 且无 default/通配子块兜底时，
/// 运行期明确抛 `RuntimeError.matchNotExhaustive`（替代原静默 no-op）。
/// P5-2（LOW-1）：位置绑定改用 enumerated 按位置绑定，消除 `firstIndex(of:)` 脆弱性
/// （重复绑定如 `case 矩形(a, a,)` 不再错位）。
final class MatchErrorTests: XCTestCase {

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "matcherr.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "matcherr.pini")
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

    // MARK: - P5-1 MED-1

    /// 枚举值未匹配任何 case、且无 default/通配子块 → 抛 matchNotExhaustive（不再静默）。
    /// 意图：s=三角形 未匹配任何 case 且无兜底，应抛 RuntimeError.matchNotExhaustive 并携带枚举名"三角形"
    func testUnmatchedEnumThrows() throws {
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
    return
"""
        do {
            _ = try runProgram(source)
            XCTFail("未匹配枚举值应抛 RuntimeError.matchNotExhaustive")
        } catch let error as RuntimeError {
            guard case .matchNotExhaustive(let value, _) = error else {
                XCTFail("期望 matchNotExhaustive，得到 \(error)")
                return
            }
            XCTAssertEqual(value, "三角形", "报错应携带未匹配的枚举 case 名")
        }
    }

    /// 有 default 兜底 → 未匹配 case 时走 default，不抛错。
    /// 意图：s=三角形 未匹配时落入 default 分支输出"默认"，不抛 matchNotExhaustive
    func testUnmatchedEnumWithDefaultNoThrow() throws {
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
            print("默认")
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "默认",
                       "有 default 时未匹配应落入 default，不抛错")
    }

    /// 有 `case _: pass` 通配兜底 → 未匹配 case 时走通配，不抛错。
    /// 意图：s=三角形 未匹配时走 `case _: pass`（no-op），输出为空且不抛错
    func testUnmatchedEnumWithWildcardNoThrow() throws {
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
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "有 case _: 时未匹配应走通配（pass 为 no-op），不抛错")
    }

    // MARK: - P5-2 LOW-1

    /// 重复位置绑定 `case 矩形(a, a,)`：enumerated 按位置绑定，第二个 a 取关联值[1]
    /// （旧实现用 firstIndex(of:) 会把两个 a 都绑到关联值[0]，错位）。
    /// 意图：重复位置绑定 a 应各按其枚举位置取值，a 最终为关联值[1]=4.0 而非两个都绑到 3.0
    func testDuplicatePositionalBindingUsesEnumeratedIndex() throws {
        let source = """
[形状]
圆(F64,)
矩形(F64, F64,)
三角形(F64, F64,)

main|func() -> ()
    var r = 矩形(3.0, 4.0,)
    match r:
        case 矩形(a, a,):
            print(a)
    return
"""
        let output = try runProgram(source)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "4.0",
                       "重复位置绑定应按枚举位置分别绑定：a 最终取关联值[1]=4.0，而非两个都取关联值[0]=3.0")
    }
}
