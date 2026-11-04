import Foundation
@testable import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniHost

/// 每个后端各自与同一份手写期望逐字节比，不是各后端互相比：同时错会互相认证，两两比还按平方膨胀。
/// 期望值取自语义、不从任一后端回抄。解释器后端进程内零依赖；LLVM 后端走子进程，缺 `PINI_LLVM_BIN` 只记 known issue，不静默跳过。
/// 让出读数两侧口径不同（每次让出 / 派发那一趟），故语料只放一处 `await`；接多处让出前须先归一，否则两支读数分岔。
struct ContractReferenceTests: Sendable {

    // MARK: - 受守卫的那一格

    /// 期望值是手写的一行，来自语料的头注释。末尾换行也算输出：逐字节比到底，
    /// 不做「去掉末尾空白」的近似 —— 近似会把「什么都没打印」与「打印了空行」并成一类。
    private static let expectedOutput = "10\n"

    /// 期望值的第二维：让出读数，同样手写、同样逐字节比。让出与阻塞在输出上分不出差别
    /// （阻塞等同样打印 `10`），故只比输出对「`await` 有没有真的让出」全盲。语料只有一处
    /// `await` ⇒ 期望取精确值 `1` 而非「`> 0`」：能量精确值的判据强一档。
    private static let expectedYields = 1

    // 闸门置位时运行时打的那一行（契约 §3.6 的形态）。 行不通  逐字节比：汇总行是确定的，
    // 而「读一个数再比大小」会把「通道没输出」与「输出 0」并成一类，那正是要分开的两种。
    private static let yieldReportPrefix = "pini-yield-report: bodies-suspended="

    @Test("异步传染的终点：各后端各自与手写期望逐字节相符 —— 输出与让出各判一维")
    func testAsyncContagionEndMatchesTheWrittenExpectationOnBothLegs() throws {
        try assertBothLegsProduceTheExpectation(of: "concurrency-async-contagion-end")
    }

    @Test(" 重要  让出可观测：同一台机器上 `await` 版计数 > 0、`wait` 版 = 0 —— 有区分力才算判据")
    func theYieldChannelTellsTheTwoAwaitFormsApart() throws {
        /// 意图：观测通道有形状不等于有区分力。`await`（承诺让出）与 `wait`（承诺占用）在同一个体上
        /// 跑，读数必须不同；相同则通道只是打了一行字，「可观测差异」那条判据就成了空话。
        /// 负控程序刻意内联：它最小到只剩「有任务、没 `await`」，落进语料面只会多一份要维护的文件。
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
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
        try #require(awaited.status == 0, "LLVM 后端未跑通：\(underTest) ⇒ \(awaited.stderr)")
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
        try #require(ungated.status == 0, "LLVM 后端未跑通：\(underTest) ⇒ \(ungated.stderr)")
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

    @Test(" 重要  解释器后端有同形的让出读数：闸门置位 ⇒ 一行、未置位 ⇒ 零输出")
    func theInterpreterLegReportsYieldsInTheSameShapeAsTheEmitter() throws {
        /// 意图：解释器后端有与发射腿同形的让出读数 —— 同一闸门、同一行、同样打到 stderr，形态一致两份读数才可比；
        /// 挂点不同（对侧进程退出钩子，本后端运行入口返回）。判据三档、一律逐字节比：有让出 ⇒ `1`；
        /// 有派发无 `await` ⇒ `0`（证明读数有区分力）；闸门未置位 ⇒ 零输出（不许污染 stderr）。
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ 解释器后端读数本次未取（跳过 +1）") {
                Issue.record("解释器后端读数未取：这一条判据本次没有跑")
            }
            return
        }
        let underTest = "\(cli)（构建于 \(buildTime(of: cli))）"
        let gate = ["PINI_YIELD_REPORT": "1"]

