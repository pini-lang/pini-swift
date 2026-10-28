import Foundation
import PiniCore
import Testing

/// IO 面的**路径解析**判据：相对路径一律相对**脚本所在目录**（程序基准），与写法的形状无关。
///
/// 靶 = 同一份逻辑的两种等价写法 —— 字面量 `readFile("a.txt")` 与变量 `var p = "a.txt"` +
/// `readFile(p)` —— 必须落到同一个文件，且两通道给出同一结论。字面量在编译期拼接、变量落到
/// 进程 CWD 的实现，会在两种写法上给出**相反**的答案。
///
/// ⚠️ 每条用例都让**进程 CWD 与脚本目录是两个不同目录**，且两边各放一个会给出不同答案的同名条目
/// —— CWD 与脚本目录相同时，「解析到基准」与「解析到 CWD」答案相同，本套件整条失去分辨力。
///
/// 参照物是**手写期望**，⛔ 不是另一条通道的输出：两条同时错会互相认证。
///
/// ⚠️ 串行：每条用例都要起 `pini run` / `pini run-llvm` 子进程，并行跑会把机器占满
/// —— 并行的其它套件里有时序敏感的用例，抢不到线程就报出与自身无关的红。
@Suite(.serialized)
struct IOBaseParityTests {

    // MARK: - 私有 helper

    private struct RunResult {
        let label: String
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private enum Channel: CaseIterable {
        case interpreter
        case llvm

        var commandName: String { self == .interpreter ? "run" : "run-llvm" }
        var label: String { self == .interpreter ? "解释器" : "LLVM" }
    }

    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-io-base-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 布一个 CWD 与脚本目录**不同**的沙盒，两边都放会给出不同答案的条目：
    ///
    /// | 条目 | `scripts/` 下 | `cwd/` 下 |
    /// |---|---|---|
    /// | `a.txt` | 文件，内容 `script-a` | 文件，内容 `cwd-a` |
    /// | `probe.txt` | 文件 | **目录** |
    /// | `cwd-only.txt` | 无 | 文件 |
    /// | `dot.txt` | 无 | 文件（供 `./dot.txt`） |
    /// | `sub/` | 目录，内含 `inner.txt` | 无 |
    ///
    /// 另有沙盒根上的 `up.txt`（供 `../up.txt`：CWD 的上一级）。
    private func seedLayout(_ base: URL) throws -> (scripts: URL, cwd: URL) {
        let scripts = base.appendingPathComponent("scripts")
        let cwd = base.appendingPathComponent("cwd")
        for dir in [scripts, cwd, scripts.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("script-a".utf8).write(to: scripts.appendingPathComponent("a.txt"))
        try Data("cwd-a".utf8).write(to: cwd.appendingPathComponent("a.txt"))
        try Data("probe".utf8).write(to: scripts.appendingPathComponent("probe.txt"))
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent("probe.txt"), withIntermediateDirectories: true)
        try Data("cwd-only".utf8).write(to: cwd.appendingPathComponent("cwd-only.txt"))
        try Data("cwd-dot".utf8).write(to: cwd.appendingPathComponent("dot.txt"))
        try Data("inner".utf8).write(to: scripts.appendingPathComponent("sub/inner.txt"))
        try Data("up".utf8).write(to: base.appendingPathComponent("up.txt"))
        return (scripts, cwd)
    }

