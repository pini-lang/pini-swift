import Foundation
import PiniSemantics
import PiniSyntax
import PiniIR

/// thunk 工厂：foreign 注册期为每个函数按精确 C 签名生成 `([Value]) throws -> Value` 闭包，
/// 经 `@convention(c)` 函数指针调用 `dlsym` 拿到的裸地址。签名来自 `FFIType`：类型面已在语义期收口，
/// 这里只决定走哪条寄存器路径。整数与指针走 GPR，`F64`/`F32` 走浮点，混用则拒绝。
enum ForeignThunk {
    /// 按「已展开的签名」生成调用闭包 —— 唯一实现，两条通道共用。
    ///
    /// - Parameter params: 与形参位置对齐的 FFI 类型，顺序即 C 原型顺序。
    /// - Parameter returnType: nil 表示 void；其余至多一项。
    static func make(
        symbol sym: UnsafeMutableRawPointer, name: String,
        params: [FFIType], returnType: FFIType?,
        location: SourceLocation
    ) throws -> ([Value]) throws -> Value {
        let paramKinds = try params.enumerated().map { index, type -> Kind in
            guard let kind = kind(of: type) else {
                throw RuntimeError.invalidOperation(
                    reason: rejection(of: type, index: index, name: name), location: location)
            }
            return kind
        }
        let retKind = returnType.flatMap { kind(of: $0) }
        // 声明了返回却说不出宽度 ⇒ 报错，不许退化成「无返回」：静默降级会让调用点读到垃圾。
        if returnType != nil, retKind == nil, let declared = returnType {
            throw RuntimeError.invalidOperation(
                reason: "FFI 裸绑定暂不支持这个返回类型：`\(declared.describe())`（\(name)）",
                location: location)
        }
        // 指针返回：把 `*T` 的元素类型回填到运行时指针值，使 store/load 等原语可用。
        let retElemType: TypeAnnotation? = {
            guard retKind == .ptr, let declared = returnType else { return nil }
            if case .pointer(let target) = declared { return elemAnnotation(for: target) }
            return nil
        }()

        // 浮点签名（参数 + 返回同宽）
        let hasFloat = paramKinds.contains { $0 == .f32 || $0 == .f64 } || retKind == .f32 || retKind == .f64
        if hasFloat {
            if retKind == .f64, paramKinds.allSatisfy({ $0 == .f64 }) {
                return makeFloatThunk(symbol: sym, asFloat: false, name: name, paramKinds: paramKinds, location: location)
            }
            if retKind == .f32, paramKinds.allSatisfy({ $0 == .f32 }) {
                return makeFloatThunk(symbol: sym, asFloat: true, name: name, paramKinds: paramKinds, location: location)
            }
            throw RuntimeError.invalidOperation(reason: "FFI 裸绑定暂不支持 GPR 与浮点混合签名：\(name)", location: location)
        }

        // GPR 路径（整数 / 指针 / void）
        typealias GPRFn = @convention(c) (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) -> UInt64
        let fn = unsafeBitCast(sym, to: GPRFn.self)
        return { (args: [Value]) throws -> Value in
            guard args.count == paramKinds.count else {
                throw RuntimeError.argumentCountMismatch(name: name, expected: paramKinds.count, got: args.count, location: location)
            }
            var cargs: [UInt64] = []
            for (arg, kind) in zip(args, paramKinds) {
                cargs.append(try toUInt64(arg, kind: kind, location: location))
            }
            while cargs.count < 8 { cargs.append(0) }
            let result = fn(cargs[0], cargs[1], cargs[2], cargs[3], cargs[4], cargs[5], cargs[6], cargs[7])
            if let rk = retKind { return try fromUInt64(result, kind: rk, location: location, elemType: retElemType) }
            return .null
        }
    }

    // MARK: - 浮点路径

    private static func makeFloatThunk(symbol sym: UnsafeMutableRawPointer, asFloat: Bool, name: String, paramKinds: [Kind], location: SourceLocation) -> ([Value]) throws -> Value {
        if asFloat {
            typealias Fn = @convention(c) (Float, Float, Float, Float, Float, Float, Float, Float) -> Float
            let fn = unsafeBitCast(sym, to: Fn.self)
            return { (args: [Value]) throws -> Value in
                guard args.count == paramKinds.count else {
                    throw RuntimeError.argumentCountMismatch(name: name, expected: paramKinds.count, got: args.count, location: location)
                }
                var dargs: [Float] = []
                for arg in args {
                    guard case .float(let d) = arg else {
                        throw RuntimeError.typeMismatch(expected: "F32", got: String(describing: arg), location: location)
                    }
                    dargs.append(Float(d))
                }
                while dargs.count < 8 { dargs.append(0) }
                let r = fn(dargs[0], dargs[1], dargs[2], dargs[3], dargs[4], dargs[5], dargs[6], dargs[7])
                return .float(Double(r))
            }
        } else {
            typealias Fn = @convention(c) (Double, Double, Double, Double, Double, Double, Double, Double) -> Double
            let fn = unsafeBitCast(sym, to: Fn.self)
            return { (args: [Value]) throws -> Value in
                guard args.count == paramKinds.count else {
                    throw RuntimeError.argumentCountMismatch(name: name, expected: paramKinds.count, got: args.count, location: location)
                }
                var dargs: [Double] = []
                for arg in args {
                    guard case .float(let d) = arg else {
                        throw RuntimeError.typeMismatch(expected: "F64", got: String(describing: arg), location: location)
                    }
                    dargs.append(d)
                }
                while dargs.count < 8 { dargs.append(0) }
                let r = fn(dargs[0], dargs[1], dargs[2], dargs[3], dargs[4], dargs[5], dargs[6], dargs[7])
                return .float(r)
            }
        }
    }

