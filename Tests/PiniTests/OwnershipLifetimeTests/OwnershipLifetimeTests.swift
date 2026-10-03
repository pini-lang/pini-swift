import Foundation
import Testing

/// **名义值的所有权与寿命**（甲路线 · 2026-10-03）：三条都属同一族 ——
/// 「值活不过它应该活过的那个位置」，而且都**只在原生路径**上发作（解释器用 Swift 值，
/// 帧退不掉内容）。三条判据一律以**解释器的行为**为权威，⛔ 不与手写期望比。
///
/// | 夹具 | 归因 |
/// |---|---|
/// | `enum-payload-alias` | 枚举构造对载荷只做**裸 store**（缺「别名点 retain」）⇒ 源变量被重赋值时把仍然被引用的那只箱收走 |
/// | `string-escapes-interp` | 插值在**本帧栈缓冲**上拼串，而结果被存进堆箱 ⇒ 帧一退就是悬垂栈地址 |
/// | `string-escapes-join` | 同上（`join` 也在栈缓冲上拼） |
///
/// ⚠️ 后两条夹具各带一个 `burn` 递归：它**把那片栈压掉**。没有它，判据只是
/// 「栈还没被复用」—— 会**碰运气变绿**，那正是本批真因曾长期被读成「非确定性」的原因。
struct OwnershipLifetimeTests {

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

    private func requireCLI(_ needed: [String]) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        for key in needed where (environment[key] ?? "").isEmpty {
            withKnownIssue("未提供 \(key) ⇒ 本批判据本次未取（跳过 +1）") {
                Issue.record("名义值所有权判据未取：\(key) 缺失")
            }
            return false
        }
        return true
    }

    /// 两路对照的公共体：解释器必须跑通，原生必须跑通，且**输出逐字节相同**。
    ///
    /// ⚠️ 这里走 **`compile`（clang / AOT 腿）而不是 `run-llvm`**，两个理由：
    /// ① 甲路线的主题就是 AOT 腿（`run-llvm` 是 JIT 腿）；
    /// ② `run-llvm` 要 `PINI_LLVM_BIN`，未配置时用例**静默空跑**（`withKnownIssue` 后 return，
    ///    仍报 passed）—— 而 `compile` 只用 clang（本机 `/usr/bin/clang` 恒在）⇒ 真跑。
    ///
    /// ⚠️ `compiled.status == 0` 这一条此前是**恒真的**（`run-llvm` / `compile` 丢掉子进程
    /// 状态，见 `Sources/PiniCLI/main.swift` 里的注释）⇒ 那类断言等于没判。
    /// 本批已把状态交出去（被信号杀死 ⇒ 128+信号，即 abort ⇒ 134），于是它与 `stdout` 比较
    /// **都**是有效判据。
    private func expectTwoPathsAgree(_ fixture: String) throws {
        let file = fixtureFile(fixture)
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["compile", file.path])

        try #require(
            interpreted.status == 0, "解释器未跑通 \(fixture)（rc=\(interpreted.status)）：\(interpreted.stderr)")
        try #require(
            compiled.status == 0,
            "\(fixture)：原生腿未跑通（rc=\(compiled.status)，⛔ 不是宿主 CLI 的 0）：\(compiled.stderr)")
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
        guard requireCLI(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("enum-payload-alias")
    }

    @Test("插值串活过产出它的帧（栈被压掉之后仍可读）")
    func interpolatedStringOutlivesItsFrame() throws {
        guard requireCLI(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("string-escapes-interp")
    }

    @Test("join 结果活过产出它的帧（栈被压掉之后仍可读）")
    func joinedStringOutlivesItsFrame() throws {
        guard requireCLI(["PINI_CLI_BIN"]) else { return }
        try expectTwoPathsAgree("string-escapes-join")
    }

    // MARK: - 产物结构级：栈上拼串的**交出点**必须经堆复制

    /// ⚠️⭐ 为什么还要这一条（2026-10-03 实测的**判据弱点**）：行为级的
    /// `string-escapes-*` 两条**抓不住**「撤掉堆复制」这个变异 —— 撤掉之后它们**仍全绿**，
    /// 因为夹具里那支 `burn` 没覆写到产出帧的那片栈（栈复用是**碰运气**的，
    /// 这恰恰是本缺陷长期被读成「非确定性」的原因）。⇒ 行为判据必要但不充分，
    /// 补一条**产物结构级**判据：栈缓冲的**交出点**必须紧跟 `@strdup`。
    ///
    /// ⚠️ 判据的**非退化锚点**：夹具必须真的走栈上拼串（`alloca i8, i64 4096`），
    /// 否则「没有 `strdup`」与「根本没有拼串」外观相同。
    @Test("栈上拼串（插值 / join）的产物必须经 @strdup 交出去")
    func stackBuiltStringsAreCopiedToTheHeap() throws {
        guard requireCLI(["PINI_CLI_BIN"]) else { return }
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
                ir.contains("alloca i8, i64 4096"),
                "\(fixture)：产物里没有栈上拼串缓冲 ⇒ 本判据会空转")
            #expect(
                ir.contains("call ptr @strdup(ptr"),
                """
                \(fixture)：栈上拼出来的串在**交出之前**必须复制到堆。
                没有 `@strdup` 调用 ⇒ 交出去的是**栈地址**，帧一退就是悬垂指针
                （自举词法层 `self.emit("int", "\\(parseDecimal(wholeText))")` 正是这种形态）。
                """)
        }
    }
}
