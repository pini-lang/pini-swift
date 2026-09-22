import Foundation
@testable import PiniCore
import Testing

/// 派发点的后端**由语言侧决定** —— 程序说明它用哪个调度器，派发点照着办。
///
/// **这一件测什么**：在它之前，「派发点用哪个调度器」是引擎里写死的一个常量，
/// 唯一能改动它的办法是宿主注入一个替身 —— 而那种改动**语言看不见**。
/// 本件钉的是接线后的一半：程序里那句声明**真的被派发点读了**。
///
/// ⚠️ **为什么判据不能只看程序输出**：声明不能让出时，等待退化为占用线程、
/// 结果**分毫不变**（那是「语义保持、只降执行策略」的内容）
/// ⇒ 输出这一侧**区分不出**「声明被读到了」与「引擎根本没理那句声明」。
/// 故本件读的是引擎侧的后端能力自述 —— 那是这条接线的**读侧**，
/// 也是它今天**唯一**的可观测面。
///
/// ⚠️ **为什么判据不跑并发语料**：这件事发生在**装载期**（解析落在那里），
/// 所以装载之后就能读，⛔ 不必真去派发任务。这不是为省时间：
/// 本引擎的后端背压会**阻塞调用线程**，而那个后端是**进程级单例**
/// ⇒ 在同一进程里并行跑多个并发程序（正是测试的处境）会把线程耗尽，
/// 实测形态是**同进程另一条不相关的判据超时、整个测试进程段错误**。
/// ⇒ 零派发是本类判据的**硬约束**，不是风格偏好。
///
/// ⚠️ **端到端那一半由既有判据覆盖**：「后端兑现不了让出时，程序仍跑完、结果不变」
/// 已有独立判据（用注入的替身后端）。本件不重复它 ——
/// 本件补的是它没覆盖的那半：**那个后端是语言声明挑的**。
///
/// ⚠️ 两条边界（本件不测）：① **策略自身**（队列 · 优先级 · 选择下一个任务）——
/// 语言今天无此表示，方法集为空；② **后端本体**（池容 · 背压）仍属宿主，
/// 本件测的是「按谁的声明作答」，不是「换了一个后端」。
struct SchedulerWiringTests {

    // MARK: - 私有 helper

    private func lowered(_ source: String) throws -> HIRModule {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 只装载、不运行，返回引擎。⭐ 本件的主测量形态（见类型说明）。
    private func prepared(_ source: String, scheduler: Scheduler? = nil) throws -> HIRExecutor {
        let executor = HIRExecutor(
            programBase: NSTemporaryDirectory(), ffiConfig: .default, scheduler: scheduler)
        try executor.prepare(module: try lowered(source))
        return executor
    }

    private func failure(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return (error as? any DiagnosticProviding)?.diagnosticCode
        }
    }

    /// 一份**只有同步代码、且不读任何字段**的语料。
    ///
    /// 判据要测的事在装载期就定了，与执行无关，故它不必并发 —— 这正是本件避开线程竞争的办法。
    /// ⚠️ **刻意不读字段**：用户整块替换那份声明时（那正是让位规则生效的场景），
    /// 预置块里的字段随之消失 ⇒ 语料一旦读某个字段名，验的就不是本件要测的事，
    /// 而是「用户有没有把那个字段也写一遍」。取用形参本身留着，因为它还证明一件事：
    /// **替换声明之后，取用位仍解析得出这个类型名**。
    private static let 同步语料 = """
    取|func(using d: 调度器,) -> (I32,):
        return 1

    main|func() -> ():
        print(取())
        return
    """

    // MARK: - 判据 1：语言侧的声明真的被派发点读到（核心）

