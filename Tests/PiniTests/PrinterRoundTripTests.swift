import Foundation
import PiniSyntax
import Testing

/// 打印器往返判据：`A(P(A(s))) ≡ A(s)` 与 `P(A(P(A(s)))) = P(A(s))`。
/// 两条合起来才排掉「打印丢信息」与「打印不稳定」两类失败；位置不进比较，排版本来就会改行号。
@Suite("打印器往返")
struct PrinterRoundTripTests {

    @Test("示例、夹具与 bench：往返等价、二次打印稳定、版面合规")
    func roundTrip() throws {
        let files = Self.corpus()
        #expect(files.count > 50, "语料不足：只找到 \(files.count) 个源文件")

        var failures: [String] = []
        for url in files {
            let label = url.path.replacingOccurrences(
                of: PiniTestEnvironment.repositoryRoot.path + "/", with: "")
            let source = try String(contentsOf: url, encoding: .utf8)
            guard let first = Self.parse(source, fileName: url.path) else {
                failures.append("\(label): 原文件解析失败，语料选择有误")
                continue
            }
            let printed = Printer.print(module: first)
            switch FrontEnd.collect(source: printed, fileName: url.path) {
            case .parsed(let second):
                if let mismatch = Self.firstMismatch(first, second, "Module") {
                    failures.append("\(label): 往返不等价 @ \(mismatch)\n" + Self.preview(printed))
                    continue
                }
                let reprinted = Printer.print(module: second)
                if reprinted != printed {
                    failures.append("\(label): 二次打印不稳定\n" + Self.firstDifference(printed, reprinted))
                    continue
                }
            case .lexFailed(let error):
                failures.append("\(label): 打印结果词法失败 \(error)\n" + Self.preview(printed))
                continue
            case .parseFailed(_, let errors):
                failures.append("\(label): 打印结果无法解析 \(errors.first.map { "\($0)" } ?? "")\n" + Self.preview(printed))
                continue
            case .expandFailed(let errors):
                failures.append("\(label): 打印结果展开失败 \(errors.first.map { "\($0)" } ?? "")\n" + Self.preview(printed))
                continue
            }
            failures.append(contentsOf: Self.layoutViolations(printed).map { "\(label): \($0)" })
        }

        for failure in failures.prefix(12) {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(failures.isEmpty, "\(failures.count) 处失败（共 \(files.count) 个文件）")
    }

    /// 语料未触及的语法点：靠构造片段补覆盖，每条同样走「解析 → 打印 → 再解析」。
    @Test("构造覆盖：语料未触及的语法点往返")
    func constructedCoverage() {
        let snippets: [(name: String, source: String)] = [
            (
                "import_export",
                """
                [import_export|import]
                别名 = "../x"
                _隐式 = "../y"

                [import_export|export]
                公开 = 私有
                对外|c = 加法
                """
            ),
            (
                "given",
                """
                [配置|given]
                线程数: I32 = 4
                名称: String = "x"

                [[配置]]
                取值|self() -> (I32,):
                    return self.线程数
                """
            ),
            (
                "defer-block",
                """
                main|func() -> ():
                    defer:
                        print(1)
                    return
                """
            ),
            (
                "try-expression",
                """
                f|func() -> (Result<I32>,):
                    return ok(1)

                main|func() -> ():
                    let x = try f() else 错误:
                        print(错误)
                        return
                    print(x)
                    return
                """
            ),
            (
                "named-returns",
                """
                除余|func(a: I32, b: I32,) -> (商: I32, 余: I32,):
                    return (a / b, a % b,)
                """
            ),
            (
                "compound-assign",
                """
                main|func() -> ():
                    var x = 1
                    x += 2
                    x -= 1
                    x *= 3
                    x /= 2
                    x %= 4
                    x &= 7
                    x |= 8
                    x ^= 15
                    x <<= 1
                    x >>= 1
                    return
                """
            ),
            (
                "detach-pass",
                """
                work|func() => ():
                    return

                main|func() -> ():
                    detach work()
                    pass
                    return
                """
            ),
            (
                "labeled-loop",
                """
                main|func() -> ():
                    var i = 0
                    外层|while i < 3:
                        if i == 1:
                            break 外层
                        i = i + 1
                    return
                """
            ),
            (
                "unsafe-compound",
                """
                [libc|foreign]
                load: (*U8,) -> (U8,)

                main|func() -> ():
                    var x: U8 = 7
                    var p = unsafe &x
                    print(unsafe (load(p) + 1))
                    return
                """
            ),
            (
                "enum-traits",
                """
                <可描述>
                    描述(self) -> (String,):
                        return "默认"

                [形状]
                圆(F64,)
                矩形(F64, F64,)
                实现: 可描述
                """
            ),
            (
                "float-edges",
                """
                main|func() -> ():
                    print(1e300)
                    print(1.5e-8)
                    print(0.0)
                    print(-2.5)
                    return
                """
            ),
            (
                "generic-nesting",
                """
                main|func() -> ():
                    let a: Dictionary<String, Dictionary<I32, String> > = {"x"= {1= "v"}}
                    print(len(a))
                    return
                """
            ),
        ]

        var failures: [String] = []
        for snippet in snippets {
            let fileName = "/tmp/\(snippet.name).pini"
            guard let first = Self.parse(snippet.source, fileName: fileName) else {
                failures.append("\(snippet.name): 片段本身解析失败")
                continue
            }
            let printed = Printer.print(module: first)
            guard let second = Self.parse(printed, fileName: fileName) else {
                failures.append("\(snippet.name): 打印结果无法解析\n\(printed)")
                continue
            }
            if let mismatch = Self.firstMismatch(first, second, "Module") {
                failures.append("\(snippet.name): 往返不等价 @ \(mismatch)\n\(printed)")
                continue
            }
            if Printer.print(module: second) != printed {
                failures.append("\(snippet.name): 二次打印不稳定\n\(printed)")
            }
        }
        for failure in failures { Issue.record(Comment(rawValue: failure)) }
        #expect(failures.isEmpty, "\(failures.count) 处失败（共 \(snippets.count) 个片段）")
    }

    /// 语料：示例全集 + 语法验收夹具的接受态 + bench。`testParserRejects*` 本就不可解析，不入选。
    static func corpus() -> [URL] {
        let root = PiniTestEnvironment.repositoryRoot
        var files: [URL] = []
        let walker = FileManager.default.enumerator(
            at: root.appendingPathComponent("examples"), includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension == "pini" { files.append(url) }
        }
        let fixtures = root.appendingPathComponent("Tests/PiniTests/GrammarAcceptanceTests/Fixtures")
        for url in (try? FileManager.default.contentsOfDirectory(
            at: fixtures, includingPropertiesForKeys: nil)) ?? []
        {
            if url.pathExtension == "pini", !url.lastPathComponent.contains("Rejects") {
                files.append(url)
            }
        }
        let bench = root.appendingPathComponent("bench")
        for url in (try? FileManager.default.contentsOfDirectory(
            at: bench, includingPropertiesForKeys: nil)) ?? []
        {
            if url.pathExtension == "pini" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func parse(_ source: String, fileName: String) -> Module? {
        switch FrontEnd.collect(source: source, fileName: fileName) {
        case .parsed(let module): return module
        case .lexFailed, .parseFailed, .expandFailed: return nil
        }
    }

    /// 版面合规：无行尾空白、无制表符、无 CRLF。这三条是打印器自己的契约。
    static func layoutViolations(_ text: String) -> [String] {
        var problems: [String] = []
        if text.contains("\t") { problems.append("输出含制表符") }
        if text.contains("\r") { problems.append("输出含回车") }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasSuffix(" ") { problems.append("第 \(index + 1) 行有行尾空白") }
        }
        return problems
    }

    static func preview(_ text: String) -> String {
        text.split(separator: "\n").prefix(8).joined(separator: "\n")
    }

    static func firstDifference(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            return "首处差异在第 \(index + 1) 行\n  一打：\(left[index])\n  二打：\(right[index])"
        }
        return "行数不同：\(left.count) 对 \(right.count)"
    }
}

// MARK: - 忽略位置的结构比较

extension PrinterRoundTripTests {

