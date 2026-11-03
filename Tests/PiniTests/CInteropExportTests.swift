import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackends

/// export 块 `|c` 条目的判据：目标解析、名字转写、语义闸门与头文件产物。
/// 端到端（`cc caller.c -lcalc`）另由命令行探针取证，这里只钉住降载与文本两层的形状。
struct CInteropExportTests: Sendable, PiniSourceLowering {

    private let source = """
        [计数器状态|given]
            count: I32 = 0
            limit: I32 = 100

        加法(a: I32, b: I32,) -> (I32,):
            return a + b

        除法(a: I32, b: I32,) -> (^I32,):
            return ok(a / b)

        累加(using 状态: 计数器状态, n: I32,) -> (I32,):
            return 状态.count + n

        [calc|export]
        calc_add|c = 加法
        calc_div|c = 除法
        calc_add_with|c = 累加
        calc_state|c = 计数器状态

        main|func() -> (I32,):
            return 0
        """

    // MARK: - 语法

    @Test("export 块收带目标的条目，块头即文件名")
    func testExportBlockParsesEntries() throws {
        let (module, _) = try typeChecked(source, fileName: "calc.pini")
        let block = try #require(module.exports.first)
        #expect(block.name == "calc")
        #expect(block.entries.count == 4)
        #expect(block.entries.first?.name == "calc_add")
        #expect(block.entries.first?.target == .c)
        #expect(block.entries.first?.symbol == "加法")
        #expect(block.entries.last?.name == "calc_state")
        #expect(block.entries.last?.symbol == "计数器状态")
    }

    @Test("省略目标与显式 |pini 等价")
    func testDefaultTargetEqualsExplicitPini() throws {
        let plain = """
            f() -> (I32,):
                return 1

            [calc|export]
            公开 = f

            main|func() -> (I32,):
                return 0
            """
        let explicit = plain.replacingOccurrences(of: "公开 = f", with: "公开|pini = f")
        let (left, _) = try typeChecked(plain, fileName: "calc.pini")
        let (right, _) = try typeChecked(explicit, fileName: "calc.pini")
        let leftEntry = try #require(left.exports.first?.entries.first)
        let rightEntry = try #require(right.exports.first?.entries.first)
        #expect(leftEntry.name == rightEntry.name)
        #expect(leftEntry.target == .pini)
        #expect(leftEntry.target == rightEntry.target)
        #expect(leftEntry.symbol == rightEntry.symbol)
    }

    @Test("空块被拒")
    func testEmptyBlockIsRejected() {
        let empty = failure {
            _ = try typeChecked(
                "[calc|export]\n\nmain|func() -> (I32,):\n    return 0\n", fileName: "calc.pini")
        }
        #expect(empty != nil, "空块应报错")
    }

