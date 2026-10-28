import Foundation
import Testing

/// 路径解析的三条**豁免支**与基准支的判据。
///
/// 组织：每条用例自建临时沙盒（脚本放 `scripts/`、进程 CWD 放 `cwd/`），⛔ 不往仓库里建文件。
/// 比对物是**手写期望**，⛔ 不是另一条通道的输出 —— 两条同时错会互相认证。
///
/// ⚠️ 本套件守的是一条**外部依赖**：自举仓的相对路径全部带 `./` 前缀，靠 `./` / `../`
/// 这一支在「程序基准」与「进程 CWD」两种语义下都落到 CWD。若把这一支改成同样拼基准，
/// 自举仓会全线失守，而它的 `check` 门禁看不出来（只有跑原生臂才暴露）⇒ 本套件就是那道拦截。
struct IOPathExemptionTests {

    // MARK: - 私有 helper

    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-io-exempt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 三种基准各自的同名文件，内容互不相同 —— 只看输出即可判出解析用了哪一支。
    /// - 基准支（无前缀）⇒ `scripts/a.txt` = `script-a`
    /// - `./` 豁免（CWD）⇒ `cwd/a.txt` = `cwd-a`
    /// - `../` 豁免（CWD 的父）⇒ `<沙盒>/a.txt` = `root-a`
    /// - 绝对路径 ⇒ `<沙盒>/abs/abs.txt` = `abs-a`
    private func seedLayout(_ base: URL) throws -> (scripts: URL, cwd: URL, abs: String) {
        let scripts = base.appendingPathComponent("scripts")
        let cwd = base.appendingPathComponent("cwd")
        let absDir = base.appendingPathComponent("abs")
        for dir in [scripts, cwd, absDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("script-a".utf8).write(to: scripts.appendingPathComponent("a.txt"))
        try Data("cwd-a".utf8).write(to: cwd.appendingPathComponent("a.txt"))
        try Data("root-a".utf8).write(to: base.appendingPathComponent("a.txt"))
        try Data("abs-a".utf8).write(to: absDir.appendingPathComponent("abs.txt"))
        return (scripts, cwd, absDir.appendingPathComponent("abs.txt").path)
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
            Issue.record("路径豁免的两通道判据本次没有跑")
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

    private func lines(_ stdout: String) -> [String] {
        stdout.split(separator: "\n").map(String.init)
    }

    // MARK: - 读路径

    @Test("无前缀走基准、./ 与 ../ 走 CWD、绝对路径原样：四种形态两通道各与手写期望相符")
    func fourPathFormsResolveToTheirOwnBase() throws {
        /// 意图：把四条分支一次钉死 —— 前两条判「基准支是否真的拼了基准」，后两条判「豁免支是否真的没拼」。
        /// 驳回性：四条里任一条被改成另一支的语义，对应行就会读到别处的同名文件，输出与期望不符。
        ///
        /// ⚠️ 前提：CWD 与脚本目录必须不同，且两者各有同名文件 —— 否则「拼没拼基准」看不出差别。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd, absPath) = try seedLayout(sandbox)
        #expect(scripts.path != cwd.path, "沙盒自身失效：脚本目录与 CWD 撞在一起")

        let source = """
            main|func() -> ():
                print(readFile("a.txt"))
                print(readFile("./a.txt"))
                print(readFile("../a.txt"))
                print(readFile("\(absPath)"))
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let expected = ["script-a", "cwd-a", "root-a", "abs-a"]
        let a = try launch(cli, ["run", script.path], workingDirectory: cwd)
        #expect(
            lines(a.stdout) == expected,
            "解释器通道与手写期望不符：\(a.stdout) / stderr \(a.stderr.prefix(300))")
        let b = try launch(cli, ["run-llvm", script.path], workingDirectory: cwd)
        #expect(
            lines(b.stdout) == expected,
            "LLVM 通道与手写期望不符：\(b.stdout) / stderr \(b.stderr.prefix(300))")
        #expect(a.status == 0, "解释器通道退出码 \(a.status)")
        #expect(b.status == 0, "LLVM 通道退出码 \(b.status)")
    }

    // MARK: - 写路径

    @Test("写路径与读路径同规则：无前缀落在脚本目录、./ 落在 CWD")
    func writePathFollowsTheSameRuleAsRead() throws {
        /// 意图：解析规则是**一套**、不是读写各一套 —— 写侧同样要过同一条。
        /// 驳回性：写侧只认字面量或只认 CWD 的实现，会把两处之一写到错目录，盘上断言随即失败。
        ///
        /// ⚠️ 两通道各跑一次前先清掉上一次留下的产物，否则第二条通道可能读到第一条写的文件而假绿。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd, _) = try seedLayout(sandbox)

        let source = """
            main|func() -> ():
                writeFile("w-base.txt", "base")
                writeFile("./w-cwd.txt", "cwd")
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let baseOut = scripts.appendingPathComponent("w-base.txt")
        let cwdOut = cwd.appendingPathComponent("w-cwd.txt")
        func reset() {
            try? FileManager.default.removeItem(at: baseOut)
            try? FileManager.default.removeItem(at: cwdOut)
        }

        for (label, channel) in [("解释器", "run"), ("LLVM", "run-llvm")] {
            reset()
            let r = try launch(cli, [channel, script.path], workingDirectory: cwd)
            #expect(r.status == 0, "\(label)通道退出码 \(r.status) / stderr \(r.stderr.prefix(300))")
            #expect(
                (try? String(contentsOf: baseOut, encoding: .utf8)) == "base",
                "\(label)通道：无前缀的写没有落在脚本目录")
            #expect(
                (try? String(contentsOf: cwdOut, encoding: .utf8)) == "cwd",
                "\(label)通道：`./` 前缀的写没有落在 CWD")
        }
    }
}
