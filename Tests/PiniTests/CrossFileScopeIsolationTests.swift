import Foundation
@testable import PiniCore
import Testing

/// 跨文件同名不串味。缺陷只在多文件模块里发作 —— 单文件时「甲类型的字段」与「乙文件的局部变量」不可能同处一个编译单元。
/// 形状：字段名与 `self` 为让裸名可推断被按变量登记，而兜底表按裸名索引、模块内共享 ⇒ 甲类型的字段类型顶掉
/// 乙文件同名局部变量的类型，且不报错。故本件钉的是表的所有权：字段答案在字段表，`self` 在方法签名，兜底表只答局部裸名。
struct CrossFileScopeIsolationTests: Sendable {

    /// 一文件一段源，走与命令行同一条前端：词法 → 语法 → 常量折叠。
    private func fileUnit(_ name: String, _ source: String) throws -> FileUnit {
        let lexer = Lexer(source: source, fileName: name)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        return FileUnit(
            fileName: name, module: ConstantFolder.foldConstants(in: parsed.module))
    }

    /// 甲文件：一个带同名字段的类型。
    ///  注意  方法不可省：字段只在**方法体作用域**里被登记，无方法的类型不带出这个副作用。
    private static let holderWithSameNamedField = """
        (盒)
        本行: String = ""

        ((盒))

        取本行|self() -> (String,):
            return self.本行
        """

    /// 乙文件：局部变量与甲的字段同名。这段长相是照实测收敛来的：兜底表只在类型推断未命中时才被读到，
    /// 故「同名 + 一个无标注数组」并不够 —— 只写 `var 本行 = [i]` 的简化版在缺陷代码上一样绿。
    /// 让推断落空的是 `本行` 与无标注空数组的互相喂养：`本行 = 本行.append(...)` 与 `前一行 = 本行` 使类型互相依赖。
    private static let consumerWithSameNamedLocal = """
        main|func() -> ():
            print("d=\\(levenshtein(a= "kitten", b= "sitting",))")
            return

        levenshtein|func(a: String, b: String,) -> (I32,):
            let a字s = a.split("")
            let b字s = b.split("")
            var 前一行 = []
            var j = 0
            while j <= len(b字s):
                前一行 = 前一行.append(j)
                j = j + 1
            var i = 1
            while i <= len(a字s):
                var 本行 = [i]
                j = 1
                while j <= len(b字s):
                    var 代 = 1
                    if a字s[i - 1] == b字s[j - 1]:
                        代 = 0
                    var 删 = 前一行[j] + 1
                    var 插 = 本行[j - 1] + 1
                    var 替 = 前一行[j - 1] + 代
                    var 最小 = 删
                    if 插 < 最小:
                        最小 = 插
                    if 替 < 最小:
                        最小 = 替
                    本行 = 本行.append(最小)
                    j = j + 1
                前一行 = 本行
                i = i + 1
            return 前一行[len(b字s)]
        """

    private func run(_ units: [FileUnit]) throws -> [String] {
        let runner = ProgramRunner()
        var lines: [String] = []
        runner.outputSink = { lines.append($0) }
        try runner.run(package: Package(name: "跨文件同名", fileUnits: units))
        return lines
    }

    @Test("甲类型的字段名与乙文件的局部变量同名 ⇒ 程序仍跑通，且局部按自己的类型算")
    func aFieldNameDoesNotShadowAnotherFilesSameNamedLocal() throws {
        /// 意图：跨文件作用域隔离的判据。串味时降载期抛 `E6-004`，位置指向乙文件那个无标注数组 —— 报错说的是
        /// 「元素的类型不对」，而真正不对的是「这个绑定被当成了什么」。断言取精确值而不是「不抛错」：
        /// 撞名若把数组退化成别的类型，只问「跑没跑起来」的判据仍会绿。
        let lines = try run([
            try fileUnit("乙.pini", Self.consumerWithSameNamedLocal),
            try fileUnit("甲.pini", Self.holderWithSameNamedField),
        ])
        #expect(lines == ["d=3"], "跨文件同名使局部绑定的类型被顶掉：\(lines)")
    }

    @Test("⛔ 同名在场时，真正的类型不符仍被拒 —— 上一条因此有区分力")
    func aGenuinelyMismatchedTypeIsStillRefused() throws {
        /// 意图：阴性对照，不是重复。上一条戒的是「**沿用**错类型」，不是
        /// 「不检查类型」；若有人把这一族的检查整个关掉，上一条照样绿。
        /// 本件据此把它们分开：名字撞车不该豁免一边的真错误。
        let wrong = """
            main|func() -> ():
                var 本行: String = 3
                print("v=\\(本行)")
                return
            """
        #expect(throws: (any Error).self) {
            _ = try run([
                try fileUnit("乙.pini", wrong),
                try fileUnit("甲.pini", Self.holderWithSameNamedField),
            ])
        }
    }
}
