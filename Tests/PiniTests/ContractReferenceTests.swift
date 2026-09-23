import Foundation
@testable import PiniCore
import Testing

/// 「契约参照」守卫：**每一个后端各自与同一份手写期望比**，不是各后端互相比。
///
/// 为什么参照物是手写期望而不是另一个后端：各后端同时错会互相认证（判据恒真），而后端一多，
/// 「两两比」的判据量按平方膨胀。期望值因此必须来自**语义**（那份语料的头注释就写着预期值），
/// 绝不能从任何一个后端的输出回抄 —— 回抄会把这一层塌回「实现与它自己一致」。
///
/// 各后端的形状刻意不同，理由是**在不在场**比对称更重要：
///   - 解释器后端**进程内**跑：与命令行的 `run` 是同一个后端（单文件 run 走的就是 HIR 执行），
///     且**零环境依赖** ⇒ 裸跑一次回归就有真覆盖，不需要谁先记得设变量。
///   - LLVM 后端要 `lli`，只能走**子进程**命令行 ⇒ 它需要 `PINI_CLI_BIN` 与 `PINI_LLVM_BIN`。
///     缺变量时**报「本臂未参与」并让跳过可见**（`known issue` 计数），不静默通过 ——
///     否则「没跑」与「通过」在读数上不可区分。
///
/// ⚠️ 覆盖面：本守卫的**各后端对照格** = 用例里各后端**各自**与手写期望比一次（有的还多判一维让出
/// 读数）。现有 **八** 格 —— 计法就是这条规则，改完用例照它数一遍，别去信一个写死的数
/// （同一个数从前就落过一次伍，正是因为它只写在标题里、没有可复算的计法）。
/// ⭐ 其中「给定实例的取用」那一格是**补**的：那条路**曾经在 LLVM 后端上无人守** —— 它的缺陷只在 LLVM 后端上
/// 才现形，而当时碰它的判据全在解释器后端上 ⇒ **一格的缺席能藏住一整类缺陷**，这一格是那次的对照。
/// ⭐ 最近两格（跨来源同名方法的合并 · 用户覆盖调度策略后的顺序）同属这一类：**只在 LLVM 后端上现形**，
/// 所以放进本件，而不是放进任何单个后端的套件。
/// 语料面下 8 份并发语料只有一份各后端可达，其余 7 份停在同一处上游降载门禁上（与 LLVM 后端无关）。
/// ⇒ 它证明的是**形态已经接通**，**不是**「并发面已被守卫覆盖」。
///
/// ⚠️ **让出那一维的前置条件**：各后端的让出计数器**语义不同** —— LLVM 后端数「每次让出」，
/// 解释器后端数「体在**派发那一趟**上让出」（续跑由决出方直接驱动、不经调度器）
/// ⇒ 一个体内**多处** `await` 的程序上两者会分岔。受守卫这一格只有一处 `await`，
/// 故两支读数一致、判据成立。**接多处让出的语料之前，须先把两处口径归一。**
struct ContractReferenceTests {

    // MARK: - 受守卫的那一格

    /// 期望值是**手写的一行**：语料的头注释自己写着「预期打印 10」。
    ///
    /// 末尾换行是输出的一部分 —— 逐字节比就比到底，不做「去掉末尾空白」的近似：
    /// 近似会把「什么都没打印」与「打印了空行」并成一类。
    private static let expectedOutput = "10\n"

    /// 期望值的**第二维**：让出读数。同样手写、同样逐字节比。
    ///
    /// ⚠️ 为什么这一维非得独立存在：让出与阻塞**在输出上分不出差别**（阻塞等同样打印 `10`）。
    /// 若守卫只比输出，「`await` 真的让出了」这件事就**没有任何守卫在看** ——
    /// 而它正是本批的验收标准里明文的那一条。⚠️ 语料自身只有**一处** `await`，
    /// 所以期望值是 `1` 而不是「`> 0`」：一个能断精确值的判据，比一个能断存在性的强一档。
    private static let expectedYields = 1

    /// 闸门置位时运行时打的那一行（`DE-6a` §3.6 的形态）。⛔ 逐字节比：汇总行是**确定**的，
    /// 而「读一个数再比大小」会把「通道没输出」与「输出 0」并成一类，那正是这一条要分开的两种。
    private static let yieldReportPrefix = "pini-yield-report: bodies-suspended="

    @Test("异步传染的终点：各后端各自与手写期望逐字节相符 —— 输出与让出各判一维")
    func testAsyncContagionEndMatchesTheWrittenExpectationOnBothLegs() throws {
        try assertBothLegsProduceTheExpectation(of: "concurrency-async-contagion-end")
    }

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

