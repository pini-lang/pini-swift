import Foundation
import Testing
import PiniSyntax
@testable import PiniHost

/// 逻辑短路的判据：真假表、右操作数是否求值、非 Bool 操作数在检查期被拒。
/// 右操作数的求值用**副作用**（打印）测 —— 只比返回值的话，短路与不短路给出同一份读数。
@Suite("逻辑短路")
struct LogicalShortCircuitTests: Sendable {

    // MARK: - 语料与手写期望

    /// 前八行是完整真假表；其后的 `短路` / `求值` 两组交替出现，钉同一件事的两面：
    /// 左值定下结果时不打印，定不下时才打印。末两行钉嵌套与比较结果参与运算。
    private static let corpus = #"""
    noisy|func() -> (Bool,):
        print("ran")
        return true

    main|func() -> ():
        print("t && t", true && true)
        print("t && f", true && false)
        print("f && t", false && true)
        print("f && f", false && false)
        print("t || t", true || true)
        print("t || f", true || false)
        print("f || t", false || true)
        print("f || f", false || false)
        print("短路", false && noisy())
        print("短路", true || noisy())
        print("求值", true && noisy())
        print("求值", false || noisy())
        print("嵌套", 1 < 2 && 3 < 4 && 4 < 5)
        print("混合", !(1 < 2) || 3 < 4)
        return
    """#

    private static let expected = #"""
    t && t true
    t && f false
    f && t false
    f && f false
    t || t true
    t || f true
    f || t true
    f || f false
    短路 false
    短路 true
    ran
    求值 true
    ran
    求值 true
    嵌套 true
    混合 true
    """#

    // MARK: - 进程内装置

    private enum Outcome: Equatable {
        case ran([String])
        case refused(String)
    }

    /// 走与命令行同一条前端，并跑起来。不装配标准库：本套语料与它无关，
    /// 装配进来只会让失败信息落到 `<stdlib>` 上。
    private static func attempt(_ source: String) -> Outcome {
        let name = "逻辑短路探针.pini"
        do {
            let lexer = Lexer(source: source, fileName: name)
            let parsed = Parser(tokens: try lexer.tokenize(), fileName: name)
                .parseModuleCollectingErrors()
            guard parsed.errors.isEmpty else {
                return .refused("解析期被拒：\(parsed.errors[0])")
            }
            let unit = FileUnit(fileName: name, module: try FrontEnd.passes(module: parsed.module))
            let runner = ProgramRunner()
            var lines: [String] = []
            runner.outputSink = { lines.append($0) }
            try runner.run(package: Package(name: "逻辑短路", fileUnits: [unit]))
            return .ran(lines)
        } catch {
            return .refused("\(error)")
        }
    }

    // MARK: - 判据

    @Test("解释器腿：真假表与短路副作用逐行等于手写期望")
    func interpreterMatchesExpectation() throws {
        let outcome = Self.attempt(Self.corpus)
        guard case .ran(let lines) = outcome else {
            Issue.record("语料应可跑，实际被拒：\(outcome)")
            return
        }
        #expect(lines.joined(separator: "\n") == Self.expected)
    }

    @Test("发射腿：同一份语料经 LLVM 通道读数相同")
    func llvmAgreesWithInterpreter() throws {
        guard let cli = PiniTestEnvironment.cliPath() else {
            Issue.record("找不到命令行产物：设 PINI_CLI_BIN 或先构建")
            return
        }
        guard let llvm = PiniTestEnvironment.llvmBinDirectory() else {
            Issue.record("找不到 lli：设 PINI_LLVM_BIN 或装 LLVM")
            return
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-logical-\(UUID().uuidString).pini")
        try Self.corpus.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try Self.launch(
            cli, ["run-llvm", file.path],
            environment: ["PINI_LLVM_BIN": llvm])
        guard result.status == 0 else {
            Issue.record("发射腿失败（退出码 \(result.status)）：\(result.stderr)")
            return
        }
        #expect(result.stdout.trimmingCharacters(in: .newlines) == Self.expected)
    }

    /// 意图：非 Bool 操作数在**检查期**就被拒，而不是拖到降载时按「不支持的特性」报。
    /// 分工依据是修法不同 —— 前者要改程序，后者是等编译器。
    @Test("非 Bool 操作数：检查期报类型错误")
    func nonBooleanOperandsAreRejectedAtCheckTime() throws {
        guard let cli = PiniTestEnvironment.cliPath() else {
            Issue.record("找不到命令行产物：设 PINI_CLI_BIN 或先构建")
            return
        }
        let source = #"""
        main|func() -> ():
            if 1 && 2:
                print("x")
            return
        """#
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-bad-logical-\(UUID().uuidString).pini")
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = try Self.launch(cli, ["check", file.path])
        #expect(result.status != 0, "非 Bool 操作数应被拒")
        #expect(result.stderr.contains("E4-001"), "应报类型错误，实际：\(result.stderr)")
        #expect(!result.stderr.contains("E6-004"), "不该落到「不支持特性」桶")
    }

    // MARK: - 子进程

    private static func launch(
        _ binary: String, _ arguments: [String], environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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
