import Foundation
import PiniCore
import Testing

/// `moduleRoot()` 内建的判据（程序基准面）。
/// 组织：每条用例自建临时沙盒（脚本放 `scripts/`、进程 CWD 放 `cwd/`），⛔ 不往仓库里建文件。
/// 比对物是**手写期望**，⛔ 不是另一条通道的输出 —— 两条同时错会互相认证。
struct ModuleRootBuiltinTests {

    // MARK: - 私有 helper

    /// 建一个受控的临时沙盒；调用方负责在结束时删除。
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-module-root-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 建 `scripts/`（内含 `a.txt` / `b.txt` / `sub/`）与 `cwd/` 两个**不同**的目录。
    /// `scripts/` 的条目集固定为这四样加调用方写入的脚本，故期望可以手写。
    private func seedLayout(_ base: URL) throws -> (scripts: URL, cwd: URL) {
        let scripts = base.appendingPathComponent("scripts")
        let cwd = base.appendingPathComponent("cwd")
        for dir in [scripts, cwd, scripts.appendingPathComponent("sub")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("a".utf8).write(to: scripts.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: scripts.appendingPathComponent("b.txt"))
        return (scripts, cwd)
    }

    /// 解析（含常量折叠）→ 语义门禁 → 类型检查 → 降载 → 发射，返回 IR 文本。
    ///
    /// `programBase` 只在命令行那条路上被注入；默认 nil 就是「未注入基准」的形态。
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
            Issue.record("程序基准内建的两通道判据本次没有跑")
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

    // MARK: - 基准值（两通道）

    @Test("moduleRoot 答脚本所在目录的绝对路径，两通道各与同一条手写期望相符")
    func moduleRootAnswersScriptDirectoryOnBothChannels() throws {
        /// 意图：`moduleRoot()` = **脚本所在目录**的绝对路径，解释器与 LLVM 各验一次。
        /// 驳回性：答进程 CWD 的实现在此给出 `…/cwd`，答空串的实现给出一个空行。

        /// ⚠️ 前提：CWD 与脚本目录必须不同 —— 相同则「答 CWD」照样通过，本用例失去分辨力。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)
        #expect(scripts.path != cwd.path, "沙盒自身失效：脚本目录与 CWD 撞在一起")

        let source = """
            main|func() -> ():
                print(moduleRoot())
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let expected = [scripts.path]
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

    @Test("listDir(moduleRoot()) 在 LLVM 通道列出脚本目录的条目")
    func listDirOfModuleRootListsScriptDirectoryOnBothChannels() throws {
        /// 意图：绝对路径不经 IO 解析，故本项即可成立 —— 条目集手写，两通道各验一次。
        /// 驳回性：基准答 CWD 的实现列出空目录（`[]`），与期望的四个条目不符。

        /// ⚠️ 条目按 UTF-8 字节序升序，`prog.pini` 排在 `sub` 之前 —— 期望值照此手写。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)

        let source = """
            main|func() -> ():
                print(listDir(moduleRoot()))
                return
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let expected = ["[a.txt, b.txt, prog.pini, sub]"]
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

    // MARK: - 发射面

    @Test("未注入基准时 moduleRoot 仍降为运行时符号，不发基准注入")
    func moduleRootMapsToRuntimeSymbolWithoutProgramBase() throws {
        /// 意图：符号映射与基准注入是**两件事** —— 没有基准时查询照样要落到 `bk_module_root`。
        /// 驳回性：落到默认 `mangle` 的实现产出 `call i8* @moduleRoot()`，本用例两条断言同时红。

        /// ⚠️ 判据落在**调用行**上：只看整份 IR 是否含运行时符号名，声明那一行就能把它骗过去。
        /// ⛔ 未注入态不该带注入点：带了就意味着「默认 nil 时产物逐字节不变」被打破。
        let ir = try emittedIR(
            """
            main|func() -> ():
                print(moduleRoot())
                return
            """)
        let callLines = ir.split(separator: "\n").filter {
            $0.contains("call") && $0.contains("@bk_module_root")
        }
        #expect(callLines.count == 1, "调用点没有落到运行时符号（实际 \(callLines.count) 处）")
        #expect(!ir.contains("@moduleRoot"), "产物里出现了没有定义的裸 @moduleRoot")
        #expect(!ir.contains("bk_set_program_base"), "未注入基准却发出了基准注入")
    }

    @Test("注入基准时入口发出一次 setter 调用与它的声明")
    func programBaseSetterIsEmittedWhenBaseIsInjected() throws {
        /// 意图：有基准时，入口第一句把基准交给运行时；声明随之出现一次。
        /// 驳回性：只想改符号映射、忘了注入的实现会让 `bk_module_root` 永远答 CWD。

        /// ⚠️ 只断 ABI 名，⛔ 不断常量名 —— 常量怎么起名不属于对外契约。
        let ir = try emittedIR(
            """
            main|func() -> ():
                print(moduleRoot())
                return
            """, programBase: "/tmp/pini-module-root-baked")
        #expect(
            ir.contains("call void @bk_set_program_base("), "入口没有发出基准注入")
        #expect(
            ir.contains("declare void @bk_set_program_base(ptr)"), "基准注入没有声明")
    }

    // MARK: - 测试模式入口

    @Test("测试模式的进程入口同样注入基准：pini test-llvm 里 moduleRoot 答脚本目录")
    func testModeEntryAlsoInjectsProgramBase() throws {
        /// 意图：测试档的程序入口是**合成**的那一个（驱动器 + `define i32 @main()`），
        /// 与生产入口不是同一处代码 ⇒ 必须单独验一次，否则这条路上 `moduleRoot` 静默答 CWD。

        /// 驳回性：测试模式入口漏注入时，断言在 LLVM 侧失败 ⇒ 退出码非 0、报告是 `✗`。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (scripts, cwd) = try seedLayout(sandbox)

        let source = """
            模块根|test() -> ():
                assert(moduleRoot() == "\(scripts.path)", "基准不是脚本目录")
            """
        let script = scripts.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let run = try launch(cli, ["test-llvm", script.path], workingDirectory: cwd)
        #expect(run.status == 0, "测试档退出码 \(run.status) / stderr \(run.stderr.prefix(300))")
        #expect(run.stdout.contains("✓ 模块根"), "报告里没有通过行：\(run.stdout)")
    }
}
