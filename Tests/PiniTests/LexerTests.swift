import XCTest
import PiniCore
import Foundation

final class LexerTests: XCTestCase {
    /// 意图：简单标识符 x 应识别为 .identifier("x") 且行号列号均为 1，token 流以 EOF 结尾
    func testTokenizeSimpleIdentifier() throws {
        let lexer = Lexer(source: "x", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        XCTAssertEqual(tokens.count, 2, "应产生 2 个 token：identifier + EOF")
        if case .identifier("x", let loc) = tokens[0] {
            XCTAssertEqual(loc.line, 1, "行号应为 1")
            XCTAssertEqual(loc.column, 1, "列号应为 1")
        } else {
            XCTFail("第一个 token 应为 identifier")
        }
        if case .eof(let loc) = tokens[1] {
            XCTAssertEqual(loc.line, 1, "EOF 行号应为 1")
        } else {
            XCTFail("第二个 token 应为 EOF")
        }
    }

    /// 意图：中文标识符"变量"应被识别为 .identifier("变量")，而非报错
    func testTokenizeChineseIdentifier() throws {
        let lexer = Lexer(source: "变量", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        XCTAssertEqual(tokens.count, 2, "应产生 2 个 token")
        if case .identifier("变量", _) = tokens[0] {
        } else {
            XCTFail("应识别中文标识符")
        }
    }

    /// 意图：`;` 行注释应被跳过不产生 token，后续标识符 x 正常识别且行号落在第二行
    func testTokenizeComment() throws {
        let lexer = Lexer(source: "; this is a comment\nx", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        XCTAssertEqual(tokens.count, 2, "注释应被忽略，只产生 identifier + EOF")
        if case .identifier("x", let loc) = tokens[0] {
            XCTAssertEqual(loc.line, 2, "标识符应在第二行")
        } else {
            XCTFail("注释后应为 identifier")
        }
    }

    /// 意图：`#` 文档注释行与 `;` 行内注释均应被跳过，仅剩 x assign 1 EOF 四个 token
    func testTokenizeDocComment() throws {
        // G35：`#` 文档注释（行首=文档注释，行中=退化行注释），到行尾；与 `;` 行注释并存
        let lexer = Lexer(source: "# doc comment\nx = 1 ; 行内注释", fileName: "test.pini")
        let tokens = try lexer.tokenize()
        XCTAssertEqual(tokens.count, 4, "`#` 注释行与 `;` 行内注释应被跳过，仅剩 x assign 1 EOF")
        guard case .identifier("x", _) = tokens[0] else { XCTFail("注释后应为 identifier x"); return }
        guard case .assign = tokens[1] else { XCTFail("应为 assign"); return }
        guard case .integerLiteral(1, _) = tokens[2] else { XCTFail("应为 1"); return }
    }

    /// 意图：行中 `#` 应退化为行注释并吞掉其后内容，仅剩 a assign 2 NL b EOF 六个 token
    func testTokenizeHashTrailingComment() throws {
        // G35：行中 `#` 退化为行注释（吞掉其后内容到行尾）
        let lexer = Lexer(source: "a = 2 # trailing\nb", fileName: "test.pini")
        let tokens = try lexer.tokenize()
        XCTAssertEqual(tokens.count, 6, "行中 `#` 应吞掉其后内容，仅剩 a assign 2 NL b EOF")
        guard case .identifier("b", _) = tokens[4] else { XCTFail("第二行应为 identifier b"); return }
    }

    /// 意图：双引号字符串 "hello" 应识别为 .stringLiteral("hello")
    func testTokenizeStringLiteral() throws {
        let lexer = Lexer(source: "\"hello\"", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        if case .stringLiteral("hello", _) = tokens[0] {
        } else {
            XCTFail("应识别字符串字面量")
        }
    }

    /// 意图：整数字面量 42 应识别为 .integerLiteral(42)
    func testTokenizeIntegerLiteral() throws {
        let lexer = Lexer(source: "42", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        if case .integerLiteral(42, _) = tokens[0] {
        } else {
            XCTFail("应识别整数字面量")
        }
    }

    /// 意图：浮点字面量 3.14 应识别为 .floatLiteral(3.14)
    func testTokenizeFloatLiteral() throws {
        let lexer = Lexer(source: "3.14", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        if case .floatLiteral(3.14, _) = tokens[0] {
        } else {
            XCTFail("应识别浮点字面量")
        }
    }

    /// 意图：true 与 false 应分别识别为 .boolLiteral(true) 与 .boolLiteral(false)
    func testTokenizeBoolLiteral() throws {
        let lexer = Lexer(source: "true", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        if case .boolLiteral(true, _) = tokens[0] {
        } else {
            XCTFail("应识别布尔字面量 true")
        }

        let lexer2 = Lexer(source: "false", fileName: "test.pini")
        let tokens2 = try lexer2.tokenize()
        if case .boolLiteral(false, _) = tokens2[0] {
        } else {
            XCTFail("应识别布尔字面量 false")
        }
    }

    /// 意图：缩进块应产生 INDENT token，块结束应产生 DEDENT token
    func testTokenizeIndentDedent() throws {
        let source = """
main() -> ()
    x
"""
        let lexer = Lexer(source: source, fileName: "test.pini")
        let tokens = try lexer.tokenize()

        var foundIndent = false
        var foundDedent = false
        for token in tokens {
            if case .indent(_) = token { foundIndent = true }
            if case .dedent(_) = token { foundDedent = true }
        }

        XCTAssertTrue(foundIndent, "应产生 INDENT token")
        XCTAssertTrue(foundDedent, "应产生 DEDENT token")
    }

    /// 意图：`<<=` 应按最长匹配识别为单个 .leftShiftAssign token，而非拆成多个
    func testTokenizeLongestMatchOperator() throws {
        let lexer = Lexer(source: "<<=", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        XCTAssertEqual(tokens.count, 2, "应产生 2 个 token")
        if case .leftShiftAssign(_) = tokens[0] {
        } else {
            XCTFail("应识别 <<= 运算符（最长匹配）")
        }
    }

    /// 意图：块标签 sigil `@` 应识别为 .at，后随标识符 label，共 3 个 token（含 EOF）
    func testTokenizeAtForLabel() throws {
        // G35：块标签 sigil 由 `#` 改 `@`；`#` 已重分配为文档注释
        let lexer = Lexer(source: "@label", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        // tokenize 始终追加 EOF，因此 @label 产生 3 个 token：at, identifier, eof
        XCTAssertEqual(tokens.count, 3, "应产生 3 个 token（含 EOF）")
        if case .at(_) = tokens[0] {
        } else {
            XCTFail("应识别 @ token")
        }
        if case .identifier("label", _) = tokens[1] {
        } else {
            XCTFail("@ 后应为 identifier")
        }
    }

    /// 意图：`#label` 整行应作为文档注释被跳过，仅剩 EOF（`#` 不再产生块标签 token）
    func testTokenizeHashIsDocComment() throws {
        // G35：`#` 整行=文档注释（不产生 token）；`#label` 不再是块标签写法
        let lexer = Lexer(source: "#label", fileName: "test.pini")
        let tokens = try lexer.tokenize()
        XCTAssertEqual(tokens.count, 1, "`#label` 整行应为文档注释，仅剩 EOF")
        guard case .eof = tokens[0] else { XCTFail("应为 EOF"); return }
    }

    /// 意图：可选类型糖前缀 `?` 应识别为 .questionMark，后随标识符 I32，共 3 个 token（含 EOF）
    func testTokenizeQuestionMark() throws {
        let lexer = Lexer(source: "?I32", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        // tokenize 始终追加 EOF，因此 ?I32 产生 3 个 token：questionMark, identifier, eof
        XCTAssertEqual(tokens.count, 3, "应产生 3 个 token（含 EOF）")
        if case .questionMark(_) = tokens[0] {
        } else {
            XCTFail("应识别 ? token（可选类型糖前缀）")
        }
    }

    /// 意图：`var` 应识别为关键字 keyword(.var)，而非普通标识符
    func testTokenizeKeyword() throws {
        let lexer = Lexer(source: "var x", fileName: "test.pini")
        let tokens = try lexer.tokenize()

        if case .keyword(.var, _) = tokens[0] {
        } else {
            XCTFail("应识别 var 关键字")
        }
    }

    /// 意图：ADR-021 宽松词法——无效字符 `$` 不再抛错，产出单字符标识符
    /// token（错误报告后移到解析/语义阶段：标识符落在不合适的位置被拒）。
    /// 推进性测量：tokenize 不抛错，唯一 token 为 identifier "$"，后随 eof。
    /// 驳回性测量：若恢复抛错或产出 unknown token，本用例失败。
    func testTokenizeInvalidCharacter() throws {
        // 注：`@` 原为无效字符样本，G35 已改为合法块标签 sigil（.at token），故改用 `$`
        let lexer = Lexer(source: "$", fileName: "test.pini")
        let tokens = try lexer.tokenize()
        guard case .identifier(let name, _) = tokens.first else {
            XCTFail("应为 identifier token"); return
        }
        XCTAssertEqual(name, "$")
        guard case .eof = tokens.last else { XCTFail("应以 eof 结尾"); return }
    }
}
