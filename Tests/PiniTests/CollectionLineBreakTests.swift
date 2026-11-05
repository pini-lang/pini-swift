import Foundation
import PiniSyntax
import Testing

/// 集合跨行判据：作者把字面量拆成多行，打印器只保留「断不断」，一律规整成一行一元素。
/// 单行字面量不被拆开；元素列按源缩进取增量，非四格文件里的集合才不会跳回四的倍数。
@Suite("集合跨行")
struct CollectionLineBreakTests {

    private func printed(_ source: String) -> String? {
        let scan = FrontEnd.syntaxOnly(source: source, fileName: "/tmp/collection.pini")
        guard case .parsed(let module) = scan.outcome else { return nil }
        return Printer.print(module: module, comments: scan.comments, hints: scan.hints)
    }

    private func canonical(_ source: String) -> String {
        source.trimmingCharacters(in: .newlines) + "\n"
    }

    @Test("数组、字典、集合、元组四种字面量保留跨行")
    func keepsBrokenLiterals() throws {
        let source = """
            main|func() -> ():
                let 字典 = {
                    "k": I32 = 1,
                    "j": I32 = 2,
                }
                let 数组 = [
                    1,
                    2,
                ]
                let 集合 = {
                    1,
                    2,
                }
                let 元组 = (
                    1,
                    2,
                )
                return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("单行字面量不被拆开")
    func keepsSingleLineLiterals() throws {
        let source = """
            main|func() -> ():
                let 数组 = [1, 2]
                let 集合 = {1, 2}
                let 字典 = {"k" = 1, "j" = 2}
                let 元组 = (1, 2,)
                return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("二格文件里的元素保持二格增量")
    func keepsOtherWidth() throws {
        let source = "main|func() -> ():\n  let 表 = [\n    1,\n    2,\n  ]\n  return\n"
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("多个元素挤在一行时规整成一行一个")
    func regularizesCrowdedRows() throws {
        let source = "main|func() -> ():\n    let 表 = [\n        1, 2,\n    ]\n    return\n"
        let expected = "main|func() -> ():\n    let 表 = [\n        1,\n        2,\n    ]\n    return\n"
        #expect(try #require(printed(source)) == expected)
    }

    @Test("嵌套字面量的收尾括号回到元素列")
    func nestsAtElementColumn() throws {
        let source = """
            main|func() -> ():
                let 表 = [
                    [
                        1,
                    ],
                    [
                        2,
                    ],
                ]
                return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("命名元组的标签不参与步长")
    func labelsDoNotSkewStep() throws {
        let source = """
            main|func() -> ():
                let 标注 = (
                    a = 1,
                    b = 2,
                )
                return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("空字面量恒单行")
    func keepsEmptyLiterals() throws {
        let source = "main|func() -> ():\n    let 空 = []\n    let 空集 = {}\n    return\n"
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("二次打印逐字节相同")
    func idempotent() throws {
        let source = """
            main|func() -> ():
                let 字典 = {
                    "k" = [1, 2],
                    "j" = [
                        3,
                    ],
                }
                return
            """
        let once = try #require(printed(source))
        #expect(try #require(printed(once)) == once)
    }
}
