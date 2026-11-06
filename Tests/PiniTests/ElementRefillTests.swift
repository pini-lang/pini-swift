import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniHost

/// 内建容器成员的返回类型按接收者元素回填：`get` 给 `Optional<T>`、`getUnchecked` 给 `T`，
/// 字典的同一对按值类型。三条腿：解释器（进程内 `ProgramRunner`，恒跑）· 命令行 `run` · 命令行 `run-llvm`。
@Suite("ElementRefill")
struct ElementRefillTests: Sendable {

    // MARK: - 语料与手写期望

    /// 一行一个读数。越界取 `none` 与未越界取 `some` 各一条，证明宽容与断言两条通道都还在。
    private static let corpus = #"""
    main|func() -> ():
        var a = [10, 20, 30]
        var g = a.get(1)
        match g:
            case some(v,): print(v + 1)
            case none: print("none")
        print(a.get(3))
        print(a.getUnchecked(0) + 1)
        var d = {"k" = 7}
        var dg = d.get("k")
        match dg:
            case some(v,): print(v * 2)
            case none: print("none")
        print(d.get("z"))
        print(d.getUnchecked("k") * 2)
        return
    """#

    /// 手写期望（逐行；不含尾换行）。第三行钉越界得 `none`；末尾两行钉字典值类型按 `V` 回填。
    private static let expected = #"""
    21
    none
    11
    14
    none
    14
    """#

    /// `last` / `pop` 的元素类型语料。末两行取字符串元素，让双通道都走一遍「元素份额跟着元组走」。
    private static let tailCorpus = #"""
    main|func() -> ():
        var a = [10, 20, 30]
        print(a.last() + 1)
        var p = a.pop()
        print(p.0)
        print(p.1 + 1)
        var words = ["x", "yy"]
        print(words.last() + "!")
        var w = words.pop()
        print(w.0)
        print(w.1)
        return
    """#

    private static let tailExpected = #"""
    31
    [10, 20]
    31
    yy!
    [x]
    yy
    """#

    // MARK: - 进程内装置

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    private static func attempt(_ source: String) -> Outcome {
        let name = "元素回填探针.pini"
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
            try runner.run(package: Package(name: "元素回填", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：宽容读与断言读的返回类型都跟随接收者，逐行等于手写期望。
    @Test("解释器腿：get / getUnchecked 逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        guard case .ran(let lines) = Self.attempt(Self.corpus) else {
            Issue.record("语料应可跑，实际被拒：\(Self.attempt(Self.corpus))")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：`last` / `pop` 的返回值就是元素本身，能直接参与算术 —— 类型若是 `Any` 这一行写不出来。
    @Test("解释器腿：last / pop 的元素类型可直接参与运算")
    func tailMembersCarryTheElementType() throws {
        guard case .ran(let lines) = Self.attempt(Self.tailCorpus) else {
            Issue.record("语料应可跑，实际被拒：\(Self.attempt(Self.tailCorpus))")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.tailExpected)
    }

    /// 意图：空数组上 `last` / `pop` 走断言通道 —— 与 `xs[len(xs) - 1]` 同一条退出，
    ///  行不通  交出 null：静态类型是元素类型，null 会让类型与值脱钩。
    @Test("解释器腿：空数组的 last / pop 终止")
    func emptyTailTerminates() throws {
        let empty = #"""
        main|func() -> ():
            var e = [1, 2].slice(0, 0)
            print(e.last())
            return
        """#
        guard case .refused = Self.attempt(empty) else {
            Issue.record("空数组的 last 应在运行时段终止，实际跑出了读数")
            return
        }
        let popped = #"""
        main|func() -> ():
            var e = [1, 2].slice(0, 0)
            print(e.pop())
            return
        """#
        guard case .refused = Self.attempt(popped) else {
            Issue.record("空数组的 pop 应在运行时段终止，实际跑出了读数")
            return
        }
    }

    /// 意图：`get` 的越界答案与 `getUnchecked` 的断言职责分开， 行不通  混成一条通道。
    @Test("越界读：get 给 none，getUnchecked 终止")
    func outOfRangeSplitsByChannel() throws {
        let source = #"""
        main|func() -> ():
            var a = [1, 2]
            print(a.get(5))
            return
        """#
        guard case .ran(let lines) = Self.attempt(source) else {
            Issue.record("宽容读不该被拒")
            return
        }
        #expect(lines == ["none"])

        let unchecked = #"""
        main|func() -> ():
            var a = [1, 2]
            print(a.getUnchecked(5))
            return
        """#
        guard case .refused = Self.attempt(unchecked) else {
            Issue.record("越界的 getUnchecked 应在运行时段终止，实际跑出了读数")
            return
        }
    }

    // MARK: - 命令行两腿

    private func cliPath() -> String? {
        let cli = PiniTestEnvironment.cliPath()
        guard PiniTestEnvironment.requireToolchain(available: cli != nil, missing: "PINI_CLI_BIN")
        else { return nil }
        return cli
    }

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
            .appendingPathComponent("pini-element-refill-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 意图：同一语料经命令行 `run` 逐行等于同一份手写期望。
    @Test("命令行 run 腿：元素回填语料逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("element-refill.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm` 逐行等于同一份期望 —— 字典的宽容读走 `contains` 先行那条新分支。
    /// lli 取不到 ⇒ 响亮跳过（ 行不通  不静默通过）。
    @Test("命令行 run-llvm 腿：元素回填语料逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("element-refill.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 把一段语料写进临时文件后交给命令行；`run-llvm` 需要调用方先备好工具链目录。
    private func runCLI(
        _ source: String, subcommand: String, llvmDir: String? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let cli = cliPath()!
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tail-members.pini")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let environment = llvmDir.map { ["PINI_LLVM_BIN": $0] } ?? [:]
        return try launch(cli, [subcommand, file.path], environment: environment)
    }

    /// 意图：末元素语料经命令行 `run` 与进程内解释器逐行一致。
    @Test("命令行 run 腿：last / pop 语料逐行等于手写期望")
    func cliRunTailLeg() throws {
        guard cliPath() != nil else { return }
        let result = try runCLI(Self.tailCorpus, subcommand: "run")
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.tailExpected + "\n")
    }

    /// 意图：`run-llvm` 里 `last` / `pop` 不再是未定义符号 —— 元素按接收者类型读回，计数元素各留一份。
    @Test("命令行 run-llvm 腿：last / pop 语料逐行等于手写期望")
    func cliLLVMTailLeg() throws {
        guard cliPath() != nil else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let result = try runCLI(Self.tailCorpus, subcommand: "run-llvm", llvmDir: llvmDir)
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.tailExpected + "\n")
    }

    /// 意图：`run-llvm` 上空数组的 `pop` 也终止（非零退出、无读数），与解释器同一条判据。
    @Test("命令行 run-llvm 腿：空数组的 pop 终止")
    func cliLLVMEmptyPopTerminates() throws {
        guard cliPath() != nil else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let source = #"""
        main|func() -> ():
            var e = [1, 2].slice(0, 0)
            print(e.pop())
            return
        """#
        let result = try runCLI(source, subcommand: "run-llvm", llvmDir: llvmDir)
        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }
}
