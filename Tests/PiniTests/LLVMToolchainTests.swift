import Foundation
import PiniBackendLLVM
import Testing
import PiniHost

/// LLVM 工具链的定位判据。编写的理由：`brew install llvm` 是 keg-only，装完不进 PATH，
/// 而报错文案正是教用户这么装 —— 少了末位兜底，「装好了却找不到」就是常态，且无人发现。
@Suite("LLVM 工具链定位")
struct LLVMToolchainTests {

    @Test("PATH 与 PINI_LLVM_BIN 都没有时，命令行仍能从 Homebrew 前缀找到 lli")
    func cliFallsBackToHomebrewPrefix() throws {
        // 前提自带独立口径，不问产品解析器：解析器坏掉时若也问它，就会得出「这台机器没装
        // LLVM」而安静跳过 —— 那正是本用例要抓的静默。走 apt 的机器没有这两个前缀，跳过。
        guard let prefix = ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/lli") })
        else {
            _ = PiniTestEnvironment.requireToolchain(["PINI_LLVM_BIN"])
            return
        }
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let cli = try #require(PiniTestEnvironment.cliPath())

        let program = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-llvm-probe-\(UUID().uuidString).pini")
        try "main|func() -> ():\n    print(\"ok\")\n    return\n"
            .write(to: program, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: program) }

        // 洗掉 PATH 里所有含 lli 的目录：`swift test` 会注入工具链自带的 LLVM 目录，
        // 不洗的话解析器走 `which` 就命中了，末位兜底这条分支根本没被压到。
        var environment = PiniTestEnvironment.childEnvironment()
        environment.removeValue(forKey: "PINI_LLVM_BIN")
        environment["PATH"] = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            .filter { !FileManager.default.isExecutableFile(atPath: $0 + "/lli") }
            .joined(separator: ":")
        let stillOnPath = ((environment["PATH"] ?? "").split(separator: ":")).contains {
            FileManager.default.isExecutableFile(atPath: String($0) + "/lli")
        }
        #expect(!stillOnPath, "PATH 没洗干净，本用例会失去意义")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["run-llvm", program.path]
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readAllData()
        let errData = err.fileHandleForReading.readAllData()
        process.waitUntilExit()

        let stderr = String(decoding: errData, as: UTF8.self)
        #expect(
            process.terminationStatus == 0,
            "lli 就在 \(prefix)，命令行却没能找到（rc=\(process.terminationStatus)）：\(stderr)")
        #expect(
            String(decoding: outData, as: UTF8.self) == "ok\n",
            "LLVM 腿的输出不符：\(String(decoding: outData, as: UTF8.self).debugDescription)")
    }
}
