import Foundation
import PiniSyntax
import Testing

/// 注释锚回判据：注释守恒、位置不动、二次打印逐字节相同。
/// 前两条分开判——只查守恒时，注释整块跑到别的块里也照样通过。
@Suite("注释锚点")
struct CommentAnchorTests {

    @Test("边界形态：空块、单语句块、块首块尾、连续整行")
    func boundaryShapes() {
        let cases: [(name: String, source: String, expected: String)] = [
            (
                "空块",
                """
                main|func() -> ():
                    if true:
                        ; 空块里只有 pass
                        pass
                    return
                """,
                """
                main|func() -> ():
                    if true:
                        ; 空块里只有 pass
                        pass
                    return
                """
            ),
            (
                "单语句块与行尾注释",
                """
                main|func() -> ():
                    print(1)        ; 行尾注释
                    return
                """,
                """
                main|func() -> ():
                    print(1) ; 行尾注释
                    return
                """
            ),
            (
                "块首与块尾",
                """
                main|func() -> ():
                    ; 块首
                    let a = 1
                    if true:
                        print(a)
                        ; 块尾在缩进内
                    ; 块外
                    return
                """,
                """
                main|func() -> ():
                    ; 块首
                    let a = 1
                    if true:
                        print(a)
                        ; 块尾在缩进内
                    ; 块外
                    return
                """
            ),
            (
                "连续整行注释",
                """
                ; 第一行
                ; 第二行
                ; 第三行

                main|func() -> ():
                    return
                """,
                """
                ; 第一行
                ; 第二行
                ; 第三行
                main|func() -> ():
                    return
                """
            ),
            (
                "块尾紧接 else",
                """
                main|func() -> ():
                    if true:
                        print(1)
                        ; 块内尾注
                    else:
                        print(2)
                    return
                """,
                """
                main|func() -> ():
                    if true:
                        print(1)
                        ; 块内尾注
                    else:
                        print(2)
                    return
                """
            ),
            (
                "文件末尾的注释",
                """
                main|func() -> ():
                    print(1)
                    ; 结尾注释
                """,
                """
                main|func() -> ():
                    print(1)
                    ; 结尾注释
                """
            ),
            (
                "case 前的注释",
                """
                main|func() -> ():
                    match 1:
                        ; 第一个分支
                        case 1:
                            print(1)
                        ; 第二个分支
                        case 2:
                            print(2)
                    return
                """,
                """
                main|func() -> ():
                    match 1:
                        ; 第一个分支
                        case 1:
                            print(1)
                        ; 第二个分支
                        case 2:
                            print(2)
                    return
                """
            ),
            (
                "顶层声明之间的注释",
                """
                main|func() -> ():
                    return

                ; 下一个声明
                (计数器)
                名称: String = "秒表"
                """,
                """
                main|func() -> ():
                    return

                ; 下一个声明
                (计数器)
                名称: String = "秒表"
                """
            ),
            (
                "连续退两层的尾注",
                """
                main|func() -> ():
                    if true:
                        if true:
                            print(1)
                            ; 两层内
                        ; 退一层
                    ; 退两层
                    return
                """,
                """
                main|func() -> ():
                    if true:
                        if true:
                            print(1)
                            ; 两层内
                        ; 退一层
                    ; 退两层
                    return
                """
            ),
        ]

        var failures: [String] = []
        for item in cases {
            guard let (module, comments) = Self.parse(item.source, name: item.name) else {
                failures.append("\(item.name): 输入本身解析失败")
                continue
            }
            let printed = Printer.print(module: module, comments: comments)
            // 打印结果总以换行收尾；比对面只写正文，这里补上。
            if printed != item.expected + "\n" {
                failures.append("\(item.name): 输出不符\n--- 实际 ---\n\(printed)--- 期望 ---\n\(item.expected)\n")
                continue
            }
            // 二次打印必须原样：注释落点若只在首打成立，第二次就会漂。
            guard let (reparsed, reloaded) = Self.parse(printed, name: item.name) else {
                failures.append("\(item.name): 打印结果无法重新解析\n\(printed)")
                continue
            }
            if Printer.print(module: reparsed, comments: reloaded) != printed {
                failures.append("\(item.name): 二次打印不稳定\n\(printed)")
            }
        }
        for failure in failures { Issue.record(Comment(rawValue: failure)) }
        #expect(failures.isEmpty, "\(failures.count) 处失败（共 \(cases.count) 个形态）")
    }

    @Test("语料：注释守恒、往返等价、二次打印稳定")
    func corpus() {
        let files = PrinterRoundTripTests.corpus()
        var failures: [String] = []
        var commentCount = 0

        for url in files {
            let label = url.path.replacingOccurrences(
                of: PiniTestEnvironment.repositoryRoot.path + "/", with: "")
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                failures.append("\(label): 读不到源文件")
                continue
            }
            guard let (first, comments) = Self.parse(source, name: url.path) else {
                failures.append("\(label): 原文件解析失败，语料选择有误")
                continue
            }
            commentCount += comments.count
            let printed = Printer.print(module: first, comments: comments)
            guard let (second, reloaded) = Self.parse(printed, name: url.path) else {
                failures.append("\(label): 打印结果无法重新解析\n" + Self.preview(printed))
                continue
            }
            if comments.map(\.text) != reloaded.map(\.text) {
                failures.append("\(label): 注释不守恒 \(Self.firstTextDifference(comments, reloaded))")
            }
            if let mismatch = PrinterRoundTripTests.firstMismatch(first, second, "Module") {
                failures.append("\(label): 往返不等价 @ \(mismatch)\n" + Self.preview(printed))
            }
            let reprinted = Printer.print(module: second, comments: reloaded)
            if reprinted != printed {
                failures.append(
                    "\(label): 二次打印不稳定\n" + PrinterRoundTripTests.firstDifference(printed, reprinted))
            }
            for violation in PrinterRoundTripTests.layoutViolations(printed) {
                failures.append("\(label): \(violation)")
            }
        }

        for failure in failures.prefix(12) { Issue.record(Comment(rawValue: failure)) }
        #expect(commentCount > 300, "语料注释太少：只读到 \(commentCount) 条")
        #expect(failures.isEmpty, "\(failures.count) 处失败（共 \(files.count) 个文件）")
    }

    static func parse(_ source: String, name: String) -> (Module, CommentTable)? {
        let scan = FrontEnd.scan(source: source, fileName: "/tmp/\(name).pini")
        guard case .parsed(let module) = scan.outcome else { return nil }
        return (module, scan.comments)
    }

    static func preview(_ text: String) -> String {
        text.split(separator: "\n").prefix(8).joined(separator: "\n")
    }

    static func firstTextDifference(_ lhs: CommentTable, _ rhs: CommentTable) -> String {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index].text != rhs[index].text {
            return "第 \(index + 1) 条：\(lhs[index].text) ≠ \(rhs[index].text)"
        }
        return "条数 \(lhs.count) 对 \(rhs.count)"
    }
}
