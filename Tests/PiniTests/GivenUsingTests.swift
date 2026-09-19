import Foundation
import PiniCore
import Testing

/// ADR-001（给定块 `given` / 取用参数 `using`）判据 —— `P1a` / `P1` / `P1b` 三批同住一件。
///
/// **`P1a` 的实质交付**：方括号从「枚举扩展」改为**通用扩展形** —— 归并时按**目标的实际
/// 注册类别**落表，而不是按定界符预设类别。三形糖（`((` / `{{` / `<<`）的 kind 语义不变。
///
/// **`P1` 的实质交付**：`using` **入关键字表**（实现侧计数 33 → 34，与规范侧同批同值），
/// 并在**参数位**接出前缀 ⇒ `Parameter.isUsing` → `HIRParam.isUsing`（降载层不断链）。
/// ⚠️ 入表是**破坏性**的：今日合法的标识符 `using` 变成保留字。它与 `given` 的处置相反
/// —— 后者只出现在 `|` 右侧的修饰符位、走标识符白名单、**不入**表；两半各有判据钉住。
///
/// **`P1b` 的实质交付**：给定块**进入降载归并表** ⇒ `[[给定块名]]` 的方法真的归并进块的
/// 方法表（`P1a` 只在注释里这么写过，实测**并未成立** —— 给定块当时落 `default: break`，
/// 其方法被静默丢弃）；三形扩展的目标**未声明**、或**指向特征**时**响亮拒绝**（新码
/// `E6-006`），今日为静默丢弃。⚠️ 枚举与泛型模板目标**不在**该诊断的射程内（各自维持今日行为）。
///
/// **`P2b` 的实质交付**：中间态**结束**。给定块进**类型面**（与结构 / 对象同规），
/// 默认实例在 `using` 取用点物化：省略的实参由编译器插入取用点，发射层发一个程序级**槽位**
/// 加一个合成的初始化函数，解释器侧一张表加记忆化。中间态的三处痕迹随之作废并**逐条改判**
/// （拒绝 → 类型面；归并计数文案 → 方法表本身）。
///
/// **仍然不做的**：强制规则（「值位引用即须声明 `using`」）属 `P3`；环检测只留**余量**
/// （`HIRModule.givenReferences` 留痕，当期不产诊断）；跨模块（独立编译单元）在本编译器里
/// **没有通路** ⇒ 「跨文件」= 同包同模块（实测：整包一个 `HIRModule`、一个 IR 模块）。
///
/// **⚠️ 两臂覆盖说明**：本件的运行面判据走 `HIRExecutor`（解释器臂）；**发射臂**
/// （槽位 / 合成初始化函数 / 运行时取用符号）不在本件覆盖内，由命令行探针两臂对照取证。
///
/// 每条用例三要素齐备：意图写在显示名与首行注释；推进性测量断言期望行为**发生**；
/// 驳回性测量断言不该发生的**确实没发生**（否定形态，见测试规程 `C5`）。
struct GivenUsingTests {

    // MARK: - 私有 helper（内联语料，不落夹具文件）