        // ① 有让出的那份语料 —— 与对侧（`run-llvm`）同一条语料、同一条手写期望。
        let awaited = try launch(
            cli, ["run", fixtureFile("concurrency-async-contagion-end").path], environment: gate)
        try #require(awaited.status == 0, "解释器后端未跑通：\(underTest) ⇒ \(awaited.stderr)")
        #expect(
            awaited.stderr == Self.yieldReportPrefix + "1\n",
            "本后端应当**真的让出过**（读数还兼作闸门是否生效的证据）：\(awaited.stderr)")

        // ② 负控 —— 有派发、一处 `await` 也没有 ⇒ 读数须与 ① 不同。
        let negativeControl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("de6a-yield-negative-\(UUID().uuidString).pini")
        defer { try? FileManager.default.removeItem(at: negativeControl) }
        try Self.waitOnlyProgram.write(to: negativeControl, atomically: true, encoding: .utf8)
        let waited = try launch(cli, ["run", negativeControl.path], environment: gate)
        try #require(waited.status == 0, "负控程序未跑通：\(underTest) ⇒ \(waited.stderr)")
        #expect(waited.stdout == Self.expectedOutput, "负控程序的输出应与 ① 一致：\(waited.stdout)")
        #expect(
            waited.stderr == Self.yieldReportPrefix + "0\n",
            "`wait` 版不该让出（它的承诺就是占用）：\(waited.stderr)")

        // ③ 闸门未置位 ⇒ **零输出**：不得污染任何正常程序的 stderr。
        let ungated = try launch(cli, ["run", fixtureFile("concurrency-async-contagion-end").path])
        try #require(ungated.status == 0, "解释器后端未跑通：\(underTest) ⇒ \(ungated.stderr)")
        #expect(ungated.stderr.isEmpty, "未置位时不许有任何输出：\(ungated.stderr)")
    }

    @Test(" 重要  嵌套控制流里的 `await` 响亮拒绝：位置不合法的那些写法不静默阻塞")
    func awaitsInNestedControlFlowAreRefusedLoudly() throws {
        /// 意图：续跑靠入口 `switch` 直接跳回让出点那一块 ⇒ 只有体那一层的语句根部能当让出点。
        /// 嵌在 `if` / `case` / 循环体里的 `await` 若照旧发射成阻塞等待，程序照样跑出结果，只是让出承诺打了折。
        /// 故钉「响亮拒绝」而非「能编译」：非零退出 + 降载层诊断码 `E6-010` —— 码只有诊断产生，abort 不产生。
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty else {
            withKnownIssue("未提供 PINI_CLI_BIN ⇒ 嵌套位置拒绝本次未验（跳过 +1）") {
                Issue.record("嵌套位置拒绝未验：本段的边界判据本次没有跑")
            }
            return
        }
        for (label, program) in [
            ("嵌在 `if` 里的语句", Self.nestedIfStatementAwaitProgram),
            ("嵌在 `match` 的 case 体里", Self.nestedMatchCaseAwaitProgram),
            ("嵌在循环体里", Self.nestedLoopBodyAwaitProgram),
        ] {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("de6c-refuse-\(UUID().uuidString).pini")
            defer { try? FileManager.default.removeItem(at: file) }
            try program.write(to: file, atomically: true, encoding: .utf8)
            let result = try launch(cli, ["emit", file.path])
            #expect(result.status != 0, "\(label) 的 `await` 本应被拒绝，却编译过去了")
            #expect(
                result.stderr.contains("E6-010"),
                "拒绝报文须带上位置码（让出点只能落在体那一层的一条语句根部），实际：\(result.stderr)")
        }
    }

    /// 嵌套位置一：`await` 是合法形态（`var x = await f()`），但**不在函数体那一层**。
    private static let nestedIfStatementAwaitProgram = """
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

    /// 嵌套位置二：同上，嵌在 `match` 的 case 体里。
    private static let nestedMatchCaseAwaitProgram = """
        f|func() => (I32,):
            return ok(1)

        g|func() => (I32,):
            match 1:
                case 1:
                    var a = await f()
                    return a
                case 2:
                    return ok(0)
            return ok(0)

        main|func() -> ():
            var r = wait g()
            print(0)
            return
        """

    /// 嵌套位置三：同上，嵌在循环体里。
    private static let nestedLoopBodyAwaitProgram = """
        f|func() => (I32,):
            return ok(1)

        g|func() => (I32,):
            var i = 0
            while i < 1:
                var a = await f()
                i = i + 1
            return ok(0)

        main|func() -> ():
            var r = wait g()
            print(0)
            return
        """

    // MARK: - 让出的其余形态：三形态各一条独立判据

    /// 一个让出形态的判据：语料里只有该形态一处 `await` ⇒ 读数 `1` 可归因于它。
    /// 三条形态各写一条用例、各自调本函数；合成一条遍历全部语料后，「哪一形态坏了」在读数上不可分。
    /// 判据取三件：读数逐字节 `1`、输出与手写期望相符、各后端同输出。只断编译通过会把退化算成通过。
    private func assertYieldFormYieldsOnce(
        _ program: String, expecting expected: String, label: String
    ) throws {
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ \(label) 的让出读数本次未取（跳过 +1）") {
                Issue.record("\(label) 的让出读数未取：本段的形态判据本次没有跑")
            }
            return
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("de6c-yield-form-\(UUID().uuidString).pini")
        defer { try? FileManager.default.removeItem(at: file) }
        try program.write(to: file, atomically: true, encoding: .utf8)

        let llvm = try launch(cli, ["run-llvm", file.path], environment: ["PINI_YIELD_REPORT": "1"])
        try #require(llvm.status == 0, "\(label)：LLVM 后端未跑通 ⇒ \(llvm.stderr)")
        #expect(
            llvm.stdout == expected,
            "\(label)：输出应是手写期望 \(expected.debugDescription)，实际 \(llvm.stdout.debugDescription)")
        #expect(
            llvm.stderr == Self.yieldReportPrefix + "1\n",
            "\(label)：该形态本应**真的让出**一次（退化成阻塞等待会让这个读数变 0）：\(llvm.stderr)")

        let interpreted = try launch(cli, ["run", file.path])
        try #require(interpreted.status == 0, "\(label)：解释器后端未跑通 ⇒ \(interpreted.stderr)")
        #expect(
            interpreted.stdout == expected,
            "\(label)：各后端须同输出，解释器后端得 \(interpreted.stdout.debugDescription)")
    }

    @Test(" 重要  `S1` 让出形态：顶层裸语句 `await f()` —— 让出，结果按语义丢弃")
    func bareStatementAwaitYields() throws {
        /// 形态：`await f()` 独占一行（`S1`）。 重要  它是四形态里**唯一没有产出**的那种 ——
        /// 结果丢弃，因而让出序列的产出档位是「丢弃」。
        try assertYieldFormYieldsOnce(
            Self.bareAwaitProgram, expecting: "7\n", label: "`S1` 顶层裸语句")
    }

    @Test(" 重要  `S3` 让出形态：`match await f():` 的判别式位 —— 判别式跨过让出存活")
    func matchSubjectAwaitYields() throws {
        /// 形态：`await` 落在 `match` 的判别式位。关键在判别式的结果必须跨过让出：紧接的分派要读它，
        /// 而续跑从函数入口跳回 ⇒ 那个值只能经帧槽。`err` 臂本段测不了：LLVM 后端上 `Error(...)` 构造
        /// 会让 `lli` 报未定义类型，解释器腿的 `err` 路径另有判据，故本格的锚落在 ok 路径上。
        try assertYieldFormYieldsOnce(
            Self.matchSubjectAwaitProgram, expecting: "3\n", label: "`S3` 判别式位")
    }

    @Test(" 重要  `S4` 让出形态：`try await f() else …` 的 try 位 —— 操作数跨过让出存活")
    func tryOperandAwaitYields() throws {
        /// 形态：`await` 落在 `try` 位，与判别式位同一条理由（求值在前、分派在后），但分派形态不同
        /// （tag → ok / else 两支）⇒ 单独一条判据。错误变量的槽在让出点之前声明，留栈则续跑路径不支配它；
        /// 该槽走 `declareLocalSlot`，而它只在发射层可验 —— 解释器腿没有「槽」这个物件，够不到。
        try assertYieldFormYieldsOnce(
            Self.tryOperandAwaitProgram, expecting: "5\n", label: "`S4` try 位")
    }

    /// `S1` 的语料：让出一次、结果丢弃，函数随后正常返回 `ok(7)`。三份语料一律 ok 分支 `print`
    /// 整数、err 分支 `print` 字符串：直接打印 `Result` 会撞上另一处上游门禁，让读数指向错的地方。
    private static let bareAwaitProgram = """
        f|func(n: I32,) => (I32,):
            sleep(1)
            return ok(n)

        g|func() => (I32,):
            await f(7)
            return ok(7)

        main|func() -> ():
            var r = wait g()
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print("err")
            return
        """

    /// `S3` 的语料（ok 路径）：判别式是 `await f(3)`，分派读出 `ok` 分支的载荷。
    private static let matchSubjectAwaitProgram = """
        f|func(n: I32,) => (I32,):
            sleep(1)
            return ok(n)

        g|func() => (I32,):
            match await f(3):
                case ok(v):
                    return ok(v)
                case err(e):
                    return ok(0)

        main|func() -> ():
            var r = wait g()
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print("err")
            return
        """

    /// `S4` 的语料（ok 路径）：`try` 位求值成功 ⇒ 跳过 `else` 块、走到紧随其后的语句。
    private static let tryOperandAwaitProgram = """
        f|func(n: I32,) => (I32,):
            sleep(1)
            return ok(n)

        g|func() => (I32,):
            try await f(5) else e:
                return ok(99)
            return ok(5)

        main|func() -> ():
            var r = wait g()
            match r:
                case ok(v):
                    print(v)
                case err(e):
                    print("err")
            return
        """

    // MARK: - 各后端
    // 每个后端判两维，期望并排手写在上方：输出与让出读数。两维不可互替 —— 让出与阻塞在输出上
    // 分不出差别，只比输出对「`await` 有没有真的让出」是全盲的，故让出读数必须单独判。

    /// 两个后端各自与同一份期望比：每个后端的每一维都是一次独立判定，不是「两边一样」——
    /// 任一后端任一维单独偏离都要报红，这正是本层与「两两对照」的分界。
    private func assertBothLegsProduceTheExpectation(of fixture: String) throws {
        let expected = Self.expectedOutput
        let source = try fixtureSource(fixture)

        // 后端一：进程内。 重要  让出读数取**只归本次运行**的后端（理由见该类型的注释）——
        // 进程级单例的计数会被并行跑的别的用例挪走，读出来的是别人的数。
        let counting = YieldCountingScheduler(inner: GCDScheduler.shared)
        let (lines, yields) = try runInProcess(source: source, named: fixture, yielding: counting)
        #expect(
            stdoutForm(lines) == expected,
            "解释器后端的输出与手写期望不符：\(fixture)")
        #expect(
            yields == Self.expectedYields,
            "解释器后端的让出读数与手写期望（\(Self.expectedYields)）不符：\(fixture) ⇒ \(yields)")

        let cli = PiniTestEnvironment.cliPath() ?? ""
        // 两条前置缺任一都算「LLVM 后端未参与」：既要找得到命令行，又要找得到 lli。后端一零环境依赖、
        // 已在上方判完 ⇒ 此处跳过只抹掉 LLVM 那一维。跳过要可见：静默通过会把「只有一腿在守」读成守住了。
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ LLVM 后端的输出与让出两维本次未验（跳过 +1）") {
                Issue.record("LLVM 后端未参与：这一格本次只有解释器后端在守")
            }
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: cli), "PINI_CLI_BIN 不可执行：\(cli)")

        // 失败报文里带上二进制的**构建时间**：解析出来的路径仍可能指向改动之前的构建，
        // 而「构建旧」与「判据红」在输出上长得很像 —— 排一行日期，让前者表现为一个旧日期。
        let underTest = "\(cli)（构建于 \(buildTime(of: cli))）"
        // 闸门只在这一趟次进程上置位 ⇒ 它的 stderr 多出那一行汇总，正是第二维的读数来源。
        let viaCLI = try launch(
            cli, ["run-llvm", fixtureFile(fixture).path],
            environment: ["PINI_YIELD_REPORT": "1"])
        try #require(viaCLI.status == 0, "LLVM 后端未跑通：\(underTest) ⇒ \(viaCLI.stderr)")
        #expect(
            viaCLI.stdout == expected,
            "LLVM 后端的输出与手写期望不符：\(underTest)")
        #expect(
            viaCLI.stderr == Self.yieldReportPrefix + "\(Self.expectedYields)\n",
            "LLVM 后端的让出读数与手写期望（\(Self.expectedYields)）不符：\(underTest) ⇒ \(viaCLI.stderr)")
    }

    /// 镜像命令行 `run` 的单文件路径：解析（含常量折叠）→ 语义门禁 → 类型收集 → 降载 → 执行。
    /// 与命令行同一序：降载需检查器推断的类型，故这条路径必须跑类型层。
    /// - Returns: 逐行输出，以及本次运行里体让出的次数（由传入的后端计）。
    private func runInProcess(
        source: String, named fixture: String, yielding scheduler: YieldCountingScheduler
    ) throws
        -> (lines: [String], yields: Int)
    {
        let lexer = Lexer(source: source, fileName: fixture + ".pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fixture + ".pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = try FrontEnd.passes(module: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        // 降载会在检查器弹出作用域之后重推 match 的 scrutinee 类型，需持久表兜底
        // （命令行各执行入口同款）。
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = IRExecutor(
            programBase: Self.fixtureDirectory.path, ffiConfig: .default, scheduler: scheduler)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        // 读在运行**之后**：`main` 的那一处 `wait` 会把整条链等到决，故此刻所有让出都已发生。
        return (lines, scheduler.yieldCount)
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

    // MARK: - 给定实例的取用：一条**LLVM 后端也参与**的判据

    /// 语料：一处给定块取用（`using`），一处 `await` 也没有 —— 本格问的是「LLVM 后端能不能收下
    /// 含给定块取用的程序」，带 `await` 的语料会先撞上上游降载门禁，把读数带偏。
    /// 期望值手写：收下一笔后队列长度 `1`，取走队首后 `0`。
    private static let givenInstanceProgram = """
        探|func(using s: 调度器,) -> (I32,):
            s.收下(空句柄)
            print(len(s.元素))
            s.选择下一个任务()
            return len(s.元素)

        main|func() -> ():
            print(探())
            return
        """

    @Test(" 重要  给定实例的取用：各后端各自与手写期望逐字节相符 —— 这条路径先前只有解释器后端在守")
    func givenInstanceUseIsAcceptedByBothLegs() throws {
        /// 意图：`using` 取用预置默认实例这条路，其缺陷形态是发射出的 IR 在解析期被拒，而那段 IR 只在
        /// 程序真的取用给定实例时才发射 —— 不取用的程序、以及没有 IR 的解释器腿都读不到它。
        /// 本格不看让出读数（语料零处 `await`，那维恒 `0` 是空维），也不只比退出码：输出才是判据。
        let expected = "1\n0\n"

        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ 给定实例取用这一格本批未验（跳过 +1）") {
                Issue.record("给定实例取用：这一格本次没有 LLVM 后端在守")
            }
            return
        }

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("given-instance-\(UUID().uuidString).pini")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.givenInstanceProgram.write(to: file, atomically: true, encoding: .utf8)

        let viaLLVM = try launch(cli, ["run-llvm", file.path])
        #expect(
            viaLLVM.stdout == expected,
            "LLVM 后端的输出应是手写期望 \(expected.debugDescription)，实际 \(viaLLVM.stdout.debugDescription)；stderr：\(viaLLVM.stderr)")

        let interpreted = try launch(cli, ["run", file.path])
        #expect(
            interpreted.stdout == expected,
            "解释器后端的输出应是手写期望 \(expected.debugDescription)，实际 \(interpreted.stdout.debugDescription)"
        )
    }

    // MARK: - 跨来源的同名方法：按名合并（与调度器无关的那一面）

    /// 同一结构的两个扩展块写同名方法。它问降载层怎么合并两处方法来源：合并留下两条同名方法时，
    /// 模块在被执行之前就被拒，而解释器后端按字典收表、后写者胜，看不出这件事 ⇒ 缺陷只在 LLVM 腿现形。
    /// 期望值手写：后声明的那份答 `2`，前一份答 `1` —— 两个数不同，读数才有区分力。
    private static let duplicateMethodProgram = """
        (匣)
        值: I32 = 0

        ((匣))
        取|self() -> (I32,):
            return 1

        ((匣))
        取|self() -> (I32,):
            return 2

        main|func() -> ():
            var x = 匣()
            print(x.取())
            return
        """

    /// 阴性对照：只留一个扩展块，读出 `1`。它证明 `2` 不是常量、也不是「恰好读到那一个数」——
    /// 少了它，一条恒打印 `2` 的实现也能让上面那格通过。
    private static let singleMethodProgram = """
        (匣)
        值: I32 = 0

        ((匣))
        取|self() -> (I32,):
            return 1

        main|func() -> ():
            var x = 匣()
            print(x.取())
            return
        """

    @Test(" 重要  两处来源的同名方法按名合并：后声明者胜 —— 且阴性对照读出不同的数")
    func laterDeclarationWinsAcrossMethodSources() throws {
        try assertBothLegsMatch(
            Self.duplicateMethodProgram, expecting: ["2"], label: "两处同名（后声明者胜）")
        try assertBothLegsMatch(
            Self.singleMethodProgram, expecting: ["1"], label: "阴性对照（只有一处）")
    }

    // MARK: - 调度策略被覆盖后的顺序

    /// 一对语料共用的行程，两份只差开头那段 `[[调度器]]` 覆盖块。
    /// 机关全在时间上：`父` 先派发 `甲`/`乙`、再 await 自己的闸 ⇒ 父先被挂起；父的续跑段睡一段 ⇒ 两笔入队都发生在任何一次挑选之前。
    /// 默认先进先出下顺序等于决出顺序，覆盖成后进先出后先跑的是后决出的乙；睡 800ms 是余量，太短会在机器忙时误报顺序。
    private static func strategyOrderCorpus(overriding: Bool) -> String {
        let overrideBlock = overriding ? """
        [[调度器]]
            选择下一个任务|self() -> (*U8,):
                var 个数 = len(self.元素)
                if 个数 == 0:
                    return 空句柄
                var 队尾 = self.元素.get(个数 - 1)
                match 队尾:
                    case some(任务):
                        self.元素 = self.元素.slice(0, 个数 - 1)
                        return 任务
                    case none:
                        return 空句柄

        """ : ""
        return overrideBlock + """
        闸|func(毫秒: I32,) => (I32,):
            sleep(毫秒)
            return ok(0)

        甲|func() => (I32,):
            var g = 闸(100)
            try await g else e:
                return ok(0)
            print("甲")
            return ok(0)

        乙|func() => (I32,):
            var g = 闸(150)
            try await g else e:
                return ok(0)
            print("乙")
            return ok(0)

        父|func() => (I32,):
            var a = 甲()
            var b = 乙()
            var g0 = 闸(50)
            try await g0 else e:
                return ok(0)
            sleep(800)
            print("父续")
            var ra = try await a else e:
                return ok(0)
            return ok(0)

        main|func() -> ():
            var t = 父()
            var q = wait t
            return
        """
    }

    @Test(" 重要  顺序由策略决定（LLVM 后端那一半）：覆盖成后进先出后，先跑的是后决出的那个")
    func thePolicyDecidesTheOrderOnTheEmittingLeg() throws {
        /// 意图：一份替换掉调度器的程序要在 LLVM 后端被接受（同名方法按名合并），才问得出「先跑谁由谁定」。
        /// 推进性：默认策略下顺序等于决出顺序（甲先于乙），这同时证明两个闸确实先后决出。
        /// 驳回性：只多那段覆盖块，先跑的必须变成乙。
        try assertBothLegsMatch(
            Self.strategyOrderCorpus(overriding: false), expecting: ["父续", "甲", "乙"],
            label: "默认策略")
        try assertBothLegsMatch(
            Self.strategyOrderCorpus(overriding: true), expecting: ["父续", "乙", "甲"],
            label: "覆盖成后进先出")
    }
    /// 各后端各跑一次这份程序，各自与同一份手写期望逐字节比输出。不比退出码：实测有「底层工具报错、
    /// 命令行仍返回成功码」的形态，退出码单独用是弱判据。也不比让出读数：本函数服务的语料要么零处
    /// `await`，要么让出次数不是本格要问的东西 ⇒ 硬塞一维是空维。期望值全部手写，不从后端回抄。
    @discardableResult
    private func assertBothLegsMatch(
        _ program: String, expecting expected: [String], label: String
    ) throws -> String {
        let cli = PiniTestEnvironment.cliPath() ?? ""
        guard !cli.isEmpty, PiniTestEnvironment.llvmBinDirectory() != nil else {
            let missing = cli.isEmpty ? "PINI_CLI_BIN" : "PINI_LLVM_BIN"
            withKnownIssue("未提供 \(missing) ⇒ \(label) 各后端本次未验（跳过 +1）") {
                Issue.record("\(label)：这一格本次没有后端在守")
            }
            return ""
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("both-legs-\(UUID().uuidString).pini")
        defer { try? FileManager.default.removeItem(at: file) }
        try program.write(to: file, atomically: true, encoding: .utf8)
        let expectedText = expected.isEmpty ? "" : expected.joined(separator: "\n") + "\n"

        let llvm = try launch(cli, ["run-llvm", file.path])
        #expect(
            llvm.stdout == expectedText,
            "\(label)：LLVM 后端的输出应是手写期望 \(expectedText.debugDescription)，实际 \(llvm.stdout.debugDescription)；stderr：\(llvm.stderr)"
        )

        let interpreted = try launch(cli, ["run", file.path])
        #expect(
            interpreted.stdout == expectedText,
            "\(label)：解释器后端的输出应是手写期望 \(expectedText.debugDescription)，实际 \(interpreted.stdout.debugDescription)"
        )
        return interpreted.stdout
    }

    // MARK: - 输出形态

    /// 把逐行收集到的输出还原成 stdout 的字节形态：每行一个换行，空输出是空串。
    /// 这样「收行」与「收字节流」两条腿才在同一个量上比，否则两把尺子会造出看起来很正常的假差异。
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

enum ContractGuardError: Error, CustomStringConvertible {
    case fixtureMissing(String)

    var description: String {
        switch self {
        case .fixtureMissing(let path): return "受守卫的语料不存在：\(path)"
        }
    }
}

/// 只数本次运行让出次数的后端：委派生产后端，只在体的结局上挂一个计数。刻意非私有 ——
/// 两处判据都要构造它、且须读出同一个数。进程级单例的增量会被并行用例挪走，本件断精确值，包装一层才只数自己的。
/// 派发与续跑两源都收在此（续跑不经派发口），少一侧就只数首跑那趟；本类型照常让出、只记次数，不验降级纪律。
final class YieldCountingScheduler: Scheduler, @unchecked Sendable {
    private let inner: GCDScheduler
    private let lock = NSLock()
    private var suspensions = 0

    init(inner: GCDScheduler) { self.inner = inner }

    /// 本次运行里体让出的次数。只由「让出」这一个动作驱动 ⇒ 取读数不需要独占整台机器。
    var yieldCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return suspensions
    }

    func spawn(_ future: FutureValue, work: @escaping @Sendable () throws -> TaskRunOutcome) {
        inner.spawn(future) {
            let outcome = try work()
            if case .suspended = outcome { self.noteYield() }
            return outcome
        }
    }

    /// 记账自己收、不委派给 `inner`：本类型数的是本次运行，而 `inner` 的计数是进程级的。
    /// 它与派发口那处配对 —— 续跑那几趟不经派发口，故必须在这里也收一次，否则只数得到首跑那趟。
    func noteYield() {
        lock.lock()
        suspensions += 1
        lock.unlock()
    }

    var activeTaskCount: Int { inner.activeTaskCount }
    var capabilities: ConcurrencyCapabilities { inner.capabilities }

    /// 委派而不是自己答：**让出判定必须走生产后端**，否则本替换品测的就是它自己的回答了。
    func yieldTask() -> Int32 { inner.yieldTask() }
}
