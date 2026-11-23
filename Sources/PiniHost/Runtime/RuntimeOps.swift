#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// 两个引擎共用的运行时操作：值级辅助函数、内建与谓词。
/// 这里不得引用 `Interpreter`，每个成员都是对 `Value` 的纯函数。
/// 名字表在加载时填一次、此后不再改写，闭包不捕获任何东西，故无锁读取安全。
public enum RuntimeOps {

    /// 值类型拷贝：`structInstance` 逐字段递归复制，其余值原样返回。
    /// 对象故意保持别名，这正是别名语义正确的来源；两个引擎的每个存储点都要遵守。
    static func copyIfStruct(_ value: Value) -> Value {
        if case .structInstance(let si) = value {
            var copiedFields: [String: Value] = [:]
            for (k, v) in si.fields {
                copiedFields[k] = copyIfStruct(v)
            }
            return .structInstance(StructInstance(typeName: si.typeName, fields: copiedFields))
        }
        return value
    }

    static func applyReturnLabels(_ labels: [String?], to value: Value) -> Value {
        guard !labels.isEmpty else { return value }
        guard case .tuple(_, let elements) = value, elements.count == labels.count else { return value }
        return RuntimeOps.relabelled(value, with: labels)
    }

    /// 字符串判等按 UTF-8 字节序列：与编译通道的「先比长度再 `memcmp`」同一条判据，不做规范等价。
    /// NFD 的 `é`（`65 CC 81`）与预组合的 `é`（`C3 A9`）因此不等 —— 这是规定行为，不是缺陷。
    @inline(__always)
    private static func byteEqual(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func binaryValue(_ l: Value, _ op: BinaryOperator, _ r: Value) throws -> Value {
        switch (l, r, op) {
        case (.int(let a), .int(let b), .plus): return .int(a + b)
        case (.int(let a), .int(let b), .minus): return .int(a - b)
        case (.int(let a), .int(let b), .multiply): return .int(a * b)
        case (.int(let a), .int(let b), .divide):
            if b == 0 { throw RuntimeError.divisionByZero(location: SourceLocation(line: 0, column: 0, fileName: "")) }
            return .int(a / b)
        case (.int(let a), .int(let b), .modulo):
            if b == 0 { throw RuntimeError.divisionByZero(location: SourceLocation(line: 0, column: 0, fileName: "")) }
            return .int(a % b)
        case (.int(let a), .int(let b), .equal): return .bool(a == b)
        case (.int(let a), .int(let b), .notEqual): return .bool(a != b)
        case (.int(let a), .int(let b), .lessThan): return .bool(a < b)
        case (.int(let a), .int(let b), .lessThanOrEqual): return .bool(a <= b)
        case (.int(let a), .int(let b), .greaterThan): return .bool(a > b)
        case (.int(let a), .int(let b), .greaterThanOrEqual): return .bool(a >= b)
        case (.float(let a), .float(let b), .plus): return .float(a + b)
        case (.float(let a), .float(let b), .minus): return .float(a - b)
        case (.float(let a), .float(let b), .multiply): return .float(a * b)
        case (.float(let a), .float(let b), .divide): return .float(a / b)
        // F64 同型比较六算符，与 int 分派形态一致：`==` / `!=` / `<` / `<=` / `>` / `>=`。
        // 缺一条就会落到 `default` 抛 `typeMismatch`，F64 于是只能算不能比。
        case (.float(let a), .float(let b), .equal): return .bool(a == b)
        case (.float(let a), .float(let b), .notEqual): return .bool(a != b)
        case (.float(let a), .float(let b), .lessThan): return .bool(a < b)
        case (.float(let a), .float(let b), .lessThanOrEqual): return .bool(a <= b)
        case (.float(let a), .float(let b), .greaterThan): return .bool(a > b)
        case (.float(let a), .float(let b), .greaterThanOrEqual): return .bool(a >= b)
        case (.string(let a), .string(let b), .plus): return .string(a + b)
        // `Char` 搭 `String` 的车：凡 `String` 支持的算符，`Char` 参与时行为一致（拼接出 `String`、比较按字素内容）。
        // 分派按值 case 的元组形状做，`Char` 与 `String` 是两个 case ⇒ 3 算符 × 3 组合写全。
        // 漏写会落到 `default: throw`，编译器同样不报 —— 只能按清单逐处勾。
        case (.char(let a), .char(let b), .plus): return .string(a + b)
        case (.char(let a), .string(let b), .plus): return .string(a + b)
        case (.string(let a), .char(let b), .plus): return .string(a + b)
        case (.string(let a), .string(let b), .equal): return .bool(byteEqual(a, b))
        case (.char(let a), .char(let b), .equal): return .bool(byteEqual(a, b))
        case (.char(let a), .string(let b), .equal): return .bool(byteEqual(a, b))
        case (.string(let a), .char(let b), .equal): return .bool(byteEqual(a, b))
        // 内建双层结构 试点发现：String 缺 notEqual 分派（语言内 contains 需要）——补齐。
        case (.string(let a), .string(let b), .notEqual): return .bool(!byteEqual(a, b))
        case (.char(let a), .char(let b), .notEqual): return .bool(!byteEqual(a, b))
        case (.char(let a), .string(let b), .notEqual): return .bool(!byteEqual(a, b))
        case (.string(let a), .char(let b), .notEqual): return .bool(!byteEqual(a, b))
        case (.bool(let a), .bool(let b), .equal): return .bool(a == b)
        case (.bool(let a), .bool(let b), .notEqual): return .bool(a != b)
        // 无主引用在编译通道就是对象指针：比较的是目标身份，同一目标的两份句柄相等。
        //  注意  目标已销毁时比较与编译通道一样落在未定义行为上，不在这里补存活判定。
        case (.unownedRef(let a), .unownedRef(let b), .equal): return .bool(a.target === b.target)
        case (.unownedRef(let a), .unownedRef(let b), .notEqual): return .bool(a.target !== b.target)
        case (.bool(let a), .bool(let b), .and): return .bool(a && b)
        case (.bool(let a), .bool(let b), .or): return .bool(a || b)
        case (.int(let a), .int(let b), .bitwiseAnd): return .int(a & b)
        case (.int(let a), .int(let b), .bitwiseOr): return .int(a | b)
        case (.int(let a), .int(let b), .bitwiseXor): return .int(a ^ b)
        case (.int(let a), .int(let b), .leftShift): return .int(a << b)
        case (.int(let a), .int(let b), .rightShift): return .int(a >> b)
        default:
            throw RuntimeError.typeMismatch(expected: "compatible", got: "\(l), \(r)", location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
    }

    static func builtinAbs(_ value: Value) throws -> Value {
        switch value {
        case .int(let v):
            // `Int.min` 没有可表示的绝对值：不先挡住，`abs(Int.min)` 会因整数溢出触发陷阱。
            if v == .min {
                throw RuntimeError.invalidOperation(
                    reason: "abs 整数溢出: \(v) 超出 Int 表示范围",
                    location: SourceLocation(line: 0, column: 0, fileName: "")
                )
            }
            return .int(abs(v))
        case .float(let v): return .float(abs(v))
        default:
            throw RuntimeError.invalidOperation(
                reason: "abs 的参数必须是数值",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    /// `F64(value)` —— 数值构造函数（`BuiltinRegistry` 的 `F64`，`value` 组）。
    /// 浮点原样返回，整数拓宽；IR 执行器与 AST 走查同守这条规则。
    static func builtinF64(_ value: Value) throws -> Value {
        switch value {
        case .float(let f): return .float(f)
        case .int(let i): return .float(Double(i))
        default:
            throw RuntimeError.invalidOperation(
                reason: "F64 的参数必须是数值（int/float）",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    /// IR 通道按名字作答的数组成员面：接收者在先，调用实参随后。
    /// 每条返回的都等于 AST 走查的成员分派结果，两个引擎因此不会漂移。
    nonisolated(unsafe) static let arrayMethods: [String: ([Value]) throws -> Value] = [
        "Array.append": builtinArrayAppend,
        "Array.last": builtinArrayLast,
        "Array.pop": builtinArrayPop,
    ]

    /// `xs.append(v)` —— 末尾追加 `v` 的新数组；接收者保持不动，
    /// 值语义因此在调用点可见。
    static func builtinArrayAppend(_ args: [Value]) throws -> Value {
        let arr = try arrayMemberReceiver(args)
        guard args.count == 2 else {
            throw RuntimeError.invalidOperation(
                reason: "append 需要一个实参",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .array(arr + [args[1]])
    }

    /// 消费式追加：调用方已把槽位清空，交进来的是唯一候选。
    /// 数组只剩这一份引用时就地增长；否则由数组自身的写时复制兜底，代价与拼接相同。
    /// 返回 false 表示接收者不是数组，调用方走原路径报同一个错。
    @discardableResult
    static func appendConsuming(_ slot: inout Value, _ element: Value) -> Bool {
        guard case .array(var items) = slot else { return false }
        slot = .null
        items.append(element)
        slot = .array(items)
        consumingAppendHits += 1
        return true
    }

    /// 消费式追加的命中计数：只服务判据，不进语义；测试读它证明快路真在跑。
    nonisolated(unsafe) public static var consumingAppendHits = 0

    /// `xs.last()` —— 末元素。空数组走安全断言通道，与 `xs[len(xs) - 1]` 同一条退出。
    ///  注意  返回的是元素本身而非 `Optional`：静态类型是元素类型，用 null 兜底会让类型与值脱钩。
    static func builtinArrayLast(_ args: [Value]) throws -> Value {
        let arr = try arrayMemberReceiver(args)
        guard let last = arr.last else {
            throw RuntimeError.indexOutOfRange(location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        return last
    }

    /// `xs.pop()` -- 一对 `(去掉末元素的数组, 末元素)`。空数组同上，走断言通道。
    static func builtinArrayPop(_ args: [Value]) throws -> Value {
        let arr = try arrayMemberReceiver(args)
        guard let last = arr.last else {
            throw RuntimeError.indexOutOfRange(location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        return .tuple(labels: [nil, nil], elements: [.array(Array(arr.dropLast())), last])
    }

    /// 接收者永远是第一个值；不可能来自降载层的调用直接拒绝，不猜测。
    private static func arrayMemberReceiver(_ args: [Value]) throws -> [Value] {
        guard let first = args.first, case .array(let a) = first else {
            throw RuntimeError.invalidOperation(
                reason: "该操作仅可用于数组接收者",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return a
    }

    static let builtinCancelErrorTypeName = "CancelError"

    static func builtinCos(_ value: Value) throws -> Value {
        return .float(cos(try trigArgument(value, name: "cos")))
    }

    static let builtinErrorTypeName = "Error"

    static func builtinGet(
        receiver: Value,
        index: Value,
        checked: Bool,
        location: SourceLocation
    ) throws -> Value {
        let name = checked ? "get" : "getUnchecked"
        let some: (Value) -> Value = { .enumValue(EnumValue(caseName: "some", associatedValues: [$0])) }
        func outOfRange() throws -> Value {
            guard checked else {
                throw RuntimeError.invalidOperation(
                    reason: "getUnchecked 越界：调用方违反前置条件（解释器以 UB 陷阱近似；LLVM 端为真 UB）",
                    location: location
                )
            }
            return .enumValue(EnumValue(caseName: "none", associatedValues: []))
        }
        // 类型分流，再各自校验参数，避免把键误当索引。
        if case .dictionary(let entries) = receiver {
            for (k, v) in entries where k == index {
                return checked ? some(v) : v
            }
            return try outOfRange()
        }
        guard case .int(let raw) = index else {
            throw RuntimeError.invalidOperation(reason: "\(name) 的参数必须是整数索引", location: location)
        }
        switch receiver {
        case .array(let arr):
            let idx = raw < 0 ? arr.count + raw : raw
            guard idx >= 0, idx < arr.count else { return try outOfRange() }
            return checked ? some(arr[idx]) : arr[idx]
        case .string(let s):
            // 字素簇语义不变，但「数总字数」与「定位第 i 个字素」都走 `GraphemeCursor`（均摊 O(1)、空间 O(1)）。
            // ⇒ 逐字符扫描整体 O(n) 而非 O(n²)；语义与边界判定（含负值尾计数）不变。
            let n = GraphemeCursor.count(of: s)
            let idx = raw < 0 ? n + raw : raw
            guard idx >= 0, idx < n else { return try outOfRange() }
            let ch: Value = .string(String(GraphemeCursor.character(in: s, at: idx)))
            return checked ? some(ch) : ch
        default:
            throw RuntimeError.invalidOperation(reason: "\(name) 的接收者必须是数组/字符串/字典", location: location)
        }
    }

    static func builtinMax(_ a: Value, _ b: Value) throws -> Value {
        switch (a, b) {
        case (.int(let x), .int(let y)): return .int(Swift.max(x, y))
        case (.float(let x), .float(let y)): return .float(Swift.max(x, y))
        default:
            throw RuntimeError.invalidOperation(
                reason: "min/max 的参数必须是同类型数值",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    static func builtinMin(_ a: Value, _ b: Value) throws -> Value {
        switch (a, b) {
        case (.int(let x), .int(let y)): return .int(Swift.min(x, y))
        case (.float(let x), .float(let y)): return .float(Swift.min(x, y))
        default:
            throw RuntimeError.invalidOperation(
                reason: "min/max 的参数必须是同类型数值",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    static let builtinResultEnumName = "Result"

    /// 取回：C 串复制成 Pini 串。空指针按空串处理，与运行时段 `bk_str_dup` 同一约定。
    /// 非法 UTF-8 在解释器侧换成 U+FFFD（Swift 串只能持合法 Unicode），LLVM 侧原样搬字节。
    static func stringFromCString(_ value: Value) throws -> Value {
        if case .null = value { return .string("") }
        guard case .rawPointer(let rp) = value else {
            throw RuntimeError.typeMismatch(
                expected: "*U8 指针", got: String(describing: value),
                location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        let length = strlen(rp.pointer.assumingMemoryBound(to: CChar.self))
        let bytes = UnsafeBufferPointer(
            start: rp.pointer.assumingMemoryBound(to: UInt8.self), count: length)
        return .string(String(decoding: bytes, as: UTF8.self))
    }

    static func builtinSin(_ value: Value) throws -> Value {
        return .float(sin(try trigArgument(value, name: "sin")))
    }

    static func builtinSqrt(_ value: Value) throws -> Value {
        switch value {
        case .int(let v): return .float(sqrt(Double(v)))
        case .float(let v): return .float(sqrt(v))
        default:
            throw RuntimeError.invalidOperation(
                reason: "sqrt 的参数必须是数值",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    static func containerLength(_ value: Value) throws -> Value {
        switch value {
        case .tuple(_, let elements): return .int(elements.count)
        case .array(let elements): return .int(elements.count)
        case .dictionary(let entries): return .int(entries.count)
        case .set(let elements): return .int(elements.count)
        case .string(let text): return .int(GraphemeCursor.count(of: text))
        default:
            throw RuntimeError.invalidOperation(
                reason: "len 不支持的类型: \(value)",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    static func decodePointer(_ rp: RawPointerValue) throws -> Value {
        let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
        guard let elem = rp.elemType else {
            throw RuntimeError.invalidOperation(reason: "load：指针元素类型未知（`&` 快照 / malloc 未标注 `*T` 元素）", location: loc)
        }
        switch elem {
        case .simple(let name, _):
            // 元素类型只能来自 `CPointerTarget` 的标量表：检查期已挡住表外名字，
            // 这里再挡一次，让「表里有、解码没写」在运行时立刻显形，而不是按错宽度读。
            guard CPointerTarget.width(of: name) != nil else {
                throw RuntimeError.invalidOperation(reason: "load：不支持的指针元素类型 `\(name)`", location: loc)
            }
            switch name {
            case "I8", "U8": return .int(Int(rp.pointer.load(as: Int8.self)))
            case "I32": return .int(Int(rp.pointer.load(as: Int32.self)))
            case "I64", "U64": return .int(rp.pointer.load(as: Int.self))
            case "F64": return .float(rp.pointer.load(as: Double.self))
            case "Bool": return .bool(rp.pointer.load(as: Bool.self))
            default:
                throw RuntimeError.invalidOperation(
                    reason: "load：`\(name)` 在标量表里，但解码分支没写", location: loc)
            }
        case .pointer:
            let p = rp.pointer.load(as: UnsafeMutableRawPointer.self)
            return .rawPointer(RawPointerValue(pointer: p, elemType: elem, freesMemory: false))
        default:
            throw RuntimeError.invalidOperation(reason: "load：不支持的指针元素类型 `\(elem.describe())`", location: loc)
        }
    }

    static func decomposePatternRow(_ element: Value, patternCount: Int, location: SourceLocation) throws -> [Value] {
        let fields: [Value]
        switch element {
        case .tuple(_, let t): fields = t
        default: fields = [element]
        }
        guard fields.count == patternCount else {
            throw RuntimeError.typeMismatch(
                expected: "\(patternCount) 字段模式元组",
                got: "\(fields.count) 字段元素（模式元组须与集合元素一一对应）",
                location: location
            )
        }
        return fields
    }

    static func describeValueKind(_ value: Value) -> String {
        switch value {
        case .int: return "I32"
        case .float: return "F64"
        case .string: return "String"
        case .char: return "Char"
        case .bool: return "Bool"
        case .tuple: return "Tuple"
        case .array: return "Array"
        case .dictionary: return "Dictionary"
        case .set: return "Set"
        case .structInstance(let si): return si.typeName
        case .objectReference(let obj): return obj.typeName
        case .enumValue(let ev): return ev.parentEnum ?? ev.caseName
        case .function: return "Function"
        case .future: return "Future"
        case .weakRef: return "WeakRef"
        case .unownedRef: return "UnownedRef"
        case .lazyRef: return "LazyRef"
        case .rawPointer: return "Pointer"
        case .null: return "Null"
        }
    }

    static func encode(_ value: Value, to ptr: UnsafeMutableRawPointer, type: TypeAnnotation?) throws {
        let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
        guard let elem = type else {
            throw RuntimeError.invalidOperation(reason: "store：指针元素类型未知", location: loc)
        }
        switch elem {
        case .simple(let name, _):
            // 与 `decodePointer` 同一道表检查：写入宽度必须是表里登记的那个，
            // 表外名字在检查期就该被拒，走到这里说明判据有漏。
            guard CPointerTarget.width(of: name) != nil else {
                throw RuntimeError.invalidOperation(reason: "store：不支持的指针元素类型 `\(name)`", location: loc)
            }
            switch name {
            case "I8", "U8":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Int8(truncatingIfNeeded: i), as: Int8.self)
            case "I32":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Int32(truncatingIfNeeded: i), as: Int32.self)
            case "I64", "U64":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: i, as: Int.self)
            case "F64":
                guard case .float(let f) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: f, as: Double.self)
            case "Bool":
                guard case .bool(let b) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: b, as: Bool.self)
            default:
                throw RuntimeError.invalidOperation(
                    reason: "store：`\(name)` 在标量表里，但编码分支没写", location: loc)
            }
        case .pointer:
            guard case .rawPointer(let rp) = value else { throw Self.typeMismatch(name: "*\(elem.describe())", value: value, loc: loc) }
            ptr.storeBytes(of: rp.pointer, as: UnsafeMutableRawPointer.self)
        default:
            throw RuntimeError.invalidOperation(reason: "store：不支持的指针元素类型 `\(elem.describe())`", location: loc)
        }
    }

    static func intArg(_ args: [Value], name: String, offset: Int = 0) throws -> Int {
        guard args.count > offset else {
            throw RuntimeError.argumentCountMismatch(
                name: name, expected: offset + 1, got: args.count,
                location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        guard case .int(let v) = args[offset] else {
            throw RuntimeError.invalidOperation(
                reason: "\(name)：第 \(offset + 1) 个参数须为整型",
                location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        return v
    }

    /// shim 认的形参形状。声明逐位相容才走 shim：借出的 `String` 与 `*T` 不是一个形状，
    /// 按名字硬套会把合法声明拒掉。
    enum ShimShape {
        case pointer, string, integer, boolean, floating

        func matches(_ type: FFIType) -> Bool {
            switch (self, type) {
            case (.pointer, .pointer), (.string, .cString), (.boolean, .boolean), (.floating, .f64):
                return true
            case (.integer, .i8), (.integer, .u8), (.integer, .i32), (.integer, .i64), (.integer, .u64):
                return true
            default:
                return false
            }
        }
    }

    /// 一条 shim：形状与实现捆在一起，命中判据因此只有一处，不会名字对上了形状没对上。
    struct LibcShim {
        let shape: [ShimShape]
        let body: ([Value]) throws -> Value

        func serves(_ params: [FFIType]) -> Bool {
            shape.count == params.count && zip(shape, params).allSatisfy { $0.matches($1) }
        }
    }

    /// 名字与声明形状都对上才给实现；否则调用方落到通用 thunk。
    static func libcShim(named name: String, params: [FFIType]) -> (([Value]) throws -> Value)? {
        guard let shim = libcShims[name], shim.serves(params) else { return nil }
        return shim.body
    }

    nonisolated(unsafe) static let libcShims: [String: LibcShim] = {
        var shims: [String: LibcShim] = [:]
        #if canImport(Darwin) || canImport(Glibc)
            let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

            // malloc(size: U64) -> *U8：C 语义——内存归用户，free 释放。
            shims["malloc"] = LibcShim(shape: [.integer]) { args in
                let n = try RuntimeOps.intArg(args, name: "malloc")
                guard let p = malloc(n) else {
                    throw RuntimeError.invalidOperation(reason: "malloc 失败：内存不足", location: loc)
                }
                return .rawPointer(
                    RawPointerValue(
                        pointer: p,
                        elemType: .simple(name: "U8", location: loc),
                        freesMemory: false
                    ))
            }

            // free(p: *U8) -> ()：C 语义。
            shims["free"] = LibcShim(shape: [.pointer]) { args in
                let p = try RuntimeOps.ptrArg(args, name: "free", self: nil)
                free(p.pointer)
                return .null
            }

            // bk_parse_double(text: String) -> F64：编译期浮点字面量取值，与宿主 `Double(text)` 同舍入。
            shims["bk_parse_double"] = LibcShim(shape: [.string]) { args in
                guard case .string(let text) = args[0] else {
                    throw RuntimeError.invalidOperation(reason: "bk_parse_double 的参数须为字符串", location: loc)
                }
                guard let value = Double(text) else {
                    throw RuntimeError.invalidOperation(reason: "bk_parse_double 无法解析 `\(text)`", location: loc)
                }
                return .float(value)
            }

            // bk_double_bits(value: F64) -> I64：位模式，发射侧据此写十六进制常量。
            shims["bk_double_bits"] = LibcShim(shape: [.floating]) { args in
                guard case .float(let value) = args[0] else {
                    throw RuntimeError.invalidOperation(reason: "bk_double_bits 的参数须为浮点", location: loc)
                }
                return .int(Int(bitPattern: UInt(value.bitPattern)))
            }

            // memcpy(dst: *U8, src: *U8, n: U64) -> *U8：复制 n 个字节，返回 dst。
            shims["memcpy"] = LibcShim(shape: [.pointer, .pointer, .integer]) { args in
                guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memcpy", expected: 3, got: args.count, location: loc) }
                guard case .rawPointer(let dst) = args[0] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 1 参须为指针", location: loc) }
                guard case .rawPointer(let src) = args[1] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 2 参须为指针", location: loc) }
                let n = try RuntimeOps.intArg(args, name: "memcpy", offset: 2)
                memcpy(dst.pointer, src.pointer, n)
                return args[0]
            }

            // memset(p: *U8, v: I32, n: U64) -> *U8：把 n 个字节置为 v 的低 8 位，返回 p。
            shims["memset"] = LibcShim(shape: [.pointer, .integer, .integer]) { args in
                guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memset", expected: 3, got: args.count, location: loc) }
                guard case .rawPointer(let p) = args[0] else { throw RuntimeError.invalidOperation(reason: "memset 第 1 参须为指针", location: loc) }
                let v = try RuntimeOps.intArg(args, name: "memset", offset: 1)
                let n = try RuntimeOps.intArg(args, name: "memset", offset: 2)
                memset(p.pointer, Int32(truncatingIfNeeded: v), n)
                return args[0]
            }

            // strlen(s: *U8) -> U64：数到第一个 NUL，长度不含结尾符。
            shims["strlen"] = LibcShim(shape: [.pointer]) { args in
                let p = try RuntimeOps.ptrArg(args, name: "strlen", self: nil)
                let s = p.pointer.assumingMemoryBound(to: CChar.self)
                return .int(strlen(s))
            }

            // puts(s: *U8) -> I32：向 stdout 写一行 C 字符串。
            shims["puts"] = LibcShim(shape: [.pointer]) { args in
                let p = try RuntimeOps.ptrArg(args, name: "puts", self: nil)
                let s = p.pointer.assumingMemoryBound(to: CChar.self)
                let r = puts(s)
                return .int(Int(r))
            }

            // strcmp(a: *U8, b: *U8) -> I32：按字节序比较，返回负、零或正。
            shims["strcmp"] = LibcShim(shape: [.pointer, .pointer]) { args in
                guard args.count >= 2 else { throw RuntimeError.argumentCountMismatch(name: "strcmp", expected: 2, got: args.count, location: loc) }
                guard case .rawPointer(let a) = args[0] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 1 参须为指针", location: loc) }
                guard case .rawPointer(let b) = args[1] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 2 参须为指针", location: loc) }
                let r = strcmp(
                    a.pointer.assumingMemoryBound(to: CChar.self),
                    b.pointer.assumingMemoryBound(to: CChar.self))
                return .int(Int(r))
            }

            // toCString(s: String) -> *U8：把 Pini 字符串转成 null 结尾的 C 字符串（malloc 分配，用户 free）。
            shims["toCString"] = LibcShim(shape: [.string]) { args in
                guard args.count >= 1 else { throw RuntimeError.argumentCountMismatch(name: "toCString", expected: 1, got: args.count, location: loc) }
                guard case .string(let s) = args[0] else {
                    throw RuntimeError.invalidOperation(reason: "toCString：第 1 个参数须为 String", location: loc)
                }
                let bytes = Array(s.utf8)
                guard let ptr = malloc(bytes.count + 1) else {
                    throw RuntimeError.invalidOperation(reason: "toCString：malloc 失败", location: loc)
                }
                if bytes.count > 0 { memcpy(ptr, bytes, bytes.count) }
                ptr.advanced(by: bytes.count).storeBytes(of: 0, as: UInt8.self)  // null terminator
                return .rawPointer(
                    RawPointerValue(
                        pointer: ptr,
                        elemType: .simple(name: "U8", location: loc),
                        freesMemory: false
                    ))
            }
        #endif
        return shims
    }()

    static func makeError(_ message: String) -> Value {
        return .structInstance(
            StructInstance(
                typeName: builtinErrorTypeName,
                fields: ["message": .string(message)]
            ))
    }

    static func makeResult(caseName: String, payload: Value) -> Value {
        return .enumValue(
            EnumValue(
                caseName: caseName,
                associatedValues: [payload],
                paramNames: [nil],
                parentEnum: builtinResultEnumName
            ))
    }

    static func matchArmMatches(caseName: String?, literal: IRMatchLiteral?, value: Value) -> Bool {
        if let literal = literal {
            switch literal {
            case .int(let n):
                if case .int(let v) = value { return v == n }
            case .float(let f):
                if case .float(let v) = value { return v == f }
            case .string(let s):
                if case .string(let v) = value { return v == s }
            case .boolean(let b):
                if case .bool(let v) = value { return v == b }
            }
            return false
        }
        if caseName == "_" { return true }
        guard let caseName = caseName else { return false }
        if case .enumValue(let ev) = value { return ev.caseName == caseName }
        return false
    }

    static func ptrArg(_ args: [Value], name: String, self: AnyObject?) throws -> RawPointerValue {
        guard !args.isEmpty else {
            throw RuntimeError.argumentCountMismatch(
                name: name, expected: 1, got: args.count,
                location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        guard case .rawPointer(let rp) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "\(name)：第 1 个参数须为 `*T` 指针",
                location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
        return rp
    }

    static func relabelled(_ value: Value, with labels: [String?]) -> Value {
        guard case .tuple(_, let elements) = value else { return value }
        return .tuple(labels: labels, elements: elements)
    }

    // 运行时段有一份同规则实现（`_bkResolveIOPath`），两侧必须同解：同一份源码在两通道上要落到同一个文件。
    // `./` / `../` 这一支是**豁免**：自举仓的相对路径全带 `./` 前缀，拼上基准会全线失守。
    static func resolveIOPath(_ path: String, programBase: String?) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("./") || path.hasPrefix("../") { return path }
        guard let base = programBase else { return path }
        return base + "/" + path
    }

    static func snapshotPointer(of value: Value, location: SourceLocation) throws -> Value {
        switch value {
        case .rawPointer(let rp):
            // 指针取址：返回自身（地址即值；`*T` 的 T 保持元素类型不变）。
            return value
        default:
            let elem = RawPointerValue.elemType(for: value) ?? .simple(name: "U8", location: location)
            let stride = RawPointerValue.stride(of: elem) ?? 1
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: stride, alignment: 1)
            try Self.encode(value, to: ptr, type: elem)
            return .rawPointer(RawPointerValue(pointer: ptr, elemType: elem, freesMemory: true))
        }
    }

    static func stringifyValue(_ value: Value) -> String {
        switch value {
        case .int(let v): return String(v)
        case .float(let v): return String(v)
        case .string(let v): return v
        // `Char` 直接打印字符本身，不加引号也不加括号；值层对 `s[i]` 一直如此。
        // 类型换成 `Char` 因此在展示上保持了原有行为。
        case .char(let v): return v
        case .bool(let v): return String(v)
        case .null: return "null"
        case .tuple(let labels, let vs):
            // 命名元组显示为 `[商: 2, 余: 1]`，位置元组保持 `[2, 1]`。
            return "["
                + vs.enumerated().map { i, v in
                    let prefix = (labels.indices.contains(i) && labels[i] != nil) ? "\(labels[i]!): " : ""
                    return (i > 0 ? ", " : "") + prefix + stringifyValue(v)
                }.joined() + "]"
        case .array(let vs):
            return "[" + vs.enumerated().map { i, v in (i > 0 ? ", " : "") + stringifyValue(v) }.joined() + "]"
        case .dictionary(let entries):
            return "{" + entries.enumerated().map { i, kv in (i > 0 ? ", " : "") + stringifyValue(kv.0) + ": " + stringifyValue(kv.1) }.joined() + "}"
        case .set(let vs):
            return "{" + vs.enumerated().map { i, v in (i > 0 ? ", " : "") + stringifyValue(v) }.joined() + "}"
        case .weakRef(let box):
            // WeakRef 引用语义承载——打印为 `WeakRef(目标类型)`（不展开内部状态）；目标已释放时如实标记。
            return "WeakRef(\(box.target?.typeName ?? "已释放"))"
        case .unownedRef:
            // 无主引用不查存活：打印连目标类型都不读——读它就是要目标活着，而「持有与传递」本该安全。
            return "UnownedRef"
        case .lazyRef:
            // LazyRef 按引用语义承载：打印为 `LazyRef`，不展开内部状态。
            return "LazyRef"
        case .structInstance(let si):
            // 内建 Error / CancelError 直接呈现其 message，便于 `print(<= t)` 输出 `err(boom)`
            // 而非结构体转储；两者呈现一致，判别仍靠 isCancel(e) 而非输出文本。
            if si.typeName == RuntimeOps.builtinErrorTypeName
                || si.typeName == RuntimeOps.builtinCancelErrorTypeName,
                case .string(let message)? = si.fields["message"]
            {
                return message
            }
            // 字段按名排序输出：Dictionary 迭代顺序非声明序、不确定；排序保证解释器与
            // LLVM 后端 `generateStringifyAggregate` 的展示顺序逐字节一致。
            let sorted = si.fields.sorted { $0.key < $1.key }
            return "\(si.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringifyValue(kv.value) }.joined() + "}"
        case .objectReference(let oref):
            let sorted = oref.fields.sorted { $0.key < $1.key }
            return "\(oref.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringifyValue(kv.value) }.joined() + "}"
        case .enumValue(let ev):
            if ev.associatedValues.isEmpty {
                return "\(ev.caseName)"
            }
            // 渲染不带关联值名（`圆(5.0)` 而非 `圆(r: 5.0)`）：`paramNames` 只供 match 具名绑定按名对位，不进渲染。
            let inner = ev.associatedValues.map { stringifyValue($0) }.joined(separator: ", ")
            return "\(ev.caseName)(\(inner))"
        case .function(let fv): return "<\(fv.name)>"
        case .future(let fv):
            if fv.isResolved, let result = fv.result {
                return "Future(\(stringifyValue(result)))"
            }
            return "<pending Future>"
        case .rawPointer(let rp):
            // 指针打印为 `*T@0x...`：元素类型加地址。
            let t = rp.elemType.map { $0.describe() } ?? "?"
            return "*\(t)@\(rp.pointer)"
        }
    }

    static func trigArgument(_ value: Value, name: String) throws -> Double {
        switch value {
        case .int(let i): return Double(i)
        case .float(let f): return f
        default:
            throw RuntimeError.invalidOperation(
                reason: "\(name) 的参数必须是数值",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
    }

    static func tupleElement(_ value: Value, index: Int, location: SourceLocation) throws -> Value {
        guard case .tuple(_, let elements) = value else {
            throw RuntimeError.typeMismatch(expected: "tuple", got: RuntimeOps.describeValueKind(value), location: location)
        }
        guard index >= 0 && index < elements.count else {
            throw RuntimeError.invalidOperation(
                reason: "元组索引越界：index \(index)，元组大小 \(elements.count)",
                location: location
            )
        }
        return elements[index]
    }

    static func typeMismatch(name: String, value: Value, loc: SourceLocation) -> RuntimeError {
        RuntimeError.invalidOperation(reason: "store：期望 `\(name)`，实际 \(Self.valueKindName(value))", location: loc)
    }

    static func unaryValue(_ op: UnaryOperator, _ v: Value) throws -> Value {
        switch (op, v) {
        case (.minus, .int(let a)): return .int(-a)
        case (.plus, .int(let a)): return .int(a)
        case (.not, .bool(let a)): return .bool(!a)
        case (.increment, .int(let a)): return .int(a + 1)
        case (.decrement, .int(let a)): return .int(a - 1)
        case (.bitwiseNot, .int(let a)): return .int(~a)
        case (.minus, .float(let a)): return .float(-a)
        case (.plus, .float(let a)): return .float(a)
        default:
            throw RuntimeError.invalidOperation(reason: "无效的一元运算", location: SourceLocation(line: 0, column: 0, fileName: ""))
        }
    }

    static func valueKindName(_ v: Value) -> String {
        switch v {
        case .int: return "int"
        case .float: return "float"
        case .bool: return "bool"
        case .string: return "string"
        case .char: return "char"
        case .rawPointer: return "指针"
        default: return "其它"
        }
    }

    /// `chars` —— 按字素簇切分（与 Swift `Character` 一致，代理对不被拆开）；空串得空数组。
    /// `len(chars(s)) == len(s)` 由构造保证；参数仍是 `String`，换成 `Char` 会塌掉。
    static func builtinChars(_ args: [Value]) throws -> Value {
        guard case .string(let s) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "chars 的参数必须是字符串",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .array(s.map { .char(String($0)) })
    }

    /// `tempUtf8Bytes` — UTF-8 字节副本，供字节缓冲读取源码文本；不改动字符串本身。
    static func builtinTempUtf8Bytes(_ args: [Value]) throws -> Value {
        guard case .string(let s) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "tempUtf8Bytes 的参数必须是字符串",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .array(s.utf8.map { .int(Int($0)) })
    }

    /// `tempByteToInt` — U8 的数值（0..255）转 I32；不做符号扩展。
    static func builtinTempByteToInt(_ args: [Value]) throws -> Value {
        guard case .int(let value) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "tempByteToInt 的参数必须是 U8",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .int(value & 0xFF)
    }

    /// `tempIntToByte` — 取低 8 位；负值同样按补码截断。
    static func builtinTempIntToByte(_ args: [Value]) throws -> Value {
        guard case .int(let value) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "tempIntToByte 的参数必须是 I32",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .int(value & 0xFF)
    }

    /// `chr` —— 码点转 `Char`。
    /// 越界（负数、超过标量上限或落在代理区）按越界 `s[i]` 那样报错。
    /// `Char` 恒持一个字素，没有表示「空」的哨兵值。
    static func builtinChr(_ args: [Value]) throws -> Value {
        guard case .int(let code) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "chr 的参数必须是整数",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        guard code >= 0, code <= 0x10FFFF, !(0xD800...0xDFFF).contains(code),
            let scalar = UnicodeScalar(UInt32(code))
        else {
            throw RuntimeError.indexOutOfRange(
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .char(String(scalar))
    }

    /// `ord` —— 首个 Unicode 标量的码点；多标量字素取首个。
    /// 这个签名拿不到「空」值，所以守卫只是兜底而不是断言。
    /// 对良类型的 `Char` 不可达；测试塞进来的 `null` 应读成错误，而不是崩掉。
    static func builtinOrd(_ args: [Value]) throws -> Value {
        guard case .char(let c) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "ord 的参数必须是字符",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        guard let first = c.unicodeScalars.first else { return .int(-1) }
        return .int(Int(first.value))
    }

    /// `is_letter` —— 首字符是否为 Unicode 字母。
    /// `Char` 不存在空值情形，守卫只兜 `null` 零值，返回 false。
    static func builtinIsLetter(_ args: [Value]) throws -> Value {
        guard case .char(let c) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "is_letter 的参数必须是字符",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        guard let first = c.first else { return .bool(false) }
        return .bool(first.isLetter)
    }

    /// `is_number` —— 首字符的 Unicode 数字属性，是 `\p{N}` 的严格超集，
    /// 与宿主 `Character.isNumber` 一致。
    static func builtinIsNumber(_ args: [Value]) throws -> Value {
        guard case .char(let c) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "is_number 的参数必须是字符",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        guard let first = c.first else { return .bool(false) }
        return .bool(first.isNumber)
    }

    /// 再进入一层函数体之前，宿主栈必须留有的字节数。
    /// 按比例而非定值：主线程 8 MB、`Thread` 512 KB，不给总量时「够用」没有意义。
    /// 留出八分之一给诊断与栈展开，栈小到留不出时退回固定下限。
    static func freeStackFloor(stackSize: Int) -> Int {
        max(stackSize / 8, 256 * 1024)
    }

    /// 读不到栈时守卫退回的调用层数上限。
    /// 取值保守：唯一职责是让「读不到栈」也无法静默压栈。
    /// 能读到余量时由栈决定，这个值不参与判断。
    static let fallbackCallCeiling = 120

    /// `depth` 处能否再进入一层函数体。
    /// 帧数判不了：标量递归每帧约 47 KB，返回枚举的 `match` 约 80 KB。
    /// 计数两头都错 —— 重形态压爆、合法深递归被误判；能判的是剩余栈。
    static func mayEnterAnotherBody(depth: Int) -> Bool {
        guard let stack = hostStack() else {
            return depth < fallbackCallCeiling
        }
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { Int(bitPattern: $0) }
        return here - stack.low > freeStackFloor(stackSize: stack.size)
    }

    /// 当前线程的栈，平台报不出时返回 `nil`。
    /// 每线程读一次并缓存到该线程结束：边界不会移动，Linux 上每次询问都要走进程映射。
    /// 读不出边界的线程同样缓存成「读不出」，不再重复询问。
    static func hostStack() -> (low: Int, size: Int)? {
        let bounds: HostStackBounds
        if let cached = hostStackBounds.value {
            bounds = cached
        } else {
            let fresh = HostStackBounds(readHostStack())
            hostStackBounds.value = fresh
            bounds = fresh
        }
        guard let low = bounds.low, let size = bounds.size else { return nil }
        return (low, size)
    }

    /// 守卫拒绝调用时抛出的错误。
    /// 只有这一个构造点，调用方按原因匹配时只需对一份措辞。
    /// 深度写进文本：它区分失控递归与单纯很深的递归。
    static func recursionGuardError(depth: Int) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "宿主栈余量不足，无法再进入一层调用（深度 \(depth)），疑似无限递归或递归过深",
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }

    /// 字符内建，按名字索引。
    /// 一张表服务两个引擎：降载器的白名单读它，执行器经它分派。
    /// 因此一个名字不会被半支持 —— 一侧有降载规则，另一侧却没有实现。
    nonisolated(unsafe) static let characterBuiltins: [String: ([Value]) throws -> Value] = [
        "chars": builtinChars,
        "tempUtf8Bytes": builtinTempUtf8Bytes,
        "tempByteToInt": builtinTempByteToInt,
        "tempIntToByte": builtinTempIntToByte,
        "chr": builtinChr,
        "ord": builtinOrd,
        "is_letter": builtinIsLetter,
        "is_number": builtinIsNumber,
    ]

    /// 内建构造器上报错误时使用的位置。
    /// 两引擎共读一个常量，位置字段上的报错文本不会分叉。
    static let builtinLocation = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

    /// `sleep` 的实参规则。共用是为了两通道拒绝同样的输入、给出同样的措辞；
    /// 时长以整数毫秒计。
    static func sleepMilliseconds(_ args: [Value]) throws -> Int {
        guard args.count == 1, case .int(let ms) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "sleep 的参数必须是整数（毫秒）",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return ms
    }

    /// `sleep(ms)` —— 阻塞调用线程该时长。
    /// 分片睡，片间检查取消，最迟一片之内停下，不必等满整段时长。
    /// 检查点是参数：AST 通道传真检查，IR 通道在拿到任务句柄前传空操作。
    static func builtinSleep(milliseconds ms: Int, checkpoint: () throws -> Void) throws -> Value {
        try checkpoint()
        var remaining = max(0, Double(ms)) / 1000.0
        let slice = 0.02
        while remaining > 0 {
            let step = min(slice, remaining)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
            try checkpoint()
        }
        return .null
    }

    /// `Error("msg")` / `CancelError("msg")` 的实参规则。
    /// 两个构造器都只接受一个字符串，类型结构相同 —— 靠 `isCancel` 区分，绝不靠载荷。
    static func errorMessageArgument(_ args: [Value]) throws -> String {
        guard args.count == 1, case .string(let message) = args[0] else {
            throw RuntimeError.typeMismatch(
                expected: "String",
                got: args.first.map { describeValueKind($0) } ?? "no argument",
                location: builtinLocation
            )
        }
        return message
    }

    /// `Error("msg")` —— 内建默认错误值。
    static func builtinErrorConstructor(_ args: [Value]) throws -> Value {
        try makeError(try errorMessageArgument(args))
    }

    /// `CancelError("msg")` —— 取消错误值。
    static func builtinCancelErrorConstructor(_ args: [Value]) throws -> Value {
        try makeCancelError(try errorMessageArgument(args))
    }

    /// 取消错误值。
    /// 两个调用方（AST 通道的按名链与 IR 执行器的表）都在此构造，规则只有一处。
    static func makeCancelError(_ message: String) -> Value {
        .structInstance(
            StructInstance(
                typeName: builtinCancelErrorTypeName,
                fields: ["message": .string(message)]
            ))
    }

    /// 这张表同步作答的并发内建，按名字索引。
    /// 契约同 `characterBuiltins`：降载器白名单读它，执行器经它分派。
    /// 只收普通调用能表达的：`sleep` 阻塞，`Error` / `CancelError` 造值；join 需要任务句柄。
    nonisolated(unsafe) static let concurrencyBuiltins: [String: ([Value]) throws -> Value] = [
        "sleep": { args in
            try builtinSleep(milliseconds: try sleepMilliseconds(args), checkpoint: {})
        },
        "Error": builtinErrorConstructor,
        "CancelError": builtinCancelErrorConstructor,
    ]

    // MARK: - 返回 Future 的并发语义，两引擎共用

    /// 值是否为取消错误 —— `isCancel(e)` 谓词。
    /// `Error` 与 `CancelError` 结构相同，区分它们的只有类型名。
    static func isCancelErrorValue(_ value: Value) -> Bool {
        guard case .structInstance(let si) = value else { return false }
        return si.typeName == builtinCancelErrorTypeName
    }

    /// err 槽的**消息** —— 两引擎共用的读口（LLVM 侧对应 `bk_error_message`）。
    /// 解释器侧的错误值是 `StructInstance`（字段 `message`），IR 里 err 槽是类型擦除的字 ⇒ 表示不同，读出的是同一件事。
    /// 非错误值 ⇒ 空串，与 LLVM 侧对「无载荷字」的处置同义：读一个不是错误的槽不该让进程炸掉。
    static func errorMessage(_ value: Value) -> String {
        guard case .structInstance(let si) = value,
            si.typeName == builtinErrorTypeName || si.typeName == builtinCancelErrorTypeName,
            case .string(let message)? = si.fields["message"]
        else { return "" }
        return message
    }

    /// 值是否已经是 `Result` 的 `ok` / `err` 用例。
    /// 它决定 join 是装箱还是原样透传；两种答案会让两引擎结果不同。
    static func isResultValue(_ value: Value) -> Bool {
        guard case .enumValue(let ev) = value else { return false }
        return ev.parentEnum == builtinResultEnumName
    }

    /// 值是否为 `Result` 的 `err` 用例（`ok` 返回 false）。
    static func isErrResultValue(_ value: Value) -> Bool {
        guard case .enumValue(let ev) = value else { return false }
        return ev.parentEnum == builtinResultEnumName && ev.caseName == "err"
    }

    /// 协作式取消检查点：等待中被取消的任务停在这里，而不是停在任意指令。
    /// 共用使规则不依赖具体引擎即可断言：只在一边取消就是语言差异。
    /// 内联：它在每个异步体入口，同步路径上只是判空，不能有开销。
    @inline(__always)
    static func checkCancellation(_ owner: FutureValue?) throws {
        if let owner = owner, owner.isCancelled {
            throw FutureValue.cancelError()
        }
    }

    /// 阻塞到 `fut` 落定，把结果归一成 `Result` 值 —— 错误变成数据，绝不穿过 join 抛出。
    /// 已是 `Result` 的原样透传，普通值装箱成 `ok(v)`，抛出或超时变成 `err`。
    /// `form` 记录关键字；两种形式都阻塞，因为让出需要可恢复的体，树遍历器没有。
    static func joinFuture(_ fut: FutureValue, timeoutMs: Int?, form: JoinForm = .waits) -> Value {
        // 被 join 的子任务脱离父任务：它的生命周期已被显式消费完，
        // 父任务返回时不该再取消它。
        defer { fut.detachFromParent() }
        do {
            let value: Value
            if let timeoutMs = timeoutMs {
                guard let joined = try fut.wait(timeout: Double(max(0, timeoutMs)) / 1000.0) else {
                    fut.cancel()
                    return makeResult(
                        caseName: "err",
                        payload: makeCancelError("任务超时: \(timeoutMs)ms")
                    )
                }
                value = joined
            } else {
                value = try fut.wait()
            }
            if isResultValue(value) { return value }
            return makeResult(caseName: "ok", payload: value)
        } catch RuntimeError.taskCancelled(let reason, _) {
            return makeResult(caseName: "err", payload: makeCancelError(reason))
        } catch let runtimeError as RuntimeError {
            return makeResult(caseName: "err", payload: makeError(runtimeError.description))
        } catch {
            return makeResult(caseName: "err", payload: makeError("\(error)"))
        }
    }

    /// `joinAll([a, b, c])` → 覆盖全部成员的聚合 future。
    /// 快速失败：第一个 `err` 决定聚合结果，其余成员被取消，因为没人在等它们。
    /// 成员保留自己的父任务，聚合只为取消而链接；调度器与钩子由参数传入。
    static func makeJoinAllFuture(
        argument: Value,
        scheduler: Scheduler,
        owner: FutureValue?,
        enterTask: @escaping (FutureValue) -> () -> Void,
        checkpoint: @escaping (FutureValue) throws -> Void
    ) throws -> Value {
        guard case .array(let items) = argument else {
            throw RuntimeError.typeMismatch(
                expected: "Array<Future<T, Error>>",
                got: describeValueKind(argument),
                location: builtinLocation
            )
        }
        var members: [FutureValue] = []
        for item in items {
            guard case .future(let fut) = item else {
                throw RuntimeError.typeMismatch(
                    expected: "Future<T, Error>",
                    got: describeValueKind(item),
                    location: builtinLocation
                )
            }
            members.append(fut)
        }

        let aggregate = FutureValue()
        owner?.addChild(aggregate)
        aggregate.onCancel { members.forEach { $0.cancel() } }

        let captured = members
        let work = WorkHandoff {
            let restore = enterTask(aggregate)
            // 登记顺序与 AST 侧一致：作用域关闭先于任务句柄恢复，
            // 关闭时看到的仍是聚合任务。
            defer { restore() }
            defer { aggregate.cancelUnjoinedChildren() }

            var values: [Value] = []
            for (index, member) in captured.enumerated() {
                try checkpoint(aggregate)
                let joined = joinFuture(member, timeoutMs: nil)
                guard case .enumValue(let ev) = joined else { continue }
                if ev.caseName == "err" {
                    for rest in captured.dropFirst(index + 1) where !rest.isFinished {
                        rest.cancel()
                    }
                    // 用显式 resolve 而非靠返回：本任务在决策点定下自己的结果。
                    // 之后再报 `.finished` 无害，future 一旦落定，第二次 `resolve` 会被忽略。
                    aggregate.resolve(joined)
                    return .finished(.null)
                }
                values.append(ev.associatedValues.first ?? .null)
            }
            aggregate.resolve(makeResult(caseName: "ok", payload: .array(values)))
            return .finished(.null)
        }
        scheduler.spawn(aggregate) { try work.run() }
        return .future(aggregate)
    }

    /// 结构化规则的有限覆盖：体以 `ok` 结束却带着未 join 的失败子任务时，结果为 `err`。
    /// 有界是有意的 —— 体自己产出的 `err` 保留，否则真正发生的失败会丢。
    /// 翻转在返回边界以值的形式发生，`match` 能检视到；不进入调用栈。
    static func flipIfLeaked(_ result: Value, leaked: [Value]) -> Value {
        guard !leaked.isEmpty else { return result }
        if isErrResultValue(result) { return result }
        let detail = leaked.map { stringifyValue($0) }.joined(separator: "; ")
        return makeResult(
            caseName: "err",
            payload: makeError("未 join 子任务失败（结构化并发兜底）: " + detail)
        )
    }
}

/// 一个线程的栈边界，随该线程存活缓存。
/// 两个字段都是可选的，「答不出」本身也是可缓存的值，否则每次调用都会再问一遍。
private final class HostStackBounds {
    let low: Int?
    let size: Int?

    init(_ bounds: (low: Int, size: Int)?) {
        self.low = bounds?.low
        self.size = bounds?.size
    }
}

/// 每线程一份缓存 —— 由 `RuntimeOps.hostStack()` 读取。
private let hostStackBounds = ThreadLocal<HostStackBounds>()

#if canImport(Glibc)
    // Glibc 的 Swift 模块不导出这个 GNU 扩展；按符号名直连，签名与 <pthread.h> 一致。
    @_silgen_name("pthread_getattr_np")
    private func piniPthreadGetattrNp(
        _ thread: pthread_t, _ attributes: UnsafeMutablePointer<pthread_attr_t>
    ) -> Int32
#endif

/// 向平台询问当前线程栈的起点与大小。
/// `low` 是栈能到达的最低地址：栈向低处生长，越靠近 `low` 的帧剩余空间越小。
private func readHostStack() -> (low: Int, size: Int)? {
    #if canImport(Darwin)
        let thread = pthread_self()
        let size = Int(pthread_get_stacksize_np(thread))
        let high = Int(bitPattern: pthread_get_stackaddr_np(thread))
        guard size > 0, high > 0 else { return nil }
        return (high - size, size)
    #elseif canImport(Glibc)
        var attributes = pthread_attr_t()
        guard piniPthreadGetattrNp(pthread_self(), &attributes) == 0 else { return nil }
        defer { pthread_attr_destroy(&attributes) }
        var base: UnsafeMutableRawPointer?
        var size = 0
        guard pthread_attr_getstack(&attributes, &base, &size) == 0,
            let low = base, size > 0
        else { return nil }
        return (Int(bitPattern: low), size)
    #else
        return nil
    #endif
}
