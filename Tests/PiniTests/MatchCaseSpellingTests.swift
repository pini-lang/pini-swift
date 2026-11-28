import Testing

@testable import PiniSyntax

/// 枚举措辞的三种拼写在打印器里原样往返：拼写是语法事实，语义层只认叶名。
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

    @Test func 限定名点号与裸名各自保真() {
        let 源码 = """
            [形状]
            圆(F64,)

            甲|func(s: 形状,) -> (F64,):
                match s:
                    case 形状.圆(r,):
                        return r
                    case .圆(r,):
                        return r
                    case 圆(r,):
                        return r

            """
        let 一次 = 格式化(源码)
        #expect(一次.contains("case 形状.圆(r,):"))
        #expect(一次.contains("case .圆(r,):"))
        #expect(一次.contains("case 圆(r,):"))
        #expect(格式化(一次) == 一次)
    }

    @Test func 关键字nil形态保真() {
        let 源码 = """
            甲|func(x: Optional<I32>,) -> (I32,):
                match x:
                    case nil:
                        return 0
                    case some(v,):
                        return v

            """
        let 一次 = 格式化(源码)
        #expect(一次.contains("case nil:"))
        #expect(!一次.contains("case none:"))
        #expect(格式化(一次) == 一次)
    }
}
