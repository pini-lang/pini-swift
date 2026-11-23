import Testing

@testable import PiniSyntax

/// 打印器的版面约定：块内空行至多一行，块间按原文行数，缩进步长落到 2 / 4 / 8 三档。
struct FormatterLayoutTests: Sendable {

    /// 走 `fmt` 的同一条链路：只到语法、带注释表与位置旁路，不跑 pass。
    private func 格式化(_ 源码: String) -> String {
        let 扫描 = FrontEnd.syntaxOnly(source: 源码, fileName: "t.pini")
        guard case .parsed(let 模块) = 扫描.outcome else {
            Issue.record("样例应当解析通过")
            return ""
        }
        return Printer.print(module: 模块, comments: 扫描.comments, hints: 扫描.hints)
    }

    @Test func 块内空行压成一行() {
        let 源码 = """
            甲|func() -> ():
                let a = 1


                return

            """
        let 期望 = """
            甲|func() -> ():
                let a = 1

                return

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 块间空行按原文保留() {
        let 源码 = """
            甲|func() -> ():
                return



            乙|func() -> ():
                return

            """
        #expect(格式化(源码) == 源码)
    }

    @Test func 三格步长落二档() {
        let 源码 = """
            甲|func() -> ():
               let a = 1
               return

            """
        let 期望 = """
            甲|func() -> ():
              let a = 1
              return

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 六格步长落四档() {
        let 源码 = """
            甲|func() -> ():
                  let a = 1
                  return

            """
        let 期望 = """
            甲|func() -> ():
                let a = 1
                return

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 类型体保持顶格() {
        let 源码 = """
            (点)
                x: I32 = 0
                y: I32 = 0

            """
        let 期望 = """
            (点)
            x: I32 = 0
            y: I32 = 0

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 扩展块体随文件步长() {
        let 源码 = """
            (点)
            x: I32 = 0

            ((点))
                取|self() -> (I32,):
                    return self.x

            """
        let 期望 = """
            (点)
            x: I32 = 0

            ((点))
            取|self() -> (I32,):
                return self.x

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 块首空行丢弃() {
        let 源码 = """
            甲|func() -> ():
            
                ; 首行注释
                return

            """
        let 期望 = """
            甲|func() -> ():
                ; 首行注释
                return

            """
        #expect(格式化(源码) == 期望)
    }

    @Test func 二次打印不变() {
        let 源码 = """
            (点)
            x: I32 = 0


            甲|func() -> ():
                let a = 1

                return

            """
        let 一次 = 格式化(源码)
        #expect(格式化(一次) == 一次)
    }
}
