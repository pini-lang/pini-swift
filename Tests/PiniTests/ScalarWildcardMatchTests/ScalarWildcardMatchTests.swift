import Foundation
import Testing

/// 裸值受试的 `match` 里，**通配臂**（`case _:`）的执行判据。
///
/// **修的是哪一层**：`IREmitter.emitMatch` 的 `default`（裸值）分支，原先只在
/// 「存在字面量臂」时才进 `emitScalarMatch`：
///
/// ```swift
/// if cases.contains(where: { $0.literal != nil }) { emitScalarMatch(...) }
/// ```
///
/// 于是 `match x:` 只写一条 `case _:` 时**一个臂都不发**——函数落到 `ret i32 undef`。
/// 静默，且 `rc=0`。
///
/// **为什么它是缺陷而不是取舍**：同一条通配臂，在「有字面量臂」时由
/// `emitScalarMatch` 的 default 块执行、在「没有字面量臂」时被整个丢掉 ——
/// 而通配臂**能**匹配裸值（这正是 `emitScalarMatch` 里那段 `if let wildcardArm`
/// 在干的事）。旧注释从「enum-case 臂打不中裸值」推到了「所有臂都死」，
/// 漏掉的那一类恰是唯一活得下来的那种臂。
///
/// ⚠️ **本判据的对象是发射层**（`IREmitter`），所以三条都走**两腿对比**：
/// 解释器腿与 LLVM 腿在同一份语料上必须读出同一串输出。⛔ 不用 IR 节点断言 ——
/// `IRLowerer` 侧本来就是对的（它产 `matchStmt` 带全部 cases），坏的只在发射。
/// ✔ 因此判据 1、2 **修前必红**；判据 3 钉「修復不得越过自己的边界」（回归）。
struct ScalarWildcardMatchTests {

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

    private func requireCLI() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        for key in ["PINI_CLI_BIN", "PINI_LLVM_BIN"] where (environment[key] ?? "").isEmpty {
            withKnownIssue("未提供 \(key) ⇒ 本批判据本次未取（跳过 +1）") {
                Issue.record("裸值通配臂判据未取：\(key) 缺失")
            }
            return false
        }
        return true
    }

    /// 两腿在同一份语料上必须读出同一串输出（各自逐字节）。
    /// `expected` 由**语料头的手写期望**给出 —— ⛔ 不从任何一腿回抄。
    private func expectBothLegs(_ fixture: String, expected: String) throws {
        let file = fixtureFile(fixture)
        let interpreted = try launch(["run", file.path])
        let compiled = try launch(["run-llvm", file.path])

        try #require(
            interpreted.status == 0, "解释器未跑通 \(fixture)：\(interpreted.stderr)")
        #expect(
            interpreted.stdout == expected,
            "\(fixture)：解释器读数应等于手写期望 \(expected.debugDescription)，实得 \(interpreted.stdout.debugDescription)")
        #expect(
            compiled.status == 0,
            "\(fixture)：LLVM 腿未跑通（rc=\(compiled.status)）—— 裸值 match 的通配臂须真的发射：\(compiled.stderr)")
        #expect(
            compiled.stdout == interpreted.stdout,
            "\(fixture)：两腿读数应逐字节相同。解释器 \(interpreted.stdout.debugDescription)，LLVM \(compiled.stdout.debugDescription)")
    }

    // MARK: - 判据 1：只有通配臂时，该臂必须执行（修前 LLVM 腿落 undef）

    @Test("裸值 + 只有 case _: ⇒ 该臂执行，函数返回值来自它")
    func wildcardOnlyArmRuns() throws {
        guard requireCLI() else { return }
        try expectBothLegs("wildcard-only", expected: "1\n")
    }

    // MARK: - 判据 2：通配臂执行后不得穿透到 match 之后（修前返回 9）

    @Test("裸值 + case _: 之后还有语句 ⇒ 控制流停在臂内，不穿透（返回 1 而非 9）")
    func wildcardArmDoesNotFallThrough() throws {
        guard requireCLI() else { return }
        try expectBothLegs("wildcard-then-tail", expected: "1\n")
    }

    // MARK: - 判据 3（边界）：字面量臂 + 通配臂的既有行为不得改变

    @Test("裸值 + 字面量臂 + 通配臂 ⇒ 字面量臂仍先命中，通配仍作兜底")
    func literalArmsKeepTheirPrecedence() throws {
        guard requireCLI() else { return }
        try expectBothLegs("literal-plus-wildcard", expected: "1\n2\n")
    }
}