    @Test("⭐ 嵌套控制流里的 `await` 响亮拒绝：位置不合法的那些写法不静默阻塞")
    func awaitsInNestedControlFlowAreRefusedLoudly() throws {
        /// 意图：让出的续跑靠**入口的 `switch` 直接跳回**让出点所在的那一块 ⇒ 只有**一条语句的
        /// 根部**能当让出点。嵌在 `if` / `match` 的 case / 循环体里的 `await` 若照旧发射成阻塞等待，
        /// 那件事**看起来完全正常** —— 程序跑得出结果，只是「让出」这个承诺被悄悄打了个折。
        /// 故这里钉的不是「能编译」，而是**编译不了且说得出理由**。
        ///
        /// ⚠️ 判据取两件：**非零退出** + 报文**说得出位置要求**（含 `statement root`）。
        /// 只断言「非零退出」会把「崩在别处」也算成通过。
        /// ⛔ **不许把断言锚在批次编号上**（原先钉的是「报文须点名下一个该接的批」）：批次编号是
        /// **过程**记号，它随批次推进而失效 —— 本段真的落地时，那条断言就会因为「报文不再提这个
        /// 编号」而变红，而它想钉的**行为**其实没变。判据该锚在**行为与理由**上，这两样才不随批次走。
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
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
                result.stderr.contains("statement root"),
                "拒绝报文须说得出位置要求（让出点只能落在一条语句的根部），实际：\(result.stderr)")
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

    // MARK: - 让出的其余形态（`DE-6c`）：三形态各一条独立判据

