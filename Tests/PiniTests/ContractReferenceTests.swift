import Foundation
import PiniCore
import Testing

/// 「契约参照」守卫：**每一条腿各自与同一份手写期望比**，不是两条腿互相比。
///
/// 为什么参照物是手写期望而不是另一条腿：两条腿同时错会互相认证（判据恒真），而后端一多，
/// 「两两比」的判据量按平方膨胀。期望值因此必须来自**语义**（那份语料的头注释就写着预期值），
/// 绝不能从任何一条腿的输出回抄 —— 回抄会把这一层塌回「实现与它自己一致」。
///
/// 两条腿的形状刻意不同，理由是**在不在场**比对称更重要：
///   - 解释器腿**进程内**跑：与命令行的 `run` 是同一条腿（单文件 run 走的就是 HIR 执行），
///     且**零环境依赖** ⇒ 裸跑一次回归就有真覆盖，不需要谁先记得设变量。
///   - LLVM 腿要 `lli`，只能走**子进程**命令行 ⇒ 它需要 `PINI_CLI_BIN` 与 `PINI_LLVM_BIN`。
///     缺变量时**报「本臂未参与」并让跳过可见**（`known issue` 计数），不静默通过 ——
///     否则「没跑」与「通过」在读数上不可区分。
///
/// ⚠️ 覆盖面：本守卫今天守**一个**断言点。样例面下 8 份并发语料只有一份两腿可达，
/// 其余 7 份停在同一处上游降载门禁上（与 LLVM 腿无关）。⇒ 它证明的是**形态已经接通**，
/// **不是**「并发面已被守卫覆盖」。
struct ContractReferenceTests {

    // MARK: - 受守卫的那一格

    /// 期望值是**手写的一行**：语料的头注释自己写着「预期打印 10」。
    ///
    /// 末尾换行是输出的一部分 —— 逐字节比就比到底，不做「去掉末尾空白」的近似：
    /// 近似会把「什么都没打印」与「打印了空行」并成一类。
    private static let expectedOutput = "10\n"

    @Test("异步传染的终点：两条腿各自与手写期望逐字节相符")
    func testAsyncContagionEndMatchesTheWrittenExpectationOnBothLegs() throws {
        try assertBothLegsProduceTheExpectation(of: "concurrency-async-contagion-end")
    }

    // MARK: - 两条腿

    /// 腿一（进程内，无依赖）与腿二（子进程，需环境变量）**各自**与同一份期望比。
    ///
    /// 两条 `#expect` 是两次独立判定，不是「两边一样」：任何一条腿单独偏离都要报红，
    /// 这正是这一层与「两两对照」的分界。
    private func assertBothLegsProduceTheExpectation(of fixture: String) throws {
        let expected = Self.expectedOutput
        let source = try fixtureSource(fixture)

        let inProcess = stdoutForm(try runInProcess(source: source, named: fixture))
        #expect(
            inProcess == expected,
            "解释器腿的输出与手写期望不符：\(fixture)")

        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        // 两条前置缺任一都算「本臂未参与」：LLVM 腿要既找得到命令行、又找得到 lli。
        // 环境未配置 ⇒ 跳过（与本仓既有 LLVM 门控同一取向），但**跳过要可见** —— 静默通过
        // 会让「只有一条腿在守」读成「这一格守住了」。
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ LLVM 腿本次未参与（跳过 +1，只有解释器腿在守）") {
                Issue.record("LLVM 腿未参与：这一格的守卫本次只覆盖一条腿")
            }
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: cli), "PINI_CLI_BIN 不可执行：\(cli)")

        // 失败报文里带上二进制的**构建时间**：解析出来的路径仍可能指向改动之前的构建，
        // 而「构建旧」与「判据红」在输出上长得很像 —— 排一行日期，让前者表现为一个旧日期。
        let underTest = "\(cli)（构建于 \(buildTime(of: cli))）"
        let viaCLI = try launch(cli, ["run-llvm", fixtureFile(fixture).path])
        try #require(viaCLI.status == 0, "LLVM 腿未跑通：\(underTest) ⇒ \(viaCLI.stderr)")
        #expect(
            viaCLI.stdout == expected,
            "LLVM 腿的输出与手写期望不符：\(underTest)")
    }

    /// 镜像命令行 `run` 的**单文件**路径：解析（含常量折叠）→ 语义门禁 → 类型收集 →
    /// 降载 → 执行。与命令行同一序，因为降载需要检查器推断出的类型 —— 这条路径**必须**跑类型层。
    private func runInProcess(source: String, named fixture: String) throws -> [String] {
        let lexer = Lexer(source: source, fileName: fixture + ".pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fixture + ".pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        // 降载会在检查器弹出作用域之后重推 match 的 scrutinee 类型，需持久表兜底
        // （命令行各执行入口同款）。
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = HIRExecutor(programBase: Self.fixtureDirectory.path)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    // MARK: - 语料定位（读样例面，不复制它）

    /// 语料住在**样例面**里，本测试读它、不复制它：复制品是第二处会漂的东西。
    private static var fixtureDirectory: URL {
        // 本文件 → 测试面目录 → 测试面 → 仓根
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples")
    }

    private func fixtureFile(_ fixture: String) -> URL {
        Self.fixtureDirectory.appendingPathComponent(fixture + ".pini")
    }

    private func fixtureSource(_ fixture: String) throws -> String {
        let url = fixtureFile(fixture)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 受守卫的语料被改名或删除时，这里必须**响亮**说出来，
            // 而不是让读文件失败伪装成更下游的解析错。
            throw ContractGuardError.fixtureMissing(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 输出形态

    /// 把逐行收集到的输出还原成 stdout 的字节形态：每行一个换行，空输出是空串。
    ///
    /// 这样两条腿（一条收行、一条收字节流）才在**同一个量**上比 —— 否则「行数组」与
    /// 「字节流」两把尺子会造出一个看起来很正常的假差异。
    private func stdoutForm(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func buildTime(of path: String) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let date = attributes?[.modificationDate] as? Date else { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 子进程

    private func launch(_ executable: String, _ arguments: [String]) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
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
}

enum ContractGuardError: Error, CustomStringConvertible {
    case fixtureMissing(String)

    var description: String {
        switch self {
        case .fixtureMissing(let path): return "受守卫的语料不存在：\(path)"
        }
    }
}
