import Foundation
import Testing

/// 运行时陷阱的**进程退出码**判据：解释器与 LLVM 两通道给同一个码（1）。
/// 靶 = 「程序因运行时错误退出」在进程边界上的可观察形态 —— 退出码与 stderr 那一条消息。
/// ⚠️ 串行：每条用例都要起 `pini run` / `pini run-llvm` 子进程，并行跑会把机器占满。
@Suite(.serialized)
struct PanicExitCodeTests {

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

        /// 读失败消息的**可辨认片段**：两通道各自的实现决定措辞，故按通道手写。
        var readFailureMessage: String {
            self == .interpreter ? "无法读取文件" : "could not read the file"
        }
    }

    /// 崩溃栈的特征串：由运行时自己打印的陷阱消息里**不该**出现。
    private static let crashMarkers = [
        "Stack dump", "PLEASE submit a bug report", "Aborted"
    ]

    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-panic-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
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
            Issue.record("陷阱退出码的两通道判据本次没有跑")
        }
        return nil
    }

    /// 把源码写成沙盒里的 `prog.pini`，在沙盒里跑**一条**通道。
    /// `extraEnvironment` 叠加在继承环境之上（空串的值即「显式置空」）。
    private func runOn(
        _ channel: Channel, source: String, sandbox: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> RunResult? {
        guard let cli = cliPath() else { return nil }
        let script = sandbox.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [channel.commandName, script.path]
        process.currentDirectoryURL = sandbox
        if !extraEnvironment.isEmpty {
            process.environment =
                ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        }
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

    /// 读不存在的文件：两通道都走「运行时错误」这条路。
    private var readFailureSource: String {
        """
        main|func() -> ():
            print("before-trap")
            print(readFile("no-such-entry.txt"))
            return
        """
    }

    // MARK: - 判据 1：IO 失败的退出码

    @Test("readFile 读不到文件时，两通道退出码都是 1")
    func readFileFailureExitsWithOneOnBothChannels() throws {
        /// 意图：IO 失败在两条通道上都是「运行时错误」⇒ 进程退出码 1。
        /// 驳回性：`abort()` 终止的实现在此给出 134，两条断言同时红。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: readFailureSource, sandbox: sandbox)
            else { return }
            #expect(
                run.status == 1,
                "\(run.label)通道退出码 \(run.status)（期望 1）/ stderr \(run.stderr.prefix(300))")
        }
    }

    // MARK: - 判据 2：stderr 的消息形态

    @Test("陷阱消息落在 stderr，且 LLVM 通道不带崩溃栈")
    func trapMessageLandsOnStderrWithoutCrashDump() throws {
        /// 意图：两通道各打印自己那条可辨认的错误消息；消息存在即证明进程终止前走到了陷阱。
        /// 驳回性：`abort()` 的实现除了 `Stack dump:` 与「PLEASE submit a bug report」，还多出整屏栈。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        /// 消息文本由两通道各自的实现决定，故期望按通道手写。
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: readFailureSource, sandbox: sandbox)
            else { return }
            #expect(!run.stderr.isEmpty, "\(run.label)通道 stderr 为空：陷阱消息不见了")
            let needle = channel.readFailureMessage
            #expect(
                run.stderr.contains(needle),
                "\(run.label)通道 stderr 里没有消息「\(needle)」：\(run.stderr.prefix(300))")
            for marker in Self.crashMarkers {
                #expect(
                    !run.stderr.contains(marker),
                    "\(run.label)通道 stderr 带崩溃栈特征「\(marker)」：\(run.stderr.prefix(300))")
            }
        }
    }

    // MARK: - 判据 3：陷阱之前的输出

    @Test("陷阱之前 print 的那一行在两通道都落地")
    func outputBeforeTrapSurvivesOnBothChannels() throws {
        /// 意图：退出前标准流被 flush ⇒ 先 `print` 再触发陷阱，那一行仍在 stdout 里。
        /// 驳回性：不 flush 的终止路径（`abort()`）在 stdout 是管道时丢掉整行，只剩下陷阱消息。

        /// ⚠️ stdout 指向管道时 libc 的缓冲是满块而非行缓冲 —— 这一条才有分辨力。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let expected = ["before-trap"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: readFailureSource, sandbox: sandbox)
            else { return }
            #expect(
                lines(run.stdout) == expected,
                "\(run.label)通道 stdout 与手写期望不符：\(run.stdout) / stderr \(run.stderr.prefix(300))"
            )
        }
    }

    // MARK: - 判据 4：逃逸通道

    @Test("`PINI_PANIC_ABORT` 非空时 LLVM 通道退出码回到 134")
    func abortEscapeHatchRestoresSignalExitCode() throws {
        /// 意图：逃逸通道交出 core dump，退出码随之不再是 1；忽略该变量的实现无法与判据 1 区分。
        /// ⚠️ 134 = 128 + SIGABRT(6)：`lli` 被信号终止，命令行按信号量回传。
        /// ⚠️ 该变量只管运行时 shim 的陷阱点；解释器通道的退出码出自命令行对 `RuntimeError` 的处理，仍为 1。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        guard
            let llvm = try runOn(
                .llvm, source: readFailureSource, sandbox: sandbox,
                extraEnvironment: ["PINI_PANIC_ABORT": "1"])
        else { return }
        #expect(
            llvm.status == 134,
            "\(llvm.label)通道退出码 \(llvm.status)（期望 134）/ stderr \(llvm.stderr.prefix(300))")

        guard
            let interpreted = try runOn(
                .interpreter, source: readFailureSource, sandbox: sandbox,
                extraEnvironment: ["PINI_PANIC_ABORT": "1"])
        else { return }
        #expect(
            interpreted.status == 1,
            "\(interpreted.label)通道退出码 \(interpreted.status)（期望 1）")
    }

    // MARK: - 判据 5：另一类陷阱

    @Test("数组下标越界时，两通道退出码都是 1")
    func arrayIndexOutOfBoundsExitsWithOneOnBothChannels() throws {
        /// 意图：越界与 IO 失败同属运行时陷阱 ⇒ 同一退出码，与该陷阱由哪一层判定无关。
        /// 驳回性：只把 IO 那条路改成 `exit(1)`、越界仍 `abort()` 的实现让本用例红。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let source = """
            main|func() -> ():
                print("before-trap")
                var a = [1, 2, 3]
                print(a[5])
                return
            """
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, sandbox: sandbox)
            else { return }
            #expect(
                run.status == 1,
                "\(run.label)通道退出码 \(run.status)（期望 1）/ stderr \(run.stderr.prefix(300))")
        }
    }
}
