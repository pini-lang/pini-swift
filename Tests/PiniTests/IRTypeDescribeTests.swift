import Testing

@testable import PiniIR

/// 诊断里的类型必须说 Pini 面的话：`IRType` 没有自定义 `description`，一旦有人退回 `"\(type)"`，
/// 用户看到的是 `PiniIR.IRType.nominal(...)` 与 `Set([0])`。这里把拼写逐 case 钉死，
/// 取用位的标记法一并钉住 —— 它是「两侧为何不等」唯一能看到差别的地方。
@Suite("IR 类型的可读拼写")
struct IRTypeDescribeTests: Sendable {

    @Test("标量逐字大写")
    func scalars() {
        #expect(IRType.i8.describe() == "I8")
        #expect(IRType.u8.describe() == "U8")
        #expect(IRType.i32.describe() == "I32")
        #expect(IRType.i64.describe() == "I64")
        #expect(IRType.u64.describe() == "U64")
        #expect(IRType.f64.describe() == "F64")
        #expect(IRType.boolean.describe() == "Bool")
        #expect(IRType.string.describe() == "String")
        #expect(IRType.char.describe() == "Char")
    }

    @Test("容器与三类前缀用泛型写法")
    func containers() {
        #expect(IRType.array(element: .i32).describe() == "Array<I32>")
        #expect(IRType.dict(key: .string, value: .i32).describe() == "Dictionary<String, I32>")
        #expect(IRType.set(element: .i32).describe() == "Set<I32>")
        #expect(IRType.optional(wrapped: .string).describe() == "Optional<String>")
        #expect(IRType.result(ok: .i32).describe() == "Result<I32>")
        #expect(IRType.future(ok: .i32).describe() == "Future<I32>")
        #expect(IRType.lazyRef(element: .i32).describe() == "LazyRef<I32>")
        #expect(IRType.pointer(element: .u8).describe() == "*U8")
    }

    @Test("名义类型与枚举按声明名，不泄漏 isObject")
    func nominals() {
        #expect(IRType.nominal(name: "点", isObject: false).describe() == "点")
        #expect(IRType.nominal(name: "计数器", isObject: true).describe() == "计数器")
        #expect(IRType.enumeration(name: "形状").describe() == "形状")
    }

    @Test("嵌套按内层先展开")
    func nesting() {
        #expect(IRType.array(element: .optional(wrapped: .nominal(name: "点", isObject: false)))
            .describe() == "Array<Optional<点>>")
    }

    @Test("元组保留标签，空元组是 ()")
    func tuples() {
        #expect(IRType.tuple(labels: ["a", nil], fieldTypes: [.i32, .f64]).describe() == "(a: I32, F64)")
        #expect(IRType.tuple(labels: [], fieldTypes: []).describe() == "()")
    }

    @Test("函数类型逐位标出取用位，空返回写成 ()")
    func functions() {
        #expect(
            IRType.function(
                params: [.nominal(name: "计数块", isObject: false)], returnType: .i32, usingIndices: [0]
            ).describe() == "(using 计数块) -> (I32)"
        )
        #expect(
            IRType.function(params: [.i32, .string], returnType: .boolean, usingIndices: [1])
                .describe() == "(I32, using String) -> (Bool)"
        )
        #expect(
            IRType.function(params: [.i32], returnType: nil, usingIndices: [])
                .describe() == "(I32) -> ()"
        )
        #expect(
            IRType.function(params: [], returnType: .i32, usingIndices: [])
                .describe() == "() -> (I32)"
        )
    }
}
