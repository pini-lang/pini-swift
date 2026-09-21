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

    // MARK: - 让出（`DE-6b`）：那条观测通道有没有区分力

    /// 闸门置位时运行时打的那一行（`DE-6a` §3.6 的形态）。⛔ 逐字节比：汇总行是**确定**的，
    /// 而「读一个数再比大小」会把「通道没输出」与「输出 0」并成一类，那正是这一条要分开的两种。
    private static let yieldReportPrefix = "pini-yield-report: bodies-suspended="

    @Test("⭐ 让出可观测：同一台机器上 `await` 版计数 > 0、`wait` 版 = 0 —— 有区分力才算判据")
    func theYieldChannelTellsTheTwoAwaitFormsApart() throws {
        /// 意图：`DE-6a` §3.6 定了观测通道的形状，而**形状在册不等于通道有区分力**。
        /// 这一条问的是后者：`await`（承诺让出）与 `wait`（承诺占用）在同一台机器、同一个体上
        /// 跑，读数必须**不同**。
        /// ⛔ 若两者读数相同（都 0 或都 >0），通道就只是「打了一行字」，`D`+`E` 验收标准里
        /// 「`await` 让出 / `wait` 占用的可观测差异」那一条会变成一句空话。
        /// ⚠️ 负控程序**刻意内联**、不进样例面：它是「最小到只剩「有任务、没 `await`」」的一段，
        /// 落进样例面就成了一份别人要维护的语料，而它要证明的只是**这一条**读数。
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ 让出读数本次未取（跳过 +1）") {
                Issue.record("让出读数未取：本批的 L1 判据本次没有跑")
            }
            return
        }
        let underTest = "\(cli)（构建于 \(buildTime(of: cli))）"
        let gate = ["PINI_YIELD_REPORT": "1"]

        // ① `await` 版 —— 就是受守卫的那一份语料。
        let awaited = try launch(
            cli, ["run-llvm", fixtureFile("concurrency-async-contagion-end").path], environment: gate)
        try #require(awaited.status == 0, "LLVM 腿未跑通：\(underTest) ⇒ \(awaited.stderr)")
        #expect(
            awaited.stderr == Self.yieldReportPrefix + "1\n",
            "`await` 版应当**真的让出过**（读数还兼作闸门是否生效的证据）：\(awaited.stderr)")

        // ② `wait` 版 —— 有派发、但一处 `await` 也没有。
        let negativeControl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("de6b-yield-negative-\(UUID().uuidString).pini")
        defer { try? FileManager.default.removeItem(at: negativeControl) }
        try Self.waitOnlyProgram.write(to: negativeControl, atomically: true, encoding: .utf8)
        let waited = try launch(cli, ["run-llvm", negativeControl.path], environment: gate)
        try #require(waited.status == 0, "负控程序未跑通：\(underTest) ⇒ \(waited.stderr)")
        #expect(waited.stdout == Self.expectedOutput, "负控程序的输出应与 await 版一致：\(waited.stdout)")
        #expect(
            waited.stderr == Self.yieldReportPrefix + "0\n",
            "`wait` 版不该让出（它的承诺就是占用）：\(waited.stderr)")

        // ③ 闸门未置位 ⇒ **零输出**：不得污染任何正常程序的 stderr。
        let ungated = try launch(cli, ["run-llvm", fixtureFile("concurrency-async-contagion-end").path])
        try #require(ungated.status == 0, "LLVM 腿未跑通：\(underTest) ⇒ \(ungated.stderr)")
        #expect(ungated.stderr.isEmpty, "未置位时不许有任何输出：\(ungated.stderr)")
    }

    /// 负控程序的全文（见上一条用例的注释：为何内联而不进样例面）。
    private static let waitOnlyProgram = """
        f|func() => (I32,):
            sleep(5)
            return ok(10)

        main|func() -> ():
            var r = wait f()
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print("err")
            return
        """

    @Test("⭐ 限外的 `await` 响亮拒绝：只支持顶层 `var x = await f(...)`，其余位置不静默阻塞")
    func awaitsOutsideTheSupportedPositionAreRefusedLoudly() throws {
        /// 意图：`DE-6b` 只接通**一个**让出形态。⛔ 其余位置（`match` 的操作数 · 嵌在 `if` 里的
        /// 语句）若照旧发射成阻塞等待，那件事**看起来完全正常** —— 程序跑得出结果，只是
        /// 「让出」这个承诺被悄悄打了个折。故这里钉的不是「能编译」，而是**编译不了且说得出理由**。
        ///
        /// ⚠️ 判据取两件：**非零退出** + 报文里点名 `DE-6c`（下一个该接的批）。只断言「非零退出」
        /// 会把「崩在别处」也算成通过。
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ 限外拒绝本次未验（跳过 +1）") {
                Issue.record("限外拒绝未验：本批的边界判据本次没有跑")
            }
            return
        }
        for (label, program) in [
            ("`match` 的操作数", Self.matchOperandAwaitProgram),
            ("嵌在 `if` 里的语句", Self.nestedStatementAwaitProgram),
        ] {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("de6b-refuse-\(UUID().uuidString).pini")
            defer { try? FileManager.default.removeItem(at: file) }
            try program.write(to: file, atomically: true, encoding: .utf8)
            let result = try launch(cli, ["emit", file.path])
            #expect(result.status != 0, "\(label) 的 `await` 本应被拒绝，却编译过去了")
            #expect(
                result.stderr.contains("DE-6c"),
                "拒绝报文须点名下一个该接的批（DE-6c），实际：\(result.stderr)")
        }
    }

    /// 限外形态一：`await` 出现在 `match` 的操作数位置。
    private static let matchOperandAwaitProgram = """
        f|func() => (I32,):
            return ok(1)

        g|func() => (I32,):
            match await f():
                case ok(v):
                    return ok(v)
                case err(e):
                    return ok(0)

        main|func() -> ():
            var r = wait g()
            print(0)
            return
        """

    /// 限外形态二：`await` 是合法语句，但**不在函数体那一层**（嵌在 `if` 里）。
    private static let nestedStatementAwaitProgram = """
        f|func() => (I32,):
            return ok(1)

        g|func() => (I32,):
            if true:
                var a = await f()
                return a
            return ok(0)

        main|func() -> ():
            var r = wait g()
            print(0)
            return
        """

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

    private func launch(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil
    ) throws
        -> (status: Int32, stdout: String, stderr: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }
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
