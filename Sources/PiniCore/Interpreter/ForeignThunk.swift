import Foundation

/// Phase 2b（ADR-017）：每签名 thunk 工厂。
///
/// 因 Phase 2a已将顶层签名收敛为**封闭集**（标量 + 指针 + `()`），
/// 在 foreign 注册期为每个函数按精确 C 签名生成 `([Value]) throws -> Value` 闭包，
/// 经 `@convention(c)` 函数指针调用 `dlsym` 得到的裸地址。
///
/// 实现策略（避免 libffi 依赖、分支可枚举）：
/// - **GPR 路径**：整数 / 指针参数与返回统一经 8 个 `UInt64` 通用寄存器传递
/// （AArch64 `x0–x7` / System V `rdi–r9`）；按参数宽度取低位、指针取地址位模式，
/// 调用后按返回宽度回填 `Value`。超出 8 参数、混用浮点者走浮点路径 / 拒绝。
/// - **浮点路径**：`F64` / `F32` 签名各自经 `Double` / `Float` 寄存器（VFP）传递，
/// 要求参数与返回同宽（混合 GPR+浮点暂不支持，抛「unsupported signature」已知限制）。
enum ForeignThunk {
 /// 为裸 C 符号地址生成调用闭包。签名取自 `decl`（已通过 静态校验）。
 static func make(symbol sym: UnsafeMutableRawPointer, decl: FuncDecl, location: SourceLocation) throws -> ([Value]) throws -> Value {
 guard decl.returnTypes.count <= 1 else {
 throw RuntimeError.invalidOperation(reason: "FFI 裸绑定仅支持单返回（多返回元组已在类型检查期拒绝）：\(decl.name)", location: location)
 }
 let paramKinds = try decl.params.map { p -> Kind in
 guard let ta = p.typeAnnotation, let k = kind(of: ta) else {
 throw RuntimeError.invalidOperation(reason: "FFI 裸绑定参数类型不可作为 C 顶层类型：\(p.name)", location: location)
 }
 return k
 }
 let retKind = decl.returnTypes.first.flatMap { kind(of: $0) }
 // 指针返回：从签名 `*T` 提取元素类型，回填到运行时指针值，使 store/load
 // 等指针原语可用（否则 elemType 为 nil，报「指针元素类型未知」）。
 let retElemType: TypeAnnotation? = {
 guard retKind == .ptr, let rt = decl.returnTypes.first else { return nil }
 if case .pointer(element: let elem, location: _) = rt { return elem }
 return nil
 }()

 // 浮点签名（参数 + 返回同宽）
 let hasFloat = paramKinds.contains { $0 == .f32 || $0 == .f64 } || retKind == .f32 || retKind == .f64
 if hasFloat {
 if retKind == .f64, paramKinds.allSatisfy({ $0 == .f64 }) {
 return makeFloatThunk(symbol: sym, asFloat: false, decl: decl, paramKinds: paramKinds, location: location)
 }
 if retKind == .f32, paramKinds.allSatisfy({ $0 == .f32 }) {
 return makeFloatThunk(symbol: sym, asFloat: true, decl: decl, paramKinds: paramKinds, location: location)
 }
 throw RuntimeError.invalidOperation(reason: "FFI 裸绑定暂不支持 GPR 与浮点混合签名：\(decl.name)", location: location)
 }

 // GPR 路径（整数 / 指针 / void）
 typealias GPRFn = @convention(c) (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) -> UInt64
 let fn = unsafeBitCast(sym, to: GPRFn.self)
 return { (args: [Value]) throws -> Value in
 guard args.count == paramKinds.count else {
 throw RuntimeError.argumentCountMismatch(name: decl.name, expected: paramKinds.count, got: args.count, location: location)
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

 private static func makeFloatThunk(symbol sym: UnsafeMutableRawPointer, asFloat: Bool, decl: FuncDecl, paramKinds: [Kind], location: SourceLocation) -> ([Value]) throws -> Value {
 if asFloat {
 typealias Fn = @convention(c) (Float, Float, Float, Float, Float, Float, Float, Float) -> Float
 let fn = unsafeBitCast(sym, to: Fn.self)
 return { (args: [Value]) throws -> Value in
 guard args.count == paramKinds.count else {
 throw RuntimeError.argumentCountMismatch(name: decl.name, expected: paramKinds.count, got: args.count, location: location)
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
 throw RuntimeError.argumentCountMismatch(name: decl.name, expected: paramKinds.count, got: args.count, location: location)
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

 private enum Kind { case ptr, i8, u8, i16, u16, i32, u32, i64, u64, f32, f64, bool }
 /// C 兼容标量 / 指针 → Kind；引用类型 / 未知 → nil（裸绑定不应到达）。
 private static func kind(of t: TypeAnnotation) -> Kind? {
 switch t {
 case .simple(let name, _):
 switch name {
 case "I8": return .i8; case "U8": return .u8
 case "I16": return .i16; case "U16": return .u16
 case "I32": return .i32; case "U32": return .u32
 case "I64": return .i64; case "U64": return .u64
 case "F32": return .f32; case "F64": return .f64
 case "Bool": return .bool
 default: return nil
 }
 case .pointer: return .ptr
 default: return nil
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
 case .i16: return UInt64(UInt16(truncatingIfNeeded: try intVal(v, location: location)))
 case .u16: return UInt64(UInt16(truncatingIfNeeded: try intVal(v, location: location)))
 case .i32: return UInt64(UInt32(truncatingIfNeeded: try intVal(v, location: location)))
 case .u32: return UInt64(UInt32(truncatingIfNeeded: try intVal(v, location: location)))
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
 return .rawPointer(RawPointerValue(pointer: ptr, elemType: elemType, ownsMemory: false))
 case .bool: return .bool(bits != 0)
 case .i8: return .int(Int(Int8(bitPattern: UInt8(bits & 0xFF))))
 case .u8: return .int(Int(bits & 0xFF))
 case .i16: return .int(Int(Int16(bitPattern: UInt16(bits & 0xFFFF))))
 case .u16: return .int(Int(bits & 0xFFFF))
 case .i32: return .int(Int(Int32(bitPattern: UInt32(bits & 0xFFFFFFFF))))
 case .u32: return .int(Int(bits & 0xFFFFFFFF))
 case .i64: return .int(Int(Int64(bitPattern: bits)))
 case .u64: return .int(Int(Int64(bitPattern: bits)))
 case .f32, .f64:
 throw RuntimeError.invalidOperation(reason: "浮点返回不应进入 GPR 路径", location: location)
 }
 }
}
