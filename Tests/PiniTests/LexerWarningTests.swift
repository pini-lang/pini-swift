import Foundation
import Testing
@testable import PiniSyntax
@testable import PiniSemantics

/// 词法警告：注释与字符串里的双向控制字符只提醒、不阻断；同一字符出现在代码位仍是错误。
/// 判据分三层：词法层看条数与位置，前端看警告是否随结果带回，装载层看它是否挂在文件单元上。
@Suite("词法警告")
struct LexerWarningTests: Sendable {

    private func warnings(_ source: String, fileName: String = "警告.pini") throws -> [LexerWarning] {
        let lexer = Lexer(source: source, fileName: fileName)
        _ = try lexer.tokenize()
        return lexer.warnings
    }

    /// 词法结果：成功返回 nil，失败返回错误本身。
    private func lexerError(_ source: String) -> LexerError? {
        do {
            _ = try Lexer(source: source, fileName: "警告.pini").tokenize()
            return nil
        } catch let 错误 as LexerError {
            return 错误
        } catch {
            return nil
        }
    }

    @Test("注释里的双向覆盖字符记一条警告，位置指向该字符")
    func recordsOverrideInComment() throws {
        let 源码 = "; 注释\u{202E}反过来\nmain|func() -> ():\n    return\n"
        let 警告 = try warnings(源码)
        #expect(警告.count == 1)
        guard case .bidirectionalControl(let 标签, let 角色, let 位置) = 警告[0] else {
            Issue.record("警告类型不对")
            return
        }
        #expect(标签 == "U+202E")
        #expect(角色 == .comment)
        #expect(位置.line == 1)
        // `;` 一列、空格一列、两个字各一列，控制字符自己是第五列。
        #expect(位置.column == 5)
    }

    @Test("字符串里的双向隔离符记一条警告")
    func recordsIsolateInString() throws {
        let 源码 = "main|func() -> ():\n    let 文本 = \"a\u{2066}b\"\n    return\n"
        let 警告 = try warnings(源码)
        #expect(警告.count == 1)
        guard case .bidirectionalControl(let 标签, let 角色, let 位置) = 警告[0] else {
            Issue.record("警告类型不对")
            return
        }
        #expect(标签 == "U+2066")
        #expect(角色 == .string)
        #expect(位置.line == 2)
    }

    @Test("一条注释里的两个双向字符各记一条")
    func recordsEachCharacter() throws {
        #expect(try warnings("; a\u{202A}b\u{202B}c\nx\n").count == 2)
    }

    @Test("普通注释与字符串不产生警告")
    func cleanSourceHasNoWarnings() throws {
        let 源码 = "; 中文注释照常\nmain|func() -> ():\n    let 文本 = \"你好，世界\"\n    return\n"
        #expect(try warnings(源码).isEmpty)
    }

    @Test("代码位置的同一字符仍是错误")
    func stillRejectsInCode() throws {
        let 错误 = try #require(lexerError("a\u{202E}b|func() -> ():\n    return\n"))
        guard case .invisibleCharacter(let 标签, _) = 错误 else {
            Issue.record("错误类型不对：\(错误)")
            return
        }
        #expect(标签 == "U+202E")
    }

    @Test("前期扫描把警告随结果带回")
    func frontEndCarriesWarnings() throws {
        let 源码 = "; 注\u{202E}释\nmain|func() -> ():\n    return\n"
        let 结果 = FrontEnd.scan(source: 源码, fileName: "扫描.pini")
        #expect(结果.warnings.count == 1)
        guard case .parsed = 结果.outcome else {
            Issue.record("语法应通过")
            return
        }
    }

    @Test("装载目录时警告挂在包上")
    func packageCarriesWarnings() throws {
        let 目录 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-警告-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: 目录, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: 目录) }
        let 文件 = 目录.appendingPathComponent("主.pini")
        try "; 注\u{202E}释\nmain|func() -> ():\n    return\n"
            .write(to: 文件, atomically: true, encoding: .utf8)
        let 包 = try FileLoader.loadDirectory(path: 目录.path)
        #expect(包.warnings.count == 1)
        #expect(包.fileUnits.count == 1)
    }

    @Test("警告的诊断码与严重度")
    func warningDiagnosticMetadata() throws {
        let 警告 = try #require(try warnings("; \u{202E}\n").first)
        let 诊断 = 警告 as any DiagnosticProviding
        #expect(诊断.diagnosticCode == "E7-009")
        #expect(诊断.diagnosticSeverity == .warning)
    }
}
