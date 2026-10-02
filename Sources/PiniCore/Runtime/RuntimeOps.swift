#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

/// Runtime operations both engines need: the value-level helpers, builtins and
/// runtime predicates that used to live as statics on `Interpreter`.
///
/// WHY THIS EXISTS (LR-4 G-1)
///
/// `P4-gamma` deletes the AST walk, and `Interpreter` with it. But `Interpreter`
/// also carried helpers the *surviving* engine uses: `IRExecutor` references
/// two dozen of them, `Value` another two. They are the leftover of the P4-0 and
/// P4-1b single-sourcing -- the implementations were extracted into one place,
/// and that place was still `Interpreter`.
///
/// Deleting first would have produced a screen of compile errors unrelated to
/// deleting the walk, dressing a structural change up as an overhaul. So they
/// move here first, and `Interpreter` keeps thin forwarders, which is what keeps
/// its own thousands of lines -- and `SuspendEvaluator`'s -- untouched.
///
/// WHAT BELONGS HERE
///
/// Only what survives the flip, and nothing here may reference `Interpreter`.
/// Every member is pure over `Value`: no `self` occurs in any of them, which is
/// what makes this a move rather than a redesign. The five private helpers that
/// came along (see `typeMismatch`, `intArg`, `trigArgument`) are the internal
/// dependencies of the rest; they are module-internal here because their
/// forwarders live in `Interpreter.swift`, while `Interpreter`'s own copies stay
/// private.
public enum RuntimeOps {

    /// Value-type copy rule: a `structInstance` is copied field by field,
    /// recursively; everything else -- objects included -- is returned as-is,
    /// which is what makes object aliasing correct rather than accidental.
    ///
    /// WHY IT IS HERE (LR-4 G-2R)
    ///
    /// Both engines owe this rule at every binding and store site, and the AST
    /// walk used to be its only home -- as an *instance* method, which is also why
    /// the IR executor could not reach it. The flip deletes that home, so the rule
    /// moves to the shared carrier and `Interpreter` keeps a forwarder. The body
    /// never touches `self` and is pure over `Value`, so this is a move rather than
    /// a redesign -- the test every member of this enum has to pass.
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
        // F64 同型比较六算符（与 int 分派形态一致）：原缺失导致 float 比较
        // 落 default 抛 typeMismatch，解释器通道 F64 只能算不能比
        // （issue-interpreter-float-compare-2026-09-07 收口）。
        case (.float(let a), .float(let b), .equal): return .bool(a == b)
        case (.float(let a), .float(let b), .notEqual): return .bool(a != b)
        case (.float(let a), .float(let b), .lessThan): return .bool(a < b)
        case (.float(let a), .float(let b), .lessThanOrEqual): return .bool(a <= b)
        case (.float(let a), .float(let b), .greaterThan): return .bool(a > b)
        case (.float(let a), .float(let b), .greaterThanOrEqual): return .bool(a >= b)
        case (.string(let a), .string(let b), .plus): return .string(a + b)
        // G68（P0d-D）：`Char` 搭 `String` 的车 —— 凡 `String` 支持的算符，`Char` 参与时
        // 行为一致（拼接出 `String`、比较按字素内容）。分派是按值 case 的**元组形状**做的，
        // `Char` 与 `String` 是两个不同的 case、无法靠一条通配覆盖 ⇒ 3 算符 × 3 组合写全。
        // ⚠️ 漏写会落到下面的 `default: throw`，编译器同样不报 —— 只能按清单逐处勾。
        case (.char(let a), .char(let b), .plus): return .string(a + b)
        case (.char(let a), .string(let b), .plus): return .string(a + b)
        case (.string(let a), .char(let b), .plus): return .string(a + b)
        case (.string(let a), .string(let b), .equal): return .bool(a == b)
        case (.char(let a), .char(let b), .equal): return .bool(a == b)
        case (.char(let a), .string(let b), .equal): return .bool(a == b)
        case (.string(let a), .char(let b), .equal): return .bool(a == b)
        // 内建双层结构 试点发现：String 缺 notEqual 分派（语言内 contains 需要）——补齐。
        case (.string(let a), .string(let b), .notEqual): return .bool(a != b)
        case (.char(let a), .char(let b), .notEqual): return .bool(a != b)
        case (.char(let a), .string(let b), .notEqual): return .bool(a != b)
        case (.string(let a), .char(let b), .notEqual): return .bool(a != b)
        case (.bool(let a), .bool(let b), .equal): return .bool(a == b)
        case (.bool(let a), .bool(let b), .notEqual): return .bool(a != b)
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
            // Int.min has no representable absolute value; without this guard
            // abs(Int.min) traps on integer overflow.
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

