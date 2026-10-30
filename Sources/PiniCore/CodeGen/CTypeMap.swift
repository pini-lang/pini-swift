import Foundation

/// C 后端的类型拼写表：IR 类型 → C 类型名、整数字面量、浮点字面量。
/// 未列出的类型一律抛错 —— 静默退化成 `void *` 会让产物编得过而在运行时读错位。
/// 打印形态不在此表：`CEmitter` 逐类型镜像 LLVM 侧，两处必须逐字一致。
public enum CTypeMap {

    /// 名义类型的 C 拼写基准。注意 —— 不加前缀的话，`IRName.mangle` 的产物以 `_` 开头，
    /// 在 C 的文件作用域下属保留标识符；加了前缀也顺带躲开 C23 那批新关键字。
    public static let aggregatePrefix = "pini_"

    public static func aggregateName(_ piniName: String) -> String {
        aggregatePrefix + IRName.mangle(piniName)
    }

    public static func spelling(of type: IRType) throws -> String {
        switch type {
        case .i8: return "int8_t"
        case .u8: return "uint8_t"
        case .i32: return "int32_t"
        case .i64: return "int64_t"
        case .u64: return "uint64_t"
        case .f64: return "double"
        case .boolean: return "bool"
        case .string, .char: return "char *"
        // 名义值一律住堆，故拼写恒为指针 —— 与 LLVM 侧的 `%struct.X*` / `%enum.X*` 同形。
        case .nominal(let name, _): return aggregateName(name) + " *"
        case .enumeration(let name): return aggregateName(name) + " *"
        // 三个容器族在 C 侧都是不透明句柄：布局与 share 记账全在运行时段，本层只搬指针。
        case .array, .dict, .set: return "void *"
        // Optional 是按值的标签联合 `{ tag, value }`，故每个载荷类型一个具名结构体。
        case .optional(let wrapped): return try optionalName(wrapped)
        // 函数值是 `{ code, env }` 两个机器字，与 LLVM 的 `{ ptr, ptr }` 同宽同序。
        case .function: return "PiniClosure"
        // 元组是按值聚合体（不是句柄）：每个形状一个具名结构体，字段序即 LLVM 的 `{ ... }` 字段序。
        case .tuple(_, let fieldTypes): return try tupleName(fieldTypes)
        // LazyRef 与三族容器同为不透明句柄，元素只决定装箱 ABI 与 `.value` 的读出宽度。
        case .lazyRef: return "void *"
        default: throw CBackendError(message: "C 后端尚未支持的类型：\(label(of: type))")
        }
    }

    /// 元组结构体名：由字段类型的后缀拼成 —— 同形状必得同名，字段数或任一字段类型变了就换名。
    /// 标签不参与命名：两个只有标签不同的元组布局相同，在 C 里本就该是同一个类型。
    public static func tupleName(_ fieldTypes: [IRType]) throws -> String {
        guard !fieldTypes.isEmpty else {
            throw CBackendError(message: "C 后端尚未支持的零字段元组")
        }
        return "PiniTuple_" + (try fieldTypes.map { try tupleSuffix($0) }.joined(separator: "_"))
    }

    /// 元组字段的类型后缀。与 `optionalSuffix` 分开维护：两处名字服务的对象不同，
    /// 合表会让 Optional 的具名规则被元组的规则牵动。
    public static func tupleSuffix(_ type: IRType) throws -> String {
        switch type {
        case .i8: return "i8"
        case .u8: return "u8"
        case .i32: return "i32"
        case .i64: return "i64"
        case .u64: return "u64"
        case .f64: return "f64"
        case .boolean: return "bool"
        case .string: return "str"
        case .char: return "chr"
        case .nominal(let name, _): return "nom_" + IRName.mangle(name)
        case .enumeration(let name): return "enum_" + IRName.mangle(name)
        case .array(let element): return "arr_" + (try tupleSuffix(element))
        case .set(let element): return "set_" + (try tupleSuffix(element))
        case .dict(let key, let value):
            return "dict_" + (try tupleSuffix(key)) + "_" + (try tupleSuffix(value))
        case .optional(let wrapped): return "opt_" + (try tupleSuffix(wrapped))
        case .lazyRef(let element): return "lazy_" + (try tupleSuffix(element))
        case .function: return "fn"
        case .tuple(_, let fields):
            return "tup_" + (try fields.map { try tupleSuffix($0) }.joined(separator: "_"))
        default:
            throw CBackendError(message: "C 后端尚未支持的元组字段：\(label(of: type))")
        }
    }

    /// 元组的按值结构体定义。字段按序落 `f0…fn`，宽度取各自的 C 拼写 ——
    /// LLVM 的 `{ i32, i8* }` 与这里的 `{ int32_t, char * }` 必须是同一套对齐规则下的同一布局。
    public static func tupleDefinition(_ fieldTypes: [IRType]) throws -> (name: String, source: String) {
        let name = try tupleName(fieldTypes)
        var source = "typedef struct \(name) {\n"
        for (index, type) in fieldTypes.enumerated() {
            source += "    \(try spelling(of: type)) f\(index);\n"
        }
        return (name, source + "} \(name);\n")
    }

    /// `{ i64, T }` 的 C 具名结构体名。按载荷类型特化 —— 名字由载荷的拼写派生，同类型必得同名。
    public static func optionalName(_ wrapped: IRType) throws -> String {
        "PiniOpt_" + (try optionalSuffix(wrapped))
    }