    /// 走 `Mirror` 逐层比较，`SourceLocation` 一律视为相等；不同时返回首个失配路径。
    /// 逐节点手写比较会随 AST 增长而漏项，反射则自动覆盖新字段。
    static func firstMismatch(_ lhs: Any, _ rhs: Any, _ path: String) -> String? {
        if lhs is PiniSyntax.SourceLocation || rhs is PiniSyntax.SourceLocation { return nil }
        let left = Mirror(reflecting: lhs)
        let right = Mirror(reflecting: rhs)

        if left.displayStyle == .optional || right.displayStyle == .optional {
            switch (left.children.first?.value, right.children.first?.value) {
            case (nil, nil): return nil
            case let (l?, r?): return firstMismatch(l, r, path + "?")
            default: return path + "（一侧为空）"
            }
        }

        if left.displayStyle == .enum {
            let name = caseName(lhs)
            guard name == caseName(rhs) else { return "\(path).\(name) ≠ \(caseName(rhs))" }
            let lc = left.children.map { $0.value }
            let rc = right.children.map { $0.value }
            guard lc.count == rc.count else { return "\(path).\(name) 子项数 \(lc.count) ≠ \(rc.count)" }
            for (index, pair) in zip(lc, rc).enumerated() {
                if let mismatch = firstMismatch(pair.0, pair.1, "\(path).\(name)[\(index)]") {
                    return mismatch
                }
            }
            return nil
        }

        if left.displayStyle == .collection || left.displayStyle == .set {
            let lc = left.children.map { $0.value }
            let rc = right.children.map { $0.value }
            guard lc.count == rc.count else { return "\(path) 元素数 \(lc.count) ≠ \(rc.count)" }
            for (index, pair) in zip(lc, rc).enumerated() {
                if let mismatch = firstMismatch(pair.0, pair.1, "\(path)[\(index)]") {
                    return mismatch
                }
            }
            return nil
        }

        if left.displayStyle == .struct || left.displayStyle == .class || left.displayStyle == .tuple {
            let lc = left.children.map { ($0.label ?? "?", $0.value) }
            let rc = right.children.map { ($0.label ?? "?", $0.value) }
            guard lc.count == rc.count else { return "\(path) 字段数 \(lc.count) ≠ \(rc.count)" }
            for (index, pair) in zip(lc, rc).enumerated() {
                if let mismatch = firstMismatch(pair.0.1, pair.1.1, "\(path).\(pair.0.0)") {
                    return mismatch
                }
            }
            return nil
        }

        if String(describing: lhs) != String(describing: rhs) {
            return "\(path): \(lhs) ≠ \(rhs)"
        }
        return nil
    }

    /// 枚举用例名：`String(describing:)` 的裸名部分（带载荷时以 `(` 分隔）。
    static func caseName(_ value: Any) -> String {
        String(String(describing: value).prefix { $0 != "(" })
    }
}