    /// `F64(value)` -- the numeric value constructor (`BuiltinRegistry` `F64`,
    /// group `.value`). A float passes through unchanged; an integer widens. The
    /// AST walk used to do this inline (G-P1), but the IR executor owes the same
    /// rule, and this is where the shared members live now.
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

    /// The Array member face the IR path answers by name (`G-2S`). Each entry
    /// takes the receiver first and then the call's arguments, and returns exactly
    /// what the AST walk's member dispatch returns -- these are its rules, moved to
    /// the shared carrier so the two engines cannot drift apart.
    static let arrayMethods: [String: ([Value]) throws -> Value] = [
        "Array.append": builtinArrayAppend,
        "Array.last": builtinArrayLast,
        "Array.pop": builtinArrayPop,
    ]

    /// `xs.append(v)` -- a new array with `v` on the end. The receiver is left
    /// alone, which is what makes the value semantics visible at the call site.
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

    /// `xs.last()` -- the final element, or `null` when the array is empty.
    static func builtinArrayLast(_ args: [Value]) throws -> Value {
        return try arrayMemberReceiver(args).last ?? .null
    }

    /// `xs.pop()` -- the pair `(arrayWithoutLast, lastOrNull)`. An empty array
    /// yields `([], null)` rather than failing, matching the AST side.
    static func builtinArrayPop(_ args: [Value]) throws -> Value {
        let arr = try arrayMemberReceiver(args)
        guard let last = arr.last else {
            return .tuple(labels: [nil, nil], elements: [.array([]), .null])
        }
        return .tuple(labels: [nil, nil], elements: [.array(Array(arr.dropLast())), last])
    }

