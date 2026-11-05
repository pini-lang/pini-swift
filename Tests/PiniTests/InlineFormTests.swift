import Foundation
import PiniSyntax
import Testing

/// 行内块形判据：单行 `if` / `elif` 保持一行，其余单行写法退回块形并缩进四格。
/// 解析器的单行体只吃表达式，故判据必须同时看语句种类与源行号。
@Suite("行内块形")
struct InlineFormTests {

    private func printed(_ source: String) -> String? {
        let scan = FrontEnd.syntaxOnly(source: source, fileName: "/tmp/inline.pini")
        guard case .parsed(let module) = scan.outcome else { return nil }
        return Printer.print(module: module, comments: scan.comments, hints: scan.hints)
    }

    private func canonical(_ source: String) -> String {
        source.trimmingCharacters(in: .newlines) + "\n"
    }

    @Test("单行 if 与 elif 保持一行，块形仍换行")
    func keepsInlineBranches() throws {
        let source = """
            main|func() -> ():
                var a = 1
                if a > 0: print(1)
                if a > 0:
                    print(2)
                if a > 1: print(3)
                elif a > 0: print(4)
                else:
                    print(5)
                return
            """
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("二格文件里的单行 if 仍在原列")
    func keepsInlineAtOtherWidth() throws {
        let source = "main|func() -> ():\n  if true: print(1)\n  return\n"
        #expect(try #require(printed(source)) == canonical(source))
    }

    @Test("单行 while 退回块形：体缩进四格，不与块头同列")
    func expandsWhileBody() throws {
        let source = "main|func() -> ():\n    while true: print(2)\n    return\n"
        let expected = "main|func() -> ():\n    while true:\n        print(2)\n    return\n"
        #expect(try #require(printed(source)) == expected)
    }

    @Test("退回块形的体跟随父块步长")
    func fallbackFollowsParentStep() throws {
        let two = "main|func() -> ():\n  while true: print(2)\n  return\n"
        let twoExpected = "main|func() -> ():\n  while true:\n    print(2)\n  return\n"
        #expect(try #require(printed(two)) == twoExpected)

        let three = "main|func() -> ():\n   while true: print(2)\n   return\n"
        let threeExpected = "main|func() -> ():\n   while true:\n      print(2)\n   return\n"
        #expect(try #require(printed(three)) == threeExpected)
    }

    @Test("二次打印逐字节相同")
    func idempotent() throws {
        let source = "main|func() -> ():\n    if true: print(1)\n    return\n"
        let once = try #require(printed(source))
        #expect(try #require(printed(once)) == once)
    }
}
