import Foundation
import Testing

/// `appendFile` 的判据：追加语义、创建语义、失败形态、路径解析，以及发射面的条件 declare。
///
/// 组织：每条用例自建临时沙盒（脚本放 `scripts/`、进程 CWD 放 `cwd/`），⛔ 不往仓库里建文件。
/// 比对物是**手写期望**，⛔ 不是另一条通道的输出 —— 两条同时错会互相认证。
struct AppendFileTests {

    // MARK: - 私有 helper

    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-append-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func cliPath() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv) {
            return fromEnv
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
        let candidates = ["/.build/debug/pini", "/.build/out/Products/Debug/pini"]
            .map { repoRoot + $0 }
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 两通道用例本次未取") {
            Issue.record("appendFile 的两通道判据本次没有跑")
        }
        return nil
    }

    private func launch(
        _ binary: String, _ arguments: [String], workingDirectory: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    // MARK: - 追加语义

    @Test("追加到已存在的文件：原内容保留、新内容接在末尾，两通道各与手写期望相符")
    func appendKeepsExistingContentAndAddsAtTheEnd() throws {
        /// 意图：`appendFile` 与 `writeFile` 在「目标已存在」这一点上语义**相反** —— 前者不截断。
        /// 驳回性：把 `appendFile` 实现成截断写的实现，读回只剩 `"B"`，与期望 `"AB"` 不符。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let scripts = sandbox.appendingPathComponent("scripts")
        let cwd = sandbox.appendingPathComponent("cwd")
        for dir in [scripts, cwd] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let source = """
            main|func() -> ():
                appendFile("log.txt", "B")
                print(readFile("log.txt"))
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let target = scripts.appendingPathComponent("log.txt")

        for (label, channel) in [("解释器", "run"), ("LLVM", "run-llvm")] {
            try Data("A".utf8).write(to: target)
            let r = try launch(cli, [channel, script.path], workingDirectory: cwd)
            #expect(r.status == 0, "\(label)通道退出码 \(r.status) / stderr \(r.stderr.prefix(300))")
            #expect(
                (try? String(contentsOf: target, encoding: .utf8)) == "AB",
                "\(label)通道：盘上内容不是 `AB`（追加被实现成了截断）")
            #expect(r.stdout.contains("AB"), "\(label)通道读回的不是 `AB`：\(r.stdout)")
        }
    }

    // MARK: - 创建语义

    @Test("目标不存在时创建它：日志程序的首行不该因文件不存在而失败")
    func appendCreatesTheTargetWhenMissing() throws {
        /// 意图：钉住 POSIX `"a"` 的创建语义 —— 这是 `appendFile` 能被当日志用的前提。
        /// 驳回性：先 require-exists 再追加的实现，在这里直接陷阱、退出码非 0。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let scripts = sandbox.appendingPathComponent("scripts")
        let cwd = sandbox.appendingPathComponent("cwd")
        for dir in [scripts, cwd] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let source = """
            main|func() -> ():
                appendFile("fresh.txt", "first-line")
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let target = scripts.appendingPathComponent("fresh.txt")

        for (label, channel) in [("解释器", "run"), ("LLVM", "run-llvm")] {
            try? FileManager.default.removeItem(at: target)
            let r = try launch(cli, [channel, script.path], workingDirectory: cwd)
            #expect(r.status == 0, "\(label)通道退出码 \(r.status) / stderr \(r.stderr.prefix(300))")
            #expect(
                (try? String(contentsOf: target, encoding: .utf8)) == "first-line",
                "\(label)通道：目标没有被创建，或内容不符")
        }
    }

    // MARK: - 失败形态

    @Test("追加到打不开的目标（目录）⇒ 两通道都陷阱且退出码为 1")
    func appendFailureTrapsWithExitCodeOne() throws {
        /// 意图：失败形态与 `writeFile` 同姿态 —— 不返回结果码、不静默。
        /// 驳回性：吞掉错误的实现退出码为 0；只在一侧统一的实现会出现 1 / 其它码并存。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let scripts = sandbox.appendingPathComponent("scripts")
        let cwd = sandbox.appendingPathComponent("cwd")
        for dir in [scripts, cwd, scripts.appendingPathComponent("adir")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let source = """
            main|func() -> ():
                appendFile("adir", "x")
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        for (label, channel) in [("解释器", "run"), ("LLVM", "run-llvm")] {
            let r = try launch(cli, [channel, script.path], workingDirectory: cwd)
            #expect(r.status == 1, "\(label)通道退出码 \(r.status)（期望 1）")
            #expect(!r.stderr.isEmpty, "\(label)通道没有给出任何诊断")
        }
    }

    @Test("appendFile 不可作值使用：出现在变量初值处由类型层拒绝")
    func appendFileIsNotUsableAsAValue() throws {
        /// 意图：`appendFile` 的返回是 `()` —— 与 `writeFile` 同一条 void 纪律。
        /// 驳回性：把返回类型登记成 `I32` 的实现会让这条通过检查（并可能在 LLVM 侧生成非法 IR）。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let script = sandbox.appendingPathComponent("prog.pini")
        try """
            main|func() -> ():
                var c = appendFile("x.txt", "y")
                return
            """.write(to: script, atomically: true, encoding: .utf8)

        let r = try launch(cli, ["check", script.path], workingDirectory: sandbox)
        #expect(r.status != 0, "值位使用没有被拒绝（退出码 0）")
        #expect(
            r.stderr.contains("()") || r.stdout.contains("()"),
            "拒绝理由里没有出现 `()`：\(r.stdout) \(r.stderr)")
    }

    // MARK: - 路径解析

    @Test("路径解析与其余内建同口径：无前缀落脚本目录、`./` 落 CWD")
    func appendFollowsTheSamePathRule() throws {
        /// 意图：新增的写内建不许自成一套路径规则。
        /// 驳回性：只认字面量或只认 CWD 的实现会把两处之一写到错目录，盘上断言随即失败。
        ///
        /// ⚠️ 前提：CWD 与脚本目录必须不同，否则两条分支落到同一处、测不出差别。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let scripts = sandbox.appendingPathComponent("scripts")
        let cwd = sandbox.appendingPathComponent("cwd")
        for dir in [scripts, cwd] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let source = """
            main|func() -> ():
                appendFile("base.txt", "base")
                appendFile("./cwdside.txt", "cwd")
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let baseOut = scripts.appendingPathComponent("base.txt")
        let cwdOut = cwd.appendingPathComponent("cwdside.txt")

        for (label, channel) in [("解释器", "run"), ("LLVM", "run-llvm")] {
            try? FileManager.default.removeItem(at: baseOut)
            try? FileManager.default.removeItem(at: cwdOut)
            let r = try launch(cli, [channel, script.path], workingDirectory: cwd)
            #expect(r.status == 0, "\(label)通道退出码 \(r.status) / stderr \(r.stderr.prefix(300))")
            #expect(
                (try? String(contentsOf: baseOut, encoding: .utf8)) == "base",
                "\(label)通道：无前缀的追加没有落在脚本目录")
            #expect(
                (try? String(contentsOf: cwdOut, encoding: .utf8)) == "cwd",
                "\(label)通道：`./` 前缀的追加没有落在 CWD")
        }
    }
}
