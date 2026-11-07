import Foundation
import Testing
import PiniSyntax
@testable import PiniHost

/// 语言内标准库的装配判据：前端并入后，方法在检查 · 解释 · 发射三条腿上都能被看见并执行。
/// 期望值全部手写；用户同名扩展压过标准库的读数由同一条语料对照给出，不从某次运行结果里抄。
@Suite("StandardLibrary")
struct StandardLibraryTests: Sendable {

    // MARK: - 语料与手写期望

    /// 四条读数钉三件事：命中前缀 · 前缀长于接收者 · 空前缀（两侧空串都对）。
    private static let corpus = #"""
    main|func() -> ():
        print("hello".startsWith("he"))
        print("hello".startsWith("hello!"))
        print("hello".startsWith(""))
        print("".startsWith(""))
        return
    """#

    private static let expected = #"""
    true
    false
    true
    true
    """#

    /// 用户在同一目标上给出同名方法：装配期摘掉标准库那份，读数取用户的 false。
    private static let overrideCorpus = #"""
    ((String))
    startsWith|self(prefix: String,) -> (Bool,):
        return false

    main|func() -> ():
        print("hello".startsWith("he"))
        return
    """#

    private static let overrideExpected = "false"

    // MARK: - 进程内装置

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "标准库探针.pini"
        do {
            let unit = FileUnit(fileName: name, module: try parsed(source, fileName: name))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "标准库", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：标准库方法在解释器腿产生手写期望；标准库源码解析失败会在这里变成未定义方法。
    @Test("解释器腿：标准库方法逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：用户扩展块与标准库同名时取用户那份，装配期不留下两份同名方法。
    @Test("解释器腿：用户同名扩展压过标准库")
    func userExtensionOverridesPrelude() throws {
        let outcome = Self.attempt(Self.overrideCorpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("覆盖语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.overrideExpected)
    }

    /// 意图：多文件包只在第一个单元并入标准库，跨文件检查同样看得见它。
    @Test("包通道：标准库并入第一个单元")
    func packageLegSeesPrelude() throws {
        let mainSource = #"""
        main|func() -> ():
            print(add(2, 3))
            print("hello".startsWith("he"))
            return
        """#
        let utilsSource = #"""
        add|func(a: I32, b: I32,) -> (I32,):
            return a + b
        """#
        do {
            let mainModule = try Self.parsed(mainSource, fileName: "main.pini")
            let utilsModule = try Self.parsed(utilsSource, fileName: "utils.pini")
            let package = Package(name: "包探针", fileUnits: [
                FileUnit(fileName: "main.pini", module: mainModule),
                FileUnit(fileName: "utils.pini", module: utilsModule),
            ])
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: package)
            #expect(lines.joined(separator: "\n") == "5\ntrue")
        } catch {
            Issue.record("包语料应可跑，实际被拒：\(error)")
        }
    }

    /// 解析 + pass，不装配：包通道的装配由 `Package.assemblingStdlib()` 负责。
    private static func parsed(_ source: String, fileName: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: fileName)
        let result = Parser(tokens: try lexer.tokenize(), fileName: fileName).parseModuleCollectingErrors()
        guard result.errors.isEmpty else { throw result.errors[0] }
        return try FrontEnd.passes(module: result.module)
    }

    // MARK: - 命令行三腿

    /// 取被测命令行：优先环境变量，其次自寻构建产物；两者都取不到 ⇒ CI 记失败。
    private func cliPath() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    /// 解析 LLVM 工具链**目录**；取不到 ⇒ nil（调用方响亮跳过 `run-llvm` 腿）。
    private func llvmToolchainDir() -> String? {
        let fromEnv = PiniTestEnvironment.llvmBinDirectory() ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv + "/lli") {
            return fromEnv
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["lli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readAllData()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let text = String(decoding: data, as: UTF8.self).split(separator: "\n").first
        else { return nil }
        return URL(fileURLWithPath: String(text)).deletingLastPathComponent().path
    }

    private func launch(
        _ binary: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func scratchFile(named name: String, contents: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-stdlib-prelude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// 意图：检查期就能看见标准库方法——检查通过即判据，缺装配会在这里报未定义。
    @Test("命令行 check 腿：标准库方法在检查期可见")
    func cliCheckLegSeesPrelude() throws {
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "stdlib-check.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["check", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
    }

    /// 意图：命令行 `run` 与进程内同一条期望。
    @Test("命令行 run 腿：标准库方法逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let file = try scratchFile(named: "stdlib-run.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm` 逐行等于同一份期望；lli 取不到 ⇒ 响亮跳过。
    @Test("命令行 run-llvm 腿：标准库方法逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-llvm.pini", contents: Self.corpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：覆盖语料在发射腿同样只留一份符号——两份同名会在 LLVM 通道重定义。
    @Test("命令行 run-llvm 腿：用户同名扩展压过标准库")
    func cliLLVMLegHonorsOverride() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let file = try scratchFile(named: "stdlib-llvm-override.pini", contents: Self.overrideCorpus)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.overrideExpected + "\n")
    }
}
