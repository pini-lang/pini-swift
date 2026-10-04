import Foundation
import Testing

/// `obj.field[i] = v` —— **字段作容器的下标写**（N79 第一半）。
///
/// 存在理由（2026-10-04 实测）：该形态此前**两条腿都做不成**，而失败形态**相反** ——
/// · 解释器（`IRExecutor.storeSubscript`）对非变量 / 非嵌套下标的目标**响亮拒绝**：
///   `E5-006`「invalid operation: subscript store target is neither a variable …」；
/// · 发射器（`IREmitter.emitSubscriptStore`）落到「原样 `emitExpr(container)`」那一支：
///   它把**字段值**当容器交出去，却**不把分裂出的新句柄写回字段**
///   ⇒ 写时复制一旦分裂，那次写**静默丢失**（与「不回写变量槽」是同一条契约义务）。
///
/// 归属：IR 契约把 `subscriptStore` 的容器定义为**可嵌套链**，字段是链的一环
/// ⇒ 这是**覆盖缺口**，⛔ 不是契约要改。
///
/// 两份夹具的**判别力不同**，⛔ 别只跑一份：
/// · `field-subscript-store`（非别名）：值就地改对、邻居不动；
///   ⚠️ 它**区分不出**「回写字段」与否 —— 独占时写路径可能就地改。
/// · `field-subscript-store-alias`（别名）：先取快照再写 ⇒ 分裂必然发生
///   ⇒ 只有「新句柄写回了字段」才可能既改到字段又不动快照。
///   ⭐ 这一份才是「回写」那条义务的**唯一见证**。
struct SubscriptFieldStoreTests {

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
                Issue.record("字段下标写判据未取：\(key) 缺失")
            }
            return false
        }
        return true
    }

    // MARK: - ① 非别名：值就地改对，且只在目标下标

    @Test("字段作容器的下标写：值改对、邻居不动（旧实现 E5-006 拒绝）")
    func fieldSubscriptStoreWritesInPlace() throws {
        guard requireCLI(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }

        let file = fixtureFile("field-subscript-store")
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["run-llvm", file.path])

        try #require(
            interpreted.status == 0,
            "解释器没跑通 —— 该形态此前正是死在这里（E5-006）：\(interpreted.stderr)")
        #expect(
            compiled.status == 0,
            "LLVM 后端没跑通（rc=\(compiled.status)）：\(compiled.stderr)")

        // 非退化锚点：只有写**真的落到了目标下标**，下面那条两路对照才有意义。
        #expect(
            interpreted.stdout == "10\n7\n30\n",
            "解释器读数不符：应只有第 2 个元素变成 7。实得 \(interpreted.stdout.debugDescription)")
        #expect(
            compiled.stdout == interpreted.stdout,
            """
            两路应逐字节相同。解释器 \(interpreted.stdout.debugDescription)，\
            LLVM \(compiled.stdout.debugDescription)
            """)
    }

    // MARK: - ② 别名：写时复制分裂 ⇒ 判「新句柄写回了字段」

    @Test("字段作容器的下标写在写时复制分裂后仍生效（不回写则那次写静默丢失）")
    func fieldSubscriptStoreSurvivesCopyOnWriteSplit() throws {
        guard requireCLI(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }

        let file = fixtureFile("field-subscript-store-alias")
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["run-llvm", file.path])

        try #require(interpreted.status == 0, "解释器没跑通：\(interpreted.stderr)")
        try #require(
            compiled.status == 0,
            "LLVM 后端没跑通（rc=\(compiled.status)）：\(compiled.stderr)")

        // 非退化锚点：快照必须**真的取到**了（否则本判据退化成 ① 那一份）。
        // 两行输出 = 字段那一格（改后的 7）+ 快照那一格（未被改的 20）。
        #expect(
            interpreted.stdout == "7\n20\n",
            """
            解释器读数不符：字段要变 7、快照要留 20。实得 \(interpreted.stdout.debugDescription)
            ⚠️ 若字段那格是 20 ⇒ 写丢了；若快照那格是 7 ⇒ 值语义破了（两者都不是「差一点」）。
            """)
        #expect(
            compiled.stdout == interpreted.stdout,
            """
            两路应逐字节相同 —— 这一份测的正是**发射器**有没有把分裂出的新句柄写回字段。
              解释器：\(interpreted.stdout.debugDescription)
              LLVM  ：\(compiled.stdout.debugDescription)
            """)
    }
}
