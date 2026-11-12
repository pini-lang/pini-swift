import Testing
import PiniSyntax

/// 字符串转义按标量解码，不按字素簇：转义字母后紧跟组合附加符号时，
/// Swift 会把两者切进同一个 `Character`，整簇比对会认不出转义而把反斜杠留在值里。
@Suite("字符串转义与字素簇")
struct LexerEscapeTests: Sendable {

    private func literal(in source: String) throws -> String? {
        let lexer = Lexer(source: source, fileName: "escape.pini")
        for token in try lexer.tokenize() {
            if case .stringLiteral(let value, _) = token { return value }
        }
        return nil
    }

    @Test("制表符转义后紧跟组合附加符号仍解成制表符")
    func tabBeforeCombiningMark() throws {
        let value = try literal(in: "main|func() -> ():\n    let s = \"a\\t\u{20DD}b\"\n    return\n")
        #expect(value == "a\t\u{20DD}b", "实际值：\(String(describing: value))")
    }

    @Test("换行转义与零宽连接符同簇时仍解成换行")
    func newlineBeforeJoiner() throws {
        let value = try literal(in: "main|func() -> ():\n    let s = \"a\\n\u{200D}b\"\n    return\n")
        #expect(value == "a\n\u{200D}b", "实际值：\(String(describing: value))")
    }

    @Test("普通转义与插值不受影响")
    func plainEscapesStillWork() throws {
        let value = try literal(in: "main|func() -> ():\n    let s = \"a\\tb\\\\c\\\"d\"\n    return\n")
        #expect(value == "a\tb\\c\"d", "实际值：\(String(describing: value))")
    }
}
