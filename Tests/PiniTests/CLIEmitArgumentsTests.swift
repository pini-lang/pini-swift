import Foundation
import Testing

/// 命令行 `emit` 的输出位置：`-o` 必须写到它指的地方，未知选项必须报错。
/// 判据看退出码与文件落点 —— 静默写错文件时退出码仍是 0，只看输出读不出来。
@Suite(.serialized)
struct CLIEmitArgumentsTests {

    private struct RunResult {
        let status: Int32
        let stderr: String
    }

    /// 只认环境变量：仓内兜底可能是旧产物，而 `swift test` 不重建命令行目标。
    private func cliPath() -> String? {
        let fromEnvironment = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        if !fromEnvironment.isEmpty, FileManager.default.isExecutableFile(atPath: fromEnvironment) {
            return fromEnvironment
        }
        return nil
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-emit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeScript(in directory: URL) throws -> URL {
        let script = directory.appendingPathComponent("prog.pini")
        try "main|func() -> ():\n    print(\"x\")\n    return\n"
            .write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private func run(_ arguments: [String], in directory: URL) throws -> RunResult {
        let cli = try #require(cliPath(), "没有命令行产物")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        _ = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stderr: String(decoding: errData, as: UTF8.self))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 没有 PINI_CLI_BIN 时记一条 known issue 并让用例退出，不拿旧产物判红。
    private func requireCLI() -> Bool {
        guard cliPath() == nil else { return true }
        withKnownIssue("未提供 PINI_CLI_BIN ⇒ 本批判据本次未取（跳过 +1）") {
            Issue.record("没有命令行产物可跑")
        }
        return false
    }

    @Test("emit -o 写到指定路径，不生成名为 -o 的文件")
    func dashOWritesTheNamedFile() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeScript(in: dir)
        let output = dir.appendingPathComponent("prog.ll")
        let result = try run(["emit", script.path, "-o", output.path], in: dir)
        #expect(result.status == 0, "退出码 \(result.status)：\(result.stderr)")
        #expect(exists(output), "没有写出目标文件")
        #expect(!exists(dir.appendingPathComponent("-o")), "不该生成名为 -o 的文件")
    }

    @Test("emit 的未知选项报错，不当成输出路径")
    func unknownOptionIsRejected() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeScript(in: dir)
        let result = try run(["emit", script.path, "--nope"], in: dir)
        #expect(result.status != 0, "未知选项应当报错")
        #expect(result.stderr.contains("--nope"), "报错点名该选项：\(result.stderr)")
        #expect(!exists(dir.appendingPathComponent("--nope")), "不该生成名为 --nope 的文件")
    }

    @Test("emit 的位置参数输出仍然可用")
    func positionalOutputStillWorks() throws {
        guard requireCLI() else { return }
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeScript(in: dir)
        let output = dir.appendingPathComponent("prog.ll")
        let result = try run(["emit", script.path, output.path], in: dir)
        #expect(result.status == 0, "退出码 \(result.status)：\(result.stderr)")
        #expect(exists(output), "没有写出目标文件")
    }
}