    /// The receiver is always the first value; a call that could not have come
    /// from the lowering layer is refused rather than guessed at.
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
        // 字典键是任意值（字符串/整数…），数组与字符串下标才是整数索引——先按接收者
        // 类型分流，再各自校验参数，避免把键误当索引（批 2 遗留缺陷，批 3 取证发现）。
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
            // 字素簇语义不变，但「数出总字数」与「定位第 i 个字素」都改走 `GraphemeCursor`
            // （均摊 O(1)，**空间 O(1)**）—— 此前 `s.count` 每次 O(len)、
            // `s.index(_:offsetBy:)` 每次 O(i) ⇒ 逐字符扫描整体 O(n²)。
            // 语义与边界判定一字未改（含负值尾计数）。
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
            switch name {
            case "I8", "U8": return .int(Int(rp.pointer.load(as: Int8.self)))
            case "I16", "U16": return .int(Int(rp.pointer.load(as: Int16.self)))
            case "I32", "U32": return .int(Int(rp.pointer.load(as: Int32.self)))
            case "I64", "U64": return .int(rp.pointer.load(as: Int.self))
            case "F32": return .float(Double(rp.pointer.load(as: Float.self)))
            case "F64": return .float(rp.pointer.load(as: Double.self))
            case "Bool": return .bool(rp.pointer.load(as: Bool.self))
            // `CChar` = the C single byte character, renamed from `Char` (FFI 的 Char 改名 CChar).
            // Unreachable in practice today: the checker accepts `*CChar`, but no
            // engine resolves the element type, so no program reaches this decode.
            // Kept because the day that face is implemented, this line is the decode.
            case "CChar": return .int(Int(rp.pointer.load(as: UInt8.self)))
            default:
                throw RuntimeError.invalidOperation(reason: "load：不支持的指针元素类型 `\(name)`", location: loc)
            }
        case .pointer:
            let p = rp.pointer.load(as: UnsafeMutableRawPointer.self)
            return .rawPointer(RawPointerValue(pointer: p, elemType: elem, ownsMemory: false))
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
            switch name {
            case "I8", "U8":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Int8(truncatingIfNeeded: i), as: Int8.self)
            case "I16", "U16":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Int16(truncatingIfNeeded: i), as: Int16.self)
            case "I32", "U32":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Int32(truncatingIfNeeded: i), as: Int32.self)
            case "I64", "U64":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: i, as: Int.self)
            case "F32":
                guard case .float(let f) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: Float(f), as: Float.self)
            case "F64":
                guard case .float(let f) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: f, as: Double.self)
            case "Bool":
                guard case .bool(let b) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: b, as: Bool.self)
            case "CChar":
                guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
                ptr.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)
            default:
                throw RuntimeError.invalidOperation(reason: "store：不支持的指针元素类型 `\(name)`", location: loc)
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

    static let libcShims: [String: ([Value]) throws -> Value] = {
        var shims: [String: ([Value]) throws -> Value] = [:]
        #if canImport(Darwin) || canImport(Glibc)
            let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

            // malloc(size: U64) -> *U8：C 语义——内存归用户，free 释放。
            shims["malloc"] = { args in
                let n = try RuntimeOps.intArg(args, name: "malloc")
                guard let p = malloc(n) else {
                    throw RuntimeError.invalidOperation(reason: "malloc 失败：内存不足", location: loc)
                }
                return .rawPointer(
                    RawPointerValue(
                        pointer: p,
                        elemType: .simple(name: "U8", location: loc),
                        ownsMemory: false
                    ))
            }

            // free(p: *U8) -> ()：C 语义。
            shims["free"] = { args in
                let p = try RuntimeOps.ptrArg(args, name: "free", self: nil)
                free(p.pointer)
                return .null
            }

            // memcpy(dst: *U8, src: *U8, n: U64) -> *U8。
            shims["memcpy"] = { args in
                guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memcpy", expected: 3, got: args.count, location: loc) }
                guard case .rawPointer(let dst) = args[0] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 1 参须为指针", location: loc) }
                guard case .rawPointer(let src) = args[1] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 2 参须为指针", location: loc) }
                let n = try RuntimeOps.intArg(args, name: "memcpy", offset: 2)
                memcpy(dst.pointer, src.pointer, n)
                return args[0]
            }

            // memset(p: *U8, v: I32, n: U64) -> *U8。
            shims["memset"] = { args in
                guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memset", expected: 3, got: args.count, location: loc) }
                guard case .rawPointer(let p) = args[0] else { throw RuntimeError.invalidOperation(reason: "memset 第 1 参须为指针", location: loc) }
                let v = try RuntimeOps.intArg(args, name: "memset", offset: 1)
                let n = try RuntimeOps.intArg(args, name: "memset", offset: 2)
                memset(p.pointer, Int32(truncatingIfNeeded: v), n)
                return args[0]
            }

            // strlen(s: *U8) -> U64。
            shims["strlen"] = { args in
                let p = try RuntimeOps.ptrArg(args, name: "strlen", self: nil)
                let s = p.pointer.assumingMemoryBound(to: CChar.self)
                return .int(strlen(s))
            }

            // puts(s: *U8) -> I32：向 stdout 写一行 C 字符串。
            shims["puts"] = { args in
                let p = try RuntimeOps.ptrArg(args, name: "puts", self: nil)
                let s = p.pointer.assumingMemoryBound(to: CChar.self)
                let r = puts(s)
                return .int(Int(r))
            }

            // strcmp(a: *U8, b: *U8) -> I32。
            shims["strcmp"] = { args in
                guard args.count >= 2 else { throw RuntimeError.argumentCountMismatch(name: "strcmp", expected: 2, got: args.count, location: loc) }
                guard case .rawPointer(let a) = args[0] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 1 参须为指针", location: loc) }
                guard case .rawPointer(let b) = args[1] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 2 参须为指针", location: loc) }
                let r = strcmp(
                    a.pointer.assumingMemoryBound(to: CChar.self),
                    b.pointer.assumingMemoryBound(to: CChar.self))
                return .int(Int(r))
            }

            // cstr(s: String) -> *U8：把 Pini 字符串转成 null 结尾的 C 字符串（malloc 分配，用户 free）。
            shims["cstr"] = { args in
                guard args.count >= 1 else { throw RuntimeError.argumentCountMismatch(name: "cstr", expected: 1, got: args.count, location: loc) }
                guard case .string(let s) = args[0] else {
                    throw RuntimeError.invalidOperation(reason: "cstr：第 1 个参数须为 String", location: loc)
                }
                let bytes = Array(s.utf8)
                guard let ptr = malloc(bytes.count + 1) else {
                    throw RuntimeError.invalidOperation(reason: "cstr：malloc 失败", location: loc)
                }
                if bytes.count > 0 { memcpy(ptr, bytes, bytes.count) }
                ptr.advanced(by: bytes.count).storeBytes(of: 0, as: UInt8.self)  // null terminator
                return .rawPointer(
                    RawPointerValue(
                        pointer: ptr,
                        elemType: .simple(name: "U8", location: loc),
                        ownsMemory: false
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
            return .rawPointer(RawPointerValue(pointer: ptr, elemType: elem, ownsMemory: true))
        }
    }

    static func stringifyValue(_ value: Value) -> String {
        switch value {
        case .int(let v): return String(v)
        case .float(let v): return String(v)
        case .string(let v): return v
        /// `Char` (P0d) prints as the character itself, not as a quoted or
        /// bracketed form — that is what the value layer already did for `s[i]`
        /// when it handed back a single-grapheme string, so the type change is
        /// behaviour-preserving here.
        case .char(let v): return v
        case .bool(let v): return String(v)
        case .null: return "null"
        case .tuple(let labels, let vs):
            // 草稿 A2（批次 1.3，D1）：命名元组显示 `[商: 2, 余: 1]`，位置元组保持 `[2, 1]`。
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
            // G42：WeakRef 引用语义承载——打印为 `WeakRef(目标类型)`（不展开内部状态）。
            return "WeakRef(\(box.target.typeName))"
        case .lazyRef:
            // G40：LazyRef 引用语义承载——打印为 `LazyRef`（不展开内部状态）。
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
            // 字段按名排序输出：Dictionary 迭代顺序非声明序，非确定性；排序保证解释器与
            // LLVM 后端 `generateStringifyAggregate` 的展示顺序逐字节一致（T2 对齐）。
            let sorted = si.fields.sorted { $0.key < $1.key }
            return "\(si.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringifyValue(kv.value) }.joined() + "}"
        case .objectReference(let oref):
            let sorted = oref.fields.sorted { $0.key < $1.key }
            return "\(oref.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringifyValue(kv.value) }.joined() + "}"
        case .enumValue(let ev):
            if ev.associatedValues.isEmpty {
                return "\(ev.caseName)"
            }
            // 渲染不带关联值名（项目契约：`圆(5.0)` 而非 `圆(r: 5.0)`——paramNames
            // 仅供 match 具名绑定按名对位，不进渲染；2026-08-29 具名关联值决议）。
            let inner = ev.associatedValues.map { stringifyValue($0) }.joined(separator: ", ")
            return "\(ev.caseName)(\(inner))"
        case .function(let fv): return "<\(fv.name)>"
        case .future(let fv):
            if fv.isResolved, let result = fv.result {
                return "Future(\(stringifyValue(result)))"
            }
            return "<pending Future>"
        case .rawPointer(let rp):
            // Phase 2a（FFI 子系统）：打印 `*T@0x...`（元素类型 + 地址）。
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

    /// `chars` — split into grapheme clusters (matching Swift `Character`, so
    /// surrogate pairs are not split); the empty string gives an empty array.
    /// `len(chars(s)) == len(s)` holds by construction.
    ///
    /// G67: the parameter stays a `String` — the whole point of `chars` is to
    /// cut a string apart, and taking a `Char` would collapse it to an
    /// always-single-element array. What changed is the *element* type.
    static func builtinChars(_ args: [Value]) throws -> Value {
        guard case .string(let s) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "chars 的参数必须是字符串",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return .array(s.map { .char(String($0)) })
    }

    /// `chr` — code point to a `Char`.
    ///
    /// G67: out of range (negative, past the scalar maximum, or a surrogate)
    /// now **panics** through the same channel as an out-of-range `s[i]`. The
    /// empty-string sentinel this used to return is gone on purpose: a `Char`
    /// always holds exactly one grapheme, so it has no value to mean "nothing".
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

    /// `ord` — the first Unicode scalar's code point. A multi-scalar grapheme
    /// yields its first scalar (the registered grapheme model, 字符模型 = Grapheme Cluster).
    ///
    /// G67: the `-1` empty-string sentinel is obsolete — a `Char` holds exactly
    /// one grapheme, so "empty" is not a value this signature can be handed.
    /// The guard stays as a floor rather than an assertion: it is unreachable
    /// for a well-typed `Char`, and a `null` (the injected test-parameter zero
    /// value) should read as an error, not as a crash.
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

    /// `is_letter` — Unicode letter property of the first character. The empty
    /// string was false rather than an error; a `Char` (G67) has no empty case,
    /// so the guard remains only as the floor for a `null` zero value.
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

    /// `is_number` — Unicode numeric property of the first character. A strict
    /// superset of `\p{N}`, matching the host's `Character.isNumber`.
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

    /// Bytes of host stack that must remain before one more body may be entered.
    ///
    /// A share of the stack rather than a constant, because "enough left" means
    /// nothing without knowing how much there was: on this host a main thread
    /// carries 8 MB while one detached through `Thread` starts with 512 KB. An
    /// eighth is held back so that raising the diagnostic and unwinding the
    /// frames still have room, with a floor for the stacks small enough that an
    /// eighth of them would leave nothing at all.
    static func freeStackFloor(stackSize: Int) -> Int {
        max(stackSize / 8, 256 * 1024)
    }

    /// The ceiling the guard falls back to where the stack cannot be read.
    ///
    /// Deliberately the conservative number the guard used on its own: the
    /// fallback's only job is to keep a silent stack smash impossible on a
    /// platform that cannot report what is left, and a generous ceiling would
    /// defeat exactly that. It is not the decision a normal run makes — where a
    /// reading is available the remaining stack decides, and this is never
    /// consulted.
    static let fallbackCallCeiling = 120

    /// Whether one more body may be entered at `depth`.
    ///
    /// WHY A FRAME COUNT COULD NOT BE THE DECISION (G-P9)
    ///
    /// What one Pini call costs the host stack depends on the shape of that
    /// call, and by enough to matter: a recursion over scalars spends about
    /// 47 KB per frame here, while one that returns a user-declared enum, takes
    /// a struct argument and runs a `match` spends about 80 KB. A single count is
    /// therefore wrong in both directions at once — high enough that the heavy
    /// shape smashes the stack before the guard is reached, which reports
    /// nothing at all and takes the buffered output down with it, yet low enough
    /// that a legal scalar recursion is refused as "suspected infinite" with
    /// most of the stack still free. The stack left on the running thread is
    /// what the decision actually needs.
    ///
    /// The fallback is not a second opinion: it answers only where no reading is
    /// available, so that a platform which cannot report the stack still gets a
    /// diagnosable refusal rather than the smash.
    static func mayEnterAnotherBody(depth: Int) -> Bool {
        guard let stack = hostStack() else {
            return depth < fallbackCallCeiling
        }
        var marker: UInt8 = 0
        let here = withUnsafeMutablePointer(to: &marker) { Int(bitPattern: $0) }
        return here - stack.low > freeStackFloor(stackSize: stack.size)
    }

    /// The running thread's stack, or `nil` where the platform cannot report it.
    ///
    /// Read once per thread and cached for its life: the bounds do not move
    /// while the thread runs, and on Linux asking for them walks the process
    /// maps — too much work to repeat on every call. A thread whose bounds
    /// cannot be read is cached as such, so it is not asked again either.
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

    /// The error the guard raises when it refuses a call.
    ///
    /// One construction site, because the wording is load-bearing: the guard's
    /// contract is "a diagnosable error instead of a stack overflow", and a
    /// caller matching on the reason can only match one wording. The depth is
    /// carried in the text because it is what separates a runaway recursion from
    /// a merely deep one.
    static func recursionGuardError(depth: Int) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "宿主栈余量不足，无法再进入一层调用（深度 \(depth)），疑似无限递归或递归过深",
            location: SourceLocation(line: 0, column: 0, fileName: "")
        )
    }

    /// The character builtins, by name.
    ///
    /// One table serves both engines: the lowerer's whitelist reads it (a name is
    /// either supported or it is not), and the executor dispatches through it.
    /// That is deliberate -- a name cannot end up half-supported, with a
    /// lowering rule on one side and no answer on the other.
    static let characterBuiltins: [String: ([Value]) throws -> Value] = [
        "chars": builtinChars,
        "chr": builtinChr,
        "ord": builtinOrd,
        "is_letter": builtinIsLetter,
        "is_number": builtinIsNumber,
    ]

    /// Where the builtin constructors report from.
    ///
    /// One constant, read by both engines: the interpreter's own
    /// `builtinLocation` now points here. The two channels' error text for a
    /// mistyped builtin argument therefore cannot diverge at the location field
    /// — and it used to be possible, because each side held its own literal.
    static let builtinLocation = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

    /// The `sleep` argument rule. Shared so both channels reject the same
    /// things in the same words; a duration is an integer number of
    /// milliseconds and always has been.
    static func sleepMilliseconds(_ args: [Value]) throws -> Int {
        guard args.count == 1, case .int(let ms) = args[0] else {
            throw RuntimeError.invalidOperation(
                reason: "sleep 的参数必须是整数（毫秒）",
                location: SourceLocation(line: 0, column: 0, fileName: "")
            )
        }
        return ms
    }

    /// `sleep(ms)` — block the calling thread for that long.
    ///
    /// Sleeps in slices rather than one long call so the caller can check a
    /// cancellation flag between them: an interrupted task stops within one
    /// slice instead of after the full duration, which is what makes "cancel a
    /// task that is sleeping" take effect in milliseconds.
    ///
    /// The checkpoint is a parameter because the two engines legitimately
    /// differ here. The AST channel holds a task handle and passes a real
    /// check; the IR channel has no cancellation context yet and passes a
    /// no-op. That difference is recorded rather than hidden — when the
    /// suspension grid gives the IR executor a task handle, this is the one
    /// place it plugs into, and until then a no-op is the honest answer
    /// instead of a check against a context that does not exist.
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

    /// The `Error("msg")` / `CancelError("msg")` argument rule. Both
    /// constructors take exactly one string, and the two types are structurally
    /// identical — they are told apart by `isCancel`, never by their payload.
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

    /// `Error("msg")` — the built-in default error value.
    static func builtinErrorConstructor(_ args: [Value]) throws -> Value {
        try makeError(try errorMessageArgument(args))
    }

    /// `CancelError("msg")` — the cancellation error.
    static func builtinCancelErrorConstructor(_ args: [Value]) throws -> Value {
        try makeCancelError(try errorMessageArgument(args))
    }

    /// The cancellation error value.
    ///
    /// Moved out of the interpreter so the constructor's two callers — the AST
    /// channel's by-name chain and the IR executor's table — build the same
    /// value from the same rule rather than from two copies of it.
    static func makeCancelError(_ message: String) -> Value {
        .structInstance(
            StructInstance(
                typeName: builtinCancelErrorTypeName,
                fields: ["message": .string(message)]
            ))
    }

    /// The concurrency builtins this grid answers synchronously, by name.
    ///
    /// Same contract as `characterBuiltins`: the lowerer's whitelist reads this
    /// table and the executor dispatches through it, so a name cannot be
    /// lowered on one side and go unanswered on the other.
    ///
    /// What is here is what a plain call can express with no context: `sleep`
    /// blocks, `Error` / `CancelError` build a value. `joinAll`, `joinWithin`
    /// and `isCancel` stay out even now that the async pipeline is connected —
    /// answering them needs a scheduler and a task handle, which a stateless
    /// closure cannot reach, so each engine matches those names itself and the
    /// rules they share live in the section below.
    static let concurrencyBuiltins: [String: ([Value]) throws -> Value] = [
        "sleep": { args in
            try builtinSleep(milliseconds: try sleepMilliseconds(args), checkpoint: {})
        },
        "Error": builtinErrorConstructor,
        "CancelError": builtinCancelErrorConstructor,
    ]

    // MARK: - G-3c-1: Future-valued concurrency, shared by both engines

    /// Whether a value is a cancellation error — the `isCancel(e)` predicate.
    ///
    /// Moved out of the interpreter so the AST channel's by-name chain and the
    /// IR executor's arm read one rule. `Error` and `CancelError` are
    /// structurally identical (one `message` field each), and this type name is
    /// the only thing that tells them apart — which is why the predicate exists
    /// at all rather than a string comparison at every call site.
    static func isCancelErrorValue(_ value: Value) -> Bool {
        guard case .structInstance(let si) = value else { return false }
        return si.typeName == builtinCancelErrorTypeName
    }

    /// Whether a value is already a `Result` case (`ok` / `err`).
    ///
    /// Shared for the same reason: "is this already wrapped?" decides whether a
    /// join boxes its value or passes it through, and two answers to that would
    /// give the two engines different results for the same async body.
    static func isResultValue(_ value: Value) -> Bool {
        guard case .enumValue(let ev) = value else { return false }
        return ev.parentEnum == builtinResultEnumName
    }

    /// Whether a value is the `err` case of a `Result` (`ok` gives false).
    static func isErrResultValue(_ value: Value) -> Bool {
        guard case .enumValue(let ev) = value else { return false }
        return ev.parentEnum == builtinResultEnumName && ev.caseName == "err"
    }

    /// Cooperative cancellation checkpoint: a task cancelled while it was waiting
    /// ends here rather than at an arbitrary instruction.
    ///
    /// Shared for the same reason as the predicates above, and it was the last
    /// one still copied: the interpreter held one and the IR executor held a
    /// private one, so the rule could not be asserted from the outside without
    /// naming one of the two engines. A cancellation that ended a task on one
    /// engine and not the other would be a difference in the language rather
    /// than in the implementation — and the join site turns either into the same
    /// `err(CancelError)`, so the two are one rule or they are wrong.
    ///
    /// Inlined because it sits on the entry path of every async body: the
    /// synchronous case is a nil check, and it has to cost nothing when no task
    /// owns the thread. ⛔ Not "the loop-header path" — there is no checkpoint
    /// there (measured 2026-09-21; see the language reference, §8.3).
    @inline(__always)
    static func checkCancellation(_ owner: FutureValue?) throws {
        if let owner = owner, owner.isCancelled {
            throw FutureValue.cancelError()
        }
    }

    /// Block until `fut` resolves and normalise the outcome to a `Result` value
    /// — errors as data, never thrown across the join.
    ///
    /// Three outcomes, and the shape each takes is the contract:
    /// - the body already produced a `Result` → pass it through untouched;
    /// - the body produced an ordinary value (a `=> ()` body's `.null` included)
    ///   → box it as `ok(v)`;
    /// - the body threw, the task was cancelled, or a timeout expired → `err`,
    ///   with cancellation always normalised to `CancelError` so a caller cannot
    ///   tell a manual cancel from a timeout by anything but the message.
    ///
    /// The join happens on both engines and the normalisation is exactly the
    /// part that would drift: a second copy would agree on the happy path and
    /// disagree about which catch clause wins.
    ///
    /// `form` is which keyword the site was written with — the one thing the
    /// grammar distinguishes and the pipeline used to drop. The two forms differ
    /// in exactly one respect: whether the site may give the current task up
    /// while it waits. **That difference is not implemented yet**, so both forms
    /// take the blocking path below. It cannot be implemented here: a
    /// tree-walking body's state *is* the machine stack, so resuming one part-way
    /// through needs a resumable body form first. Until that lands, `await`
    /// degrades to `wait` — the compliant direction, since yielding is optional
    /// while the join is not (see the C ABI face, `DE-1`, for the primitive that
    /// will carry it and the layering rule that makes degradation the required
    /// behaviour rather than a bug).
    static func joinFuture(_ fut: FutureValue, timeoutMs: Int?, form: JoinForm = .waits) -> Value {
        // A joined child leaves its parent: its lifetime has been consumed
        // explicitly, so the parent's return must stop cancelling it.
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

    /// `joinAll([a, b, c])` → an aggregate future over every member.
    ///
    /// fail-fast: the first member to yield `err` decides the aggregate and the
    /// remaining ones are cancelled — nobody is waiting for them, so they must
    /// not keep burning threads. A member keeps its own parent: the aggregate
    /// links to it for cancellation only, because rewriting a member's parent
    /// would make some caller's return cancel a task it never owned.
    ///
    /// The scheduler, the owning task and the two engine hooks arrive as
    /// parameters rather than fields because this type holds no state: each
    /// engine passes its own back end and its own thread-local task handle, and
    /// neither ends up with a second copy of the rule to disagree with.
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
        scheduler.spawn(aggregate) {
            let restore = enterTask(aggregate)
            // Registration order matches the AST side: the scope close runs
            // before the task handle is restored, so the close still sees the
            // aggregate as the current task.
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
                    // Resolve explicitly rather than by returning: this task
                    // decides its own outcome at the decision point, and the
                    // `Value` it hands back would otherwise be the thing the
                    // scheduler reads. Reporting `.finished` afterwards is
                    // harmless for the same reason a second `resolve` is — it
                    // is ignored once the future is settled.
                    aggregate.resolve(joined)
                    return .finished(.null)
                }
                values.append(ev.associatedValues.first ?? .null)
            }
            aggregate.resolve(makeResult(caseName: "ok", payload: .array(values)))
            return .finished(.null)
        }
        return .future(aggregate)
    }

    /// The strict structured rule's one bounded override: a body that finished
    /// `ok` while a child nobody joined had failed comes out as `err(aggregate)`.
    ///
    /// Bounded on purpose — a body that produced its own `err` keeps it, because
    /// errors-as-data already carries a failure and overwriting it would lose
    /// which one happened. The flip happens at the return boundary, as a value,
    /// and stays inspectable by `match`: nothing is injected into the call stack.
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

