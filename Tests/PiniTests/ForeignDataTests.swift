import Foundation
import Testing
import PiniHost

/// 外部数据符号的三条路径：读、取址、写。
/// 判据落在「写后再读」上 —— 副本与真符号地址的差别只有写回时才显形，只读一遍两种实现都过。
@Suite("外部数据符号")
struct ForeignDataTests {
    private enum Channel: String, CaseIterable {
        case interpreter = "run"
        case llvm = "run-llvm"

        var label: String { self == .interpreter ? "解释器" : "LLVM" }
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// 命令行产物：只认环境变量。兜底找旧产物会让这条用例对着没有数据符号支持的二进制判红。
    private func cliPath() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnvironment.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnvironment) {
            return fromEnvironment
        }
        return nil
    }

    private func run(_ channel: Channel, source: String) throws -> RunResult? {
        guard let cli = cliPath() else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-foreign-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("prog.pini")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [channel.rawValue, script.path]
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    @Test("取址写回后读到新值，两条通道一致")
    func dataSymbolRoundTrip() throws {
        /// 意图：`&符号` 给的是符号地址本身，`store` 写进去的值下一次读必须见到。
        /// 若哪条通道把取址做成了值快照，写回就落在副本上，`after` 停在旧值。
        let source = #"""
        [libc|foreign]
        optind: I32

        main|func() -> (I32,):
            var pointer = unsafe &optind
            unsafe store(pointer, 42)
            var after = unsafe optind
            print(after)
            return 0
        """#
        guard cliPath() != nil else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ 外部数据符号的两通道用例本次未取") {
                Issue.record("没有命令行产物可跑")
            }
            return
        }
        for channel in Channel.allCases {
            guard let result = try run(channel, source: source) else { continue }
            #expect(result.status == 0, "\(channel.label) 退出码 \(result.status)：\(result.stderr)")
            #expect(result.stdout == "42\n", "\(channel.label) 读到 \(result.stdout.debugDescription)")
        }
    }

    @Test("|readonly 的外部符号拒绝直接 store")
    func readonlySymbolRejectsStore() throws {
        /// 意图：`readonly` 的写侧禁令落在语义期，`check` 就该红，不等运行。
        let source = #"""
        [libc|foreign]
        optind|readonly: I32

        main|func() -> (I32,):
            unsafe store(&optind, 5)
            return 0
        """#
        guard cliPath() != nil else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ readonly 用例本次未取") {
                Issue.record("没有命令行产物可跑")
            }
            return
        }
        guard let result = try run(.interpreter, source: source) else { return }
        let output = result.stdout + result.stderr
        #expect(result.status != 0, "只读符号的写入应被拒，实际通过：\(output)")
        #expect(output.contains("readonly"), "拒绝理由应点出 readonly，实际：\(output)")
    }
}