    /// 定位命令行产物：先看环境变量，再按仓根兜底。
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
            Issue.record("IO 基准面的两通道判据本次没有跑")
        }
        return nil
    }

    /// 把脚本写进 `scripts/`，在 `cwd/` 里跑**一条**通道。两条通道各跑一次、各自比期望，
    /// 故被测通道之间不共享产物。
    private func runOn(
        _ channel: Channel, source: String, scripts: URL, cwd: URL
    ) throws -> RunResult? {
        guard let cli = cliPath() else { return nil }
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [channel.commandName, script.path]
        process.currentDirectoryURL = cwd
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(
            label: channel.label,
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private func lines(_ stdout: String) -> [String] {
        stdout.split(separator: "\n").map(String.init)
    }

    // MARK: - 判据 1/2：同义改写同解（读与写）

    @Test("字面量路径与变量路径读到同一个文件：两通道各与同一份手写期望相符")
    func literalAndVariableReadTheSameFile() throws {
        /// 意图：`readFile("a.txt")` 与 `var p = "a.txt"; readFile(p)` 同解。
        /// 驳回性：变量路径落到进程 CWD 的实现在 `cwd/a.txt` 上给出 `cwd-a`（LLVM 通道曾直接 panic）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)
        #expect(scripts.path != cwd.path, "沙盒自身失效：脚本目录与 CWD 撞在一起")

        let source = """
            main|func() -> ():
                print(readFile("a.txt"))
                var p = "a.txt"
                print(readFile(p))
                return
            """
        let expected = ["script-a", "script-a"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, scripts: scripts, cwd: cwd)
            else { return }
            #expect(
                lines(run.stdout) == expected,
                "\(run.label)通道与手写期望不符：\(run.stdout) / stderr \(run.stderr.prefix(300))")
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status)")
        }
    }

    @Test("字面量路径与变量路径写到同一个目录：两通道都落在脚本目录下")
    func literalAndVariableWriteToTheSameDirectory() throws {
        /// 意图：`writeFile("o-lit.txt", …)` 与 `var p = "o-var.txt"; writeFile(p, …)` 同解。
        /// 驳回性：变量路径落到 CWD 的实现会在 `cwd/` 下建文件，`scripts/` 下两处断言随即落空。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)

        let source = """
            main|func() -> ():
                writeFile("o-lit.txt", "L")
                var p = "o-var.txt"
                writeFile(p, "V")
                return
            """
        let literalTarget = scripts.appendingPathComponent("o-lit.txt")
        let variableTarget = scripts.appendingPathComponent("o-var.txt")
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, scripts: scripts, cwd: cwd)
            else { return }
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status) / stderr \(run.stderr.prefix(300))")
            #expect(run.stdout.isEmpty, "\(run.label)通道不该有输出：\(run.stdout)")

            /// 期望是**这份源码自己写下的字面量**；读在跑完之后，故读到的一定是本通道的产物。
            let literalText = try? String(contentsOf: literalTarget, encoding: .utf8)
            let variableText = try? String(contentsOf: variableTarget, encoding: .utf8)
            #expect(literalText == "L", "\(run.label)通道：字面量路径没写进脚本目录（实际 \(literalText ?? "缺失")）")
            #expect(variableText == "V", "\(run.label)通道：变量路径没写进脚本目录（实际 \(variableText ?? "缺失")）")
            for name in ["o-lit.txt", "o-var.txt"] {
                #expect(
                    !FileManager.default.fileExists(
                        atPath: cwd.appendingPathComponent(name).path),
                    "\(run.label)通道：\(name) 写进了 CWD")
            }

            /// 清掉本通道的产物，下一条通道从零开始写。
            try? FileManager.default.removeItem(at: literalTarget)
            try? FileManager.default.removeItem(at: variableTarget)
        }
    }

    // MARK: - 判据 3：三个豁免形态不受基准影响

    @Test("绝对路径、`./x`、`../x` 在两通道都按进程 CWD 语义解析")
    func exemptFormsKeepProcessCWDSemantics() throws {
        /// 意图：这三种写法**不**拼接程序基准 —— 绝对路径原样，`./` 与 `../` 相对进程 CWD。
        /// 驳回性：无条件拼接基准的实现会把 `./dot.txt` 解成 `<scripts>/./dot.txt`（不存在 ⇒ 读失败）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)

        let absolute = scripts.appendingPathComponent("a.txt").path
        let source = """
            main|func() -> ():
                print(readFile("\(absolute)"))
                print(readFile("./dot.txt"))
                print(readFile("../up.txt"))
                return
            """
        let expected = ["script-a", "cwd-dot", "up"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, scripts: scripts, cwd: cwd)
            else { return }
            #expect(
                lines(run.stdout) == expected,
                "\(run.label)通道与手写期望不符：\(run.stdout) / stderr \(run.stderr.prefix(300))")
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status)")
        }
    }

    // MARK: - 判据 4：exists / isDir / listDir 同步

    @Test("exists / isDir / listDir 的变量路径在两通道同答")
    func pathProbesAgreeOnVariablePaths() throws {
        /// 意图：探测与列目录三个内建与读写的解析口径**同一套**。
        /// 驳回性：解析到 CWD 的实现会把 `cwd-only.txt` 答成存在、把 `probe.txt` 答成目录、
        /// 并在 `listDir("sub")` 上 panic（CWD 下没有 `sub`）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)

        let source = """
            main|func() -> ():
                var p = "a.txt"
                print(exists(p))
                var onlyInCWD = "cwd-only.txt"
                print(exists(onlyInCWD))
                var probe = "probe.txt"
                print(isDir(probe))
                var d = "sub"
                print(exists(d))
                print(isDir(d))
                print(listDir(d))
                return
            """
        let expected = ["true", "false", "false", "true", "true", "[inner.txt]"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, scripts: scripts, cwd: cwd)
            else { return }
            #expect(
                lines(run.stdout) == expected,
                "\(run.label)通道与手写期望不符：\(run.stdout) / stderr \(run.stderr.prefix(300))")
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status)")
        }
    }

    // MARK: - 发射面：路径不在编译期拼接，写路径不经 libc

    @Test("注入基准时字面量路径原样交出：不拼接、不发 fopen 一族")
    func literalPathsAreHandedOverUnbaked() throws {
        /// 意图：解析只剩运行时一处入口 ⇒ 产物里不存在 `base + "/" + 字面量` 那种常量，
        /// 写路径也不再是 `fopen` / `fwrite` / `fclose` 那一组调用。
        /// 驳回性：在发射侧烘焙字面量的实现会让最后一条断言红；退回 libc 写的实现让第三条红。

        /// ⚠️ 判据落在**调用行**上：只查整份 IR 是否含某个符号，声明那一行就能把它骗过去。
        let base = "/tmp/pini-io-base-baked"
        let ir = try emittedIR(
            """
            main|func() -> ():
                writeFile("o.txt", "x")
                print(readFile("a.txt"))
                return
            """, programBase: base)
        let writeCalls = ir.split(separator: "\n").filter {
            $0.contains("call void @bk_write_file(")
        }
        let readCalls = ir.split(separator: "\n").filter {
            $0.contains("call ptr @bk_read_file(")
        }
        #expect(writeCalls.count == 1, "写路径没有落到运行时 shim（实际 \(writeCalls.count) 处）")
        #expect(readCalls.count == 1, "读路径没有落到运行时 shim（实际 \(readCalls.count) 处）")
        #expect(!ir.contains("@fopen"), "产物里仍有 libc 写路径的符号")
        #expect(!ir.contains("\(base)/o.txt"), "字面量路径被编译期拼接进了常量")
        #expect(!ir.contains("\(base)/a.txt"), "字面量路径被编译期拼接进了常量")
    }

    // MARK: - 发射 helper

    /// 解析（含常量折叠）→ 语义门禁 → 类型检查 → 降载 → 发射，返回 IR 文本。
    private func emittedIR(_ source: String, programBase: String? = nil) throws -> String {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        let module = ConstantFolder.foldConstants(in: parsed.module)
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let emitter = IREmitter()
        emitter.programBase = programBase
        return emitter.emit(module: lowered)
    }
}
