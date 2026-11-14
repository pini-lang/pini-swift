import Testing
@testable import PiniSyntax
@testable import PiniSemantics

/// 标识符身份：NFC 比较、原始拼写保留、不可见字符在词法层被拒。
/// 判据分两层：词法层看错误码与码点标签，语义层看规范化等价是否算同一声明。
@Suite("标识符身份")
struct IdentifierIdentityTests: Sendable {

    private func module(_ source: String, fileName: String = "标识符.pini") throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return try FrontEnd.passes(module: parsed.module)
    }

    /// 词法结果：成功返回 nil，失败返回错误本身。
    private func lexerError(_ source: String) -> LexerError? {
        do {
            _ = try Lexer(source: source, fileName: "不可见.pini").tokenize()
            return nil
        } catch let 错误 as LexerError {
            return 错误
        } catch {
            return nil
        }
    }

    @Test("NFC 与 NFD 两种拼写按同一符号判重声明")
    func rejectsCanonicallyEquivalentRedeclaration() throws {
        let 源码 = """
            caf\u{00E9}|func() -> (I32,):
                return 1

            cafe\u{0301}|func() -> (I32,):
                return 2
            """
        let 模块 = try module(源码)
        do {
            try SemanticAnalyzer().analyze(module: 模块)
            Issue.record("NFC 等价的两个声明没有被判重")
        } catch let 错误 as SemanticError {
            guard case .redeclaredSymbol = 错误 else {
                Issue.record("错误类型不对：\(错误)")
                return
            }
        }
    }

    @Test("NFD 拼写的标识符合法通过")
    func acceptsDecomposedIdentifier() throws {
        let 源码 = """
            cafe\u{0301}|func(_起始: I32,) -> (I32,):
                return _起始
            """
        try SemanticAnalyzer().analyze(module: try module(源码))
    }

    @Test("组合附加符号不能作标识符首字符")
    func rejectsLeadingCombiningMark() throws {
        let 错误 = try #require(lexerError("\u{0301}abc|func() -> ():\n    return\n"))
        guard case .misplacedCombiningMark(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+0301")
    }

    @Test("反引号内的 NFD 名字合法")
    func acceptsDecomposedInsideBackticks() throws {
        let 词法 = try Lexer(source: "`cafe\u{0301}`|func() -> ():\n    return\n", fileName: "转义.pini")
            .tokenize()
        var 首个标识符: String? = nil
        for 记号 in 词法 {
            if case .identifier(let 名字, _) = 记号 {
                首个标识符 = 名字
                break
            }
        }
        let 名字 = try #require(首个标识符)
        #expect(名字.unicodeScalars.count == 5)
    }

    @Test("反引号转义不绕过不可见字符判据")
    func rejectsInvisibleInsideBackticks() throws {
        let 错误 = try #require(lexerError("`a\u{200B}b`|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+200B")
    }

    @Test("Jamo 序列单独作标识符合法通过")
    func acceptsJamoIdentifier() throws {
        let 源码 = """
            \u{1100}\u{1161}\u{11A8}|func(_起始: I32,) -> (I32,):
                return _起始
            """
        try SemanticAnalyzer().analyze(module: try module(源码))
    }

    @Test("拼写不同的名字不判重")
    func acceptsDistinctSpellings() throws {
        let 源码 = """
            \u{AC01}|func() -> (I32,):
                return 1

            \u{AC00}|func() -> (I32,):
                return 2
            """
        try SemanticAnalyzer().analyze(module: try module(源码))
    }

    @Test("原始拼写不被改写为 NFC")
    func keepsOriginalSpelling() throws {
        let 源码 = "\u{1100}\u{1161}\u{11A8}|func() -> ():\n    return\n"
        let 记号 = try Lexer(source: 源码, fileName: "拼写.pini").tokenize()
        var 首个标识符: String? = nil
        for 记号 in 记号 {
            if case .identifier(let 名字, _) = 记号 {
                首个标识符 = 名字
                break
            }
        }
        let 名字 = try #require(首个标识符)
        #expect(名字.unicodeScalars.count == 3)
    }

    @Test("标识符里的零宽空格被词法层拒绝")
    func rejectsZeroWidthSpace() throws {
        let 错误 = try #require(lexerError("a\u{200B}b|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+200B")
    }

    @Test("双向覆盖字符被词法层拒绝")
    func rejectsBidiOverride() throws {
        let 错误 = try #require(lexerError("a\u{202E}b|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+202E")
    }

    @Test("起始 BOM 被词法层拒绝")
    func rejectsByteOrderMark() throws {
        let 错误 = try #require(lexerError("\u{FEFF}main|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+FEFF")
    }

    @Test("字素簇里的变体选择符同样被拒")
    func rejectsVariationSelectorInsideCluster() throws {
        let 错误 = try #require(lexerError("a\u{FE0F}|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+FE0F")
    }

    @Test("脚本表与混淆表都已加载")
    func loadsUnicodeIdentityData() {
        #expect(IdentifierScripts.rangeCount > 100, "脚本区间数应在一百以上")
        #expect(ConfusableSkeleton.entryCount > 6000, "混淆映射应在六千条以上")
    }

    @Test("拉丁与西里尔混写的标识符被词法层拒绝")
    func rejectsMixedScript() throws {
        let 错误 = try #require(lexerError("\u{0430}bc|func() -> ():\n    return\n"))
        guard case .mixedScriptIdentifier(let 名字, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(名字.unicodeScalars.count == 3)
    }

    @Test("中文与拉丁混写不算混写")
    func acceptsChineseWithLatin() throws {
        let 源码 = """
            计数2|func(_起始: I32,) -> (I32,):
                return _起始
            """
        try SemanticAnalyzer().analyze(module: try module(源码))
    }

    @Test("形近的不同脚本名字给出混淆警告")
    func warnsOnConfusableIdentifier() throws {
        let 源码 = """
            \u{0430}|func() -> (I32,):
                return 1

            a|func() -> (I32,):
                return 2
            """
        let 分析器 = SemanticAnalyzer()
        try 分析器.analyze(module: try module(源码))
        var 命中 = 0
        for 警告 in 分析器.warnings {
            if case .confusableIdentifier = 警告 { 命中 = 命中 + 1 }
        }
        #expect(命中 == 1, "西里尔 а 与拉丁 a 应按形近给出恰好一条警告")
    }

    @Test("同一脚本内的不同名字不触发混淆警告")
    func skipsConfusableWithinOneScript() throws {
        let 源码 = """
            alpha|func() -> (I32,):
                return 1

            beta|func() -> (I32,):
                return 2
            """
        let 分析器 = SemanticAnalyzer()
        try 分析器.analyze(module: try module(源码))
        for 警告 in 分析器.warnings {
            if case .confusableIdentifier = 警告 {
                Issue.record("同脚本名字不应触发混淆警告")
                return
            }
        }
    }

    @Test("中文标识符不受规范化与不可见字符判据影响")
    func acceptsChineseIdentifier() throws {
        let 源码 = """
            计数|func(_起始: I32,) -> (I32,):
                var 结果 = _起始
                return 结果
            """
        try SemanticAnalyzer().analyze(module: try module(源码))
    }
}
