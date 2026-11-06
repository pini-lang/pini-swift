import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniHost

/// 内建容器成员的元素类型跟随：`Array<T>.append` / `.slice` 的形参与返回按接收者元素定，
/// `join` 的元素渲染按元素类型走（整型 / 浮点 / 布尔 / 串）。
/// 三条腿：解释器（进程内 `ProgramRunner`，恒跑）· 命令行 `run` · 命令行 `run-llvm`。
@Suite("ArrayMemberTypes")
struct ArrayMemberTypeTests: Sendable {

    // MARK: - 语料与手写期望

    /// 一行一个读数。泛型 `map` 用 `slice(0, 0)` 取同元素的空数组起步 —— 返回值若不是 `Array<T>`
    /// 而是 `Array<Any>`，`append(f(...))` 当场类型不符；空数组 `join` 是空串而非 `null`。
    private static let corpus = #"""
    map|func<T>(f: (T,) -> (T,), arr: Array<T>,) -> (Array<T>,):
        var out = arr.slice(0, 0)
        var i = 0
        while i < len(arr):
            out = out.append(f(arr[i]))
            i = i + 1
        return out

    main|func() -> ():
        print(map<I32>(func (n,) -> (I32,): return n * 2, [1, 2, 3]))
        print(map<String>(func (s,) -> (String,): return s + "!", ["a", "b"]))
        print([1, 2, 3].join("-"))
        print([true, false].join(","))
        print([1.5, 2.5].join("|"))
        print([].join(","))
        var part = [1, 2, 3].slice(0, 2)
        part = part.append(9)
        print(part)
        return
    """#

    /// 手写期望（逐行；不含尾换行）。第二行钉 String 元素同样走通单态化；第六行是空行，钉空数组；
    /// 末行钉 `slice` 的元素类型回填后 `append` 仍收同一元素。
    private static let expected = #"""
    [2, 4, 6]
    [a!, b!]
    1-2-3
    true,false
    1.5|2.5

    [1, 2, 9]
    """#

    // MARK: - 进程内装置

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    private static func attempt(_ source: String) -> Outcome {
        let name = "成员类型探针.pini"
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
            try runner.run(package: Package(name: "成员类型", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：元素类型跟随在解释器腿逐行产生手写期望。
    @Test("解释器腿：成员类型语料逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：`append` 的形参按接收者元素校验， 行不通  让异类元素混进去。
    /// 这是驳回性测量：断言「不该发生的确实没发生」。
    @Test("异类元素追加被静态拒绝")
    func mismatchedAppendIsRejected() throws {
        let source = #"""
        main|func() -> ():
            var a = [1, 2, 3]
            var b = a.append("x")
            print(b)
            return
        """#
        guard case .refused(let message) = Self.attempt(source) else {
            Issue.record("异类元素追加应被拒，实际跑出了读数")
            return
        }
        #expect(message.contains("type mismatch") || message.contains("类型不匹配"), "实际说明：\(message)")
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
            .appendingPathComponent("pini-array-member-types-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 意图：同一语料经命令行 `run` 逐行等于同一份手写期望。
    @Test("命令行 run 腿：成员类型语料逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("array-member-types.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm` 逐行等于同一份期望 —— 覆盖 `join` 的元素渲染与空数组。
    /// lli 取不到 ⇒ 响亮跳过（ 行不通  不静默通过）。
    @Test("命令行 run-llvm 腿：成员类型语料逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            _ = PiniTestEnvironment.requireToolchain(available: false, missing: "PINI_LLVM_BIN")
            return
        }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("array-member-types.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }
}