    // MARK: - 类型编解码

    /// `IRType` → 类型标注的桥：只给外部**数据**符号用（读写宽度来自声明）。
    /// 调用签名不再经过它——那条路由 `FFIType` 决定 ABI 路径。
    static func annotation(for type: IRType) -> TypeAnnotation? {
        let location = SourceLocation(line: 0, column: 0, fileName: "<ir>")
        switch type {
        case .i8: return .simple(name: "I8", location: location)
        case .u8: return .simple(name: "U8", location: location)
        case .i32: return .simple(name: "I32", location: location)
        case .i64: return .simple(name: "I64", location: location)
        case .u64: return .simple(name: "U64", location: location)
        case .f64: return .simple(name: "F64", location: location)
        case .boolean: return .simple(name: "Bool", location: location)
        case .pointer(let element):
            guard let inner = annotation(for: element) else { return nil }
            return .pointer(element: inner, location: location)
        default: return nil
        }
    }

    /// FFI 类型 → 指针元素标注：只服务运行时指针值的 load/store 宽度，不参与 ABI 判定。
    private static func elemAnnotation(for type: FFIType) -> TypeAnnotation? {
        let location = SourceLocation(line: 0, column: 0, fileName: "<ffi>")
        switch type {
        case .i8: return .simple(name: "I8", location: location)
        case .u8: return .simple(name: "U8", location: location)
        case .i32: return .simple(name: "I32", location: location)
        case .i64: return .simple(name: "I64", location: location)
        case .u64: return .simple(name: "U64", location: location)
        case .f64: return .simple(name: "F64", location: location)
        case .boolean: return .simple(name: "Bool", location: location)
        case .pointer(let target):
            guard let inner = elemAnnotation(for: target) else { return nil }
            return .pointer(element: inner, location: location)
        case .cString: return nil
        }
    }

    /// 到了解释器还接不住的形状：目前只有借出的 `String` 形参，文案给出替代写法。
    private static func rejection(of type: FFIType, index: Int, name: String) -> String {
        switch type {
        case .cString:
            return "FFI 裸绑定暂不支持 String 形参：第 \(index + 1) 个；先用 `cstr` 转成 `*U8` 再传（\(name)）"
        default:
            return "FFI 裸绑定参数类型不可作为 C 顶层类型：第 \(index + 1) 个（\(name)）"
        }
    }

    private enum Kind { case ptr, i8, u8, i32, i64, u64, f32, f64, bool }
    /// C 标量 / 指针 → Kind；借出的 `String` 返回 nil，由调用方报错。
    private static func kind(of type: FFIType) -> Kind? {
        switch type {
        case .i8: return .i8
        case .u8: return .u8
        case .i32: return .i32
        case .i64: return .i64
        case .u64: return .u64
        case .f64: return .f64
        case .boolean: return .bool
        case .pointer: return .ptr
        case .cString: return nil
        }
    }

    /// 把 Pini `Value` 按目标 C 标量/指针宽度转为 `UInt64` 位模式（GPR 传递）。
    private static func toUInt64(_ v: Value, kind: Kind, location: SourceLocation) throws -> UInt64 {
        switch kind {
        case .ptr:
            guard case .rawPointer(let rp) = v else {
                throw RuntimeError.typeMismatch(expected: "指针", got: String(describing: v), location: location)
            }
            return UInt64(UInt(bitPattern: rp.pointer))
        case .bool:
            guard case .bool(let b) = v else {
                throw RuntimeError.typeMismatch(expected: "Bool", got: String(describing: v), location: location)
            }
            return b ? 1 : 0
        case .i8: return UInt64(UInt8(truncatingIfNeeded: try intVal(v, location: location)))
        case .u8: return UInt64(UInt8(truncatingIfNeeded: try intVal(v, location: location)))
        case .i32: return UInt64(UInt32(truncatingIfNeeded: try intVal(v, location: location)))
        case .i64: return UInt64(bitPattern: Int64(try intVal(v, location: location)))
        case .u64: return UInt64(bitPattern: Int64(try intVal(v, location: location)))
        case .f32, .f64:
            throw RuntimeError.invalidOperation(reason: "浮点参数不应进入 GPR 路径", location: location)
        }
    }

    private static func intVal(_ v: Value, location: SourceLocation) throws -> Int {
        guard case .int(let i) = v else {
            throw RuntimeError.typeMismatch(expected: "整数", got: String(describing: v), location: location)
        }
        return i
    }

    /// 把 GPR 返回的 `UInt64` 位模式按目标 C 类型回填为 `Value`。
    /// - Parameter elemType：指针返回时携带的 `*T` 元素类型（来自签名），`nil` 表示未知。
    private static func fromUInt64(_ bits: UInt64, kind: Kind, location: SourceLocation, elemType: TypeAnnotation? = nil) throws -> Value {
        switch kind {
        case .ptr:
            if bits == 0 { return .null }
            var b = bits
            let ptr = withUnsafeBytes(of: &b) { $0.load(as: UnsafeMutableRawPointer.self) }
            return .rawPointer(RawPointerValue(pointer: ptr, elemType: elemType, freesMemory: false))
        case .bool: return .bool(bits != 0)
        case .i8: return .int(Int(Int8(bitPattern: UInt8(bits & 0xFF))))
        case .u8: return .int(Int(bits & 0xFF))
        case .i32: return .int(Int(Int32(bitPattern: UInt32(bits & 0xFFFFFFFF))))
        case .i64: return .int(Int(Int64(bitPattern: bits)))
        case .u64: return .int(Int(Int64(bitPattern: bits)))
        case .f32, .f64:
            throw RuntimeError.invalidOperation(reason: "浮点返回不应进入 GPR 路径", location: location)
        }
    }
}
