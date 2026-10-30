import Foundation
@testable import PiniCore
import Testing

/// 派发点的后端由语言侧决定：程序说明它用哪个调度器，派发点照着办。判据不能只看程序输出 ——
/// 声明不能让出时等待退化为占用线程、结果分毫不变 ⇒ 输出区分不出「声明被读到」与「引擎没理那句声明」。
/// 故读引擎侧的能力自述；且零派发：接线在装载期就定，后端又是进程级单例，并行派发会耗尽线程。
struct SchedulerWiringTests: Sendable {

    // MARK: - 私有 helper

    private func lowered(_ source: String) throws -> IRModule {
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
        return try IRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 只装载、不运行，返回引擎。⭐ 本件的主测量形态（见类型说明）。
    private func prepared(_ source: String, scheduler: Scheduler? = nil) throws -> IRExecutor {
        let executor = IRExecutor(
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

    /// 一份只有同步代码、且不读任何字段的语料。判据要测的事在装载期就定了，与执行无关，故不必并发 ——
    /// 这正是本件避开线程竞争的办法。刻意不读字段：用户整块替换声明时预置字段随之消失，读字段名就会
    /// 变成验「用户有没有把字段也写一遍」。取用形参留着，它还证明替换声明后取用位仍解析得出这个类型名。
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
        /// 意图：本件的核心 —— 「派发点用哪个调度器」这一格改由程序说了算。本条必须读引擎侧的能力自述：
        /// 只看程序输出，「接线断了」与「接线生效」给出同一个读数。
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
        /// 意图：用户可以整块替换那份声明，替换时没提到的这一格不应当被罚 —— 该名字的处置承诺「零破坏性」，
        /// 拿一处没写去罚一处没改正好违反它。这条同时是故意留的缝：区分力不靠它，靠判据 1 那条显式声明。
        let executor = try prepared(
            "[调度器|given]\n    名称: String = \"我的\"\n\n" + Self.同步语料)
        #expect(
            executor.dispatchBackEndCapabilities.supports(.yield),
            "没提这一格时应当取语言默认（可让出），而不是被当成改坏")
    }

    @Test("那一格的初值不是布尔时，同样取语言默认 —— 宽容读法只认字面量")
    func aFieldThatIsNotABoolFallsBackToTheDefault() throws {
        // 意图：宽容读法的边界在于它认的是字面量。本条同时钉住「不求值」：若读声明时
        // 在装载期物化实例再读它的值，本判据仍会绿（退回默认），而那种实现是错的（装载期求值会碰
        // 尚未就绪的执行状态）⇒ 它由本件的零派发形态守着，不由这一条的读数守着。
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
