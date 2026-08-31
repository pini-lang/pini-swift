import XCTest
import PiniCore
import Foundation

/// 批 1.5（A12 方案 B / 路 C 裁决）：跨行集合/元组字面量的词法布局抑制。
///
/// 规则（终版）：
/// - 抑制判据 = 最内层未闭合括号是「普通括号」→ 行尾不发 newline、行首旁路缩进；
/// - 「块携带括号」= 开括号后同行紧跟块开启关键字 `func`（草稿 IIFE / 实参位函数
///   字面量的包裹括号）→ 内部布局完全照常（token 流与抑制前逐字节相同）；
/// - 已裁决边界：`< >` 不跟踪（D-5）；未闭合到 EOF 宽松静默（D-6）；不匹配
///   closer 一律 pop（D-7）；前瞻仅限同行；`` `func` `` 反引号转义不算块携带。
final class LexerCrosslineTests: XCTestCase {

    // MARK: - helpers

    /// token 种类名序列（去掉位置与载荷，便于流断言）
    private func kinds(_ source: String) throws -> [String] {
        let tokens = try Lexer(source: source, fileName: "test.pini").tokenize()
        return tokens.map { kindName($0) }
    }

    private func kindName(_ token: Token) -> String {
        switch token {
        case .identifier: return "ident"
        case .keyword(let kw, _): return "kw(\(kw.rawValue))"
        case .integerLiteral: return "int"
        case .floatLiteral: return "float"
        case .stringLiteral: return "str"
        case .interpolatedString: return "interp"
        case .boolLiteral: return "bool"
        case .leftParen: return "("
        case .rightParen: return ")"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .newline: return "NL"
        case .indent: return "INDENT"
        case .dedent: return "DEDENT"
        case .eof: return "EOF"
        case .colon: return ":"
        case .comma: return ","
        case .assign: return "="
        case .arrow: return "->"
        case .pipe: return "|"
        case .dot: return "."
        case .plus: return "+"
        case .minus: return "-"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        default: return "other"
        }
    }

    // MARK: - 普通括号：布局抑制

