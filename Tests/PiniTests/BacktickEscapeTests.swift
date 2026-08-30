import XCTest
@testable import PiniCore

/// ADR-027 反引号关键字转义（批次 2，自举探针 G-P5）
final class BacktickEscapeTests: XCTestCase {

    /// 意图：`名称` 整体产出 IDENT token（跳过关键字分类）
    /// 推进性测量：`step` / `object` 转义后均为 .identifier
    /// 驳回性测量：产出 .keyword(step) 等均不合格
    func testBacktickYieldsIdentifierNotKeyword() throws {
        let source = "`step` `object` x"
        let tokens = try Lexer(source: source, fileName: "bt.pini").tokenize()
        guard case .identifier(let n1, _) = tokens[0] else {
            return XCTFail("第一个 token 应为 identifier，实际 \(tokens[0])")
        }
        XCTAssertEqual(n1, "step")
        guard case .identifier(let n2, _) = tokens[1] else {
            return XCTFail("第二个 token 应为 identifier，实际 \(tokens[1])")
        }
        XCTAssertEqual(n2, "object")
        guard case .identifier(let n3, _) = tokens[2] else {
            return XCTFail("普通标识符不受影响")
        }
        XCTAssertEqual(n3, "x")
    }

    /// 意图：未闭合/空转义回退 ADR-021 兜底（单字符 IDENT，词法器零错误契约）
    /// 推进性测量：裸反引号产出 .identifier("`")；未闭合 `step 产出 .identifier("`")
    /// 驳回性测量：抛词法错误或产出关键字 token 均不合格
    func testUnclosedEscapeFallsBackToLooseLex() throws {
        let bare = try Lexer(source: "var bs = `", fileName: "bt.pini").tokenize()
        guard case .identifier(let b, _) = bare[3] else {
            return XCTFail("裸反引号应为兜底 identifier，实际 \(bare[3])")
        }
        XCTAssertEqual(b, "`")
        let unclosed = try Lexer(source: "`step", fileName: "bt.pini").tokenize()
        guard case .identifier(let u, _) = unclosed[0] else {
            return XCTFail("未闭合转义应回退兜底，实际 \(unclosed[0])")
        }
        XCTAssertEqual(u, "`")
    }

    /// 意图：端到端——转义关键字作变量名与非关键字名作函数实参标签
    /// 推进性测量：程序运行输出 3 与 5
    /// 驳回性测量：解析/类型/运行错误均不合格
    func testBacktickEndToEnd() throws {
        let source = """
f|func(a: I32,) -> (I32,)
    return a

main|func() -> ()
    let `step` = 3
    print(`step`)
    print(f(`a`: 5,))
    return
"""
        let out = try runProgram(source)
        XCTAssertTrue(out.contains("3"), out)
        XCTAssertTrue(out.contains("5"), out)
    }

    // MARK: - 执行助手（与 BuiltinFunctionTests.runProgram 同型：
    // fd 恢复先于 read，防 EOF 死锁——见批次 0 死锁修复教训）

    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "backtick.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "backtick.pini")
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
            pipe.fileHandleForWriting.closeFile()
            throw error
        }

        fflush(stdout)
        pipe.fileHandleForWriting.closeFile()
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
