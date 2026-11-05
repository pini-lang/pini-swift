import Foundation
import PiniSyntax
import Testing

/// `fmt` 走只到语法的路径：折叠与展开都改写程序，打印跑过 pass 的树就不再是同一份程序的排版。
/// 判据是「不跑 pass 的打印仍是逐字节不动点」——语料里的 `unroll` 与常量运算都留在原处。
@Suite("格式化出口")
struct FmtCommandTests {

    @Test("语法模式不跑 pass：常量不折叠、unroll 不展开")
    func syntaxOnlyKeepsSourceConstructs() {
        let source = """
            main|func() -> ():
                let a = 2 + 3 * 4
                unroll (码) in [1, 2]:
                    print(码)
                print(a)
                return
            """
        let scan = FrontEnd.syntaxOnly(source: source, fileName: "probe.pini")
        guard case .parsed(let module) = scan.outcome else {
            Issue.record("语法模式解析失败")
            return
        }
        let printed = Printer.print(module: module, comments: scan.comments)
        #expect(printed.contains("2 + 3 * 4"), "折叠混进了格式化的树：\n\(printed)")
        #expect(printed.contains("unroll"), "展开混进了格式化的树：\n\(printed)")
    }

    @Test("语料：不跑 pass 的打印是逐字节不动点，注释不丢")
    func corpusIsFixedPointWithoutPasses() throws {
        let files = PrinterRoundTripTests.corpus()
        #expect(files.count > 50, "语料不足：只找到 \(files.count) 个源文件")

        var failures: [String] = []
        for url in files {
            let label = url.path.replacingOccurrences(
                of: PiniTestEnvironment.repositoryRoot.path + "/", with: "")
            let source = try String(contentsOf: url, encoding: .utf8)
            guard let first = Self.printed(source, fileName: url.path) else {
                failures.append("\(label): 原文件语法模式解析失败，语料选择有误")
                continue
            }
            guard let second = Self.printed(first.text, fileName: url.path) else {
                failures.append("\(label): 打印结果无法再解析\n" + Self.preview(first.text))
                continue
            }
            if second.text != first.text {
                failures.append("\(label): 二次打印不稳定\n" + Self.difference(first.text, second.text))
                continue
            }
            if first.comments != second.comments {
                failures.append("\(label): 注释不守恒 \(first.comments.count) → \(second.comments.count)")
            }
            for problem in PrinterRoundTripTests.layoutViolations(first.text) {
                failures.append("\(label): \(problem)")
            }
        }

        for failure in failures.prefix(10) { Issue.record(Comment(rawValue: failure)) }
        #expect(failures.isEmpty, "\(failures.count) 处失败（共 \(files.count) 个源文件）")
    }

    /// 一次语法模式打印：文本与注释文本序列。解析失败返回 nil。
    static func printed(_ source: String, fileName: String) -> (text: String, comments: [String])? {
        let scan = FrontEnd.syntaxOnly(source: source, fileName: fileName)
        switch scan.outcome {
        case .parsed(let module):
            return (Printer.print(module: module, comments: scan.comments), scan.comments.map(\.text))
        case .lexFailed, .parseFailed, .expandFailed:
            return nil
        }
    }

    static func preview(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
            .map { "  | " + $0 }.joined(separator: "\n")
    }

    static func difference(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in left.enumerated() where index >= right.count || line != right[index] {
            let other = index < right.count ? String(right[index]) : "<缺失>"
            return "  首处差异在第 \(index + 1) 行\n  - \(line)\n  + \(other)"
        }
        return "  仅长度不同：\(left.count) 行 vs \(right.count) 行"
    }
}

