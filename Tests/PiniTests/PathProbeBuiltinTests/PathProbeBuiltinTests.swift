import Foundation
import PiniCore
import Testing

/// `exists` / `isDir` 内建的判据（路径探测面）。
///
/// 组织：一夹具一条用例，夹具在本文件同目录的 `Fixtures/` 下、文件名即消费它的用例名 ——
/// 「有夹具而无用例」与「有用例而无夹具」都能一眼看出（同 `GrammarAcceptanceTests` 的约定）。
///
/// ⚠️ 本套件被测对象是**文件系统** ⇒ 每条用例自建临时目录当程序基准，
/// ⛔ 不在仓库里建任何文件，⛔ 也不把基准指向夹具目录（后者会让用例互相看见对方的产物）。
///
/// ⚠️ 靶 = **探测类与操作类的分界**：`listDir` / `readFile` 对坏路径 panic，而本组答 false。
/// 只查「存在」的实现会在 `isDir` 的文件用例上给出 true ⇒ 那条用例专抓这个。
struct PathProbeBuiltinTests {

    // MARK: - 私有 helper

    /// 建一个受控的临时基准目录；调用方负责在结束时删除。
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 建 `probe-dir/` 与其下的 `present.txt`。
    private func seedProbeDirectory(_ base: URL) throws {
        let dir = base.appendingPathComponent("probe-dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: dir.appendingPathComponent("present.txt"))
    }

    /// 解析（含常量折叠）→ 语义门禁 → 类型检查 → 降载 → 在指定基准上执行，返回标准输出逐行。
    private func run(_ fixture: String, programBase: URL) throws -> [String] {
        let source = try loadPiniFixture(fixture + ".pini", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: fixture + ".pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fixture + ".pini")
            .parseModuleCollectingErrors()
        let module = ConstantFolder.foldConstants(in: parsed.module)
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: programBase.path)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    // MARK: - 正向

    @Test("存在的文件 ⇒ exists 为真")
    func testExistsIsTrueForFile() throws {
        /// 意图：`exists` 收**文件**，⛔ 不是「只答目录」。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seedProbeDirectory(sandbox)

        let lines = try run("testExistsIsTrueForFile", programBase: sandbox)
        #expect(lines == ["true"], "实际：\(lines)")
    }

    @Test("存在的目录 ⇒ exists 为真")
    func testExistsIsTrueForDirectory() throws {
        /// 意图：目录也算存在 —— 与上面那条合成「两类都答真」，
        /// 只答其中一类的实现在另一条上会红。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seedProbeDirectory(sandbox)

        let lines = try run("testExistsIsTrueForDirectory", programBase: sandbox)
        #expect(lines == ["true"], "实际：\(lines)")
    }

    // MARK: - 负向

    @Test("不存在 ⇒ exists 为假，且不 panic")
    func testExistsIsFalseWhenMissing() throws {
        /// 意图：走**返回值**通道、⛔ 不走错误通道 —— 这是探测类与操作类的分界。
        /// 驳回性：若实现改成 panic，本用例会以抛错而非断言失败告终。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seedProbeDirectory(sandbox)

        let lines = try run("testExistsIsFalseWhenMissing", programBase: sandbox)
        #expect(lines == ["false", "false"], "实际：\(lines)")
    }

    @Test("isDir 判「是目录」，文件与不存在的路径同答假")
    func testIsDirDistinguishesFileFromDirectory() throws {
        /// 意图：钉住「检查的是**是目录**，不只是**存在**」。
        /// ⚠️ 只查 `fileExists` 的实现会在第二行给出 true ⇒ 本用例专抓这个。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try seedProbeDirectory(sandbox)

        let lines = try run("testIsDirDistinguishesFileFromDirectory", programBase: sandbox)
        #expect(lines == ["true", "false", "false"], "实际：\(lines)")
    }

    @Test("对不存在的路径连续探测不 panic，程序跑到底")
    func testProbesOnMissingPathDoNotPanic() throws {
        /// 意图：与 `listDir` 的 panic 形态**直接对照** —— 第三条输出是「跑到底」的证据；
        /// 若探测抛错，前两行也不会有。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let lines = try run("testProbesOnMissingPathDoNotPanic", programBase: sandbox)
        #expect(lines == ["false", "false", "still-running"], "实际：\(lines)")
    }

    // MARK: - 两通道

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
            Issue.record("路径探测内建的两通道判据本次没有跑")
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

    @Test("两通道：同一份探测语料在解释器与 LLVM 上一致")
    func testProbesAgreeAcrossBothChannels() throws {
        /// 意图：`exists` / `isDir` 在两个后端上给出**同一份**手写期望。
        /// ⭐ 参照物是手写期望，⛔ 不是「另一条通道」—— 两条同时错会互相认证。
        guard let cli = cliPath() else { return }
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let workspace = sandbox.appendingPathComponent("chan")
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("probe-dir"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: workspace.appendingPathComponent("probe-dir/present.txt"))

        let source = """
            main|func() -> ():
                print(exists("probe-dir"))
                print(exists("absent"))
                print(isDir("probe-dir"))
                print(isDir("probe-dir/present.txt"))
                print(isDir("absent"))
                return
            """
        let script = workspace.appendingPathComponent("probe.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let expected = ["true", "false", "true", "false", "false"]
        let a = try launch(cli, ["run", script.path], workingDirectory: workspace)
        #expect(
            a.stdout.split(separator: "\n").map(String.init) == expected,
            "解释器通道与手写期望不符：\(a.stdout) / stderr \(a.stderr.prefix(300))")
        let b = try launch(cli, ["run-llvm", script.path], workingDirectory: workspace)
        #expect(
            b.stdout.split(separator: "\n").map(String.init) == expected,
            "LLVM 通道与手写期望不符：\(b.stdout) / stderr \(b.stderr.prefix(300))")
        #expect(a.status == 0, "解释器通道退出码 \(a.status)")
        #expect(b.status == 0, "LLVM 通道退出码 \(b.status)")
    }
}
