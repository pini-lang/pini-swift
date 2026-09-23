import Foundation
@testable import PiniCore
import Testing

/// 调度特征的**预置默认实例** —— 它由宿主给出，且必须**取得到**。
///
/// **这一件测什么**：语言提供的默认调度实例是一条**取用通路**：一个 `using` 形参
/// 声明成该类型、调用点省略那个实参，就能拿到它。通路若只写在形状文件里，
/// 那么「默认实现」就只是一句话 —— 取不到的东西谈不上是默认值。
///
/// ⚠️ 本件**不测**策略自身的逻辑：那个方法的抽象方法集今天为空（它的严格形状依附于
/// 「任务在语言里怎么表示」这一面，而那一面还没有载体）。本件只管：
/// **取得到** · **取到的实例带着它声明的字段** · **名字没被钉成保留字** · **用户可以顶掉它**。
///
/// ⭐ **为什么判据要读到字段，而不是只断言「不报错」**：默认实例的物化路径与普通复合类型
/// 是同一条，而**类型表**与**名义表**是两张表 —— 只进后者时，字段在静态期读得出来、
/// 运行时却报该类型无此字段。那正是本段第一次跑通的形态：程序过静态检查、跑起来才断。
/// ⇒ 断言落在**运行结果**上，两步都被覆盖。
struct SchedulerDefaultInstanceTests {

    // MARK: - 私有 helper

    private func parsed(_ source: String) throws -> Module {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let result = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard result.errors.isEmpty else { throw result.errors[0] }
        return ConstantFolder.foldConstants(in: result.module)
    }

    /// 过语义层与类型层，返回类型错误（空数组 = 两侧都通过）。
    private func typeErrors(_ source: String) throws -> [TypeError] {
        let module = try parsed(source)
        try SemanticAnalyzer().analyze(module: module)
        return TypeChecker().checkCollecting(module: module)
    }

    /// 走**收集模式**入口的语义层错误。
    ///
    /// ⚠️ 这个入口不是备选路径：**命令行实际走的是它**，而上面那个走的是单错误入口。
    /// 两者是同一套初始化的**两份平行拷贝** ⇒ 只在一处登记预置声明时，
    /// 另一条路上的那个名字**照旧**被报成「未定义的变量」，而单元测试却全绿。
    /// ⇒ 每条「某名字必须被认识」的判据，都要问：**两条入口都测到了吗。**
    private func collectingErrors(_ source: String) throws -> [SemanticError] {
        SemanticAnalyzer().analyzeCollecting(module: try parsed(source))
    }

