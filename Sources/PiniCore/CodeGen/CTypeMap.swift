import Foundation

/// C 后端的类型拼写表：IR 类型 → C 类型名、整数字面量、浮点字面量。
/// 未列出的类型一律抛错 —— 静默退化成 `void *` 会让产物编得过而在运行时读错位。
/// 打印形态不在此表：`CEmitter` 逐类型镜像 LLVM 侧，两处必须逐字一致。
public enum CTypeMap {

    public static func spelling(of type: IRType) throws -> String {
        switch type {
        case .i32: return "int32_t"
        case .i64: return "int64_t"
        case .u64: return "uint64_t"
        case .f64: return "double"
        case .boolean: return "bool"
        case .string, .char: return "char *"
        default: throw CBackendError(message: "C 后端尚未支持的类型：\(label(of: type))")
        }
    }

    /// 整数字面量。后缀随宽度走：无后缀的十进制在 C 里是 `int`，
    /// 拿它初始化 `int64_t` 会在 32 位目标上截断。
    public static func integerLiteral(_ value: Int, type: IRType) throws -> String {
        switch type {
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

    /// 错误信息与 `_Static_assert` 里用的类型名。⛔ 不用 `String(describing:)`：
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
