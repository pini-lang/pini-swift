import Foundation
import PiniCore
import Testing

/// AD-001 `P1a`：`[[X]]` 通用扩展形 + `[名称|given]` 声明位的判据。
///
/// **本批的实质交付**：方括号从「枚举扩展」改为**通用扩展形** —— 归并时按**目标的实际
/// 注册类别**落表，而不是按定界符预设类别。三形糖（`((` / `{{` / `<<`）的 kind 语义不变。
///
/// **中间态（必须知道）**：给定块只落**声明面**（解析 + AST + 类型层注册），
/// 默认实例的物化面属 `P2` ⇒ 含给定块的程序在降载层被**响亮拒绝**（不是静默丢弃）。
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

    @Test("给定块在降载层被响亮拒绝，且指名块与批次")
    func givenBlockFailsLoudlyAtLowering() throws {
        /// 意图：声明面已落地但物化面未接 ⇒ 降载必须**响亮拒绝**并说清「属后续批次」。
        /// 静默丢弃会让「写对了却没效果」无从定位 —— 那才是本批要避免的失败形态。
        let source = #"""
        [配置|given]
            名称: String = "默认"
        """#
        let failed = failure { _ = try lowered(source) }
        #expect(failed?.code == "E6-004", "实际判定码 \(failed?.code ?? "无（未被拒绝）")")
        #expect(failed?.message.contains("配置") == true, "拒绝文案应指名块，实际：\(failed?.message ?? "")")
        #expect(failed?.message.contains("P2") == true, "拒绝文案应点明后续批次，实际：\(failed?.message ?? "")")
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
}
