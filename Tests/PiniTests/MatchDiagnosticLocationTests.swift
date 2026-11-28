import Foundation
import Testing
import PiniSemantics
import PiniSyntax

/// 匹配诊断的位置与判定面：模式级错误报在模式起点，与自举侧同一列。
/// 主体确定不是枚举时，`nil` 与内建 some/none 同样按未知用例拒绝。
struct MatchDiagnosticLocationTests: Sendable {

    private func module(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return try FrontEnd.passes(module: parsed.module)
    }

    /// 语义错误：只跑到名字与模式面，没有抛出时答 nil。
    private func 语义错误(_ source: String) throws -> SemanticError? {
        let module = try module(source)
        do {
            try SemanticAnalyzer().analyze(module: module)
        } catch let error as SemanticError {
            return error
        }
        return nil
    }

    @Test("未知用例报在模式起点，不落在 case 关键字")
    func 未知用例位置() throws {
        let 源码 = """
            [甲]
            a
            b

            f|func(x: 甲,) -> (I32,):
                match x:
                    case .c:
                        return 1
                    case _:
                        return 2
            """
        guard case .unknownMatchCase(let name, let location)? = try 语义错误(源码) else {
            Issue.record("期望 unknownMatchCase")
            return
        }
        #expect(name == "c")
        #expect(location.line == 7)
        #expect(location.column == 14)
    }

    @Test("标量上的 nil 与 .none 都按未知用例拒绝")
    func 标量上的空值() throws {
        for (写法, 名字) in [("nil", "nil"), (".none", "none")] {
            let 源码 = """
                f|func(x: I32,) -> (I32,):
                    match x:
                        case \(写法):
                            return 1
                        case _:
                            return 2
                """
            guard case .unknownMatchCase(let name, let location)? = try 语义错误(源码) else {
                Issue.record("\(写法) 应被拒绝")
                return
            }
            #expect(name == 名字)
            #expect(location.line == 3)
            #expect(location.column == 14)
        }
    }

    @Test("枚举上的字面量臂报在字面量起点")
    func 字面量臂位置() throws {
        let 源码 = """
            [甲]
            a
            b

            f|func(x: 甲,) -> (I32,):
                match x:
                    case 1:
                        return 1
                    case _:
                        return 2
            """
        guard case .unknownMatchCase(_, let location)? = try 语义错误(源码) else {
            Issue.record("期望 unknownMatchCase")
            return
        }
        #expect(location.line == 7)
        #expect(location.column == 14)
    }

    @Test("臂内绑定重名按重复声明拒绝，报在模式起点")
    func 绑定重名位置() throws {
        let 源码 = """
            [矩形]
            方(宽: F64, 高: F64,)

            f|func(x: 矩形,) -> (I32,):
                match x:
                    case .方(a, a,):
                        return 1
                    case _:
                        return 2
            """
        guard case .redeclaredSymbol(let name, let location)? = try 语义错误(源码) else {
            Issue.record("期望 redeclaredSymbol")
            return
        }
        #expect(name == "a")
        #expect(location.line == 6)
        #expect(location.column == 14)
    }

    @Test("可选主体上的 nil 与 some 照旧通过")
    func 可选主体放行() throws {
        let 源码 = """
            f|func(x: Optional<I32>,) -> (I32,):
                match x:
                    case nil:
                        return 1
                    case .some(v,):
                        return v
            """
        #expect(try 语义错误(源码) == nil)
    }
}