/// The stack bounds of one thread, cached for the life of that thread.
///
/// Both fields are optional so that "this platform cannot answer" is a value
/// that can be cached too: without that, a platform which cannot report its
/// stack would be asked again on every single call.
private final class HostStackBounds {
    let low: Int?
    let size: Int?

    init(_ bounds: (low: Int, size: Int)?) {
        self.low = bounds?.low
        self.size = bounds?.size
    }
}

/// One cache per thread — read by `RuntimeOps.hostStack()`.
private let hostStackBounds = ThreadLocal<HostStackBounds>()

/// Ask the platform where the running thread's stack begins and how big it is.
///
/// `low` is the lowest address that stack can reach, which is what a reading of
/// the current frame is measured against: the stack grows downward, so a frame
/// closer to `low` has less room left beneath it.
private func readHostStack() -> (low: Int, size: Int)? {
    #if canImport(Darwin)
        let thread = pthread_self()
        let size = Int(pthread_get_stacksize_np(thread))
        let high = Int(bitPattern: pthread_get_stackaddr_np(thread))
        guard size > 0, high > 0 else { return nil }
        return (high - size, size)
    #elseif canImport(Glibc)
        var attributes = pthread_attr_t()
        guard pthread_getattr_np(pthread_self(), &attributes) == 0 else { return nil }
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
