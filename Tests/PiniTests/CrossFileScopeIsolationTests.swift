import Foundation
@testable import PiniCore
import Testing

/// 跨文件同名不串味。
///
/// **为什么这一格要单独立件**：缺陷**只在多文件模块里发作** —— 单文件时
/// 「甲类型的字段」与「乙文件的局部变量」不可能同处一个编译单元，同名也就无从撞起。
/// 它因此躲过了全部单文件回归，直到自举仓把两层产物装进一个模块才现形
/// （`pini run . <层>` 在降载期报 `E6-004`，而 `check` 全绿）。
///
/// **缺陷的形状**：类型检查期为了让方法体内**裸名**引用字段可推断，字段名与
/// `self` 被按**变量**登记；而那张供降载事后重推用的兜底表按**裸名**索引、
/// 模块内共享 ⇒ 甲类型的字段类型顶掉了乙文件里同名局部变量的类型，
/// 且**不报任何错**：沿用错类型的那个绑定在降载处才炸。
///
/// 所以这一件钉的是**表的所有权**：字段的答案在字段表，`self` 的答案在方法签名，
/// 兜底表只回答「这个裸名在本模块的**局部绑定**里是什么类型」。
struct CrossFileScopeIsolationTests {

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
    /// ⚠️ 方法不可省：字段只在**方法体作用域**里被登记，无方法的类型不带出这个副作用。
    private static let holderWithSameNamedField = """
        (盒)
        本行: String = ""

        ((盒))

        取本行|self() -> (String,):
            return self.本行
        """

    /// 乙文件：局部变量与甲的字段**同名**。
    ///
    /// ⚠️ **这一段的长相是照实测收敛来的，不是随手写的**。兜底表只在
    /// **类型推断未命中**时才会被读到，所以「同名 + 一个无标注数组」**并不够**：
    /// 一个只写 `var 本行 = [i]` 的简化版，在**未修**的代码上一样绿
    /// （2026-09-26 实测），拿它当判据是**假绿**。
    ///
    /// 让推断落空的是 `本行` 与上面那个**无标注空数组**的互相喂养 ——
    /// `本行 = 本行.append(...)` 与 `前一行 = 本行` 使二者的类型互相依赖，
    /// 谁也无法先被推出来。本件因此照抄了触发它的那个函数的形状
    /// （自举仓 `common` 层的编辑距离），只在外面套一层调用与打印。
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
        /// 意图：这条是**跨文件作用域隔离**的判据。未修时它在降载期抛 `E6-004`
        /// （`i32 is not string`），位置指向乙文件那个**无标注数组**——报错说的是
        /// 「元素的类型不对」，而真正不对的是「这个绑定被当成了什么」。
        /// ⛔ 断言取精确值而不是「不抛错」：撞名若把数组退化成别的类型，
        /// 一个只问「跑没跑起来」的判据仍会绿。
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
