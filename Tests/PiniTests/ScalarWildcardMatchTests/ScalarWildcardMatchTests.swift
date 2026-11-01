import Foundation
import Testing

/// 裸值受试的 `match` 里，通配臂（`case _:`）的执行判据。`IREmitter.emitMatch` 的裸值分支只在「存在字面量臂」
/// 时才进 `emitScalarMatch` ⇒ `match x:` 只写一条 `case _:` 时一个臂都不发，函数落到 `ret i32 undef`，静默且 `rc=0`。
/// 通配臂本就能匹配裸值，被丢的恰是唯一活得下来的那种臂；判据对象是发射层，故三条都走两腿对比同输出。
struct ScalarWildcardMatchTests: Sendable {

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
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    /// 两腿在同一份语料上必须读出同一串输出（各自逐字节）。
    /// `expected` 由**语料头的手写期望**给出 ——  行不通  不从任何一腿回抄。
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
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }
        try expectBothLegs("wildcard-only", expected: "1\n")
    }

    // MARK: - 判据 2：通配臂执行后不得穿透到 match 之后（修前返回 9）

    @Test("裸值 + case _: 之后还有语句 ⇒ 控制流停在臂内，不穿透（返回 1 而非 9）")
    func wildcardArmDoesNotFallThrough() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }
        try expectBothLegs("wildcard-then-tail", expected: "1\n")
    }

    // MARK: - 判据 3（边界）：字面量臂 + 通配臂的既有行为不得改变

    @Test("裸值 + 字面量臂 + 通配臂 ⇒ 字面量臂仍先命中，通配仍作兜底")
    func literalArmsKeepTheirPrecedence() throws {
        guard PiniTestEnvironment.requireToolchain(["PINI_CLI_BIN", "PINI_LLVM_BIN"]) else { return }
        try expectBothLegs("literal-plus-wildcard", expected: "1\n2\n")
    }
}
