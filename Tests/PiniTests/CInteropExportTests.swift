import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR
@testable import PiniBackends

/// C 导出面的判据：块解析、名字转写、语义闸门与头文件产物。
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

        [calc|c]
        calc_add = 加法
        calc_div = 除法
        calc_add_with = 累加
        calc_state: 计数器状态

        main|func() -> (I32,):
            return 0
        """

    // MARK: - 语法

    @Test("C 导出块收两类条目")
    func testExportBlockParsesBothItemShapes() throws {
        let (module, _) = try typeChecked(source)
        guard case .exportCDecl(let block) = module.declarations.first(where: {
            if case .exportCDecl = $0 { return true }
            return false
        }) else {
            Issue.record("应有 C 导出块"); return
        }
        #expect(block.name == "calc")
        #expect(block.items.count == 4)
        guard case .function(let cName, let pinName, _) = block.items.first else {
            Issue.record("首项应为函数项"); return
        }
        #expect(cName == "calc_add")
        #expect(pinName == "加法")
        guard case .storage(let storageName, let typeName, _) = block.items.last else {
            Issue.record("末项应为量项"); return
        }
        #expect(storageName == "calc_state")
        #expect(typeName == "计数器状态")
    }

    @Test("空导出块被拒")
    func testEmptyExportBlockIsRejected() {
        let failed = failure { _ = try typeChecked("[calc|c]\n\nmain|func() -> (I32,):\n    return 0\n") }
        #expect(failed != nil, "空块应报错")
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

    // MARK: - 语义闸门

    @Test("未声明的函数与量被拒")
    func testUnknownTargetsAreRejected() {
        let unknownFunction = failure {
            _ = try typeChecked("[calc|c]\ncalc_ghost = 没有这个函数\n\nmain|func() -> (I32,):\n    return 0\n")
        }
        #expect(unknownFunction?.message.contains("不是本模块的自由函数") == true)
        let unknownStorage = failure {
            _ = try typeChecked("[calc|c]\ncalc_ghost: 没有这个块\n\nmain|func() -> (I32,):\n    return 0\n")
        }
        #expect(unknownStorage?.message.contains("导出的量只能取给定块") == true)
    }

    @Test("C 名重复被拒")
    func testDuplicateMachineNamesAreRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f() -> (I32,):
                    return 1
                [calc|c]
                calc_a = f
                calc_a = f

                main|func() -> (I32,):
                    return 0
                """)
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
                [calc|c]
                calc_init = f

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.message.contains("生命周期符号") == true)
    }

    @Test("非 C 兼容的形参被拒")
    func testNonCParameterIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                f(s: String,) -> (I32,):
                    return 1
                [calc|c]
                calc_f = f

                main|func() -> (I32,):
                    return 0
                """)
        }
        #expect(failed?.message.contains("不是 C 兼容标量") == true)
    }

    // MARK: - 降载

    @Test("取用位不进 C 原型，Result 走状态码")
    func testLoweredExportBlockShape() throws {
        let module = try lowered(source)
        guard let export = module.export else {
            Issue.record("IR 应携带导出块"); return
        }
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
        let module = try lowered(source)
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

    @Test("没有导出块时头文件报错，不出空文件")
    func testHeaderBackendRejectsModuleWithoutExportBlock() throws {
        let module = try lowered("main|func() -> (I32,):\n    return 0\n")
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