    @Test("程序声明调度器不能让出时，派发点照着它答 —— 而不是照引擎那个常量")
    func theDispatchBackEndHonoursTheDeclaredCapability() throws {
        /// 意图：这是本件的核心 —— 「派发点用哪个调度器」这一格改由**程序**说了算。
        ///
        /// ⚠️ 本条**必须**读引擎侧的能力自述（理由见类型说明）：只看程序输出，
        /// 「接线断了」与「接线生效」给出同一个读数。
        let executor = try prepared(
            "[调度器|given]\n    可让出: Bool = false\n\n" + Self.同步语料)
        #expect(
            !executor.dispatchBackEndCapabilities.supports(.yield),
            "派发点没读程序里那句声明 —— 它仍宣称可以让出")
        #expect(
            executor.dispatchBackEndCapabilities.supports(.dispatch),
            "接线把调度本身弄丢了 —— 那是把能力那一格换成了空位图")
    }

    // MARK: - 判据 2：没有用户声明时，语言预置的那份生效

    @Test("程序没提调度器时，派发点取语言预置的那份 —— 它宣称可以让出")
    func withoutAUserDeclarationThePresetOneApplies() throws {
        /// 意图：判据 1 单独在场时，「接线永远答不能让出」这种实现照样绿
        /// ⇒ 必须有另一侧钉住默认。同时钉住分层：换的是**能力那一格**，
        /// 调度（L0）必须还在 —— 否则那种实现读起来像「本语言不支持并发」。
        let executor = try prepared(Self.同步语料)
        #expect(
            executor.dispatchBackEndCapabilities.supports(.yield),
            "没有用户声明时，派发点应当取语言预置那份（它宣称可以让出）")
        #expect(
            executor.dispatchBackEndCapabilities.supports(.dispatch),
            "接线把调度本身弄丢了")
    }

    // MARK: - 判据 3：宽容读法（没提这一格 ≠ 红；非布尔也只认字面量）

    @Test("用户替换了那份声明、但没提这一格时，取语言默认 —— 不算改错")
    func aReplacementThatOmitsTheFieldStillRuns() throws {
        /// 意图：用户可以整块替换那份声明。替换时**没提到**这一格，不应当被罚 ——
        /// 该名字的处置有一条承诺是「零破坏性」，而拿一处**没写**去罚一处**没改**的地方
        /// 正好违反它。⚠️ 这条同时是**故意留的缝**：判据的区分力不靠它，
        /// 靠的是判据 1 那条**显式**声明（它会真的变红）。
        let executor = try prepared(
            "[调度器|given]\n    名称: String = \"我的\"\n\n" + Self.同步语料)
        #expect(
            executor.dispatchBackEndCapabilities.supports(.yield),
            "没提这一格时应当取语言默认（可让出），而不是被当成改坏")
    }

    @Test("那一格的初值不是布尔时，同样取语言默认 —— 宽容读法只认字面量")
    func aFieldThatIsNotABoolFallsBackToTheDefault() throws {
        /// 意图：宽容读法的边界要说清 —— 它认的是**字面量**。
        /// ⚠️ 它同时钉住「不求值」这一条：若哪天有人把读声明写成
        /// 「在装载期物化实例再读它的值」，本判据仍会绿（退回默认），
        /// 而**那种实现是错的**（装载期求值会碰一套尚未就绪的执行状态，实测代价见类型说明）
        /// ⇒ 它由本件的**零派发**形态与全量回归共同守着，而不是由这一条的读数守着。
        let executor = try prepared(
            "[调度器|given]\n    可让出: I32 = 0\n\n" + Self.同步语料)
        #expect(
            executor.dispatchBackEndCapabilities.supports(.yield),
            "非布尔初值应当退回语言默认，而不是被当成 false")
    }

    // MARK: - 判据 4：注入仍然赢（保住既有的替身后端面）

    @Test("宿主注入后端时，语言侧的声明不生效 —— 注入是构造期说的话")
    func anInjectedBackEndOverridesTheDeclaredCapability() throws {
        /// 意图：注入面是**既有**的，而「降级而不失败」那条纪律的判据正是经它摆进替身后端的
        /// ⇒ 接线不许把它挤掉。若哪天有人在解析时无视注入值，本判据会红 ——
        /// 而那种实现读起来像「语言侧声明总是赢」，不像「判据再也摆不进替身后端」。
        let executor = try prepared(
            "[调度器|given]\n    可让出: Bool = false\n\n" + Self.同步语料,
            scheduler: GCDScheduler.shared)
        #expect(
            executor.dispatchBackEndCapabilities.supports(.yield),
            "注入的后端被语言侧声明盖过了 —— 替身后端的口子被封住了")
    }

    // MARK: - 判据 5：阴性对照（接线没有放宽取用位）

    @Test("引擎接入语言侧后端之后，未登记的类型名仍取不到 —— 判据有区分力")
    func theWiringDidNotLoosenTheObtainSide() throws {
        /// 意图：接线只该换**后端**，不该碰**取用位**。若有某一版顺手把取用放宽成
        /// 「任何名字都放行」，本条会红。它与判据 1 合起来，把「换对了东西」与
        /// 「顺手把门开大了」两件事分开。
        let source = """
        取默认|func(using s: 没有这个类型,) -> (String,):
            return "x"

        main|func() -> ():
            print(取默认())
            return
        """
        let code = failure { _ = try self.lowered(source) }
        #expect(code == "E6-004", "实际判定码 \(code ?? "无（被接受了）")")
    }
}
