import Foundation
import PiniCore
import Testing
import PiniSyntax
@testable import PiniSemantics
@testable import PiniIR

/// FFI 类型面的判据：`[名称|foreign]` 块里能写什么，由一张闭合表回答。
/// 这张表是三处消费点（语义校验、降载、解释器）的唯一来源，故用例按「表外拒 / 表内收」两路取证。
struct ForeignTypeSurfaceTests: Sendable, PiniSourceLowering {

    // MARK: - 表外：一律拒

    @Test("对象类型作形参被拒：ARC 引用没有 C 布局")
    func testObjectParameterIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                {人}
                    名字: String = "x"

                [libc|foreign]
                puts: (人,) -> (I32,)

                main|func() -> ():
                    return
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("人") == true, "实际：\(String(describing: failed))")
    }

    @Test("未知简单名被拒：不再有「shim 也许认得」的放行")
    func testUnknownSimpleNameIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                foo: (不是类型,) -> (I32,)

                main|func() -> ():
                    return
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("不是类型") == true, "实际：\(String(describing: failed))")
    }

    @Test("元组与集合被拒：C 边界没有它们的布局")
    func testTupleAndCollectionAreRejected() {
        let tuple = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: ((I32, I32),) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(tuple?.code == "E4-028", "实际：\(String(describing: tuple))")

        let collection = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: ([I32],) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(collection?.code == "E4-028", "实际：\(String(describing: collection))")
    }

    @Test("Result 与 Char 被拒")
    func testResultAndCharAreRejected() {
        let result = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: (^I32,) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(result?.code == "E4-028", "实际：\(String(describing: result))")

        let char = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: (Char,) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(char?.code == "E4-028", "实际：\(String(describing: char))")
    }

    @Test("语言层有、IR 没有的宽度被拒：U32 / I16 / F32")
    func testWidthsOutsideIRAreRejected() {
        for width in ["U32", "I16", "F32", "U16"] {
            let failed = failure {
                _ = try typeChecked(
                    "[libc|foreign]\nfoo: (\(width),) -> (I32,)\n\nmain|func() -> ():\n    return\n")
            }
            #expect(failed?.code == "E4-029", "\(width) 实际：\(String(describing: failed))")
            #expect(failed?.message.contains(width) == true, "\(width) 实际：\(String(describing: failed))")
        }
    }

    @Test("指针目标也过同一张表：*U32 与 *String 都被拒")
    func testPointerTargetsFollowTheSameTable() {
        let width = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: (*U32,) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(width?.code == "E4-029", "实际：\(String(describing: width))")

        let string = failure {
            _ = try typeChecked(
                "[libc|foreign]\nfoo: (*String,) -> (I32,)\n\nmain|func() -> ():\n    return\n")
        }
        #expect(string?.code == "E4-028", "实际：\(String(describing: string))")
    }

    @Test("String 落在返回位被拒：C 返回的指针归属不明")
    func testStringInReturnPositionIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                getenv: (*U8,) -> (String,)

                main|func() -> ():
                    return
                """)
        }
        #expect(failed?.code == "E4-030", "实际：\(String(describing: failed))")
    }

    @Test("C 函数指针形参暂被拒：语法认得出，语义层还没接通")
    func testFunctionPointerParameterIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                """
                [libc|foreign]
                qsort: (*U8, U64, U64, (*U8, *U8,) -> (I32,),) -> ()

                main|func() -> ():
                    return
                """)
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
        #expect(failed?.message.contains("函数指针") == true, "实际：\(String(describing: failed))")
    }

    // MARK: - 表内：收下，并落到 IR

    @Test("标量、指针与 String 形参都能降载，签名进 IR 时保住形状")
    func testRepresentableSignatureLowers() throws {
        let module = try lowered(
            """
            [libc|foreign]
            atoi: (String,) -> (I32,)
            memcpy: (*U8, *U8, U64,) -> (*U8,)
            optind: I32

            main|func() -> ():
                return
            """)
        let block = try #require(module.foreigns.first)
        #expect(block.funcs.count == 2)
        let atoi = try #require(block.funcs.first { $0.name == "atoi" })
        #expect(atoi.params == [.cString])
        #expect(atoi.returnType == .i32)
        let memcpy = try #require(block.funcs.first { $0.name == "memcpy" })
        #expect(memcpy.params == [.pointer(.u8), .pointer(.u8), .u64])
        #expect(block.data.first?.name == "optind")
    }

    @Test("数据符号走数据位：String 不是可读写的 C 存储")
    func testStringDataSymbolIsRejected() {
        let failed = failure {
            _ = try typeChecked(
                "[libc|foreign]\nname: String\n\nmain|func() -> ():\n    return\n")
        }
        #expect(failed?.code == "E4-028", "实际：\(String(describing: failed))")
    }

    @Test("数据符号与函数分表：数据项不进 funcs")
    func testDataSymbolsStayOutOfFunctionList() throws {
        let module = try lowered(
            """
            [libc|foreign]
            optind: I32
            malloc: (U64,) -> (*U8,)

            main|func() -> ():
                return
            """)
        let block = try #require(module.foreigns.first)
        #expect(block.funcs.map(\.name) == ["malloc"])
        #expect(block.data.map(\.name) == ["optind"])
    }

    // MARK: - helper

    private func failure(_ body: () throws -> Void) -> (code: String, message: String)? {
        do {
            try body()
            return nil
        } catch {
            let code = (error as? any DiagnosticProviding)?.diagnosticCode ?? ""
            return (code, String(describing: error))
        }
    }
}
