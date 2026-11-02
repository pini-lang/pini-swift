import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackends
@testable import PiniBackendLLVM

/// 错误码表的判据：派生区、自动区、散列区各自落点，手动优先、自动避让，
/// 以及 E7-004 的触发条件。端到端（C 侧拿到同一个值）由命令行探针取证。
struct ErrorCodeTableTests: Sendable, PiniSourceLowering {

    private let location = SourceLocation(line: 1, column: 1, fileName: "calc.pini")

    // MARK: - 派生区

    @Test("派生码 = 类型序 << 8 | 用例 tag，类型序按名字字典序")
    func testDerivedCodesFollowTypeOrderAndCaseTag() throws {
        let module = try lowered(
            """
            [甲错误]
                实现: 错误
                不存在
                拒绝

            [乙错误]
                实现: 错误
                超时

            读甲() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            读乙() -> (Result<I32, 乙错误>,):
                return err(乙错误.超时)

            [calc|export]
            calc_a|c = 读甲
            calc_b|c = 读乙

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let export = try #require(module.export)
        // 乙（U+4E59）排在 甲（U+7532）之前 ⇒ 乙 拿 0x0100，甲 拿 0x0200。
        #expect(export.errorCodes.first { $0.typeName == "乙错误" && $0.caseName == "超时" }?.code == 0x0100)
        #expect(export.errorCodes.first { $0.typeName == "甲错误" && $0.caseName == "不存在" }?.code == 0x0200)
        #expect(export.errorCodes.first { $0.typeName == "甲错误" && $0.caseName == "拒绝" }?.code == 0x0201)
        #expect(export.errorCodes.allSatisfy { $0.source == .derived })
    }

    @Test("类型序只由进错误集的类型决定，改声明顺序不动码")
    func testDerivedCodesIgnoreDeclarationOrder() throws {
        let first = try typeChecked(
            """
            [甲错误]
                实现: 错误
                不存在

            [乙错误]
                实现: 错误
                超时

            读() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            读乙() -> (Result<I32, 乙错误>,):
                return err(乙错误.超时)

            [calc|export]
            calc_a|c = 读
            calc_b|c = 读乙

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let second = try typeChecked(
            """
            [乙错误]
                实现: 错误
                超时

            [甲错误]
                实现: 错误
                不存在

            读() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            读乙() -> (Result<I32, 乙错误>,):
                return err(乙错误.超时)

            [calc|export]
            calc_a|c = 读
            calc_b|c = 读乙

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let left = ErrorCodePlan.build(module: first.module)
        let right = ErrorCodePlan.build(module: second.module)
        #expect(left.byType == right.byType)
    }

    // MARK: - 自动区

    @Test("非 enum 未申报码：从 0x4000 起按名字序分配")
    func testAutomaticCodesStartAtAutomaticBase() throws {
        let (module, _) = try typeChecked(
            """
            [甲错误|object]
                实现: 错误
                message: String = ""

            读甲() -> (Result<I32, 甲错误>,):
                return err(甲错误())

            [calc|export]
            calc_a|c = 读甲

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let plan = ErrorCodePlan.build(module: module)
        #expect(plan.byType["甲错误"] == ErrorCodeSpace.automaticBase)
        #expect(plan.automaticEntries.map(\.typeName) == ["甲错误"])
    }

    @Test("手动码优先，自动码跳开已占位")
    func testDeclaredCodesWinAndAutomaticCodesAvoidThem() throws {
        let (module, _) = try typeChecked(
            """
            [甲错误|object]
                实现: 错误
                message: String = ""

            [乙错误|object]
                实现: 错误
                message: String = ""

            [[甲错误]]
                码|self() -> (I32,):
                    return 16384

            读甲() -> (Result<I32, 甲错误>,):
                return err(甲错误())

            读乙() -> (Result<I32, 乙错误>,):
                return err(乙错误())

            [calc|export]
            calc_a|c = 读甲
            calc_b|c = 读乙

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let plan = ErrorCodePlan.build(module: module)
        #expect(plan.byType["甲错误"] == Int32(16384))
        #expect(plan.byType["乙错误"] == Int32(16385))
    }

    @Test("不在导出面可达的错误类型不占码")
    func testUnreachableErrorTypesTakeNoCode() throws {
        let (module, _) = try typeChecked(
            """
            [甲错误]
                实现: 错误
                不存在

            内部读() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            公开读() -> (I32,):
                return 0

            [calc|export]
            calc_read|c = 公开读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let plan = ErrorCodePlan.build(module: module)
        #expect(plan.entries.isEmpty)
        #expect(plan.automaticEntries.isEmpty)
    }

    // MARK: - E7-004

    @Test("非 enum 未申报码发 E7-004，写明码值与固定办法")
    func testAutomaticCodeWarningNamesTheCodeAndTheFix() throws {
        let warnings = try warnings(
            """
            [文件错误|object]
                实现: 错误
                message: String = ""

            读() -> (Result<I32, 文件错误>,):
                return err(文件错误())

            [calc|export]
            calc_read|c = 读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let warning = try #require(warnings.first { $0.diagnosticCode == "E7-004" })
        guard case .automaticErrorCode(let typeName, let code, let location) = warning else {
            Issue.record("E7-004 应是自动码警告，实际 \(warning)")
            return
        }
        #expect(typeName == "文件错误")
        #expect(code == ErrorCodeSpace.automaticBase)
        #expect(location.line == 1, "警告要指到类型声明处")
    }

    @Test("申报了码() 的非 enum 不发警告")
    func testDeclaredCodeSuppressesTheWarning() throws {
        let warnings = try warnings(
            """
            [文件错误|object]
                实现: 错误
                message: String = ""

            [[文件错误]]
                码|self() -> (I32,):
                    return 20001

            读() -> (Result<I32, 文件错误>,):
                return err(文件错误())

            [calc|export]
            calc_read|c = 读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        #expect(!warnings.contains { $0.diagnosticCode == "E7-004" })
    }

    @Test("导出面之外的非 enum 不发警告")
    func testUnreachableNonEnumDoesNotWarn() throws {
        let warnings = try warnings(
            """
            [文件错误|object]
                实现: 错误
                message: String = ""

            内部读() -> (Result<I32, 文件错误>,):
                return err(文件错误())

            公开读() -> (I32,):
                return 0

            [calc|export]
            calc_read|c = 公开读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        #expect(!warnings.contains { $0.diagnosticCode == "E7-004" })
    }

    // MARK: - 散列区

    @Test("稳定码落在散列区，且等于三段名字的散列值")
    func testStableCodesLandInTheHashedRange() throws {
        let (module, _) = try typeChecked(stableSource(caseOrder: ["不存在", "权限不足"]), fileName: "calc.pini")
        let plan = ErrorCodePlan.build(module: module)
        let entry = try #require(plan.entries.first { $0.typeName == "文件错误" && $0.caseName == "不存在" })
        #expect(entry.source == .hashed)
        #expect(entry.probeSteps == 0)
        #expect(entry.code == ErrorCodePlan.hashedCode(surface: "calc", type: "文件错误", case: "不存在"))
        #expect(entry.code >= ErrorCodeSpace.hashedBase)
        #expect(entry.code < ErrorCodeSpace.hashedBase + ErrorCodeSpace.hashedSpan)
    }

    @Test("散列只吃三段名字：改用例顺序不动码，换块名才动")
    func testHashedCodeDependsOnlyOnTheThreeNames() throws {
        let first = try typeChecked(
            stableSource(caseOrder: ["不存在", "权限不足"]), fileName: "calc.pini")
        let second = try typeChecked(
            stableSource(caseOrder: ["权限不足", "不存在"]), fileName: "calc.pini")
        let left = ErrorCodePlan.build(module: first.module)
        let right = ErrorCodePlan.build(module: second.module)
        for name in ["不存在", "权限不足"] {
            let a = left.entries.first { $0.typeName == "文件错误" && $0.caseName == name }
            let b = right.entries.first { $0.typeName == "文件错误" && $0.caseName == name }
            #expect(a?.code == b?.code)
        }
        #expect(
            ErrorCodePlan.hashedCode(surface: "calc", type: "文件错误", case: "不存在")
                != ErrorCodePlan.hashedCode(surface: "other", type: "文件错误", case: "不存在"))
    }

    @Test("散列撞位按名字序顺延，并在条目上留步数")
    func testHashedCollisionProbesForward() {
        // 同一 (类型, 用例) 出现两次：第二项必然撞上第一项占的位，这是可构造的碰撞。
        let allocation = ErrorCodePlan.allocateHashed(
            [ErrorCodePlan.HashedType(name: "甲", cases: ["x", "x"], location: location)],
            surface: "calc", occupied: [])
        #expect(allocation.entries.count == 2)
        let first = allocation.entries[0]
        let second = allocation.entries[1]
        #expect(first.probeSteps == 0)
        #expect(second.probeSteps == 1)
        #expect(second.code == ErrorCodePlan.nextHashed(first.code))
        #expect(second.code != first.code)
    }

    @Test("散列项避开派生区与手动码占用的位")
    func testHashedAllocationAvoidsOccupiedCodes() {
        let taken = ErrorCodePlan.hashedCode(surface: "calc", type: "甲", case: "x")
        let allocation = ErrorCodePlan.allocateHashed(
            [ErrorCodePlan.HashedType(name: "甲", cases: ["x"], location: location)],
            surface: "calc", occupied: [taken])
        let entry = allocation.entries[0]
        #expect(entry.code != taken)
        #expect(entry.probeSteps == 1)
    }

    @Test("稳定码必须与错误同用，且只用于 enum")
    func testStableCodeTraitIsChecked() {
        let withoutError = failure {
            _ = try typeChecked(
                """
                [文件错误]
                    实现: 稳定码
                    不存在

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(withoutError?.message.contains("同时写 `错误`") == true, "实际：\(String(describing: withoutError))")

        let onStruct = failure {
            _ = try typeChecked(
                """
                [文件错误|object]
                    实现: 错误
                    实现: 稳定码
                    message: String = ""

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(onStruct?.message.contains("只用于 enum") == true, "实际：\(String(describing: onStruct))")
    }

    // MARK: - 头文件与发射物

    @Test("头文件常量与码表同值，来源写进注释")
    func testHeaderConstantsMatchThePlan() throws {
        let (module, checker) = try typeChecked(
            stableSource(caseOrder: ["不存在", "权限不足"]), fileName: "calc.pini")
        let plan = ErrorCodePlan.build(module: module)
        let ir = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let header = try CHeaderBackend().emit(module: ir)
        for entry in plan.entries {
            #expect(header.contains("\(entry.code)"))
            #expect(header.contains(entry.display))
        }
        #expect(header.contains("名字散列"))
    }

    @Test("散列错误在发射层带码表指针，运行时段按 tag 查")
    func testEmitterCarriesTheCodeTable() throws {
        let ir = try lowered(stableSource(caseOrder: ["不存在", "权限不足"]), fileName: "calc.pini")
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("@__pini_err_codes_0 = private constant [2 x i32]"))
        #expect(listing.contains("ptr @__pini_err_codes_0"))
        #expect(listing.contains("declare i64 @bk_error_from_enum(i64, i32, ptr, ptr)"))
    }

    @Test("两个类型的同名用例各自成常量，不在预处理期互相覆盖")
    func testHeaderConstantsIncludeTheTypeName() throws {
        let (module, checker) = try typeChecked(
            """
            [甲错误]
                实现: 错误
                不存在

            [乙错误]
                实现: 错误
                不存在

            读甲() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            读乙() -> (Result<I32, 乙错误>,):
                return err(乙错误.不存在)

            [calc|export]
            calc_a|c = 读甲
            calc_b|c = 读乙

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let ir = try IRLowerer.lower(module: module, typeInference: checker.typeInference)
        let header = try CHeaderBackend().emit(module: ir)
        let defines = header.split(separator: "\n").filter { $0.hasPrefix("#define calc_err_") }
        #expect(defines.count == 2)
        #expect(Set(defines).count == defines.count, "同名用例生成了同一个宏：\(defines)")
        let casePart = "_u004E0D_u005B58_u005728"
        #expect(defines.contains { $0.contains("_u007532") && $0.contains(casePart) })
        #expect(defines.contains { $0.contains("_u004E59") && $0.contains(casePart) })
    }

    @Test("非 enum 的码直接按基址造盒，不按枚举读 tag")
    func testNonEnumUsesTheCodeOnlyEntry() throws {
        let ir = try lowered(
            """
            [文件错误|object]
                实现: 错误
                message: String = ""

            读() -> (Result<I32, 文件错误>,):
                return err(文件错误())

            [calc|export]
            calc_read|c = 读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let listing = try IREmitter().emit(module: ir)
        #expect(listing.contains("call i64 @bk_error_with_code(i32 16384)"))
        #expect(!listing.contains("call i64 @bk_error_from_enum"))
    }

    @Test("派生错误不带码表，运行时按基址或 tag 折算")
    func testDerivedErrorsCarryNoTable() throws {
        let ir = try lowered(
            """
            [甲错误]
                实现: 错误
                不存在

            读() -> (Result<I32, 甲错误>,):
                return err(甲错误.不存在)

            [calc|export]
            calc_read|c = 读

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let listing = try IREmitter().emit(module: ir)
        #expect(!listing.contains("@__pini_err_codes_"))
        #expect(listing.contains("ptr null)"))
    }

    // MARK: - helper

    private func stableSource(caseOrder: [String]) -> String {
        var lines = ["[文件错误]", "    实现: 错误", "    实现: 稳定码"]
        lines += caseOrder.map { "    \($0)" }
        lines += [
            "",
            "读() -> (Result<I32, 文件错误>,):",
            "    return err(文件错误.\(caseOrder[0]))",
            "",
            "[calc|export]",
            "calc_read|c = 读",
            "",
            "main|func() -> (I32,):",
            "    return 0",
        ]
        return lines.joined(separator: "\n")
    }

    /// 只走到语义分析：E7-004 在那一层的 warnings 里，类型检查不产警告。
    private func warnings(_ source: String, fileName: String) throws -> [SemanticWarning] {
        let lexer = Lexer(source: source, fileName: fileName)
        let parsed = Parser(tokens: try lexer.tokenize(), fileName: fileName)
            .parseModuleCollectingErrors()
        guard parsed.errors.isEmpty else { throw parsed.errors[0] }
        let module = ConstantFolder.foldConstants(in: parsed.module)
        let analyzer = SemanticAnalyzer()
        try analyzer.analyze(module: module)
        return analyzer.warnings
    }

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let message = (error as? any DiagnosticProviding).map { "\($0.diagnosticCode)" } ?? ""
            return (message, String(describing: error))
        }
    }
}