    /// 一个让出形态的判据：**这份语料里只有该形态一处 `await`** ⇒ 读数 `1` 归因于它。
    ///
    /// ⛔ 三条形态**各写一条用例**、各自调本函数，而不是合成一条遍历全部语料：合成之后
    /// 「哪一形态坏了」在读数上不可分（与「不得顺手互做」同一条理由 —— 一次做完则不可归因）。
    ///
    /// ⭐ 判据取三件：**该形态真的让出过**（读数逐字节 `1`）· **输出与手写期望相符** ·
    /// **各后端同输出**。只断言「编译通过」会把「悄悄退化成阻塞等待」也算成通过 ——
    /// 而那正是本段要防的形态（让出计数**不可**由输出替代：阻塞等待下输出同样正确）。
    ///
    /// ⚠️ 期望值全部**手写**（来自语料自身的意图），不从任何一个后端回抄；各后端各比一次。
    private func assertYieldFormYieldsOnce(
        _ program: String, expecting expected: String, label: String
    ) throws {
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
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

    @Test("⭐ `S1` 让出形态：顶层裸语句 `await f()` —— 让出，结果按语义丢弃")
    func bareStatementAwaitYields() throws {
        /// 形态：`await f()` 独占一行（`S1`）。⭐ 它是四形态里**唯一没有产出**的那种 ——
        /// 结果丢弃，因而让出序列的产出档位是「丢弃」。
        try assertYieldFormYieldsOnce(
            Self.bareAwaitProgram, expecting: "7\n", label: "`S1` 顶层裸语句")
    }

    @Test("⭐ `S3` 让出形态：`match await f():` 的判别式位 —— 判别式跨过让出存活")
    func matchSubjectAwaitYields() throws {
        /// 形态：`await` 落在 `match` 的**判别式**位（`S3`）。⚠️ 这一形态的关键在于
        /// **判别式的结果必须跨过让出**：紧接其后的分派（tag 提取 · 逐 arm 比较）要读它，
        /// 而续跑是从函数入口跳回来的 ⇒ 那个值只能经帧槽。
        ///
        /// ⚠️ **本形态的 `err` 臂今天测不了**（不是漏了，是做不到），两处都**与本段无关**、
        /// 且都经独立实测确认：① 要造出 `err` 就得用 `Error(...)` 构造，而它在 LLVM 后端上
        /// `lli` 直接报 `use of undefined type named 'struct.Error'` —— ⭐ 这一点由一份**不含任何
        /// `await`/`wait` 的同步程序**独立证明（既有语料 `try.pini` 走的是字符串载荷，所以没暴露）；
        /// ② 解释器后端在同形态上给出的是「`g` 返回 `err`」（未走 `case err(e):`），而解释器后端的让出
        /// 由 `HIRExecutor` 承担、**不在本段改动面内**。⇒ 判据锚在**能建立**的那条路上。
        try assertYieldFormYieldsOnce(
            Self.matchSubjectAwaitProgram, expecting: "3\n", label: "`S3` 判别式位")
    }

    @Test("⭐ `S4` 让出形态：`try await f() else …` 的 try 位 —— 操作数跨过让出存活")
    func tryOperandAwaitYields() throws {
        /// 形态：`await` 落在 `try` 位（`S4`）。与 `S3` 同一条理由（求值在前、分派在后），
        /// 但分派形态不同（tag → ok / else 两支）⇒ 单独一条判据。
        /// ⚠️ 本形态另有一处**专属**的坑：错误变量的槽在让出点**之前**声明 ⇒ 它若留在栈上，
        /// 续跑路径**不支配**它，续跑后写进的是一块悬垂地址。那一处的修正已落地
        /// （`errSlot` 改走 `declareLocalSlot`），但**没有判据能证明它**：要走到那条路同样得先
        /// 造出 `err`，而那卡在上面 `S3` 记的同一处既有缺陷上。⇒ 如实登记，不当成已覆盖。
        try assertYieldFormYieldsOnce(
            Self.tryOperandAwaitProgram, expecting: "5\n", label: "`S4` try 位")
    }

    /// `S1` 的语料：让出一次、结果丢弃，函数随后正常返回 `ok(7)`。
    ///
    /// ⚠️ 三份语料一律在 ok 分支 `print` **整数**、err 分支 `print` **字符串**：打印 `Result`
    /// 本身会撞上另一处上游门禁（与本段无关），混进来会让读数指向错的地方。
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
    //
    // 每个后端判**两维**，两维的期望都是手写的一份、并排写在上面：**输出**与**让出读数**。
    // ⚠️ 两维不可互相替代：让出与阻塞在**输出**上分不出差别（阻塞等同样打印 `10`）⇒
    // 只比输出的守卫对「`await` 到底有没有真的让出」是全盲的。而本批的验收标准里，
    // 「`await` 让出 / `wait` 占用的可观测差异」正是明文那一条 ⇒ 它必须落在这里，
    // 而不是落在一条只跑 LLVM 后端的旁证上。

    /// 后端一（进程内，无依赖）与后端二（子进程，需环境变量）**各自**与同一份期望比。
    ///
    /// 每个后端的每一维都是**一次独立判定**，不是「两边一样」：任何一个后端任一维单独偏离都要报红，
    /// 这正是这一层与「两两对照」的分界。
    private func assertBothLegsProduceTheExpectation(of fixture: String) throws {
        let expected = Self.expectedOutput
        let source = try fixtureSource(fixture)

        // 后端一：进程内。⭐ 让出读数取**只归本次运行**的后端（理由见该类型的注释）——
        // 进程级单例的计数会被并行跑的别的用例挪走，读出来的是别人的数。
        let counting = YieldCountingScheduler(inner: GCDScheduler.shared)
        let (lines, yields) = try runInProcess(source: source, named: fixture, yielding: counting)
        #expect(
            stdoutForm(lines) == expected,
            "解释器后端的输出与手写期望不符：\(fixture)")
        #expect(
            yields == Self.expectedYields,
            "解释器后端的让出读数与手写期望（\(Self.expectedYields)）不符：\(fixture) ⇒ \(yields)")

        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        // 两条前置缺任一都算「LLVM 后端未参与」：它要既找得到命令行、又找得到 lli。
        // ⚠️ 后端一**已经在上方判完**（它零环境依赖）⇒ 这一处跳过只抹掉 LLVM 后端的那一维，
        // 不像从前那样把各后端一起跳过。环境未配置 ⇒ 跳过（与本仓既有 LLVM 门控同一取向），
        // 但**跳过要可见** —— 静默通过会让「只有一个后端在守」读成「这一格守住了」。
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
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

