import Foundation
import Testing

/// 入口判读一致性：**同一条规则必须由四条入口同判**。
///
/// 存在理由（2026-10-01 实测）：闭包捕获的声明检查（`E3-008`）此前只在解释侧生效 ——
/// 同一份源 `check` / `run` 报 `E3-008`，而 `emit` / `compile` 照跑并产出目标码。
/// 语法与语义检查的位置在**两路之前**；只跑在一条路之前的检查不是检查，而是那条路的脾气
/// —— 于是「这条规则拦不拦得住」取决于你从哪条门进来，这本身就是缺陷。
///
/// ⚠️ 本套件刻意同时锁定**两个方向**：拒绝要四条都拒且判定码相同（阴性件），
/// 接受要四条都放行（阳性对照）—— 只有前者时，「凡闭包一律拒」也能过判据。
struct EntryParityTests {

    /// 四条入口。前两条不带工具链，后两条要 clang/LLVM。
    private static let entries = ["check", "run", "emit", "compile"]

    private static var fixturesDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").path
    }

    private func fixtureFile(_ fixture: String) -> URL {
        URL(fileURLWithPath: Self.fixturesDirectory).appendingPathComponent(fixture + ".pini")
    }

    /// 一条入口对一份夹具的判读，压缩成一个可比较的字符串：`接受` 或 `拒绝 <判定码>`。
    ///
    /// 取**判定码**而不是退出码：四条入口的退出码都能是 1，那是「拒了」而不是「按哪条规则拒的」，
    /// 而本缺陷恰恰是「同一条规则有没有被同一条路执行」。
    private func verdict(entry: String, fixture: URL, scratch: URL) throws -> String {
        var arguments = [entry, fixture.path]
        // `emit` 不带输出路径会把 IR 打到 stdout —— 给个落点，免得读数混进标准输出。
        if entry == "emit" {
            arguments.append(scratch.appendingPathComponent("\(UUID().uuidString).ll").path)
        }
        let result = try launch(arguments)
        guard result.status == 0 else {
            return "拒绝 " + (firstCode(in: result.stderr) ?? "rc=\(result.status)")
        }
        return "接受"
    }

    /// 命令行诊断里的首条判定码，与 `ContractReferenceTests` 同口径。
    private func firstCode(in stderr: String) -> String? {
        guard let range = stderr.range(of: #"\[E[0-9]+-[0-9]+\]"#, options: .regularExpression)
        else { return nil }
        return String(stderr[range].dropFirst().dropLast())
    }

    private func launch(_ arguments: [String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let binary = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
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

    /// 缺 `PINI_CLI_BIN` 时**响亮跳过**（同 `ContractReferenceTests` 的既有形态）：
    /// 记一条已知问题，而不是让用例静默通过 —— 静默通过与「判据跑过了且是绿的」外观相同。
    private func requireCLI() -> String? {
        let cli = ProcessInfo.processInfo.environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, FileManager.default.isExecutableFile(atPath: cli) else {
            withKnownIssue("未提供可执行的 PINI_CLI_BIN ⇒ 入口一致性判据本次未取（跳过 +1）") {
                Issue.record("入口一致性未取：本批判据本次没有跑")
            }
            return nil
        }
        return cli
    }

    private func scratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-entry-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("闭包捕获未声明：四条入口同判拒绝，且判定码都是 E3-008")
    func undeclaredCaptureRejectedByEveryEntry() throws {
        guard requireCLI() != nil else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = fixtureFile("closure-capture-undeclared")

        for entry in Self.entries {
            let got = try verdict(entry: entry, fixture: fixture, scratch: scratch)
            #expect(
                got == "拒绝 E3-008",
                "\(entry)：期望四条入口同判「拒绝 E3-008」，实际 \(got) —— 检查只跑在一条路之前时，这条读数会分叉")
        }
    }

    @Test("闭包捕获已声明：四条入口全部放行")
    func declaredCaptureAcceptedByEveryEntry() throws {
        guard requireCLI() != nil else { return }
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = fixtureFile("closure-capture-declared")

        for entry in Self.entries {
            let got = try verdict(entry: entry, fixture: fixture, scratch: scratch)
            #expect(got == "接受", "\(entry)：期望放行，实际 \(got)")
        }
    }
}
