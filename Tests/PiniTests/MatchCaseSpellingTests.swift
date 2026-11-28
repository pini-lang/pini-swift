import Testing

@testable import PiniSyntax

/// 枚举措辞的拼写在打印器里原样往返：拼写是语法事实，语义层只认叶名。
struct MatchCaseSpellingTests: Sendable {

    /// 走 `fmt` 的同一条链路：只到语法、带注释表与位置旁路，不跑 pass。
    private func 格式化(_ 源码: String) -> String {
        let 扫描 = FrontEnd.syntaxOnly(source: 源码, fileName: "t.pini")
        guard case .parsed(let 模块) = 扫描.outcome else {
            Issue.record("样例应当解析通过")
            return ""
        }
        return Printer.print(module: 模块, comments: 扫描.comments, hints: 扫描.hints)
    }

    @Test func 限定名与点号各自保真() {
        let 源码 = """
            [形状]
            圆(F64,)

            甲|func(s: 形状,) -> (F64,):
                match s:
                    case 形状.圆(r,):
                        return r
                    case .圆(r,):
                        return r

            """
        let 一次 = 格式化(源码)
        #expect(一次.contains("case 形状.圆(r,):"))
        #expect(一次.contains("case .圆(r,):"))
        #expect(格式化(一次) == 一次)
    }

    @Test func 裸名模式被拒() {
        let 源码 = """
            [形状]
            圆(F64,)

            甲|func(s: 形状,) -> (F64,):
                match s:
                    case 圆(r,):
                        return r

            """
        let 扫描 = FrontEnd.syntaxOnly(source: 源码, fileName: "t.pini")
        guard case .parseFailed(_, let 诊断) = 扫描.outcome else {
            Issue.record("裸名应当解析失败")
            return
        }
        // 块内解析错会连带后续分支一起报，判据只看首条：它必须指出裸名这个成因。
        guard case .invalidStatement(let 理由, _) = 诊断.first else {
            Issue.record("首条诊断应为无效语句，实际 \(String(describing: 诊断.first))")
            return
        }
        #expect(理由.contains("裸名"))
    }

    @Test func 关键字nil形态保真() {
        let 源码 = """
            甲|func(x: Optional<I32>,) -> (I32,):
                match x:
                    case nil:
                        return 0
                    case .some(v,):
                        return v

            """
        let 一次 = 格式化(源码)
        #expect(一次.contains("case nil:"))
        #expect(!一次.contains("case none:"))
        #expect(格式化(一次) == 一次)
    }
}