    /// 镜像命令行 `run` 的**单文件**路径：解析（含常量折叠）→ 语义门禁 → 类型收集 →
    /// 降载 → 执行。与命令行同一序，因为降载需要检查器推断出的类型 —— 这条路径**必须**跑类型层。
    ///
    /// - Returns: 逐行输出，以及**本次运行**里体让出的次数（由传入的后端计）。
    private func runInProcess(
        source: String, named fixture: String, yielding scheduler: YieldCountingScheduler
    ) throws
        -> (lines: [String], yields: Int)
    {
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
        let executor = HIRExecutor(
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

    /// 语料：一处给定块取用（`using`），**一处 `await` 也没有**。
    ///
    /// ⚠️ 为什么刻意不含 `await`：这一格问的是「**LLVM 后端能不能收下含给定块取用的程序**」。
    /// 带 `await` 的语料会先撞上上游降载门禁（与本格无关）⇒ 混进来会让读数指向错的地方。
    ///
    /// ⚠️ 期望值是**手写**的：收下一笔之后队列长度 `1`，取走队首之后长度 `0`。
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

    @Test("⭐ 给定实例的取用：各后端各自与手写期望逐字节相符 —— 这条路径先前只有解释器后端在守")
    func givenInstanceUseIsAcceptedByBothLegs() throws {
        /// 意图：`using` 取用**预置默认实例**这条路，在 LLVM 后端上曾**零判据守着** ——
        /// 它的缺陷形态是「发射出的 IR 在**解析期**被拒」，而那段 IR 只在**程序真的取用给定实例**
        /// 时才被发射出来 ⇒ 一份不取用的程序读不到它，解释器后端更读不到它（那边根本没有 IR）。
        ///
        /// ⛔ 这一格**不看让出读数**（与三条形态判据的关键差异）：本语料零处 `await`，
        /// 那个读数恒为 `0` ⇒ 加进来是个**空维**；而「精确值」的强处恰恰来自它能取到**不同**的值。
        ///
        /// ⛔ 也**不**只比退出码：实测过「底层工具报错、而命令行仍返回成功码」的形态
        /// ⇒ 退出码单独用是**弱判据**，输出才是。
        let expected = "1\n0\n"

        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
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

    /// 同一结构的两个扩展块写**同名**方法。
    ///
    /// ⚠️ 这条与调度无关，放在本件的理由却与调度那一格**同一个**：它问的是降载层怎么合并
    /// 两处方法来源，而出问题的是 LLVM 后端 —— 合并留下两条同名方法时，模块在被执行之前就被拒；
    /// 解释器后端按字典收表、后写者胜，因而**看不出**这件事。⇒ **缺陷只在 LLVM 后端上现形**。
    ///
    /// ⭐ 期望值手写：后声明的那一份答 `2`，前一份答 `1` —— 两个数不同，读数才有区分力。
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

    /// 阴性对照：只留**一个**扩展块。
    ///
    /// ⭐ 它证明「`2`」不是常量、也不是「恰好打印了顺手读到的那一个数」——
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

    @Test("⭐ 两处来源的同名方法按名合并：后声明者胜 —— 且阴性对照读出不同的数")
    func laterDeclarationWinsAcrossMethodSources() throws {
        try assertBothLegsMatch(
            Self.duplicateMethodProgram, expecting: ["2"], label: "两处同名（后声明者胜）")
        try assertBothLegsMatch(
            Self.singleMethodProgram, expecting: ["1"], label: "阴性对照（只有一处）")
    }

    // MARK: - 调度策略被覆盖后的顺序（此前只有一个策略可验的那一半）

    /// 一对语料共用的行程，两份**只差**开头那段 `[[调度器]]` 覆盖块。
    ///
    /// ⭐ 机关全在**时间**上，三处缺一不可：
    /// - `父` 先派发 `甲`/`乙`（各 await 一个闸），**再** await 自己的闸 ⇒ 「父被挂起」先发生；
    /// - `父` 的**续跑段**睡一段 ⇒ 它占住驱动，而 `甲` 与 `乙` 的闸在这段里先后决出
    ///   ⇒ **两笔入队都发生在任何一次挑选之前**；
    /// - 于是策略层拿到的是一个**装着两件待跑项的队列**，它挑谁谁就先跑。
    ///
    /// ⇒ 默认策略（先进先出）下顺序**等于决出顺序**（甲先于乙）；覆盖成后进先出之后，
    /// 先跑的必须是**后决出的乙**。两条读数互为反证 —— 只看后一条，
    /// 「策略生效」与「碰巧乙先跑」在读数上同形。
    ///
    /// ⚠️ 与解释器后端那一侧的同名判据**不是同一份语料**，差在两处、都是刻意的：
    /// ① 那边每处 `else` 臂用错误构造，而 LLVM 后端表达不出那个构造（那条路上的既有边界，
    /// 不是本段引入）；② 那边父的续跑段睡 300ms，这里睡 800ms —— 本件不与任何套件串行，
    /// 睡太短会在机器忙时把「乙的闸还没决出、父就醒了」误报成顺序不符。**这是余量，不是语义。**
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

    @Test("⭐ 顺序由策略决定（LLVM 后端那一半）：覆盖成后进先出后，先跑的是后决出的那个")
    func thePolicyDecidesTheOrderOnTheEmittingLeg() throws {
        /// 意图：这半格此前**建立不起来** —— 一份替换掉调度器的程序在 LLVM 后端上不被接受
        /// （同一个类型上出现两个同名的方法定义），于是覆盖块形同虚设。合并那一处补上之后，
        /// 各后端才都问得出「先跑谁由谁决定」。
        ///
        /// 推进性：默认策略下顺序**等于决出顺序**（甲先于乙）—— 这一步同时证明语料里的两个闸
        /// 确实先后决出，否则后一条读数没有意义。驳回性：只多那段覆盖块，先跑的必须变成乙。
        try assertBothLegsMatch(
            Self.strategyOrderCorpus(overriding: false), expecting: ["父续", "甲", "乙"],
            label: "默认策略")
        try assertBothLegsMatch(
            Self.strategyOrderCorpus(overriding: true), expecting: ["父续", "乙", "甲"],
            label: "覆盖成后进先出")
    }
    /// 各后端各跑一次这份程序，**各自**与同一份手写期望比输出。
    ///
    /// ⛔ 不比退出码：本仓实测过「底层工具报错、而命令行仍返回成功码」的形态（本段的语料
    /// 当时就是 `rc=0`），退出码单独用是**弱判据**，输出才是。
    /// ⛔ 也不比让出读数：本函数服务的语料要么零处 `await`、要么让出次数不是本格要问的东西
    /// ⇒ 硬塞一维进来会是个空维。
    ///
    /// ⚠️ 期望值全部**手写**、逐字节比，⛔ 不从任何一个后端的输出回抄。
    @discardableResult
    private func assertBothLegsMatch(
        _ program: String, expecting expected: [String], label: String
    ) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let cli = environment["PINI_CLI_BIN"] ?? ""
        guard !cli.isEmpty, !(environment["PINI_LLVM_BIN"] ?? "").isEmpty else {
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
    ///
    /// 这样各后端（一条收行、一条收字节流）才在**同一个量**上比 —— 否则「行数组」与
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

/// 只数**本次运行**让出次数的后端：把生产后端整个委派出去，只在体的结局上挂一个计数。
///
/// ⚠️ 为什么不能直接读进程级单例的增量：那个计数是**整台进程**的读数，并行的另一条用例
/// 让出一次就把它挪走 ⇒ 判据既可能在自己的程序**没**让出时报绿（读到别人的数），
/// 也可能在自己的程序让出时读出**别人的次数**。本件要断的是**精确值**（`= 1`），
/// 增量式的「至少一次」给不了这个判别力。包装一层就只数自己的。
///
/// ⚠️ **两个来源都落在这里 ⇒ 本类型与 LLVM 后端那个计数器是同一个量**：派发那一趟由派发口调，
/// **续跑那几趟**由引擎在让出被消费时调（续跑不经派发口）。⛔ 少掉任一侧，本类型就只数得到
/// 「首跑那一趟」，而那种漏计**没有症状** —— 两边的数各自都看不出错，
/// 差别只在「一个体内让出多次」的程序上显形。
///
/// ⚠️ 与 `ConcurrencyCapabilitiesTests` 里那个替身后端**不是同一件事**：那个宣告
/// 「本后端不能让出」（`yieldTask()` 恒返 `0`）以检验降级纪律；本类型**照常让出**，
/// 只是把次数记下来 ⇒ 它验的是读数，不是纪律。
/// ⚠️ **本类型刻意不是私有的**：让出口径的两条判据分居两处（一处按契约参照跑各后端、
/// 一处在只读进程内读数的件里），而**两侧必须读出同一个数** ⇒ 两处都要能构造它。
/// 这不是「为了方便共享」，是那条判据的形态要求：只保一侧的话，「归并完成」会变成一侧的完成。
final class YieldCountingScheduler: Scheduler {
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

    func spawn(_ future: FutureValue, work: @escaping () throws -> TaskRunOutcome) {
        inner.spawn(future) {
            let outcome = try work()
            if case .suspended = outcome { self.noteYield() }
            return outcome
        }
    }

    /// 记账**自己收**、⛔ 不委派给 `inner` —— 本类型数的是「**本次运行**」，
    /// 而 `inner` 的计数是**进程级**的（并行的另一条用例让出一次就把它挪走）。
    ///
    /// ⚠️ 它与派发口里那一处**配对**：续跑那几趟不经派发口，故必须在这里也收一次
    /// —— 否则本替身只数得到首跑那一趟，与生产后端再度分岔，而两边的数**各自都看不出错**。
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
