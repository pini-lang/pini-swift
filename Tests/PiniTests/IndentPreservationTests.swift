import Foundation
import PiniSyntax
import Testing

/// 缩进还原判据：每个缩进块按自身首行宽度输出，二次打印逐字节相同。
/// 语料全是四格，只跑语料查不出这条，故一律用构造形态。
@Suite("缩进还原")
struct IndentPreservationTests {

    private func printed(_ source: String) -> String? {
        let scan = FrontEnd.syntaxOnly(source: source, fileName: "/tmp/indent.pini")
        guard case .parsed(let module) = scan.outcome else { return nil }
        return Printer.print(module: module, comments: scan.comments, hints: scan.hints)
    }

    /// 源码与打印结果都以单独一个换行结尾，比较前把两端裁齐。
    private func canonical(_ source: String) -> String {
        source.trimmingCharacters(in: .newlines) + "\n"
    }

    @Test(
        "每块按首行宽度还原：二格、三格、八格",
        arguments: [
            "main|func() -> ():\n  var a = 1\n  if a > 0:\n    print(a)\n  return\n",
            "main|func() -> ():\n   var a = 1\n   if a > 0:\n      print(a)\n   return\n",
            "main|func() -> ():\n        var a = 1\n        if a > 0:\n                print(a)\n        return\n",
        ])
    func keepsUniformWidth(source: String) throws {
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("混合宽度：外层二格、内层六格")
    func keepsMixedWidth() throws {
        let source = "main|func() -> ():\n  if true:\n      print(1)\n  return\n"
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("match 与 step 各自按块还原")
    func keepsNestedWidths() throws {
        let source = """
            main|func() -> ():
              var i = 0
              match i:
                case 1:
                  print(1)
                case _:
                  print(0)
              while i < 3:
                i = i + 1
              step:
                print(i)
              return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("注释按落点取列：二格文件里的块首与块尾注释")
    func commentTakesBlockColumn() throws {
        let source = """
            main|func() -> ():
              ; 块首注释
              print(1)
              ; 块尾注释
              return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("二次打印逐字节相同")
    func idempotent() throws {
        let source = "main|func() -> ():\n  if true:\n      print(1)\n  return\n"
        let once = try #require(printed(source))
        #expect(try #require(printed(once)) == once)
    }

    @Test("无旁路：回四格")
    func fallsBackToFour() throws {
        let scan = FrontEnd.syntaxOnly(
            source: "main|func() -> ():\n  print(1)\n", fileName: "/tmp/indent.pini")
        guard case .parsed(let module) = scan.outcome else {
            Issue.record("样例应解析通过")
            return
        }
        let text = Printer.print(module: module, comments: scan.comments)
        #expect(text == "main|func() -> ():\n    print(1)\n")
    }
}
