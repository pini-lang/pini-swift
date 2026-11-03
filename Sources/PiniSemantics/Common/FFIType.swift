import Foundation
import PiniSyntax

/// C 边界上能出现的类型。闭合集：不在这张表里的标注一律拒绝——没有「也许某个 shim 认得」的中间态。
/// 位置决定哪些形状成立，`String` 只在形参位作为借出的 `const char*`。
public enum FFIType: Equatable, Sendable {
    case i8
    case u8
    case i32
    case i64
    case u64
    case f64
    case boolean
    /// `*T`：目标只能是标量或另一个指针，且不含任何 Pini 运行时类型。
    indirect case pointer(FFIType)
    /// `String` 形参：借出，UTF-8、NUL 结尾，只在本次调用期间有效。
    case cString
    /// C 函数指针形参：`(A, B) -> C`。与 Pini 的闭包值不是同一个表示 —— 后者是 `{code, env}` 胖指针，
    /// 调用时先传 env；把 C 指针塞进那条路等于把代码指针当环境指针用。
    indirect case callback(params: [FFIType], returnType: FFIType?)

    /// 标注所在的位置。同一份标注换个位置可能成立也可能不成，判据收在这里。
    public enum Position {
        /// 外部函数的形参：`String` 可以借出。
        case parameter
        /// 外部函数的返回位：`String` 不行——C 返回的指针归属不明。
        case result
        /// 外部数据符号：只有标量与指针，没有借出这回事。
        case data
    }

    /// 归一一条类型标注。失败时带足够的上下文，让调用方只负责套诊断码。
    public static func resolve(_ annotation: TypeAnnotation, at position: Position) throws -> FFIType {
        switch annotation {
        case .simple(let name, _):
            if let scalar = scalar(named: name) { return scalar }
            if name == "String" {
                guard position != .data else {
                    throw FFITypeError.notRepresentable(
                        type: name, reason: "外部数据符号只能是标量或指针")
                }
                guard position == .parameter else { throw FFITypeError.cStringInReturnPosition }
                return .cString
            }
            if Self.widthsOutsideIR.contains(name) { throw FFITypeError.widthNotInIR(type: name) }
            throw FFITypeError.notRepresentable(type: name, reason: "不是 C 兼容标量或指针")
        case .pointer(let element, _):
            return .pointer(try pointerTarget(element))
        case .function(let params, let returns, let captured, let usingIndices, _):
            /// 函数类型只在形参位成立：返回位需要一个可持有、可比较、可空的一等函数指针值，
            /// 而第二版没有这样的值类型 —— 放行只会把「指针存进变量」的坑留给用户。
            guard position == .parameter else {
                throw FFITypeError.callbackOutsideParameter
            }
            return try callback(params: params, returns: returns, captured: captured, usingIndices: usingIndices)
        case .tuple, .generic:
            throw FFITypeError.notRepresentable(
                type: annotation.describe(), reason: "C 边界只收标量、指针与借出的 String 形参")
        }
    }

    /// 回调签名：参数与返回都只收标量与指针，返回至多一项，`using` 与捕获都是空的。
    /// `String` 与 `Bool` 在这里各有一句拒绝 —— 它们的问题不是宽度，是表示不同。
    private static func callback(
        params: [TypeAnnotation], returns: [TypeAnnotation],
        captured: [TypeAnnotation], usingIndices: Set<Int>
    ) throws -> FFIType {
        guard captured.isEmpty, usingIndices.isEmpty else {
            throw FFITypeError.notRepresentable(
                type: "闭包", reason: "回调只能是顶层自由函数：捕获与取用都在 C 侧无从传递")
        }
        guard returns.count <= 1 else {
            throw FFITypeError.notRepresentable(
                type: "多返回", reason: "C 函数最多返回一个值")
        }
        let paramTypes = try params.map { try callbackElement($0, position: "参数") }
        let returnType = try returns.first.map { try callbackElement($0, position: "返回") }
        return .callback(params: paramTypes, returnType: returnType)
    }

    /// 回调签名里的一个位置。标量与指针放行，`Bool` 与 `String` 各自有专门的拒绝理由。
    private static func callbackElement(_ annotation: TypeAnnotation, position: String) throws -> FFIType {
        switch annotation {
        case .simple(let name, _):
            if name == "Bool" { throw FFITypeError.booleanInCallback }
            if name == "String" {
                throw FFITypeError.notRepresentable(
                    type: "String",
                    reason: "回调\(position)写 String 不行：C 传的是裸字节，Pini 串是带头的堆对象，两侧表示不同")
            }
            if let scalar = scalar(named: name) { return scalar }
            if Self.widthsOutsideIR.contains(name) { throw FFITypeError.widthNotInIR(type: name) }
            throw FFITypeError.notRepresentable(type: name, reason: "回调\(position)只能是 C 标量或指针")
        case .pointer(let element, _):
            return .pointer(try pointerTarget(element))
        default:
            throw FFITypeError.notRepresentable(
                type: annotation.describe(), reason: "回调\(position)只能是 C 标量或指针")
        }
    }

    /// 指针目标：标量继续递归，指针再套一层；其余（含 `String`）都不行。
    private static func pointerTarget(_ annotation: TypeAnnotation) throws -> FFIType {
        switch annotation {
        case .simple(let name, _):
            if let scalar = scalar(named: name) { return scalar }
            if Self.widthsOutsideIR.contains(name) { throw FFITypeError.widthNotInIR(type: name) }
            throw FFITypeError.notRepresentable(type: name, reason: "指针目标只能是 C 标量或指针")
        case .pointer(let element, _):
            return .pointer(try pointerTarget(element))
        default:
            throw FFITypeError.notRepresentable(
                type: annotation.describe(), reason: "指针目标只能是 C 标量或指针")
        }
    }

    /// 标量表。IR 只有这几个宽度，语义层不再多认。
    private static func scalar(named name: String) -> FFIType? {
        switch name {
        case "I8": return .i8
        case "U8": return .u8
        case "I32": return .i32
        case "I64": return .i64
        case "U64": return .u64
        case "F64": return .f64
        case "Bool": return .boolean
        default: return nil
        }
    }

    /// 语言层有这几个宽度，IR 没有对应类型。留一张表是为了报「宽度」而不是「不认识」。
    private static let widthsOutsideIR: Set<String> = ["I16", "U16", "U32", "F32"]

    /// Pini 面拼写，用于诊断。
    public func describe() -> String {
        switch self {
        case .i8: return "I8"
        case .u8: return "U8"
        case .i32: return "I32"
        case .i64: return "I64"
        case .u64: return "U64"
        case .f64: return "F64"
        case .boolean: return "Bool"
        case .pointer(let target): return "*\(target.describe())"
        case .cString: return "String"
        case .callback(let params, let returnType):
            let returned = returnType.map { $0.describe() } ?? ""
            return "(" + params.map { $0.describe() }.joined(separator: ", ") + ") -> (\(returned)) [C]"
        }
    }
}

/// 归一失败的原因。分成几类是为了让诊断码能区分「不认识」「宽度不对」「位置不对」「表示不同」。
public enum FFITypeError: Error, Equatable, Sendable {
    case notRepresentable(type: String, reason: String)
    case widthNotInIR(type: String)
    case cStringInReturnPosition
    /// 函数类型落在形参位之外：返回位与数据位都没有可承载它的值。
    case callbackOutsideParameter
    /// 回调签名里的 `Bool`：Pini 的 `i1` 与 C 的 `_Bool`（零扩展的 `i8`）不是一个寄存器约定。
    case booleanInCallback
}
