import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// `readFile` 内建的判据：契约说读取文件的全部内容 ⇒ 判据只有一条，就是没有上限，判据本身不含任何上限。
/// 要证明一条不存在的行为只能靠规模，故正向用例取探针尺寸的数倍而非「恰好等于」；那个尺寸只作探针，不作语义。
/// 被测对象同时是文件系统与两条执行腿：前者自建临时基准、不在仓库建文件；后者要 `lli`，只在可用时才跑。
struct ReadFileBuiltinTests: Sendable {

    // MARK: - 探针尺寸

    /// 被测文件的内容：探针尺寸的 4 倍，末尾带一个标记。两层都要：长度判「一个字节都没丢」，末尾标记判
    /// 「丢的是尾巴而不是中段」。只判长度时，「读全了但顺序错乱」的实现拿不到；只判标记时，丢一个字节发现不了。
    private static let largeContent: String = {
        let marker = "\nTAIL-MARKER\n"
        let filler = String(repeating: "x", count: (64 * 1024 * 4) - marker.utf8.count)
        return filler + marker
    }()

    // MARK: - 私有 helper

    /// 建一个受控的临时基准目录；调用方负责在结束时删除（同 `ListDirBuiltinTests`）。
    private func makeSandbox() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pini-readfile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 解析（含常量折叠）→ 语义门禁 → 类型检查 → 降载 → 在指定基准上执行，返回标准输出逐行。
    private func run(_ fixture: String, programBase: URL) throws -> [String] {
        let source = try loadPiniFixture(fixture + ".pini", filePath: #filePath)
        let lexer = Lexer(source: source, fileName: fixture + ".pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fixture + ".pini")
            .parseModuleCollectingErrors()
        let module = ConstantFolder.foldConstants(in: parsed.module)
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(programBase: programBase.path)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 子进程跑 CLI（LLVM 腿只能这样跑），同 `ContractReferenceTests` 的形态。
    private func launch(
        _ executable: String, _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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

    // MARK: - 正向

    @Test("超过旧上限的文件被整份读入：长度与末尾标记各判一维")
    func testReadFileReadsWholeFilePastTheOldCap() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let content = Self.largeContent
        try Data(content.utf8).write(to: sandbox.appendingPathComponent("big.txt"))

        let lines = try run("testReadFileReadsWholeFilePastTheOldCap", programBase: sandbox)

        /// 期望值由**用例自己写下的内容**算出（⛔ 不是从任何后端回抄）。
        let expected = ["\(content.utf8.count)", "true"]
        #expect(lines == expected, "读取结果不符。实际：\(lines)")

        /// ⭐ 再加一条**不依赖上面那张表**的断言：表本身可能被改错，
        /// 而这一条钉的是「文件确实远大于旧上限」这个**事实**（探针尺寸有效的前提）。
        #expect(content.utf8.count > 64 * 1024 * 3,
                "探针文件的规模失效了（\(content.utf8.count) 字节）⇒ 本用例已不再能证明「超过旧上限」")
    }

    // MARK: - 负向（与正向配对，见夹具头注）

    @Test("读不到文件时响亮拒绝，不是静默返回空串")
    func testReadFileRejectsMissingFile() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        do {
            let lines = try run("testReadFileRejectsMissingFile", programBase: sandbox)
            Issue.record("文件不存在时应走错误通道，实际跑通并输出：\(lines)")
        } catch let RuntimeError.invalidOperation(reason, _) {
            #expect(reason.contains("无法读取文件"),
                    "错误原因应指明是读取失败，实际：\(reason)")
        }
    }

    // MARK: - 另一条腿（LLVM 腿要 `lli`；缺变量时报「本臂未参与」并让跳过可见）

    @Test("LLVM 腿读同一份文件：与同一份手写期望逐字节相符")
    func testReadFileReadsPastTheOldCapOnTheLLVMLeg() throws {
        /// 意图：本条钉的是另一条腿。两条腿读同一份文件的结果必须一致 —— 只改一侧会制造新的两侧偏离，
        /// 而两侧一致正是 `IOLimits` 存在的全部理由 ⇒ 两侧各与同一份手写期望比一次，⛔ 不两腿互比（同错会互相认证）。
        /// 期望值由用例自己写下的内容算出，两条腿用同一个 `expected`。
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ LLVM 腿本次未取（跳过 +1）") {
                Issue.record("LLVM 腿的 readFile 判据本次没有跑")
            }
            return
        }

        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let content = Self.largeContent
        let big = sandbox.appendingPathComponent("big.txt")
        try Data(content.utf8).write(to: big)

        let source = try loadPiniFixture(
            "testReadFileReadsPastTheOldCapOnTheLLVMLeg.pini", filePath: #filePath
        ).replacingOccurrences(of: "__BIG_PATH__", with: big.path)
        let program = sandbox.appendingPathComponent("leg.pini")
        try source.write(to: program, atomically: true, encoding: .utf8)

        let expected = "\(content.utf8.count)\ntrue\n"

        let llvm = try launch(cli, ["run-llvm", program.path])
        try #require(llvm.status == 0, "LLVM 腿未跑通：\(llvm.stderr)")
        #expect(llvm.stdout == expected,
                "LLVM 腿的读取结果应是 \(expected.debugDescription)，实际 \(llvm.stdout.debugDescription)；stderr：\(llvm.stderr)")

        /// 同一份程序在解释器腿上也跑一次 —— 两腿各自与**同一份**期望比，不是互相比。
        let interpreted = try launch(cli, ["run", program.path])
        try #require(interpreted.status == 0, "解释器腿未跑通：\(interpreted.stderr)")
        #expect(interpreted.stdout == expected,
                "解释器腿的读取结果应是 \(expected.debugDescription)，实际 \(interpreted.stdout.debugDescription)")
    }
}
