import Foundation
import Testing
import PiniHost

/// 名义值的持有与寿命：三条都属同一族 —— 「值活不过它应该活过的那个位置」，且都只在原生路径上发作
/// （解释器用 Swift 值，帧退不掉内容）⇒ 判据以解释器的行为为权威。三条归因：枚举构造对载荷只做裸 store ·
/// 插值在帧栈缓冲上拼串后存进堆箱 · `join` 同样在栈缓冲上拼；后两条各带 `burn` 压栈，否则判据会碰运气变绿。
struct ShareLifetimeTests: Sendable {

    private static var fixturesDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").path
    }

    private func fixtureFile(_ fixture: String) -> URL {
        URL(fileURLWithPath: Self.fixturesDirectory).appendingPathComponent(fixture + ".pini")
    }

    private func launch(_ arguments: [String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let binary = PiniTestEnvironment.cliPath() ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = PiniTestEnvironment.childEnvironment()
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

    /// 两路对照的公共体：解释器必须跑通，原生必须跑通，且输出逐字节相同。这里走 `compile`（clang / AOT 腿）
    /// 而不是 `run-llvm`：主题是 AOT 腿，且 `run-llvm` 缺 `PINI_LLVM_BIN` 时会静默空跑，而 `compile` 只用 clang。
    /// `compiled.status == 0` 与 `stdout` 比较都有效：子进程状态已交出（被信号杀 ⇒ 128+信号，abort ⇒ 134）。
    private func expectTwoPathsAgree(_ fixture: String) throws {
        let file = fixtureFile(fixture)
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["compile", file.path])

        try #require(
            interpreted.status == 0, "解释器未跑通 \(fixture)（rc=\(interpreted.status)）：\(interpreted.stderr)")
        try #require(
            compiled.status == 0,
            "\(fixture)：原生腿未跑通（rc=\(compiled.status)， 行不通  不是宿主 CLI 的 0）：\(compiled.stderr)")
        #expect(
            compiled.stdout == interpreted.stdout,
            """
            \(fixture)：两路读数应逐字节相同。
              · 解释器：\(interpreted.stdout.debugDescription)
              · 原生  ：\(compiled.stdout.debugDescription)
            """)
    }

    @Test("枚举载荷占用自己那一份份额：源变量重赋值之后仍可读")
    func enumPayloadKeepsItsShare() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("enum-payload-alias")
    }

    @Test("插值串活过产出它的帧（栈被压掉之后仍可读）")
    func interpolatedStringOutlivesItsFrame() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("string-escapes-interp")
    }

    @Test("join 结果活过产出它的帧（栈被压掉之后仍可读）")
    func joinedStringOutlivesItsFrame() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("string-escapes-join")
    }

    // MARK: - 产物结构级：栈上拼串的**交出点**必须经堆复制

    ///  注意  重要  为什么还要这一条：行为级的 `string-escapes-*` 抓不住「撤掉堆复制」这个变异 —— 撤掉之后它们仍全绿，
    /// 因为夹具里那支 `burn` 没覆写到产出帧的那片栈（栈复用是碰运气的）⇒ 行为判据必要但不充分，
    /// 补一条产物结构级判据：插值与 `join` 必须累积到运行时串，**不许**再有固定栈缓冲。
    @Test("插值与 join 累积到运行时串：产物里没有固定栈缓冲")
    func stackBuiltStringsAreCopiedToTheHeap() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN"]) else { return }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-stack-str-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for fixture in ["string-escapes-interp", "string-escapes-join"] {
            let file = fixtureFile(fixture)
            let out = scratch.appendingPathComponent("\(fixture).ll")
            let emit = try launch(["emit", file.path, out.path])
            try #require(emit.status == 0, "\(fixture)：emit 未通过：\(emit.stderr)")
            let ir = try String(contentsOf: out, encoding: .utf8)

            #expect(
                !ir.contains("alloca i8, i64 4096"),
                """
                \(fixture)：固定 4096 字节栈缓冲必须已退役。
                它拼接前不校验长度 ⇒ 超过 4 KiB 直接踩内存（4200 字节 SIGBUS、8192 字节 SIGSEGV 实测）。
                """)
            #expect(
                ir.contains("call ptr @bk_str_append_cstr(ptr"),
                "\(fixture)：插值与 join 应累积到运行时串（容量倍增），否则长度上限只是从 4096 挪到别处")
        }
    }
}