    /// 跑到底，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        let module = try parsed(source)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let errors = checker.checkCollecting(module: module)
        guard errors.isEmpty else { throw errors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        let lowered = try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
        var lines: [String] = []
        let executor = HIRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: GCDScheduler.shared)
        executor.outputSink = { lines.append($0) }
        try executor.run(module: lowered)
        return lines
    }

    /// 把「抛出的诊断」摊平成「判定码 + 文案」；没抛则返回 nil。
    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            return ((error as? any DiagnosticProviding)?.diagnosticCode ?? "?", String(describing: error))
        }
    }

    /// 一份取默认实例并读它可观测面的语料。
    private static func corpus(field: String) -> String {
        """
        取默认|func(using s: 调度器,) -> (String,):
            return s.\(field)

        main|func() -> ():
            print(取默认())
            return
        """
    }

    // MARK: - 判据 1：取得到（推进性）

    @Test("省略取用实参时默认实例真的被取得 —— 读得出它声明的字段")
    func theDefaultInstanceIsObtainableAndCarriesItsField() throws {
        /// 意图：这是一条**通路**判据。断言的是运行结果，不是「没报错」——
        /// 因为默认实例要先被物化、字段才读得出，而物化走的是普通复合类型那条路。
        /// ⚠️ 本判据在预置声明缺席时**必红**（实测形态：`using` 形参的类型解析不出来）。
        let lines = try runOutput(Self.corpus(field: "名称"))
        #expect(lines == ["默认"], "the default instance was not obtained, or its field was empty: \(lines)")
    }

    @Test("同一份语料在静态检查侧也通过 —— 通路不是只对运行路径敞开")
    func theSameCorpusPassesTypeCheckingAlone() throws {
        /// 意图：类型层与降载层是两张表。只在降载层登记时，静态侧会先拒 ——
        /// 而两侧给出的答案不一致本身就是缺陷（同一个程序，一个入口说能写、另一个说不能）。
        ///
        /// ⚠️ **本条不区分「通路在不在」**，这是实测出来的（两轮变异都没能让它变红）：
        /// 类型标注位对未知名字本就宽容，故只有特征形态时静态侧照样过 —— 它的作用是守
        /// 「**不误拒**」这一侧，而不是证明通路存在。证明通路存在的是运行面那几条。
        let errors = try typeErrors(Self.corpus(field: "名称"))
        #expect(errors.isEmpty, "type check rejected it: \(errors.map(\.diagnosticCode))")
    }

    // MARK: - 判据 2：阴性对照（驳回性）

    @Test("没有预置声明的类型名仍取不到 —— 判据有区分力")
    func anUnknownTypeStillHasNoDefaultInstance() throws {
        /// 意图：正向那条在「登记生效」与「登记根本没查」两种实现下**都会绿**
        /// ⇒ 必须有一条能红的对照。若某一版把取用位放宽成「任何名字都放行」，本条会红。
        let source = """
        取默认|func(using s: 没有这个类型,) -> (String,):
            return "x"

        main|func() -> ():
            print(取默认())
            return
        """
        let failed = failure { _ = try runOutput(source) }
        #expect(failed?.code == "E6-004", "实际判定码 \(failed?.code ?? "无（被接受了）")")
    }

    // MARK: - 判据 3：名字没有被钉成保留字（软关键字的承诺）

    @Test("用户自己写一个同名函数并按名调用它 —— 该名字不是保留字")
    func aUserFunctionMayStillTakeThatName() throws {
        /// 意图：该名字的处置是**软关键字**：它不作保留字，今天合法的标识符保持合法。
        /// ⚠️ 实测踩过一次：只把预置名当成「已被占用的类型名」而不问本程序自己声明了什么，
        /// 会让这处调用被解析成「该类型的构造」⇒ 既有程序**静默换义**。
        /// 本条钉的是那条让位规则（用户声明优先）。
        let source = """
        调度器|func(x: I32,) -> (I32,):
            return x

        main|func() -> ():
            print(调度器(5))
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["5"], "a user function with that name was hijacked: \(lines)")
    }

    // MARK: - 判据 4：用户可以顶掉默认实例

    @Test("用户自己声明同名块时，取到的是用户那份 —— 预置声明让位")
    func aUserDeclarationReplacesTheDefault() throws {
        /// 意图：默认实例是**默认**的：可以替换。若预置声明抢在用户声明之前、
        /// 或两者同时进表，取到的会是预置那份（`默认`），而本判据要红。
        let source = """
        [调度器|given]
            名称: String = "我自己写的"

        取默认|func(using s: 调度器,) -> (String,):
            return s.名称

        main|func() -> ():
            print(取默认())
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["我自己写的"], "the preset declaration won over the user's own: \(lines)")
    }

    // MARK: - 判据 5：预置块可被像普通类型那样扩展

    @Test("给预置块加方法后，默认实例上调用得到它")
    func thePresetBlockAcceptsUserExtension() throws {
        /// 意图：预置声明与用户声明的**行为**应当一致 —— 否则「预置」就成了一种二等类型。
        /// 它同时钉住让位规则的一处边界：**扩展块不算占名**（它挂在一个别处声明的类型上），
        /// 若把它算进去，本判据会红 —— 而红的原因会读起来像「预置块不能扩展」。
        let source = """
        [[调度器]]
            问好|self() -> (String,):
                return "你好"

        取默认|func(using s: 调度器,) -> (String,):
            return s.问好()

        main|func() -> ():
            print(取默认())
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["你好"], "a method added to the preset block was not reachable: \(lines)")
    }

    // MARK: - 判据 6：值位诊断对**预置**块也生效（与用户声明的块同一条）

    @Test("预置块的名字出现在值位时，给的是可行动诊断 —— 两处对同一件事给出同一答案")
    func thePresetBlockNameIsDiagnosedInValuePosition() throws {
        /// 意图：同一个名字，**用户自己声明成给定块**时早有一条可行动诊断
        /// （「该类型名不能作值，请改用取用参数」），而**语言预置**的那份此前拿到的是
        /// 「未定义的变量」—— 一条**旧式**诊断，读起来像拼错了名字，而那个名字确实存在。
        ///
        /// ⚠️ 本判据**必须**钉住**判定码**而不是「报了错就行」：旧式与新式都报错，
        /// 断言「有错误」会让两种实现都通过 —— 而那正是本条要区分的东西。
        ///
        /// ⚠️ 命名一致性与让位规则是**同一批工作的两半**，判据 3 钉另一半：
        /// 把预置名并进诊断的判定集，等于让它在**任何**值位都不可用
        /// ⇒ 若同时不做出「用户占名则预置让位」，用户自己写的同名函数会被判红。
        /// 两半必须同时在场，本件与判据 3 一起构成那个「同时」。
        let source = """
        取|func(x: String,) -> (String,):
            return x

        main|func() -> ():
            print(取(调度器))
            return
        """
        let failed = failure { _ = try runOutput(source) }
        #expect(
            failed?.code == "E4-015",
            "实际判定码 \(failed?.code ?? "无（被接受了）") —— 期望可行动诊断，而不是「未定义的变量」")
    }

    @Test("收集模式那条入口同样认识这个名字 —— 两条入口不得给出两个答案")
    func theCollectingEntryAlsoKnowsThePresetName() throws {
        /// 意图：语义层那套初始化有**两份平行拷贝**（`pini check` 走收集模式，单元测试走另一条）
        /// ⇒ 「预置名被登记」这件事**两处都要做**，只做一处会伪装成已修好：
        /// 另一条路上那个名字仍被判「未定义变量」。
        ///
        /// ⚠️ 断言的是**「不报未定义变量」**而不是「没有错误」：收集模式只跑语义层，
        /// 值位那条可行动诊断生在类型层 ⇒ 本入口本来就不该报它。
        /// 断错这一格会让本判据永远红（把「本该没有的错误」当成漏做）。
        let source = """
        取|func(x: String,) -> (String,):
            return x

        main|func() -> ():
            print(取(调度器))
            return
        """
        let codes = try collectingErrors(source).map(\.diagnosticCode)
        #expect(
            !codes.contains("E3-001"),
            "收集模式入口把预置名判成未定义 —— 那个名字确实存在，只是不能作值：\(codes)")
    }

    // MARK: - 判据 7：策略层两个方法都调得动（接口真的在）

    @Test("默认实例上「收下」与「选择下一个任务」都调得动 —— 接口不是只登记了名字")
    func bothStrategyMethodsAreCallableOnTheDefaultInstance() throws {
        /// 意图：方法**存在**（名字登记了）与「调用得通」是两件事 —— 降载层没把方法体接上时，
        /// 调用点以「该类型没有这个方法」告终，而那是**跑起来才知道**的形态。
        /// 断言落在运行输出上，故静态与运行两步都被覆盖。
        let source = """
        探|func(using s: 调度器,) -> (I32,):
            s.收下(空句柄)
            print(s.选择下一个任务())
            return 1

        main|func() -> ():
            print(探())
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["0", "1"], "策略层的两个方法没有都调通：\(lines)")
    }

    // MARK: - 判据 8：空队列的答案是空句柄

    @Test("队列为空时「选择下一个任务」给出空句柄 —— 不报错，也不是别的值")
    func anEmptyQueueYieldsTheEmptyHandle() throws {
        /// 意图：空队列是策略层**必然遇到**的一格（刚建好的调度器就是空的）。
        /// ⚠️ 它今天走的**是特征默认体**：真正的先进先出实现要等「结果决出 ⇒ 入队」那一段
        /// 才有对象可挑 ⇒ 本判据此刻钉的是「空队列这一格有答案」。
        /// ⚠️ 「非空队列返回队首」今天**验不了** —— 语言里只构造得出一个句柄值（空句柄本身），
        /// 两个不同的句柄无从区分。
        let source = """
        空|func(using s: 调度器,) -> (I32,):
            print(s.选择下一个任务())
            return 1

        main|func() -> ():
            print(空())
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["0", "1"], "空队列没有给出空句柄：\(lines)")
    }

    // MARK: - 判据 9 / 10：覆盖生效 · 与它的阴性对照（互为一对，不可拆开）

    /// 一对判据共用的语料 —— 两份只差一段 `[[调度器]]` 扩展块。
    ///
    /// ⭐ **为什么必须成对**：单看「覆盖后队列为空」那一格，「覆盖生效」与「`收下` 根本没被调到」
    /// 两种实现**读数完全相同** ⇒ 一条正向判据在这里没有区分力。成对之后，两条读数
    /// （0 与 1）互为反证，任一侧的实现走偏都会让其中一条转红。
    private static func queueLengthCorpus(overriding: Bool) -> String {
        let overrideBlock = overriding ? """
        [[调度器]]
            收下|self(任务: *U8,) -> ():
                return

        """ : ""
        return """
        \(overrideBlock)数|func(using s: 调度器,) -> (I32,):
            s.收下(空句柄)
            return len(s.元素)

        main|func() -> ():
            print(数())
            return
        """
    }

    @Test("用户覆盖「收下」后跑的是用户那一份 —— 默认实现在队列上不动手")
    func aUserOverrideReplacesThePresetBody() throws {
        /// 意图：可替换性的兑现面。用户那份**不往队列里放**东西 ⇒ 读到的长度是 0。
        let lines = try runOutput(Self.queueLengthCorpus(overriding: true))
        #expect(lines == ["0"], "覆盖没有生效，用户那份没被跑到：\(lines)")
    }

    @Test("未覆盖时跑的是预置那一份 —— 收到的任务真的进了队列（阴性对照）")
    func thePresetBodyActuallyEnqueues() throws {
        /// 意图：上一条的对照。预置的「收下」把任务接到队尾 ⇒ 长度从 0 变成 1。
        /// ⚠️ 这一格同时钉住一处**易漏**：队列字段走的是**函数式**更新（`append` 返回新数组），
        /// 漏了写回字段这一步，任务会**静默丢掉** —— 不报错、调用方看不出异常，读数退回 0。
        /// 也就是说：本判据是那条实现在今天**唯一**的观测面。
        let lines = try runOutput(Self.queueLengthCorpus(overriding: false))
        #expect(lines == ["1"], "预置的「收下」没有把任务接到队列里：\(lines)")
    }

    // MARK: - 判据 11：取走队首时它真的离开了队列

    @Test("取走队首后队列少一个 —— 「选择下一个任务」把它移出了队列")
    func pickingMovesTheHeadOutOfTheQueue() throws {
        /// 意图：先进先出的**移出**那一半。
        /// ⚠️ 它必须独立成条：那个方法的**返回值**今天验不了（语言里只构造得出一个句柄值，
        /// 取到队首与取到空句柄读数相同）；能验的是**队列长度的变化**。
        /// ⚠️ 而「取走不移」正是最容易漏的一步 —— 队列字段是函数式更新（`slice` 返回新数组），
        /// 漏了写回字段，下一次还会拿到同一个任务，而读数退回 1（本判据转红）。
        let source = """
        取|func(using s: 调度器,) -> (I32,):
            s.收下(空句柄)
            print(len(s.元素))
            s.选择下一个任务()
            return len(s.元素)

        main|func() -> ():
            print(取())
            return
        """
        let lines = try runOutput(source)
        #expect(lines == ["1", "0"], "取走队首后队列长度没有减少：\(lines)")
    }
}
