import Foundation
import Testing
import PiniSyntax
@testable import PiniHost

/// 同名局部变量跨函数互不顶替：降载阶段重推类型时，用的必须是**本函数**的声明。
/// 语料把宽类型排在后面 —— 检查按声明顺序写入持久表，后写者胜，故修复前先声明的那个函数会被顶替。
@Suite("局部名隔离")
struct LocalNameIsolationTests: Sendable {

    private static let corpus = #"""
    narrow|func(q: I32,) -> (I32,):
        var n = q
        var i = n - 1
        return i

    wide|func(p: U64,) -> (U64,):
        var n = p
        return n

    main|func() -> ():
        print(narrow(7))
        print(wide(9))
        return
    """#

    private static let expected = #"""
    6
    9
    """#

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    private static func attempt(_ source: String) -> Outcome {
        let name = "局部名隔离探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(fileName: name, module: try FrontEnd.passes(module: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "局部名隔离", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    /// 意图：先声明的窄类型不被后声明的同名宽类型顶替；被拒时的报文也要说清是哪一边。
    @Test("先声明的窄类型不被同名宽类型顶替")
    func narrowDeclarationSurvivesLaterWideOne() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：隔离不等于放行 —— 名字对上但类型真不符时仍要拒。
    /// 没有这条，上一条的「跑通了」也可以由「根本不检查」造成。
    @Test("同名在场时真正的类型不符仍被拒")
    func genuineMismatchIsStillRejected() throws {
        let source = #"""
        narrow|func(q: I32,) -> (I32,):
            var n = q
            var i: U64 = n - 1
            return i

        main|func() -> ():
            print(narrow(7))
            return
        """#
        guard case .refused(let message) = Self.attempt(source) else {
            Issue.record("类型不符应被拒")
            return
        }
        #expect(message.contains("type mismatch"), "应报类型不匹配，实际：\(message)")
        #expect(message.contains("U64"), "报文应指出期望的类型，实际：\(message)")
    }
}