    @Test("未知目标被拒并列出可用值")
    func testUnknownTargetIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                "[calc|export]\ncalc_add|rust = f\n\nmain|func() -> (I32,):\n    return 0\n",
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("`pini` 或 `c`") == true, "实际：\(String(describing: failed))")
    }

    @Test("同文件第二个 export 块被拒")
    func testSecondExportBlockIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f() -> (I32,):
                    return 1
                [calc|export]
                calc_a|c = f

                [calc|export]
                calc_b|c = f

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("最多一个 export 块") == true, "实际：\(String(describing: failed))")
    }

    @Test("块头与文件名不符被拒，消息指向产物名")
    func testBlockHeaderMustMatchFileName() {
        let failed = failure {
            _ = try typeChecked(
                "[calc|export]\ncalc_add|c = f\n\nmain|func() -> (I32,):\n    return 0\n",
                fileName: "surface.pini")
        }
        #expect(failed?.message.contains("当前文件名") == true, "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("C 产物名") == true, "实际：\(String(describing: failed))")
    }

    // MARK: - 名字转写

    @Test("ASCII 名字零变化，非 ASCII 转 6 位码位")
    func testEscapeKeepsASCIIAndEncodesWideCharacters() {
        #expect(CName.escape("calc_add") == "calc_add")
        #expect(CName.escape("点") == "_u0070B9")
        #expect(CName.escape("a_b") == "a_b")
    }

    @Test("字面转义序列与 C 保留区都被拒")
    func testEscapeCollisionAndReservedAreaAreRejected() {
        #expect(CName.collidesWithEscape("_u0070B9"))
        #expect(!CName.collidesWithEscape("_u70B9"))
        #expect(CName.isReserved("__x"))
        #expect(CName.isReserved("_X"))
        #expect(!CName.isReserved("_x"))
        #expect(!CName.isReserved("x_y"))
    }

    @Test("转写在允许域内单射：不同名字不会撞成同一个对外名")
    func testEscapeIsInjectiveOnAllowedDomain() {
        // 允许域 = 不含字面转义形状、转写后不落保留区。单射若只靠禁令而没有判据，
        // 哪天转义表改了宽度或前缀，撞名会以「两个 C 符号同名」的形态出现在链接期。
        let alphabet = ["a", "Z", "0", "_", "点", "算", "é", "β"]
        var samples = [""]
        var frontier = [""]
        for _ in 0..<3 {
            var next: [String] = []
            for prefix in frontier {
                for character in alphabet { next.append(prefix + character) }
            }
            samples.append(contentsOf: next)
            frontier = next
        }
        var owners: [String: String] = [:]
        for name in samples where !CName.collidesWithEscape(name) && !CName.isReserved(CName.escape(name)) {
            let escaped = CName.escape(name)
            if let first = owners[escaped] {
                Issue.record("`\(first)` 与 `\(name)` 都转写成 `\(escaped)`")
            }
            owners[escaped] = name
        }
        #expect(owners.count > 500, "样本太少（\(owners.count)），这条判据没压到东西")
    }

    // MARK: - 语义闸门

    @Test("目标不在册被拒：C 面只收自由函数与给定块")
    func testUnknownTargetsAreRejected() {
        let unknown = failure {
            _ = try typeChecked(
                "[calc|export]\ncalc_ghost|c = 没有这个函数\n\nmain|func() -> (I32,):\n    return 0\n",
                fileName: "calc.pini")
        }
        #expect(unknown?.message.contains("不能发布") == true, "实际：\(String(describing: unknown))")
    }

    @Test("pini 条目不进 C 面判据")
    func testPiniEntriesSkipCValidation() {
        #expect(throws: Never.self) {
            _ = try typeChecked(
                "[calc|export]\n公开 = 没有这个符号\n\nmain|func() -> (I32,):\n    return 0\n",
                fileName: "calc.pini")
        }
    }

    @Test("对外名重复被拒")
    func testDuplicateMachineNamesAreRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f() -> (I32,):
                    return 1
                [calc|export]
                calc_a|c = f
                calc_a|c = f

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("转写后同为 C 名") == true)
    }

    @Test("与生成的生命周期符号同名被拒")
    func testLifecycleNameCollisionIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f() -> (I32,):
                    return 1
                [calc|export]
                calc_init|c = f

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("生命周期符号") == true)
    }

    @Test("错误访问器名不预留，库可自行导出")
    func testLastErrorNameIsAvailableToTheLibrary() throws {
        let module = try lowered(
            """
            f() -> (I32,):
                return 1
            [calc|export]
            calc_last_error|c = f

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let export = try #require(module.export)
        #expect(export.functions.map(\.cName) == ["calc_last_error"])
    }

    @Test("非 C 兼容的形参被拒")
    func testNonCParameterIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f(n: I16,) -> (I32,):
                    return 1
                [calc|export]
                calc_f|c = f

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("不是 C 兼容标量") == true)
    }

    @Test("指针目标必须是 C 标量")
    func testPointerTargetMustBeAScalar() {
        let failed = failure {
            _ = try typeChecked(
                """
                [状态|given]
                    n: I32 = 0

                f(p: *状态,) -> (I32,):
                    return 0
                [calc|export]
                calc_f|c = f

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("指针目标") == true)
        #expect(failed?.message.contains("void*") == true, "诊断要说明为什么不能过")
    }

    @Test("给定块的指针字段同样按指针目标判")
    func testPointerFieldTargetMustBeAScalar() {
        let failed = failure {
            _ = try typeChecked(
                """
                [甲|given]
                    n: I32 = 0

                [乙|given]
                    p: *甲 = nil

                [calc|export]
                calc_b|c = 乙

                main|func() -> (I32,):
                    return 0
                """,
                fileName: "calc.pini")
        }
        #expect(failed?.message.contains("指针目标") == true)
    }

    @Test("标量指针过检查，头文件写成具体指针")
    func testScalarPointerReachesTheHeader() throws {
        let module = try lowered(
            """
            f(p: *U8,) -> (I32,):
                return 0

            [calc|export]
            calc_f|c = f

            main|func() -> (I32,):
                return 0
            """,
            fileName: "calc.pini")
        let header = try CHeaderBackend().emit(module: module)
        #expect(header.contains("int32_t calc_f(uint8_t*);"))
    }

    // MARK: - 降载

    @Test("取用位不进 C 原型，Result 走状态码")
    func testLoweredExportBlockShape() throws {
        let module = try lowered(source, fileName: "calc.pini")
        guard let export = module.export else {
            Issue.record("IR 应携带 C 面"); return
        }
        #expect(export.name == "calc")
        #expect(export.functions.count == 3)
        let addWith = try #require(export.functions.first { $0.cName == "calc_add_with" })
        #expect(addWith.cParamTypes.count == 1, "取用位不进 C 原型")
        #expect(addWith.params.count == 2, "Pini 形参仍含取用位")
        let div = try #require(export.functions.first { $0.cName == "calc_div" })
        #expect(div.statusPayload == .i32)
        #expect(export.storages.first?.fields.map(\.name) == ["count", "limit"])
        #expect(export.initName == "calc_init")
    }

    // MARK: - 头文件

    @Test("头文件含结构体、原型与布局断言")
    func testHeaderContainsStructPrototypesAndAssertions() throws {
        let module = try lowered(source, fileName: "calc.pini")
        let header = try CHeaderBackend().emit(module: module)
        #expect(header.contains("typedef struct calc_state_s {"))
        #expect(header.contains("} calc_state_t;"))
        #expect(header.contains("_Static_assert(sizeof(calc_state_t) == 8"))
        #expect(header.contains("offsetof(calc_state_t, limit) == 4"))
        #expect(header.contains("calc_state_t* calc_state_get(void);"))
        #expect(header.contains("int32_t calc_add(int32_t, int32_t);"))
        #expect(header.contains("int32_t calc_div(int32_t, int32_t, int32_t* out);"))
        #expect(header.contains("int32_t calc_add_with(int32_t);"))
        #expect(header.contains("void calc_init(void);"))
    }

    @Test("没有 |c 条目时头文件报错，不出空文件")
    func testHeaderBackendRejectsModuleWithoutCSurface() throws {
        let module = try lowered("main|func() -> (I32,):\n    return 0\n", fileName: "plain.pini")
        #expect(throws: CHeaderError.self) {
            _ = try CHeaderBackend().emit(module: module)
        }
    }

    // MARK: - helper

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
