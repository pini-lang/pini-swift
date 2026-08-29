import XCTest
import PiniCore
import Foundation

/// 词法补全测试：数值进制 / 科学计数 / 字符串转义 / 字符串插值
final class LexicalTests: XCTestCase {
    private func runProgram(_ source: String) throws -> String {
        let lexer = Lexer(source: source, fileName: "lexical.pini")
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens, fileName: "lexical.pini")
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

    // MARK: - 数值进制

    // Intent: 词法层应识别十六进制字面量 0xFF 为 integerLiteral（推进性测量：值 255）
    func testHexLiteral() throws {
        let lexer = Lexer(source: "0xFF", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .integerLiteral(let v, _) = tokens[0] else { XCTFail("应为 integerLiteral"); return }
        XCTAssertEqual(v, 255)
    }

    // Intent: 词法层应识别二进制字面量 0b1010 为 integerLiteral（推进性测量：值 10）
    func testBinaryLiteral() throws {
        let lexer = Lexer(source: "0b1010", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .integerLiteral(let v, _) = tokens[0] else { XCTFail("应为 integerLiteral"); return }
        XCTAssertEqual(v, 10)
    }

    // Intent: 词法层应识别八进制字面量 0o17 为 integerLiteral（推进性测量：值 15）
    func testOctalLiteral() throws {
        let lexer = Lexer(source: "0o17", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .integerLiteral(let v, _) = tokens[0] else { XCTFail("应为 integerLiteral"); return }
        XCTAssertEqual(v, 15)
    }

    // Intent: 驳回性测量——前导零十进制 "07" 必须保持十进制（值 7），不得误判为八进制
    func testLeadingZeroDecimalUnchanged() throws {
        let lexer = Lexer(source: "07", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .integerLiteral(let v, _) = tokens[0] else { XCTFail("应为 integerLiteral"); return }
        XCTAssertEqual(v, 7, "前导零十进制应保持十进制语义，不按八进制解释")
    }

    // Intent: ADR-021 宽松词法——"0xG" 不再抛错：前缀后无有效数字，
    // 只消费 '0' 产出 int 0，"xG" 走标识符通道（错误后移到解析/语义）。
    // 驳回性测量：若恢复抛错或吞掉 '0'，本用例失败。
    func testInvalidHexThrows() throws {
        let lexer = Lexer(source: "0xG", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .integerLiteral(let v, _) = tokens[0] else {
            XCTFail("首 token 应为 int 0"); return
        }
        XCTAssertEqual(v, 0)
        guard case .identifier(let name, _) = tokens[1] else {
            XCTFail("次 token 应为 identifier xG"); return
        }
        XCTAssertEqual(name, "xG")
    }

    // MARK: - 科学计数

    // Intent: 词法层应识别科学计数法为 floatLiteral（推进性测量：1.5e3==1500.0，2e-2==0.02）
    func testScientificFloat() throws {
        let lexer = Lexer(source: "1.5e3", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .floatLiteral(let v, _) = tokens[0] else { XCTFail("应为 floatLiteral"); return }
        XCTAssertEqual(v, 1500.0)

        let lexer2 = Lexer(source: "2e-2", fileName: "t.pini")
        let tokens2 = try lexer2.tokenize()
        guard case .floatLiteral(let v2, _) = tokens2[0] else { XCTFail("应为 floatLiteral"); return }
        XCTAssertEqual(v2, 0.02)
    }

    // Intent: 词法层应识别大写指数与正负号（推进性测量：3.0E+2==300.0）
    func testScientificUppercaseAndSign() throws {
        let lexer = Lexer(source: "3.0E+2", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .floatLiteral(let v, _) = tokens[0] else { XCTFail("应为 floatLiteral"); return }
        XCTAssertEqual(v, 300.0)
    }

    // MARK: - 字符串转义

    // Intent: 解释器应正确解释转义序列 \n \t（推进性测量：输出 "a\nb\tc"）
    func testEscapeSequences() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                print("a\\nb\\tc")
                return
            """
        )
        XCTAssertEqual(output, "a\nb\tc\n")
    }

    // Intent: 解释器应正确解释转义引号 \"（推进性测量：输出 q"q）
    func testEscapedQuote() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                print("q\\"q")
                return
            """
        )
        XCTAssertEqual(output, "q\"q\n")
    }

    // Intent: ADR-021 宽松词法——非法转义 \q 原样保留进字符串内容（不报错）。
    // 驳回性测量：若抛错或吞掉反斜杠，本用例失败。
    func testInvalidEscapeThrows() throws {
        let lexer = Lexer(source: "\"\\q\"", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .stringLiteral(let s, _) = tokens[0] else {
            XCTFail("应为 stringLiteral"); return
        }
        XCTAssertEqual(s, "\\q", "非法转义应原样保留")
    }

    // MARK: - 字符串插值（\(expr)）

    // Intent: 词法层应将插值字符串拆为 literal/expression 段（推进性测量：段数与段内容）
    func testInterpolatedStringToken() throws {
        let lexer = Lexer(source: "\"x=\\(1+2)\"", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .interpolatedString(let segs, _) = tokens[0] else { XCTFail("应为 interpolatedString"); return }
        XCTAssertEqual(segs.count, 2)
        if case .literal(let s) = segs[0] { XCTAssertEqual(s, "x=") } else { XCTFail("段0应为字面量") }
        if case .expression(let e) = segs[1] { XCTAssertEqual(e, "1+2") } else { XCTFail("段1应为表达式") }
    }

    // Intent: 驳回性测量——无插值的纯字符串仍应识别为 stringLiteral，保持向后兼容
    func testPlainStringStillStringLiteral() throws {
        let lexer = Lexer(source: "\"abc\"", fileName: "t.pini")
        let tokens = try lexer.tokenize()
        guard case .stringLiteral(let v, _) = tokens[0] else { XCTFail("无插值的字符串应保持 stringLiteral，向后兼容"); return }
        XCTAssertEqual(v, "abc")
    }

    // Intent: 解释器应正确求值基础插值 "x=\(1+2)"（推进性测量：x=3）
    func testInterpolationBasic() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                print("x=\\(1+2)")
                return
            """
        )
        XCTAssertEqual(output, "x=3\n")
    }

    // Intent: 解释器应正确求值变量插值（推进性测量：hi Pini）
    func testInterpolationVariable() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                var name = "Pini"
                print("hi \\(name)")
                return
            """
        )
        XCTAssertEqual(output, "hi Pini\n")
    }

    // Intent: 解释器应正确求值嵌套算术插值（推进性测量：sum=7）
    func testInterpolationNestedExpr() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                print("sum=\\(2*3+1)")
                return
            """
        )
        XCTAssertEqual(output, "sum=7\n")
    }

    // Intent: 解释器应正确在插值中嵌入容器字面量（推进性测量：a=[1, 2, 3]）
    func testInterpolationContainer() throws {
        let output = try runProgram(
            """
            main|func() -> ()
                print("a=\\([1, 2, 3])")
                return
            """
        )
        XCTAssertEqual(output, "a=[1, 2, 3]\n")
    }

    // Intent: 驳回性测量——未闭合的插值表达式 "\(1+" 应抛出词法错误
    func testUnterminatedInterpolationThrows() throws {
        let lexer = Lexer(source: "\"\\(1+", fileName: "t.pini")
        XCTAssertThrowsError(try lexer.tokenize(), "未闭合的插值表达式应报错")
    }
}
