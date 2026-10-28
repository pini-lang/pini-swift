import Foundation
import Testing

/// 可接住的 IO（`tryReadFile` / `tryWriteFile` / `tryAppendFile`）的**两通道**判据。
///
/// 靶 = 「同一个 IO 操作，失败作为值返回而不是终止进程」。与陷阱版**并存**：
/// 两条路的差别只在调用点写的名字，所以本套件同时钉住两侧 —— 一条要 status 0 并拿到
/// `err`，另一条要 status 1。只钉一侧的判据会让「顺手把陷阱版也改成返回值」判绿。
///
/// ⚠️ 串行：每条用例都起 `run` / `run-llvm` 子进程，并行会把机器占满。
@Suite(.serialized)
struct TryIOBuiltinTests {

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
            .appendingPathComponent("pini-try-io-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 兜底产物**是否认识本批三个内建**。
    ///
    /// ⚠️ 为什么需要这一问：仓内的 `.build/debug/pini` 是主树产物，可能**早于**新内建
    /// （本仓构建常落独立 scratch，仓内那份因此长期陈旧）。拿一份不认识 `try*` 的二进制
    /// 跑本套件，红在「内建不存在」，读起来却像「实现错了」—— 那是假红。
    /// 环境变量明示时不探测：那是「我知道自己在测什么」的信号。
    private static func cliUnderstandsTryIO(_ cli: String) -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-try-io-probe-" + UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true))
            != nil
        else { return false }
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("probe.pini")
        let source = #"""
        main|func() -> ():
            match tryWriteFile("p.txt", "x"):
                case ok(v): print("ok")
                case err(e): print("err")
            return
        """#
        guard (try? source.write(to: script, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["check", script.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 定位命令行产物：先看环境变量，再按仓根兜底（兜底那一支要先验它认识新内建）。
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
            if Self.cliUnderstandsTryIO(candidate) { return candidate }
            withKnownIssue("仓内兜底产物早于 `try*` 三内建 ⇒ 两通道用例本次未取（PINI_CLI_BIN 可指定当前构建）")
            {
                Issue.record("可接住 IO 的两通道判据本次没有跑：\(candidate) 不认识新内建")
            }
            return nil
        }
        withKnownIssue("既未提供 PINI_CLI_BIN，也未找到命令行构建产物 ⇒ 两通道用例本次未取") {
            Issue.record("可接住 IO 的两通道判据本次没有跑")
        }
        return nil
    }

    /// 把源码写成沙盒里的 `prog.pini`，在沙盒里跑**一条**通道。
    /// 脚本落在沙盒里 ⇒ 裸相对路径（不带 `./`）解析到入口目录，正是被测的路径规则。
    private func runOn(_ channel: Channel, source: String, sandbox: URL) throws -> RunResult? {
        guard let cli = cliPath() else { return nil }
        let script = sandbox.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [channel.commandName, script.path]
        process.currentDirectoryURL = sandbox
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

    // MARK: - 语料

    /// 写 → 读回 → 追加 → 再读回。期望值手写，两通道各自与它比。
    private var roundTripSource: String {
        #"""
        main|func() -> ():
            match tryWriteFile("t.txt", "hello"):
                case ok(v):
                    print("write-ok")
                case err(e): print("write-err")
            match tryReadFile("t.txt"):
                case ok(s): print(s)
                case err(e): print("read-err")
            match tryAppendFile("t.txt", " world"):
                case ok(v):
                    print("append-ok")
                case err(e): print("append-err")
            match tryReadFile("t.txt"):
                case ok(s): print(s)
                case err(e): print("read-err")
            return
        """#
    }

    private var failingReadSource: String {
        #"""
        main|func() -> ():
            match tryReadFile("no-such-entry-xyz.txt"):
                case ok(s): print("unexpected-ok")
                case err(e):
                    print("read-failed")
                    print(isCancel(e))
            print("still-alive")
            return
        """#
    }

    private var failingWriteSource: String {
        #"""
        main|func() -> ():
            match tryWriteFile("no-such-dir/x.txt", "x"):
                case ok(v): print("unexpected-ok")
                case err(e):
                    print("write-failed")
                    print(isCancel(e))
            match tryAppendFile("no-such-dir/y.txt", "y"):
                case ok(v): print("unexpected-ok")
                case err(e):
                    print("append-failed")
            print("still-alive")
            return
        """#
    }

    /// 陷阱版对照：同一份「读不到」的输入，这一条必须仍然终止进程。
    private var trappedReadSource: String {
        #"""
        main|func() -> ():
            print("before-trap")
            print(readFile("no-such-entry-xyz.txt"))
            return
        """#
    }

    // MARK: - 判据 1：成功路径

    @Test("写 / 读 / 追加三件在成功路径上给出正确内容，且两通道逐字一致")
    func roundTripMatchesHandwrittenExpectationOnBothChannels() throws {
        /// 意图：三个内建的成功路径各走一遍，读回的内容就是刚写的 —— 载荷形态与通道无关。
        /// 驳回性：`!stdout.contains("Pini runtime error")` —— 成功路径上不该出现陷阱文案。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let expected = ["write-ok", "hello", "append-ok", "hello world"]
        var seen: [String] = []
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: roundTripSource, sandbox: sandbox)
            else { return }
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status) / \(run.stderr.prefix(300))")
            #expect(
                lines(run.stdout) == expected,
                "\(run.label)通道输出与手写期望不符：\(run.stdout)")
            #expect(!run.stdout.contains("Pini runtime error"), "\(run.label)通道成功路径上出现陷阱文案")
            seen.append(run.stdout)
        }
        // 两通道逐字相同 —— 单独一条，因为「各自都对」不含「彼此一样」。
        if seen.count == 2 {
            #expect(seen[0] == seen[1], "两通道 stdout 不同：\(seen)")
        }
        // 落盘结果也是判据的一部分：追加确实追加在既有内容之后。
        let written = try String(
            contentsOf: sandbox.appendingPathComponent("t.txt"), encoding: .utf8)
        #expect(written == "hello world", "落盘内容 = \(written)")
    }

    // MARK: - 判据 2：失败读

    @Test("读不到文件时返回 err 且进程继续，err 不标记为取消")
    func readFailureReturnsErrAndKeepsRunning() throws {
        /// 意图：错误作为**值**返回 —— 进程退出码 0，`case err` 那一支被走到。
        /// 驳回性：`isCancel(e)` 必须为 false —— 把 IO 失败当取消错误会让调用方错误地
        /// 走取消分支（那一条在本仓有独立语义）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let expected = ["read-failed", "false", "still-alive"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: failingReadSource, sandbox: sandbox)
            else { return }
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status)（期望 0，可接住不该终止）")
            #expect(lines(run.stdout) == expected, "\(run.label)通道输出：\(run.stdout)")
        }
    }

    // MARK: - 判据 3：失败写与失败追加

    @Test("写与追加到不存在的目录时都返回 err 且进程继续")
    func writeAndAppendFailuresReturnErrAndKeepRunning() throws {
        /// 意图：写侧的两个内建与读侧同一姿态 —— 失败是值，不是终止理由。
        /// 驳回性：`unexpected-ok` 必须**不出现**；出现即说明失败被吞成了成功。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let expected = ["write-failed", "false", "append-failed", "still-alive"]
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: failingWriteSource, sandbox: sandbox)
            else { return }
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status)（期望 0）")
            #expect(lines(run.stdout) == expected, "\(run.label)通道输出：\(run.stdout)")
            #expect(!run.stdout.contains("unexpected-ok"), "\(run.label)通道把失败报成了成功")
        }
    }

    // MARK: - 判据 4：两种失败形态并存

    @Test("同一份读不到的输入：try 版返回 err，陷阱版仍然终止进程")
    func bothFailureFormsCoexistOnTheSameInput() throws {
        /// 意图：本批新增的是**名字**，不是语义替换 —— 陷阱版一字未动，两条路并存。
        /// 驳回性：`try` 版 status 必须是 0、陷阱版必须是 1；两侧相等即说明有一侧被改错了
        /// （要么新增的接不住，要么旧的被顺手改成返回值 —— 后者是静默的破坏性变更）。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for channel in Channel.allCases {
            guard let caught = try runOn(channel, source: failingReadSource, sandbox: sandbox)
            else { return }
            #expect(caught.status == 0, "\(caught.label)通道 try 版退出码 \(caught.status)")

            guard let trapped = try runOn(channel, source: trappedReadSource, sandbox: sandbox)
            else { return }
            #expect(
                trapped.status == 1,
                "\(trapped.label)通道陷阱版退出码 \(trapped.status)（期望 1）/ \(trapped.stderr.prefix(300))"
            )
        }
    }

    // MARK: - 判据 5：ok 载荷是空元组

    @Test("写成功的载荷能绑给 `()` 类型的变量")
    func writeSuccessPayloadIsUnit() throws {
        /// 意图：载荷就是空元组 —— 类型层能把它绑给 `var u: ()`，编译过即证明形态。
        /// 驳回性：若载荷是别的东西（哨兵 I32、Bool……），`check` 会按 `E4-001` 拒绝，
        /// 产物里出现 `E4-001` 或退出码非 0 都算红。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let source = #"""
        main|func() -> ():
            match tryWriteFile("u.txt", "x"):
                case ok(v):
                    var u: () = v
                    print("unit-ok")
                case err(e): print("write-err")
            return
        """#
        for channel in Channel.allCases {
            guard let run = try runOn(channel, source: source, sandbox: sandbox) else { return }
            #expect(run.status == 0, "\(run.label)通道退出码 \(run.status) / \(run.stderr.prefix(300))")
            #expect(lines(run.stdout) == ["unit-ok"], "\(run.label)通道输出：\(run.stdout)")
        }
    }

    // MARK: - 判据 6：路径解析与陷阱版同解

    @Test("裸相对路径落在入口文件所在目录，与陷阱版同解")
    func bareRelativePathResolvesAgainstEntryDirectory() throws {
        /// 意图：三个 `try*` 内建与陷阱版共用同一套路径解析 —— 裸名拼在程序基准之后。
        /// 驳回性：文件**不得**落在进程当前目录之外的地方；本用例让 CWD 与脚本目录分离，
        /// 若解析走 CWD（或走了别的口径），断言的文件就找不到。
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scriptDir = sandbox.appendingPathComponent("entry")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let source = #"""
        main|func() -> ():
            match tryWriteFile("sub-relative.txt", "landed"):
                case ok(v): print("ok")
                case err(e): print("err")
            return
        """#
        for channel in Channel.allCases {
            guard let cli = cliPath() else { return }
            let script = scriptDir.appendingPathComponent("prog.pini")
            try source.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [channel.commandName, script.path]
            // 刻意让当前目录与脚本目录不同 ⇒ 「走 CWD」的实现在这里露馅。
            process.currentDirectoryURL = sandbox
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "\(channel.label)通道退出码 \(process.terminationStatus)")

            let landed = scriptDir.appendingPathComponent("sub-relative.txt")
            #expect(
                FileManager.default.fileExists(atPath: landed.path),
                "\(channel.label)通道没有把裸名解析到入口目录：\(landed.path)")
            let here = sandbox.appendingPathComponent("sub-relative.txt")
            #expect(
                !FileManager.default.fileExists(atPath: here.path),
                "\(channel.label)通道把裸名解析到了进程当前目录")
            try? FileManager.default.removeItem(at: landed)
        }
    }
}
