import Foundation
import PiniCore
import Testing

/// `readFile` 内建的判据。
///
/// ⚠️⭐ **本套件存在的全部理由是一条已删的语义**：`readFile` 曾按固定字节数**静默截断**
///   （越限部分丢弃 · 无诊断 · **退出码 0**）。那条上限不是语言选的 —— 它继承自发射器的
///   固定栈缓冲，而且与契约自己的语义列（「读取文件的**全部内容**」）直接冲突。
///   2026-10-01 两侧同改：解释器读全，发射器改走运行时 shim（`bk_read_file`）。
///
/// ⇒ 判据只有一条，就是**没有上限**。要证明一条**不存在**的行为只能靠规模，
///   故正向用例取**旧上限的数倍**，而不是「恰好等于」。
///
/// ⚠️ 与 `ListDirBuiltinTests` 的**结构性不同**：本套件的被测对象同时是**文件系统**与
///   **两条执行腿**。文件系统那半照 `ListDirBuiltinTests` 的规矩（自建临时基准，
///   ⛔ 不在仓库里建文件）；两条腿那半只在 LLVM 腿可用时才跑（它要 `lli`，只能走子进程）。
///
/// ⚠️ 旧上限那个数（64 KiB）在此**只作探针尺寸**，⛔ 不作语义 —— 判据本身不含任何上限。
///   它的历史理由与删除记录在 `IOLimits` 头注里，那里是**唯一**载体。
struct ReadFileBuiltinTests {

    // MARK: - 探针尺寸

    /// 被测文件的内容：旧上限（64 KiB）的 **4 倍**，末尾带一个标记。
    ///
    /// 两层都要：**长度**判「一个字节都没丢」，**末尾标记**判「丢的是尾巴而不是中段」。
    /// 只判长度时，一个「读全了但顺序错乱」的实现拿不到；只判标记时，丢一个字节也发现不了。
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
        /// 意图：本条钉的是**另一条腿** —— 上限原本长在两侧（解释器读后截断 · 发射器用固定
        /// 栈缓冲 `fread`），只改一侧会制造**新的两侧偏离**，而 `IOLimits` 存在的全部理由
        /// 就是两侧一致 ⇒ 两侧各与**同一份手写期望**比一次（⛔ 两腿互比：同时错会互相认证）。
        ///
        /// ⚠️ 期望值同样由用例自己写下的内容算出，两条腿用**同一个** `expected`。
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
