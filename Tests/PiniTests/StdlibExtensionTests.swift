import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniHost

/// 内建类型扩展块（`((String))` / `((Array))`）的宿主单测。右端 = 手写期望，不是从某次运行输出抄来的。
/// 三条腿：解释器（进程内 `ProgramRunner`，恒跑）· 命令行 `run` · 命令行 `run-llvm`（自寻二进制，取不到则响亮跳过）。
/// 覆盖三件事：新方法可派发 · 同名覆盖压过内建 · 泛型容器形参在单态化后拿到元素类型。
@Suite("StdlibExtension")
struct StdlibExtensionTests: Sendable {

    // MARK: - 语料与手写期望

    /// 一行一个读数，全部经 `print` 出可观测文本。函数名取英文，与内建成员方法同一命名面。
    ///  注意  raw 字符串：括号与引号原样进 Pini 词法层。
    private static let corpus = #"""
    ((String))
    replace|self(old: String, new: String,) -> (String,):
        var out = ""
        var i = 0
        var n = len(self)
        var m = len(old)
        if m == 0:
            return self
        while i < n:
            if i + m <= n:
                if self.slice(i, i + m) == old:
                    out = out + new
                    i = i + m
                else:
                    out = out + self.slice(i, i + 1)
                    i = i + 1
            else:
                out = out + self.slice(i, i + 1)
                i = i + 1
        return out

    startsWith|self(prefix: String,) -> (Bool,):
        var m = len(prefix)
        if m > len(self):
            return false
        return self.slice(0, m) == prefix

    endsWith|self(suffix: String,) -> (Bool,):
        var n = len(self)
        var m = len(suffix)
        if m > n:
            return false
        return self.slice(n - m, n) == suffix

    repeat|self(times: I32,) -> (String,):
        var out = ""
        var i = 0
        while i < times:
            out = out + self
            i = i + 1
        return out

    contains|self(needle: String,) -> (Bool,):
        return true

    caps|self() -> (String,):
        return self.upper() + "!"

    ((Array))
    second|self() -> (I32,):
        return self[1]

    first|func<T>(arr: Array<T>,) -> (T,):
        return arr[0]

    main|func() -> ():
        print("a-b-c".replace("-", "+"))
        print("a--b".replace("--", "+"))
        print("abc".replace("", "x"))
        print("abc".replace("z", "x"))
        print("hello".startsWith("he"))
        print("hello".startsWith("hello!"))
        print("中文".endsWith("文"))
        print("ab".repeat(0))
        print("ab".repeat(3))
        print("abc".contains("z"))
        print("abc".indexOf("b"))
        print([10, 20, 30].second())
        print(first<I32>([7, 8]))
        print(first<String>(["x", "y"]))
        print("ab".caps())
        return
    """#

    /// 手写期望（逐行；不含尾换行）。第一二条钉多字符替换不是按字符集；第三四条钉空模板与无匹配原样返回。
    /// 五六条钉前缀超长是 false；第八条钉空串（保留的空行）；第十条钉用户 `contains` 压过内建。
    /// 第十一条钉覆盖只影响同名；后四条钉数组扩展与泛型容器形参的两种实参。
    private static let expected = #"""
    a+b+c
    a+b
    abc
    abc
    true
    false
    true

    ababab
    true
    1
    20
    7
    x
    AB!
    """#

    // MARK: - 进程内装置

    /// 一段程序跑出来的结果。
    private enum Outcome: Equatable {
        /// 跑完了，附打印出来的行。
        case ran([String])
        /// 被拒了——文本是那条例外的说明。
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。
    private static func attempt(_ source: String) -> Outcome {
        let name = "扩展块探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(
                fileName: name,
                module: try FrontEnd.passes(module: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "扩展块", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：扩展块的新方法、同名覆盖与泛型容器形参在解释器腿逐行产生手写期望。
    @Test("解释器腿：扩展块语料逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：目标类型未声明时仍在降载层响亮拒绝， 行不通  静默丢弃方法体。
    /// 这是驳回性测量：扩展块放行面只加宽到内建类型，未知名与特征的拒绝不动。
    @Test("未声明的扩展目标仍被拒")
    func unknownExtensionTargetIsRejected() throws {
        let source = #"""
        ((不存在))
        做|self() -> (I32,):
            return 1

        main|func() -> ():
            print(1)
            return
        """#
        guard case .refused(let message) = Self.attempt(source) else {
            Issue.record("未声明的扩展目标应被拒，实际跑出了读数")
            return
        }
        #expect(message.contains("未声明为可归并的类型"), "实际说明：\(message)")
    }

    // MARK: - 命令行两腿

    /// 取被测命令行：优先环境变量，其次自寻构建产物。
    /// 两者都取不到 ⇒ 裸跑记已知问题、CI 记失败，不静默通过。
    private func cliPath() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

    /// 解析 LLVM 工具链**目录**（`PINI_LLVM_BIN` 是目录，不是可执行文件路径）；
    /// 取不到 ⇒ nil（调用方响亮跳过 `run-llvm` 腿）。
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
              let text = String(decoding: data, as: UTF8.self)
              .split(separator: "\n").first
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

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-stdlib-extension-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 意图：同一语料经命令行 `run` 逐行等于同一份手写期望。
    @Test("命令行 run 腿：扩展块语料逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stdlib-extension.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm`（发射器 + 运行时段 shim）逐行等于同一份期望。
    /// lli 取不到 ⇒ 响亮跳过（ 行不通  不静默通过）。
    @Test("命令行 run-llvm 腿：扩展块语料逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stdlib-extension.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }
}
