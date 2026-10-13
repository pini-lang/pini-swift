import Foundation
@testable import PiniCore
import Testing

/// 字符串内建 `trimLeft` / `trimRight` / `indexOf` 的宿主单测。
///
/// 右端 = **手写期望**（⛔ 不是从某次运行输出抄来的）；语料与期望同源同版。
/// 三条腿：解释器（进程内 `ProgramRunner`，恒跑）· 命令行 `run` · 命令行
/// `run-llvm`（后两腿经构建产物，自寻二进制；取不到 ⇒ 响亮跳过，⛔ 不静默通过）。
///
/// 覆盖：三内建逐行判别式 + 边界（空串 / 全空格 / 首尾混合 / tab 不剥 /
/// 空 needle ⇒ 0 / 未找到 ⇒ −1 / 多字节字素单位）+ LLVM 腿的发射器与
/// 新运行时段 shim（`bk_string_trim_left` / `bk_string_trim_right` /
/// `bk_string_index_of`）。
@Suite("StringBuiltins")
struct StringBuiltinTests {

    // MARK: - 语料与手写期望

    /// 一行一个读数，全部经 `print` 出可观测文本。
    /// ⚠️ raw 字符串：`\t` 在此是**两字符**字面（到 Pini 词法层才成为制表符）——
    /// 普通多行串会把它静默变成真制表符，语料被悄悄改写。
    private static let corpus = #"""
    main|func() -> ():
        var s = "  ab  "
        print("t1", "[" + s.trimLeft() + "]")
        print("t2", "[" + s.trimRight() + "]")
        print("t3", len("\tab".trimLeft()))
        print("t4", len("ab\t".trimRight()))
        print("t5", "[" + "   ".trimLeft() + "]")
        print("t6", "[" + "".trimRight() + "]")
        print("t7", "[" + "ab".trimLeft() + "]")
        print("t8", "[" + " x ".trimLeft() + "][" + " x ".trimRight() + "]")
        print("i1", "hello.world".indexOf("o"))
        print("i2", "hello.world".indexOf("z"))
        print("i3", "hello".indexOf(""))
        print("i4", "".indexOf("a"))
        print("i5", "中文测试".indexOf("试"))
        print("i6", "abc".indexOf("abc"))
        return
    """#

    /// 手写期望（逐行；⛔ 不含尾换行——raw 串的尾换行被闭合符吃掉）。
    ///
    /// 其中三条同时是**驳回性测量**的落点：`t3`/`t4` 钉住「tab 不被剥」
    /// （只剥空格的实现会得 2）；`i2` 钉住「未找到是 −1 而非 0」；
    /// `i3` 钉住「空 needle 是 0 而非 −1」；`i5` 钉住「单位是字素而非字节」
    /// （按字节实现会得 6）。
    private static let expected = #"""
    t1 [ab  ]
    t2 [  ab]
    t3 3
    t4 3
    t5 []
    t6 []
    t7 [ab]
    t8 [x ][ x]
    i1 4
    i2 -1
    i3 0
    i4 -1
    i5 3
    i6 0
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
        let name = "字符串内建探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(
                fileName: name,
                module: ConstantFolder.foldConstants(in: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "字符串内建", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    /// 意图：三内建在解释器腿逐行产生手写期望。
    @Test("解释器腿：trim/indexOf 逐行等于手写期望")
    func interpreterLegMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    /// 意图：成员内建实参个数错配在静态层被拒（⛔ 不静默按零值跑）。
    /// 这是驳回性测量：断言「不该发生的确实没发生」——错配形态不得跑出读数。
    @Test(arguments: [
        #""ab".indexOf("a", "b")"#,
        #""ab".trimLeft("x")"#,
        #""ab".indexOf()"#,
        #""ab".trimRight(1)"#,
    ])
    func arityMismatchIsStaticallyRejected(expression: String) throws {
        let source = #"""
        main|func() -> ():
            print(\#(expression))
            return
        """#
        guard case .refused = Self.attempt(source) else {
            Issue.record("实参个数错配应被静态层拒，实际跑出了读数：\(expression)")
            return
        }
    }

    // MARK: - 命令行两腿

    /// 取被测命令行：优先环境变量，其次自寻构建产物。
    /// 两者都取不到 ⇒ 响亮跳过（⛔ 不静默通过）。
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
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 命令行两腿本次未取（跳过）") {
            Issue.record("字符串内建的命令行两腿本次没有跑")
        }
        return nil
    }

    /// 解析 LLVM 工具链**目录**（`PINI_LLVM_BIN` 是目录，不是可执行文件路径）；
    /// 取不到 ⇒ nil（调用方响亮跳过 `run-llvm` 腿）。
    private func llvmToolchainDir() -> String? {
        let fromEnv = ProcessInfo.processInfo.environment["PINI_LLVM_BIN"] ?? ""
        if !fromEnv.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnv + "/lli") {
            return fromEnv
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["lli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-string-builtins-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 意图：同一语料经命令行 `run` 逐行等于同一份手写期望。
    @Test("命令行 run 腿：trim/indexOf 逐行等于手写期望")
    func cliRunLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("string-builtins.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(cli, ["run", file.path])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }

    /// 意图：同一语料经 `run-llvm`（发射器 + 运行时段 shim）逐行等于同一份期望。
    /// lli 取不到 ⇒ 响亮跳过（⛔ 不静默通过）。
    @Test("命令行 run-llvm 腿：trim/indexOf 逐行等于手写期望")
    func cliLLVMLegMatchesExpectation() throws {
        guard let cli = cliPath() else { return }
        guard let llvmDir = llvmToolchainDir() else {
            withKnownIssue("lli 取不到（PINI_LLVM_BIN 未设且 PATH 里没有）⇒ run-llvm 腿本次未跑") {
                Issue.record("run-llvm 腿本次没有跑：LLVM 工具链不可用")
            }
            return
        }
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("string-builtins.pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        let result = try launch(
            cli, ["run-llvm", file.path], environment: ["PINI_LLVM_BIN": llvmDir])
        #expect(result.status == 0, "stderr: \(result.stderr)")
        #expect(result.stdout == Self.expected + "\n")
    }
}