/// 两个命令的对外行为：输出落点、退出码、参数组合。全部走真实子进程，命令自身的分支才算数。
@Suite(.serialized)
struct FmtCommandCLITests {

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func cliPath() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnvironment.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnvironment) {
            return fromEnvironment
        }
        return nil
    }

    private func requireCLI() -> Bool {
        guard cliPath() == nil else { return true }
        withKnownIssue("未提供 PINI_CLI_BIN ⇒ 本批判据本次未取（跳过 +1）") {
            Issue.record("没有命令行产物可跑")
        }
        return false
    }

    private func makeDirectory(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-fmt-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func run(_ arguments: [String]) throws -> RunResult {
        let cli = try #require(cliPath(), "没有命令行产物")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// 故意不合规范形：行尾注释列对齐、连续空行。缩进宽度是作者的选择，打印器不碰它。
    private var unformatted: String {
        """
        main|func() -> ():
          let a = 1        ; 行尾
          print(a)


          return
        """ + "\n"
    }

    /// 规范形只改注释间距与空行：二格缩进原样留下，故期望值也是二格。
    private var formatted: String {
        """
        main|func() -> ():
          let a = 1 ; 行尾
          print(a)
          return
        """ + "\n"
    }

    @Test("默认打印到 stdout，--check 只列路径并以退出码表达差异")
    func stdoutAndCheck() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("check")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("prog.pini")
        try write(unformatted, to: script)

        let printed = try run(["fmt", script.path])
        #expect(printed.status == 0, "退出码 \(printed.status)：\(printed.stderr)")
        #expect(printed.stdout == formatted, "输出不符：\n\(printed.stdout)")

        let dirty = try run(["fmt", "--check", script.path])
        #expect(dirty.status == 1, "有差异应当退出 1")
        #expect(dirty.stdout == script.path + "\n", "只列路径：\(dirty.stdout)")

        let cleanFile = dir.appendingPathComponent("clean.pini")
        try write(formatted, to: cleanFile)
        let clean = try run(["fmt", "--check", cleanFile.path])
        #expect(clean.status == 0, "已规范的文件不该报脏：\(clean.stdout)")
        #expect(clean.stdout.isEmpty, "干净时不该有输出：\(clean.stdout)")
    }

    @Test("fmt -w 原地写回，二次运行不再改动，注释留在原处")
    func writeInPlace() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("write")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("prog.pini")
        try write(unformatted, to: script)

        let first = try run(["fmt", "-w", script.path])
        #expect(first.status == 0, "退出码 \(first.status)：\(first.stderr)")
        let once = try read(script)
        #expect(once == formatted, "写回内容不符：\n\(once)")

        let second = try run(["fmt", "-w", script.path])
        #expect(second.status == 0, "二次写回失败：\(second.stderr)")
        #expect(try read(script) == once, "二次写回改了文件")
        #expect(try run(["fmt", "--check", script.path]).status == 0, "写回后仍报脏")
    }

    @Test("fmt 不跑 pass：unroll 与常量运算原样保留")
    func keepsSourceConstructs() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("passes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("prog.pini")
        try write(
            """
            main|func() -> ():
                let a = 2 + 3 * 4
                unroll (码) in [1, 2]:
                    print(码)
                print(a)
                return
            """, to: script)

        let result = try run(["fmt", script.path])
        #expect(result.status == 0, "退出码 \(result.status)：\(result.stderr)")
        #expect(result.stdout.contains("2 + 3 * 4"), "常量被折叠了：\n\(result.stdout)")
        #expect(result.stdout.contains("unroll"), "unroll 被展开了：\n\(result.stdout)")
    }

    @Test("目录递归取 .pini，跳过 .build 与隐藏项")
    func directoryWalk() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("walk")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(unformatted, to: dir.appendingPathComponent("a.pini"))
        try write(unformatted, to: dir.appendingPathComponent("sub/b.pini"))
        try write(unformatted, to: dir.appendingPathComponent(".build/c.pini"))
        try write(unformatted, to: dir.appendingPathComponent(".hidden/d.pini"))

        let result = try run(["fmt", "--check", dir.path])
        #expect(result.status == 1, "有差异应当退出 1")
        let listed = result.stdout.split(separator: "\n").map(String.init)
        #expect(listed.contains { $0.hasSuffix("a.pini") }, "漏了顶层文件：\(result.stdout)")
        #expect(listed.contains { $0.hasSuffix("sub/b.pini") }, "漏了子目录文件：\(result.stdout)")
        #expect(!listed.contains { $0.contains(".build") }, "不该进 .build：\(result.stdout)")
        #expect(!listed.contains { $0.contains(".hidden") }, "不该进隐藏目录：\(result.stdout)")
    }

    @Test("expand 去掉 unroll，产物跑出与原文件相同的输出")
    func expandMatchesOriginalRun() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("expand")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = PiniTestEnvironment.repositoryRoot
            .appendingPathComponent("examples/unroll.pini")

        let expanded = try run(["expand", original.path])
        #expect(expanded.status == 0, "退出码 \(expanded.status)：\(expanded.stderr)")
        #expect(!expanded.stdout.contains("unroll"), "产物里还留着 unroll：\n\(expanded.stdout)")

        let copy = dir.appendingPathComponent("unroll.pini")
        try write(expanded.stdout, to: copy)
        let before = try run(["run", original.path])
        let after = try run(["run", copy.path])
        #expect(before.status == 0, "原文件跑不起来：\(before.stderr)")
        #expect(after.status == before.status, "退出码不同：\(before.status) vs \(after.status)")
        #expect(after.stdout == before.stdout, "输出不同：\n\(before.stdout)\n---\n\(after.stdout)")
    }

    @Test("参数组合：--check 与 -w 互斥，多路径要显式选写回或检查")
    func argumentConflicts() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory("args")
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("one.pini")
        let two = dir.appendingPathComponent("two.pini")
        try write(formatted, to: one)
        try write(formatted, to: two)

        let both = try run(["fmt", "--check", "-w", one.path])
        #expect(both.status != 0, "--check 与 -w 同时给应当报错")
        #expect(both.stderr.contains("--check"), "报错点名冲突的选项：\(both.stderr)")

        let ambiguous = try run(["fmt", one.path, two.path])
        #expect(ambiguous.status != 0, "多路径无 -w/--check 应当报错")
        #expect(ambiguous.stdout.isEmpty, "不该往 stdout 混多份输出")

        let unknown = try run(["fmt", "--nope", one.path])
        #expect(unknown.status != 0, "未知选项应当报错")
        #expect(unknown.stderr.contains("--nope"), "报错点名该选项：\(unknown.stderr)")
    }
}
