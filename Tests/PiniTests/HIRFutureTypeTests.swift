import Testing

@testable import PiniCore

/// `DE-3a`：句柄与结算值是**两个类型**。
///
/// 这批把「一次异步调用的结果」在中间表示里从「一个 `Result`」改成「一个句柄」，
/// 好让后端能分辨「该派发到线程的调用」与「该直接调用的调用」。改动落在**类型**上，
/// 所以判据也钉类型，而不是钉运行输出 —— 后者在本批里**故意不变**。
///
/// 五条里两条是**驳回性**的，它们守的是「这次分叉不许越界」：
/// 体协议那一侧不能被一起改掉（否则后端会拿句柄的类型去搬一个聚合值），
/// 结算翻译也不许对着非句柄臆造一个结果。
@Suite("HIR 的句柄类型")
struct HIRFutureTypeTests {

    /// 语料刻意**只用一个维度**：一个异步函数、一个同步函数、两条等待。
    /// 同步那一条是阳性对照 —— 它证明分叉是**只在异步上**发生的，不是「所有调用都变了」。
    private static let corpus = #"""
    慢|func(n: I32,) => (I32,):
        return ok(n)

    同步取|func(n: I32,) -> (I32,):
        return n

    main|func() -> ():
        let t = 慢(1)
        let s = 同步取(2)
        let r = try wait t else e:
            return
        print(r)
        print(s)
        return
    """#

    /// 每个测试件各持一份（本仓惯例）：语料内联，不落夹具文件。
    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        try checker.check(module: module)
        return (module, checker)
    }

    private func lowered(_ source: String) throws -> HIRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    private func function(_ name: String, in module: HIRModule) throws -> HIRFunction {
        try #require(
            module.functions.first { $0.name == name },
            "模块里没有函数 \(name)：\(module.functions.map(\.name))"
        )
    }

    private func allocVar(
        named name: String, in block: HIRBlock
    ) throws -> (type: HIRType, initializer: HIRExpr?) {
        for statement in block {
            if case .allocVar(let slotName, let type, _, let initializer) = statement,
                slotName == name
            {
                return (type, initializer)
            }
        }
        throw TestError.missing("函数体里没有变量 \(name)")
    }

    private enum TestError: Error {
        case missing(String)
    }

    // MARK: - 推进性

    @Test("异步函数调用之后，变量槽的类型是句柄 —— 不再是它将来会结算成的那个值")
    func anAsyncCallBindsAHandle() throws {
        let module = try lowered(Self.corpus)
        let main = try function("main", in: module)

        let slot = try allocVar(named: "t", in: main.body)
        #expect(
            slot.type == .future(ok: .i32),
            "变量槽应是句柄，实际是 \(slot.type)"
        )
    }

    @Test("join 站点把句柄结算成 Result —— 读进来的东西是句柄，存下来的东西是结算值")
    func aJoinSiteSettlesTheHandleIntoAResult() throws {
        let module = try lowered(Self.corpus)
        let main = try function("main", in: module)

        // 等待站点上有两个不同的类型，判据要把它们**分别**取出来：
        // 被等待的那个值的类型，挂在操作数节点自己身上；
        // 站点产出的类型，挂在站点上。
        // ⚠️ 站点上的那个字段**不是**操作数的类型 —— 它一开始被我按操作数类型读过，
        // 于是判据报红而实现是对的。先把两个位置分清，再断言。
        var awaitedType: HIRType? = nil
        var siteType: HIRType? = nil
        for statement in main.body {
            if case .tryStmt(.join(let awaited, let site, _), _, _, _, _) = statement {
                siteType = site
                if case .load(_, let type) = awaited { awaitedType = type }
            }
        }

        let awaited = try #require(awaitedType, "等待的操作数不是一次变量读取")
        let site = try #require(siteType, "等待站点没有带类型")

        #expect(awaited == .future(ok: .i32), "被等待的值应是句柄，实际是 \(awaited)")
        #expect(site == .result(ok: .i32), "站点应结算成 Result，实际是 \(site)")
    }

    // MARK: - 驳回性（守改动边界）

    @Test("异步函数的体协议没被一起改掉 —— 节点带的是被调用方真正产出的那个值")
    func theCallNodeStillCarriesTheBodyProtocol() throws {
        let module = try lowered(Self.corpus)
        let async = try function("慢", in: module)

        // 函数自己的返回类型是**体**的类型：它的 `return ok(n)` 要对着这个检查。
        // 若这一侧一起变成句柄，体里所有 `return ok(v)` 都会失去类型依据，
        // 而后端也会拿句柄的表示去搬一个聚合返回值。
        #expect(async.isAsync, "慢 应当是异步函数")
        #expect(
            async.returnType == .result(ok: .i32),
            "体的返回类型应是 Result，实际是 \(String(describing: async.returnType))"
        )

        // 调用节点上的协议槽同理：它是发射层照以搬值的那个类型。
        let main = try function("main", in: module)
        let slot = try allocVar(named: "t", in: main.body)
        guard case .call(_, _, let nodeProtocol)? = slot.initializer else {
            Issue.record("期望调用节点，实际是 \(String(describing: slot.initializer))")
            return
        }
        #expect(
            nodeProtocol == .result(ok: .i32),
            "调用节点的协议槽应是体协议（Result），实际是 \(String(describing: nodeProtocol))"
        )
    }

    @Test("同步函数不参与这次分叉 —— 两侧类型仍是同一个")
    func synchronousCallsKeepBothTypesEqual() throws {
        let module = try lowered(Self.corpus)
        let main = try function("main", in: module)

        let slot = try allocVar(named: "s", in: main.body)
        #expect(slot.type == .i32, "同步调用的变量槽应是 I32，实际是 \(slot.type)")

        guard case .call(_, _, let nodeProtocol)? = slot.initializer else {
            Issue.record("期望调用节点，实际是 \(String(describing: slot.initializer))")
            return
        }
        #expect(
            nodeProtocol == slot.type,
            "同步调用上两侧应当相同：节点带 \(String(describing: nodeProtocol))，表达式是 \(slot.type)"
        )
    }

    @Test("结算翻译只对句柄说话 —— 在别的类型上它保持沉默，不臆造一个结果")
    func theSettlementTranslationOnlySpeaksAboutHandles() {
        #expect(HIRType.future(ok: .i32).joinedResultType == .result(ok: .i32))
        // 已经是结算值的，不再翻译一次。
        #expect(HIRType.result(ok: .i32).joinedResultType == nil)
        // 标量上更不该有。
        #expect(HIRType.i32.joinedResultType == nil)
        #expect(HIRType.string.joinedResultType == nil)
    }
}