    /// 意图：跨行元组 `(1,\n 2)` 括号内无 newline/indent，闭合后 newline 恢复
    func testCrosslineTupleSuppressed() throws {
        let ks = try kinds("var x = (1,\n         2)\nvar y = 3\n")
        // 括号内：int 1 comma 直接接 int 2，无 NL/INDENT；")" 后恢复 NL
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "int", ",", "int", ")", "NL",
                            "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图：跨行数组与集合字面量同样抑制
    func testCrosslineBracketAndSetSuppressed() throws {
        XCTAssertEqual(try kinds("var a = [1,\n 2]\n"), ["kw(var)", "ident", "=", "[", "int", ",", "int", "]", "NL", "EOF"])
        XCTAssertEqual(try kinds("var s = {1,\n 2}\n"), ["kw(var)", "ident", "=", "{", "int", ",", "int", "}", "NL", "EOF"])
    }

    /// 意图：多层嵌套 `f(g(x),\n [1,\n {2,\n 3}])` 全程抑制，闭合后恢复
    func testNestedBracketsAllSuppressed() throws {
        let ks = try kinds("f(g(x),\n  [1,\n   {2,\n    3}])\nvar y = 1\n")
        // 中间不得出现任何 NL/INDENT/DEDENT
        let openIdx = ks.firstIndex(of: "(")!
        let closeIdx = ks.firstIndex(of: ")")!
        for k in ks[openIdx...closeIdx] {
            XCTAssertFalse(k == "NL" || k == "INDENT" || k == "DEDENT", "嵌套括号内不应有布局记号：\(k)")
        }
        XCTAssertEqual(ks.last, "EOF")
        XCTAssertTrue(ks.contains("NL"), "闭合后应有 newline")
    }

    /// 意图：括号内空行完全透明（不产生任何记号、不影响缩进栈）
    func testBlankLineInsideBracketsTransparent() throws {
        let ks = try kinds("var x = (1,\n\n   2)\nvar y = 3\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "int", ",", "int", ")", "NL",
                            "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图：括号内注释行（`;`）与行尾注释透明
    func testCommentInsideBracketsTransparent() throws {
        let ks = try kinds("var x = (1, ; 注释\n ; 独立注释行\n 2)\nvar y = 3\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "int", ",", "int", ")", "NL",
                            "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图：括号在行内闭合后，同一行后续换行恢复 newline 发射
    func testNewlineResumesAfterCloseMidline() throws {
        let ks = try kinds("var x = (1,\n 2) ; 尾注\nvar y = 3\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "int", ",", "int", ")", "NL",
                            "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图：跨行闭合后，下一行回到缩进语句 → 无残留 INDENT/DEDENT，缩进栈完好
    func testIndentResumesAfterClose() throws {
        let src = "main|func() -> ():\n    var x = (1,\n         2)\n    var y = 3\n    return\n"
        let ks = try kinds(src)
        // 函数体第一层 INDENT 恰好一次；括号行的续行（更深缩进）不产生 INDENT
        XCTAssertEqual(ks.filter { $0 == "INDENT" }.count, 1, "仅函数体一次 INDENT")
        XCTAssertEqual(ks.filter { $0 == "DEDENT" }.count, 1, "EOF 收口一次 DEDENT")
        XCTAssertFalse(ks.contains("NL") == false)
    }

    // MARK: - 已裁决边界行为

    /// 意图（D-6）：未闭合括号到 EOF 宽松静默——不抛错，后续行按括号内处理
    func testUnclosedBracketAtEofLenient() throws {
        let ks = try kinds("var x = (1,\nvar y = 2\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "int", ",", "kw(var)", "ident", "=", "int", "EOF"])
    }

    /// 意图（D-7）：不匹配 closer（`( ]`）一律 pop，布局随即恢复
    func testMismatchedCloserPopsAnyway() throws {
        let ks = try kinds("var x = ( ]\nvar y = 2\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "]", "NL",
                            "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图（D-5 守卫）：比较运算符 `a < b` 不参与深度跟踪，换行照常
    func testComparisonLessThanUnaffected() throws {
        let ks = try kinds("if a < b:\n    return\n")
        XCTAssertEqual(ks, ["kw(if)", "ident", "<", "ident", ":", "NL", "INDENT",
                            "kw(return)", "NL", "DEDENT", "EOF"])
    }

    /// 意图（D-5 守卫）：泛型实参单行形态不受影响
    func testGenericSingleLineUnaffected() throws {
        let ks = try kinds("var b = 盒<T>(1)\n")
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "ident", "<", "ident", ">", "(", "int", ")", "NL", "EOF"])
    }

    /// 意图：字符串与插值内的括号不参与深度跟踪（不经 token 发射点）
    func testStringAndInterpolationBracketsIgnored() throws {
        // 插值内多一重括号：深度不受影响
        let ks = try kinds("var s = \"\\(a + (b))\"\nvar y = 1\n")
        XCTAssertEqual(ks.filter { $0 == "interp" }.count, 1)
        XCTAssertEqual(ks.filter { $0 == "(" || $0 == ")" }.count, 0, "插值内括号不应出现在 token 流")
        // 字符串内未配平括号不影响后续行布局
        let ks2 = try kinds("var s = \"x ( y\"\nvar y = 1\n")
        XCTAssertEqual(ks2, ["kw(var)", "ident", "=", "str", "NL", "kw(var)", "ident", "=", "int", "NL", "EOF"])
    }

    /// 意图：四类块声明头（行首单行配平）不受抑制影响（F2 锁）
    func testDeclHeadersUnaffected() throws {
        let src = "(名)\n    值: I32 = 0\n{名}\n    值: I32 = 0\n[名]\n    值: I32 = 0\n"
        let ks = try kinds(src)
        // 每个块头行后应有 NL 与随后的 INDENT；块头行内无抑制痕迹
        XCTAssertEqual(ks.filter { $0 == "INDENT" }.count, 3)
        XCTAssertEqual(ks.filter { $0 == "DEDENT" }.count, 3, "每个块体的缩进在下一块头处收回")
    }

    /// 意图：`((名称))` 内嵌组合标记（行首单行配平）不受影响
    func testCompositionDoubleParenUnaffected() throws {
        let ks = try kinds("((计数器))\n    值: I32 = 0\n")
        XCTAssertEqual(ks, ["(", "(", "ident", ")", ")", "NL", "INDENT",
                            "ident", ":", "ident", "=", "int", "NL", "DEDENT", "EOF"])
    }

    // MARK: - 块携带括号：布局照常

    /// 意图：LazyRef 式「实参位函数字面量块体」布局完整保留（newline/INDENT/DEDENT 齐全）
    func testBlockCarryingLazyRefFormLayoutIntact() throws {
        let src = "main|func() -> ():\n    var r = LazyRef<I32>(func () -> (I32,):\n        return 42\n    )\n    return\n"
        let ks = try kinds(src)
        // 冒号行后有 NL；块体行有 INDENT；`)` 行收回 DEDENT；块体行尾有 NL
        XCTAssertTrue(ks.contains("INDENT"), "块体应产生 INDENT")
        XCTAssertTrue(ks.contains("DEDENT"), "块体结束应产生 DEDENT")
        let colonIdx = ks.firstIndex(of: ":")!
        XCTAssertEqual(ks[colonIdx + 1], "NL", "块携带括号内冒号行尾应有 newline")
        XCTAssertEqual(ks.filter { $0 == "DEDENT" }.count, 2, "函数体 + 内嵌块体各一次 DEDENT")
    }

    /// 意图：草稿 IIFE 形态 `(func ...:\n body\n)(5)` 布局完整保留
    func testIIFEFormLayoutIntact() throws {
        let src = "let v = (func (x,) -> (I32,):\n    return x + 1\n)(5)\n"
        let ks = try kinds(src)
        let colonIdx = ks.firstIndex(of: ":")!
        XCTAssertEqual(ks[colonIdx + 1], "NL", "IIFE 包裹括号内冒号行尾应有 newline")
        XCTAssertTrue(ks.contains("INDENT"), "IIFE 块体应产生 INDENT")
        XCTAssertTrue(ks.contains("DEDENT"), "IIFE 块体结束应产生 DEDENT")
        XCTAssertEqual(ks.last, "EOF")
    }

    /// 意图：单行块体实参（closures.pini L41 形态）不受影响
    func testSingleLineFuncLiteralArgumentIntact() throws {
        let ks = try kinds("print(应用(func (n,) -> (I32,): return n + 100, 3))\n")
        XCTAssertEqual(ks, ["ident", "(", "ident", "(", "kw(func)", "(", "ident", ",", ")",
                            "->", "(", "ident", ",", ")", ":", "kw(return)", "ident", "+",
                            "int", ",", "int", ")", ")", "NL", "EOF"])
    }

    /// 意图：块体内嵌套普通括号的跨行字面量 → innermost 判据：嵌套字面量内抑制、
    /// 块体本身布局照常（正交组合）
    func testCrosslineInsideBlockBody() throws {
        let src = "foo(func () -> (I32,):\n    return [1,\n        2]\n)\n"
        let ks = try kinds(src)
        // `[1,` 行尾（栈顶=普通 `[`）→ 无 NL；`2]` 行行首无 INDENT；`]` 闭合后恢复
        let bracketIdx = ks.firstIndex(of: "[")!
        XCTAssertEqual(ks[bracketIdx + 1], "int")
        let literalCommaIdx = (bracketIdx + 1..<ks.count).first { ks[$0] == "," }!
        XCTAssertNotEqual(ks[literalCommaIdx + 1], "NL", "嵌套字面量行尾应抑制")
        XCTAssertEqual(ks[literalCommaIdx + 1], "int", "逗号后直接接续行内容")
        XCTAssertTrue(ks.contains("DEDENT"), "块体收回应有 DEDENT")
    }

    /// 意图：`` `func` `` 反引号转义后不构成块携带（边界锁定）
    func testBacktickFuncNotBlockCarrying() throws {
        let ks = try kinds("var x = (`func`, 1,\n 2)\n")
        // 反引号产出的 identifier("func") 不触发块携带 → 抑制照常
        XCTAssertEqual(ks, ["kw(var)", "ident", "=", "(", "ident", ",", "int", ",", "int", ")", "NL", "EOF"])
    }

    /// 意图：开括号后同行无 func、下一行才有 func → 前瞻不跨行 → 普通括号（边界锁定）
    func testLookaheadSameLineOnly() throws {
        let ks = try kinds("var x = (\n func () -> (I32,): return 1)\nvar y = 1\n")
        // `(` 行尾即抑制；后续 func 不改变既有普通括号判定
        let openIdx = ks.firstIndex(of: "(")!
        XCTAssertNotEqual(ks[openIdx + 1], "NL") // 抑制中，NL 不出现
        XCTAssertTrue(ks.contains("NL"), "闭合后恢复 newline")
    }
}