    /// 载荷类型的后缀。容器与名义类型递归展开，故嵌套容器的 Optional 也有稳定的独立名字。
    public static func optionalSuffix(_ type: IRType) throws -> String {
        switch type {
        case .i8: return "i8"
        case .u8: return "u8"
        case .i32: return "i32"
        case .i64: return "i64"
        case .u64: return "u64"
        case .f64: return "f64"
        case .boolean: return "bool"
        case .string: return "str"
        case .char: return "chr"
        case .nominal(let name, _): return "nom_" + IRName.mangle(name)
        case .enumeration(let name): return "enum_" + IRName.mangle(name)
        case .array(let element): return "arr_" + (try optionalSuffix(element))
        case .set(let element): return "set_" + (try optionalSuffix(element))
        case .dict(let key, let value):
            return "dict_" + (try optionalSuffix(key)) + "_" + (try optionalSuffix(value))
        case .optional(let wrapped): return "opt_" + (try optionalSuffix(wrapped))
        default:
            throw CBackendError(message: "C 后端尚未支持的 Optional 载荷：\(label(of: type))")
        }
    }

    /// Optional 的结构体定义。标签与载荷与 LLVM 侧 `{ i64, T }` 同序：tag 0 = some、1 = none。
    public static func optionalDefinition(_ type: IRType) throws -> (name: String, source: String) {
        guard case .optional(let wrapped) = type else {
            throw CBackendError(message: "C 后端：为非 Optional 类型请求 Optional 定义")
        }
        let name = try optionalName(wrapped)
        let source =
            "typedef struct \(name) {\n"
            + "    int64_t tag;\n"
            + "    \(try spelling(of: wrapped)) value;\n"
            + "} \(name);\n"
        return (name, source)
    }

    /// 零值。`null` 只对指针成立；名义 / 字符串 / 容器都是指针，标量走各自的零。
    public static func zeroLiteral(of type: IRType) throws -> String {
        switch type {
        case .i8, .u8, .i32, .i64, .u64: return "0"
        case .f64: return "0.0"
        case .boolean: return "false"
        case .string, .char, .nominal, .enumeration: return "NULL"
        case .array, .dict, .set: return "NULL"
        // 复合字面量：只给 tag，载荷按 C 的聚合初始化落零。`tag = 1` 即 none。
        case .optional(let wrapped):
            return "((\(try optionalName(wrapped))){ 1 })"
        // 空函数值：code 与 env 同为 NULL，与 LLVM 侧「未初始化即 null」同形。
        case .function: return "((PiniClosure){ NULL, NULL })"
        // 元组是聚合体：只给第一个字段一个 0，其余按 C 的聚合初始化落零（与 LLVM 的零聚合同值）。
        case .tuple(_, let fieldTypes):
            return "((\(try tupleName(fieldTypes))){ 0 })"
        // 句柄：NULL 对 `bk_lazyref_destroy` / 任何读口都是明确的空值。
        case .lazyRef: return "NULL"
        default:
            throw CBackendError(message: "C 后端尚未支持的零值类型：\(label(of: type))")
        }
    }

    /// 整数字面量。后缀随宽度走：无后缀的十进制在 C 里是 `int`，
    /// 拿它初始化 `int64_t` 会在 32 位目标上截断。窄整数一律带强转，
    /// 否则 `int8_t f = 200` 在不同编译器上给的诊断不同。
    public static func integerLiteral(_ value: Int, type: IRType) throws -> String {
        switch type {
        case .i8: return "(int8_t)\(value)"
        case .u8: return "(uint8_t)\(value)"
        case .i32:
            // `-2147483648` 会被解析成「一元负号作用于 2147483648」，那是个越界的 int 常量，
            // 故最小值写成 `(-2147483647 - 1)`。
            if value == Int(Int32.min) { return "(-2147483647 - 1)" }
            return "\(value)"
        case .i64: return "INT64_C(\(value))"
        case .u64:
            guard value >= 0 else {
                throw CBackendError(message: "C 后端：U64 字面量为负（\(value)），降载层不应产出")
            }
            return "UINT64_C(\(value))"
        default:
            throw CBackendError(message: "C 后端尚未支持的整数字面量类型：\(label(of: type))")
        }
    }

    /// 浮点字面量。`%.17g` 保证双精度往返无损；缺小数点与指数时补 `.0`，
    /// 否则 C 会把它当整数读，`1 / 2` 这类表达式的类型随之改变。
    public static func floatLiteral(_ value: Double) throws -> String {
        guard value.isFinite else {
            throw CBackendError(message: "C 后端尚未支持非有限浮点字面量")
        }
        var text = String(format: "%.17g", value)
        if !text.contains(".") && !text.contains("e") && !text.contains("E") {
            text += ".0"
        }
        return text
    }

    /// 错误信息与 `_Static_assert` 里用的类型名。注意 —— 不用 `String(describing:)`：
    /// 那是 Swift 的调试形态，对着 IR 找不到同名节点。
    public static func label(of type: IRType) -> String {
        switch type {
        case .i8: return "I8"
        case .u8: return "U8"
        case .i32: return "I32"
        case .i64: return "I64"
        case .u64: return "U64"
        case .f64: return "F64"
        case .boolean: return "Bool"
        case .string: return "String"
        case .char: return "Char"
        case .result: return "Result"
        case .future: return "Future"
        case .array: return "Array"
        case .optional: return "Optional"
        case .nominal(let name, _): return name
        case .enumeration(let name): return name
        case .dict: return "Dictionary"
        case .lazyRef: return "LazyRef"
        case .set: return "Set"
        case .tuple: return "Tuple"
        case .function: return "Function"
        case .pointer: return "Pointer"
        }
    }
}