    /// 前端四道门：词法 → 语法 → 常量折叠 → 语义 → 类型。任一拒绝即抛出首条诊断。
    /// 返回类型检查器本身：降载需要它的 `typeInference`（与命令行同序）。
    private func typeChecked(_ source: String) throws -> (module: Module, checker: TypeChecker) {
        let lexer = Lexer(source: source, fileName: "inline.pini")
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: "inline.pini")
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        try SemanticAnalyzer().analyze(module: module)
        let checker = TypeChecker()
        let typeErrors = checker.checkCollecting(module: module)
        guard typeErrors.isEmpty else { throw typeErrors[0] }
        return (module, checker)
    }

    /// 跑到降载层为止，返回可执行模块。
    private func lowered(_ source: String) throws -> HIRModule {
        let (module, checker) = try typeChecked(source)
        checker.typeInference.environment?.persistAcrossScopesForCodegen = true
        return try HIRLowerer.lower(module: module, typeInference: checker.typeInference)
    }

    /// 完整跑一遍，返回标准输出逐行。
    private func runOutput(_ source: String) throws -> [String] {
        var lines: [String] = []
        let executor = HIRExecutor(programBase: NSTemporaryDirectory())
        executor.outputSink = { lines.append($0) }
        try executor.run(module: try lowered(source))
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

    private func decls(_ source: String) throws -> [TopLevelDecl] {
        let (module, _) = try typeChecked(source)
        return module.declarations
    }

    // MARK: - 声明位：`[名称|given]`

    @Test("给定块的声明位被解析为具名块，字段初值与特征都落到声明上")
    func givenBlockDeclarationCarriesFieldsAndTraits() throws {
        /// 意图：`[配置|given]` 解析为 `.givenDecl`，两条带初值的字段与 `实现:` 摘出的特征都在。
        /// （`实现:` 在解析期即被摘出字段表 —— 与对象体同路径，故不出现于 `fields`。）
        let source = #"""
        <可描述>
            描述(self) -> (String,):
                return "默认描述"

        [配置|given]
            名称: String = "默认"
            重试: I32 = 3
            实现: 可描述
        """#
        let declarations = try decls(source)
        guard case .givenDecl(let given) = declarations.last else {
            Issue.record("末条声明应为给定块，实际：\(String(describing: declarations.last))")
            return
        }
        #expect(given.name == "配置")
        #expect(given.fields.count == 2, "两条字段应都在，实际 \(given.fields.count) 条")
        #expect(given.fields.allSatisfy { $0.initializer != nil }, "给定块字段的初值不应被吞掉")
        #expect(given.traits == ["可描述"], "`实现: 可描述` 应被摘成特征而非字段，实际 \(given.traits)")
        // 驳回性：两种声明类别不得互相冒充。
        #expect(
            !declarations.contains { if case .objectDecl = $0 { return true } else { return false } },
            "给定块不应被解析成对象声明"
        )
    }

    @Test("`given` 不入关键字表：它仍可作为普通标识符")
    func givenStaysAnOrdinaryIdentifier() throws {
        /// 意图：`given` 只占 `|` 右侧的修饰符位 ⇒ 它作为普通标识符**仍然合法**。
        /// 这条正是「不入关键字表」的可观测证据 —— 入表会让本用例转红。
        let source = #"""
        given|func() -> (I32,):
            return 7

        main|func() -> ():
            print(given())
            return
        """#
        #expect(try runOutput(source) == ["7"])
    }

    // MARK: - 扩展位：方括号通用形

    @Test("方括号扩展解析为通用形，目标名与闭合都正确")
    func bracketFormParsesAsGeneralExtension() throws {
        /// 意图：`[[配置]]` 的 kind 是 `.bracketExt`（通用形），而不是被钉成某一具体类别。
        let source = #"""
        [配置|given]
            名称: String = "默认"

        [[配置]]
            摘要|self() -> (String,):
                return 名称
        """#
        let declarations = try decls(source)
        guard case .extensionDecl(let ext) = declarations.last else {
            Issue.record("末条声明应为扩展块，实际：\(String(describing: declarations.last))")
            return
        }
        #expect(ext.kind == .bracketExt, "方括号应是通用形，实际 \(ext.kind)")
        #expect(ext.targetType == "配置")
        #expect(ext.methods.count == 1, "方法不应被闭合定界符吞掉")
    }

    @Test("三形糖的扩展类别不受通用形落地影响")
    func specialisedBracketsKeepTheirKinds() throws {
        /// 意图：`((` / `{{` 两形仍是结构 / 对象扩展 ⇒ 通用形的引入没有改写既有糖的分类。
        /// 对照 `[]` 缺省即枚举声明 —— 单方括号与双方括号各司其职。
        let source = #"""
        (甲)
            x: I32 = 1

        ((甲))
            取|self() -> (I32,):
                return x

        {乙}
            y: I32 = 2

        {{乙}}
            取|self() -> (I32,):
                return y
        """#
        let extensions = try decls(source).compactMap { decl -> ExtensionDecl? in
            if case .extensionDecl(let ext) = decl { return ext } else { return nil }
        }
        #expect(extensions.count == 2, "两条扩展块都应解析出来，实际 \(extensions.count) 条")
        #expect(extensions.map(\.kind) == [.structExt, .objectExt], "实际 \(extensions.map(\.kind))")
        #expect(extensions.map(\.targetType) == ["甲", "乙"])
    }

    @Test("特征扩展仍走尖括号，方括号不抢它的类别")
    func traitExtensionKeepsItsOwnBracket() throws {
        /// 意图：`<<丁>>` 仍是特征扩展（`.traitExt`）—— 与方括号通用形并存而不相扰。
        let source = #"""
        <<丁>>
            取|self() -> (I32,):
                return 1
        """#
        let declarations = try decls(source)
        guard case .extensionDecl(let ext) = declarations.first else {
            Issue.record("唯一声明应为扩展块，实际：\(String(describing: declarations.first))")
            return
        }
        #expect(ext.kind == .traitExt, "尖括号应是特征扩展，实际 \(ext.kind)")
    }

    // MARK: - 通用形的**行为**：按目标类别归并

    @Test("通用形对结构类型：扩展方法归并生效")
    func generalFormBindsMethodsToANominalTarget() throws {
        /// 意图：`[[点]]` 的方法真的挂到结构类型上 —— 调用点取到字段 `x` 返回 3。
        /// 这是本批的**实质交付**：此前该形态的方法被静默丢弃（语料零使用 ⇒ 无观测）。
        let source = #"""
        (点)
            x: I32 = 3

        [[点]]
            取|self() -> (I32,):
                return x

        main|func() -> ():
            var p = 点()
            print(p.取())
            return
        """#
        #expect(try runOutput(source) == ["3"])
        // 驳回性：不得落到「未实现」通道上（那正是通用形落地前的形态）。
        let rejected = failure { _ = try runOutput(source) }
        #expect(rejected == nil, "该方法应已归并，不应报任何诊断，实际：\(rejected?.code ?? "")")
    }

    @Test("通用形对枚举目标：维持不归并的既有行为")
    func generalFormLeavesEnumTargetsAlone() throws {
        /// 意图：`[[色彩]]` 的目标是**枚举**（不在名义类型注册表里）⇒ 方法不归并 ⇒
        /// 与通用形落地**前**的行为逐字相同（调用点报既定缺口判定码）。
        /// ⚠️ 这条钉的是「不扩大改动面」：用户裁定枚举目标的语义维持今日、另行登记。
        let source = #"""
        [色彩]
            红
            绿

        [[色彩]]
            名|self() -> (String,):
                return "红"

        main|func() -> ():
            let c = 红
            print(c.名())
            return
        """#
        let failed = failure { _ = try runOutput(source) }
        #expect(failed?.code == "E6-004", "枚举扩展方法的调用应报既有缺口，实际 \(failed?.code ?? "无（跑通了）")")
    }

    // MARK: - 中间态：响亮拒绝而不是静默丢弃

    @Test("给定块进类型面：中间态结束，字段初值随行")
    func givenBlockLowersToATypeWithDefaultInstance() throws {
        /// 意图：`P1a`/`P1b` 的中间态（「能解析、跑不到」）在 `P2b` 结束 —— 给定块与结构 /
        /// 对象同规进 `types` 面。**观测口径也换了**：不再是「拒绝文案携带归并计数」
        /// （那是中间态下的唯一面），而是**类型面本身**。
        let source = #"""
        [配置|given]
            名称: String = "默认"

        main|func() -> ():
            return
        """#
        let module = try lowered(source)
        guard let decl = module.types.first(where: { $0.name == "配置" }) else {
            Issue.record("类型面里找不到给定块，实际：\(module.types.map(\.name))")
            return
        }
        #expect(decl.isObject == false, "`P1b` 的登记是「非引用」——值 / 引用语义仍未预裁")
        #expect(decl.fields.map(\.name) == ["名称"], "实际：\(decl.fields.map(\.name))")
        // 驳回性：字段初值必须跟着进类型面 —— 丢了它默认实例就无从物化。
        #expect(decl.fields.first?.defaultValue != nil, "字段初值应随字段进类型面")
    }

    @Test("给定块类型体内写方法被拒，且提示指向通用扩展括号")
    func givenBlockRejectsMethodsInTheBody() throws {
        /// 意图：与对象体同规（数据与逻辑分离）⇒ 方法必须写扩展块。
        /// 提示里的括号形态应为 `[[配置]]`（通用形），不是对象糖 `{{配置}}` ——
        /// 这是复用对象体解析时把「指哪个扩展块」参数化的可观测证据。
        let source = #"""
        [配置|given]
            名称: String = "默认"

            摘要|self() -> (String,):
                return 名称
        """#
        let failed = failure { _ = try decls(source) }
        #expect(failed?.code == "E2-007", "实际判定码 \(failed?.code ?? "无（未被拒绝）")")
        #expect(failed?.message.contains("[[配置]]") == true, "提示应指向通用扩展括号，实际：\(failed?.message ?? "")")
        // 驳回性：不得把对象糖的括号塞给给定块。
        #expect(failed?.message.contains("{{配置}}") == false, "不得提示对象扩展括号")
    }

    // MARK: - `P1`：`using` 入关键字表 + 参数位

    @Test("关键字表把 `using` 计入，`given` 仍不入表")
    func usingJoinsTheKeywordTableButGivenDoesNot() throws {
        /// 意图：`using` 是**关键字** —— 实现侧计数 33 → 34，且规范侧同一批改、同值。
        /// 这条钉的是「入表」这个裁定的实现侧一半；集合相同、顺序不作判据。
        #expect(Keyword(rawValue: "using") == .using, "`using` 应在关键字表内")
        #expect(Keyword.allCases.count == 34, "实际 \(Keyword.allCases.count) 个")
        // 驳回性：`given` **不入**表（它只在 `|` 右侧修饰符位，走标识符白名单）。
        #expect(Keyword(rawValue: "given") == nil, "`given` 不应是关键字")
    }

    @Test("取用前缀只标记它自己那一个参数")
    func usingPrefixMarksOnlyItsOwnParameter() throws {
        /// 意图：`using 甲: I32` 的 `isUsing` 为真，同一签名里的普通参数 `乙` 为假 ——
        /// 标记是**逐参数**的事实，不是整个签名的事实。
        /// 行为面：本调用点是**全显式**形态（实参个数 = 形参个数）⇒ ADR 明文允许，
        /// 且那个 `using` 位**不得**被注入的取用点顶掉（取用点只在省略式下插入）。
        /// 对照见本件「全显式形态不触默认实例」一条 —— 两条合起来才把这个分歧钉死。
        let source = #"""
        取|func(using 甲: I32, 乙: I32,) -> (I32,):
            return 甲

        main|func() -> ():
            print(取(5, 6,))
            return
        """#
        let declarations = try decls(source)
        guard case .funcDecl(let fn) = declarations.first else {
            Issue.record("首条声明应为函数，实际：\(String(describing: declarations.first))")
            return
        }
        #expect(fn.params.map(\.isUsing) == [true, false], "实际 \(fn.params.map(\.isUsing))")
        #expect(try runOutput(source) == ["5"])
    }

    @Test("降载层随行携带取用标记，不在中间表示处断链")
    func loweringCarriesTheUsingFlag() throws {
        /// 意图：`Parameter.isUsing` 要到得了 HIR —— 与 `isAsync` / `isTest` / `sourceFile`
        /// 同族：「AST 面上有的事实，HIR 面必须随行」，否则后续批次在后端再也问不出来。
        /// ⚠️ 该语料用的是 `I32` 形参（不是给定块）：本条的射程是「标记到了 HIR」，
        /// 与物化无关。**旧版这里写「语料里不能出现给定块：那会让整个模块在降载层被拒」——
        /// 那句随本批失效**（给定块现在降载通过），故一并删掉，不留下一条假约束。
        let source = #"""
        取|func(using 甲: I32, 乙: I32,) -> (I32,):
            return 甲

        main|func() -> ():
            print(取(5, 6,))
            return
        """#
        let module = try lowered(source)
        guard let fn = module.functions.first(where: { $0.name == "取" }) else {
            Issue.record("降载后找不到函数 `取`，实际函数名：\(module.functions.map(\.name))")
            return
        }
        #expect(fn.params.map(\.isUsing) == [true, false], "实际 \(fn.params.map(\.isUsing))")
        // 驳回性：普通参数不得被顺带标成取用 —— 那会让后续批次的强制规则误报。
        #expect(fn.params.filter(\.isUsing).count == 1, "只有取用位那一个参数该被标记")
    }

    @Test("入表是破坏性的：`using` 在标识符位被拒")
    func usingIsNoLongerAnIdentifier() throws {
        /// 意图：入表的**代价**必须在判据上可见 —— 今日合法的标识符 `using`
        /// （`let using = 1`）现在落解析错。这条是「破坏性变更」的可观测证据。
        let source = #"""
        main|func() -> ():
            let using = 1
            print(using)
            return
        """#
        let failed = failure { _ = try decls(source) }
        #expect(failed?.code == "E2-002", "实际判定码 \(failed?.code ?? "无（被接受了）")")
        // 阳性对照：同一位置换成普通标识符必须被接受 —— 否则本用例拦下的是别的东西。
        let control = #"""
        main|func() -> ():
            let 使用 = 1
            print(使用)
            return
        """#
        #expect(try runOutput(control) == ["1"])
    }

    @Test("`using` 与 `given` 分工不同：方括号修饰符位不认识它")
    func usingIsRejectedOutsideTheParameterPosition() throws {
        /// 意图：`using` 是**参数位前缀**，不是块修饰符 ⇒ `[名称|using]` 必须落回
        /// 无效的方括号声明修饰符，而不是被当成某个块的糖。
        /// 与「`given` 走该修饰符位」互为对照：同一条总线、两个词各占一头。
        let source = #"""
        [配置|using]
            名称: String = "默认"
        """#
        let failed = failure { _ = try decls(source) }
        #expect(failed?.code == "E2-005", "实际判定码 \(failed?.code ?? "无（被接受了）")")
        #expect(failed?.message.contains("方括号声明修饰符") == true, "实际：\(failed?.message ?? "")")
    }

    @Test("字段缺初值 ⇒ 降载期响亮拒绝（对每个给定块，含从未被取用的）")
    func missingInitializerIsDiagnosedAtLowering() throws {
        /// 意图：默认实例的定义就是「各字段初值合起来」（ADR §2.2）⇒ 缺一个就没有完整默认值。
        /// 用户 2026-09-19 裁定：**降载期就对每个给定块报**（不做「用到了才报」）。
        /// ⇒ 下面两份语料里**都没有取用点**，仍应一绿一红 —— 那正是「对每个给定块」的观测形态。
        /// ⚠️ 这是**语义收紧**；新码与「不支持的特性」分开：前者是「程序写错了」，
        /// 后者是「语言有了、编译器还没做」。
        let complete = #"""
        [配置|given]
            名称: String = "默认"

        main|func() -> ():
            return
        """#
        let withoutInitializer = #"""
        [配置|given]
            名称: String

        main|func() -> ():
            return
        """#
        let ok = failure { _ = try lowered(complete) }
        #expect(ok == nil, "字段齐备的给定块不该被拒，实际：\(ok?.code ?? "") \(ok?.message ?? "")")
        let incomplete = failure { _ = try lowered(withoutInitializer) }
        #expect(incomplete?.code == "E6-007", "实际 \(incomplete?.code ?? "无（未被拒绝）")")
        #expect(
            incomplete?.message.contains("初值") == true,
            "拒绝理由应指向初值缺失，实际：\(incomplete?.message ?? "")"
        )
        // 驳回性：不得退回那个「不支持的特性」桶 —— 那会让「程序写错了」与「编译器还没做」分不开。
        #expect(incomplete?.code != "E6-004", "不得复用「不支持的特性」桶")
    }

    // MARK: - `P2b`：默认实例的物化面（取用 · 恰一次 · 惰性 · 副本）

    @Test("省略式调用：实参由编译器插入，取到默认实例")
    func omittedUsingArgumentTakesTheDefaultInstance() throws {
        /// 意图：`using` 形参可以**不传** —— 实参个数 = 形参个数 − using 个数 时判为省略式，
        /// 编译器在 `using` 位插入取用点。这是本批的**语言可见行为**。
        let source = #"""
        [配置|given]
            名称: String = "默认"

        取名|func(using 配: 配置,) -> (String,):
            return 配.名称

        main|func() -> ():
            print(取名())
            return
        """#
        #expect(try runOutput(source) == ["默认"])
    }

    @Test("恰一次：同一类型的两次取用只物化一次")
    func materializationHappensExactlyOnce() throws {
        /// 意图：ADR §2.2 四项承诺之一 —— **恰一次**。
        /// 观测口径：字段初值里放一个**打点**，数它被跑了几次（副作用是唯一骗不了人的口径）。
        /// 两次取用来自**两个不同的函数**（两个独立调用点），不是一个函数里取两遍。
        let source = #"""
        [计数块|given]
            值: I32 = 打点()

        打点|func() -> (I32,):
            print("物化")
            return 1

        甲|func(using 块: 计数块,) -> (I32,):
            return 块.值

        乙|func(using 块: 计数块,) -> (I32,):
            return 块.值

        main|func() -> ():
            print(甲())
            print(乙())
            return
        """#
        #expect(try runOutput(source) == ["物化", "1", "1"])
    }

    @Test("惰性：未被取用的给定块，其字段初值从不求值")
    func unusedGivenBlockIsNeverMaterialized() throws {
        /// 意图：ADR 的招牌卖点 —— 「未访问的给定块从不物化」，故无启动风暴。
        /// 观测口径同「恰一次」：打点一次都不该出现。
        let source = #"""
        [未用块|given]
            值: I32 = 打点()

        打点|func() -> (I32,):
            print("不该出现")
            return 1

        main|func() -> ():
            print("只此一行")
            return
        """#
        #expect(try runOutput(source) == ["只此一行"])
    }

    @Test("全显式形态不触默认实例：取用点只在省略式下插入")
    func explicitArgumentDoesNotTriggerTheDefaultInstance() throws {
        /// 意图：ADR §2.3「显式提供 ✅ 允许」。**本条的判别力靠计数**：
        /// 语料自备一个实例（它自己会跑一次字段初值），若编译器**还**在 `using` 位插一个取用点，
        /// 打点就会出现**两次** ⇒ 断言恰好把那个缺陷拦死
        /// （它不是想出来的：本批实现首版正是这样，被本件抓红后修掉）。
        let source = #"""
        [计数块|given]
            值: I32 = 打点()

        打点|func() -> (I32,):
            print("物化")
            return 1

        取块|func(using 块: 计数块,) -> (I32,):
            return 块.值

        main|func() -> ():
            let 自备 = 计数块()
            print(取块(自备,))
            return
        """#
        #expect(try runOutput(source) == ["物化", "1"], "自备实例只该物化一次，不得再插取用点")
    }

    @Test("取用参数的类型无默认实例时响亮拒绝")
    func usingOnATypeWithoutDefaultInstanceIsRejected() throws {
        /// 意图：默认实例**只由给定块提供**（ADR §3：`object` 没有这个概念，故 `using` 无从解析）。
        /// ⇒ `using 甲: I32` 在省略式调用下必须报错，而不是静默给个零值。
        /// ⚠️ 全显式调用同一签名是**合法**的（见本件「取用前缀只标记它自己那一个参数」）。
        let source = #"""
        取|func(using 甲: I32,) -> (I32,):
            return 甲

        main|func() -> ():
            print(取())
            return
        """#
        let failed = failure { _ = try lowered(source) }
        #expect(failed?.code == "E6-007", "实际 \(failed?.code ?? "无（未被拒绝）")")
        #expect(
            failed?.message.contains("无默认实例") == true,
            "文案应说清「无默认实例」，实际：\(failed?.message ?? "")"
        )
    }

    @Test("依赖留痕：函数名 → 它取用的给定块类型（环检测的余量）")
    func givenReferencesAreRecorded() throws {
        /// 意图：用户第 5 条裁定的余量第 1 条 —— 环检测后置，但**留痕当期就要做对**。
        /// 没有这张表，后置的检测要重扫降载结果；有了它，检测是加一条遍历。
        /// ⚠️ 当期**不产任何诊断** —— 这条留痕是纯观测面。
        let source = #"""
        [计数块|given]
            值: I32 = 1

        [未用块|given]
            值: I32 = 2

        甲|func(using 块: 计数块,) -> (I32,):
            return 块.值

        main|func() -> ():
            print(甲())
            return
        """#
        let module = try lowered(source)
        // 驳回性②：从没被取用的给定块不该出现在**任何**一条边的值里。
        #expect(
            module.givenReferences.values.allSatisfy { !$0.contains("未用块") },
            "未取用的给定块不该留痕：\(module.givenReferences)"
        )
        // ⭐ **边的方向是「调用方 → 给定块」，不是被调用方**：`using` 的实参由编译器在
        // **调用点**插入 ⇒ 取用点长在 `main` 的体内。这条期望本身就是那句设计的观测面。
        #expect(module.givenReferences["main"] == ["计数块"], "实际：\(module.givenReferences)")
        // 驳回性①：被调用方 `甲` 体内没有取用点 —— 「有 `using` 形参」不等于「自己取用」，
        // 表要反映**真实取用**，不是「凡带取用形参的函数都记一行」。
        #expect(module.givenReferences["甲"] == nil, "甲 的实参由调用方给，不该留痕：\(module.givenReferences)")
    }

    @Test("泛型给定块：特化按用到的类型参数各进一份（含泛型但只到降载）")
    func genericGivenBlockSpecializesOnDemand() throws {
        /// 意图：`[匣<T>|given]` 的特化**只有 `using` 形参的类型标注这一个入口**
        /// （它没有构造点、没有调用点）⇒ 扫描面就是参数表。
        /// 本条的射程是**降载面**：特化类型要真的进 `types`。
        /// ⭐ 实测附带：这么接上之后**端到端也能跑**（发射层的路径与泛型无关）——
        /// 那是顺带的结果，故运行断言只作辅助，不作判据。
        let source = #"""
        [匣<T>|given]
            计数: I32 = 7

        取匣|func(using 箱: 匣<I32>,) -> (I32,):
            return 箱.计数

        main|func() -> ():
            print(取匣())
            return
        """#
        let module = try lowered(source)
        #expect(module.types.map(\.name).contains("匣_I32"), "实际：\(module.types.map(\.name))")
        #expect(try runOutput(source) == ["7"])
    }

    // MARK: - `P1b`：方括号扩展的归并，与「目标无法归并」的诊断

    @Test("给定块的方括号扩展方法确实归并进块的方法表")
    func givenBlockMergesBracketExtensionMethods() throws {
        /// 意图：`[[配置]]` 的方法要**真的进块的方法表**，而不是被静默丢弃 ——
        /// `P1a` 把「`[[X]]` 对给定块生效」写在注释里当既成事实，实测（2026-09-19）并非如此。
        /// ⭐ **观测口径在本批换了**：中间态下给定块跑不到，只能把归并计数写进拒绝文案；
        /// 现在它进类型面 ⇒ 直接读**类型的方法表**，不必再借道诊断文案（更硬的证据）。
        let source = #"""
        [配置|given]
            名称: String = "默认"

        [[配置]]
            取名|self() -> (String,):
                return self.名称

            改名|self(n: String) -> ():
                return

        main|func() -> ():
            return
        """#
        let module = try lowered(source)
        guard let decl = module.types.first(where: { $0.name == "配置" }) else {
            Issue.record("类型面里找不到给定块，实际：\(module.types.map(\.name))")
            return
        }
        #expect(decl.methods.count == 2, "两条扩展方法都应进方法表，实际：\(decl.methods.map(\.name))")
        // 驳回性：方法名要对得上 —— 计数对了但名字错了同样是「归并未生效」。
        // ⚠️ 类型面里存的是 **IR 名**（`方法__类型`），不是源名 —— 断言按同一 mangle 算期望，
        // 而不是拿源名去比（那样只会红一次，然后被改成「只数个数」而失去判别力）。
        let expected: Set<String> = Set(
            ["取名", "改名"].map { "\(IRName.mangle($0))__\(IRName.mangle("配置"))" })
        #expect(Set(decl.methods.map(\.name)) == expected, "实际：\(decl.methods.map(\.name))")
    }

    @Test("阴性对照：无扩展块时方法表为空（计数是活的，不是常量）")
    func mergeCountIsLiveNotConstant() throws {
        /// 意图：与上一条成对 —— 上一条只证明「有扩展时是 2」，若表里塞的是常量也会通过；
        /// 本条用**无扩展块**的同一个块证明方法表随输入变化。
        let source = #"""
        [配置|given]
            名称: String = "默认"

        main|func() -> ():
            return
        """#
        let module = try lowered(source)
        guard let decl = module.types.first(where: { $0.name == "配置" }) else {
            Issue.record("类型面里找不到给定块")
            return
        }
        #expect(decl.methods.isEmpty, "无扩展块时不该有方法，实际：\(decl.methods.map(\.name))")
        // 驳回性：字段与类型都还在 —— 证明本条测的是「方法是空的」，不是「类型没进面」。
        #expect(decl.fields.count == 1, "字段应在，实际 \(decl.fields.map(\.name))")
    }

    @Test("扩展的目标未声明时响亮拒绝")
    func extensionOnUndeclaredTargetFailsLoudly() throws {
        /// 意图：今日「目标未声明 ⇒ 方法静默丢弃」改为出声（用户 2026-09-19 裁定）。
        /// 静默的代价与给定块那条相同：「写对了却没效果」无从定位。
        let source = #"""
        ((盒))
        取|self() -> (I32,):
            return 1
        """#
        let failed = failure { _ = try lowered(source) }
        #expect(failed?.code == "E6-006", "实际判定码 \(failed?.code ?? "无（未被拒绝）")")
        #expect(failed?.message.contains("盒") == true, "文案应指名目标，实际：\(failed?.message ?? "")")
        // 驳回性：码不得复用「不支持的特性」桶 —— 混同会让两条不同的缺口无法区分。
        #expect(failed?.code != "E6-004", "新诊断不得与给定块未落地的码混同")
    }

    @Test("扩展的目标指向特征时响亮拒绝")
    func extensionOnTraitTargetFailsLoudly() throws {
        /// 意图：特征与结构 / 对象是**不同的类型类别**，把方法挂到特征上今日无路径 ⇒
        /// 与「目标未声明」同一次裁定（用户原话：「目标未声明 / 是特征」）⇒ 共用判定码。
        let source = #"""
        <<丁>>
        取|self() -> (I32,):

        [[丁]]
        额外|self() -> (I32,):
            return 2
        """#
        let failed = failure { _ = try lowered(source) }
        #expect(failed?.code == "E6-006", "实际判定码 \(failed?.code ?? "无（未被拒绝）")")
        #expect(failed?.message.contains("丁") == true, "文案应指名目标，实际：\(failed?.message ?? "")")
    }

    @Test("不扩大改动面：泛型模板目标不被新诊断波及")
    func genericTemplateTargetsAreNotRejected() throws {
        /// 意图：`((盒<T>))` 的归并走 `G10` 特化段落（按 `盒_<实参>` 落表），归并处**碰不到**
        /// 模板名 ⇒ 新诊断必须放过它，否则会把一条合法且今日可用的路径打红。
        /// 观测口径：只断言**不是** `E6-006`（该程序没有 `main`，另有别的判定码，与本条无关）。
        let source = #"""
        (盒<T>)
        值: T

        ((盒<T>))
        取|self() -> (T,):
            return self.值
        """#
        let failed = failure { _ = try lowered(source) }
        #expect(
            failed?.code != "E6-006",
            "泛型模板目标不得被判为「无法归并」，实际：\(failed?.message ?? "无诊断")"
        )
    }
}
