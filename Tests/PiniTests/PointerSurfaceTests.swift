import Foundation
import Testing

/// 指针在两通道上的差分读数。每条都写死「现在是多少」：修好一侧时这里先红，
/// 提示把本文件与 `tools/ir-parity-baseline.tsv` 的登记一起改，而不是让差异悄悄消失。
@Suite("指针差分现状")
struct PointerSurfaceTests: Sendable {

    // MARK: - 语料

    /// `&x` 之后写 x：解释器取快照，LLVM 取真地址。两种实现都能跑完，只有读数不同。
    private static let addressOfSource = """
        main|func() -> ():
            var x: I64 = 7
            var p = unsafe (&x)
            x = 9
            print(unsafe load(p))
            return
        """

    /// `**I64`：解释器在 `&p` 上停下，LLVM 正常读出两层。
    private static let doublePointerSource = """
        main|func() -> ():
            var x: I64 = 7
            var p: *I64 = unsafe (&x)
            var pp: **I64 = unsafe (&p)
            print(unsafe load(unsafe load(pp)))
            return
        """

    // MARK: - 差分

    @Test("&x 之后写 x：解释器读 7、LLVM 读 9 —— 已裁统一到真引用，解释器待修")
    func addressOfDiverges() throws {
        guard let cli = cliOrSkip(needsLLVM: false) else { return }
        let interpreted = try run(cli, channel: "run", source: Self.addressOfSource)
        #expect(interpreted.status == 0, "解释器失败：\(interpreted.stderr)")
        #expect(interpreted.stdout == "7\n", "解释器读数：\(interpreted.stdout)")

        guard let llvmCLI = cliOrSkip(needsLLVM: true) else { return }
        let compiled = try run(llvmCLI, channel: "run-llvm", source: Self.addressOfSource)
        #expect(compiled.status == 0, "LLVM 失败：\(compiled.stderr)")
        #expect(compiled.stdout == "9\n", "LLVM 读数：\(compiled.stdout)")
    }

    @Test("**I64：解释器停在 E5-006，LLVM 打出 7 —— 解释器待修")
    func doublePointerDiverges() throws {
        guard let cli = cliOrSkip(needsLLVM: false) else { return }
        let interpreted = try run(cli, channel: "run", source: Self.doublePointerSource)
        #expect(interpreted.status != 0, "解释器现在应当失败；若已修好，改这条期望与基线")
        #expect(interpreted.stderr.contains("E5-006"), "解释器报错：\(interpreted.stderr)")

        guard let llvmCLI = cliOrSkip(needsLLVM: true) else { return }
        let compiled = try run(llvmCLI, channel: "run-llvm", source: Self.doublePointerSource)
        #expect(compiled.status == 0, "LLVM 失败：\(compiled.stderr)")
        #expect(compiled.stdout == "7\n", "LLVM 读数：\(compiled.stdout)")
    }

    // MARK: - 命令行

    private func cliOrSkip(needsLLVM: Bool) -> String? {
        var keys = ["PINI_CLI_BIN"]
        if needsLLVM { keys.append("PINI_LLVM_BIN") }
        guard PiniTestEnvironment.requireToolchain(keys) else { return nil }
        return PiniTestEnvironment.cliPath()
    }

    private func run(
        _ cli: String, channel: String, source: String
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-pointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.pini")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [channel, "probe.pini"]
        process.currentDirectoryURL = directory
        process.environment = PiniTestEnvironment.childEnvironment()
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
}
