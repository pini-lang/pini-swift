import Foundation

/// High-level IR shared by every backend: a typed tree where every expression carries its resolved
/// scalar type and every variable access its declared type. All type decisions live in `IRLowerer`;
/// consumers translate mechanically and never re-derive types; the capability gate rejects the rest.

/// Resolved scalar types carried by IR nodes (slice set).
public indirect enum IRType: Equatable {
    case i32
    case i64
    /// `U64` (G14): 64-bit unsigned integer. LLVM has no separate unsigned
    /// spelling — same `i64` as I64; signedness rides on the operations.
    /// Printing mirrors the interpreter (one unified int value, `%d`).
    case u64
    /// `U8` (G14): 8-bit unsigned integer — same `i8` spelling as I8;
    /// signedness rides on the operations.
    case u8
    /// `I8`: 8-bit signed integer. Struct fields / method returns / field reads are the in-slice surface;
    /// arithmetic on i8 widens to i32 at emission, since the interpreter models all integers as one value.
    case i8
    case f64
    case boolean
    case string
    /// `Char`: one extended grapheme cluster — the user-perceived "one character", not a code point
    /// and not a byte. It shares `String`'s representation, so the LLVM spelling is `i8*` and no new ABI
    /// travels through aggregates, calls or the runtime. "Exactly one grapheme" is the type system's job.
    case char
    /// `Result<T, E>`: only the ok payload type is statically carried — Pini's `^T` pins T but leaves E
    /// unconstrained, so the error slot is type-erased to a machine word in the IR ABI.
    case result(ok: IRType)
    /// `Future<T, E>`：`=>` 函数对外签名的返回类型 —— 运行中的并发进程句柄，表示是不透明句柄。
    /// 与 `result` 不可互换：那是已结算的值，这是未结算的句柄；发射层要静态分辨两者，否则一次异步调用
    /// 与「返回 Result 的同步调用」逐字相同。仅携带 ok 载荷，错误槽与 `result` 同口径（擦除为一个机器字）。
    case future(ok: IRType)
    /// `Array<T>` (G2). The array itself is an opaque runtime handle
    /// (`%bk_array*`, 并发后端抽象); elements are boxed through the `bk_array_*`
    /// C ABI. Nested arrays recurse via the element type.
    case array(element: IRType)
    /// `Optional<T>` (G2). Tagged aggregate `{ i64, T }` — tag 0 = some,
    /// 1 = none. The interpreter models Optional as an enum with `some` /
    /// `none` cases; `none` is the language-level nil (user adjudication).
    case optional(wrapped: IRType)
    /// 用户名义类型：结构体（值布局，以栈指针携带，ABI 形态 `%struct.<mangled>*`）
    /// 或对象（引用，`%object.<mangled>*`）；两者头四格同为 {强计数, 弱计数, 类型标识, 旁表}。
    case nominal(name: String, isObject: Bool)
    /// 用户枚举：标签联合 `%enum.<mangled>*`，标签落在头四格之后（第 4 格），
    /// 载荷槽按最大元数的用例定型、直接按值存放。
    case enumeration(name: String)
    /// `Dictionary<K, V>` (G5): opaque handle `%bk_dict*`, keys/values boxed
    /// through the `bk_dict_*` C ABI.
    case dict(key: IRType, value: IRType)
    /// `LazyRef<T>` (G13 batch 1): opaque handle `%bk_lazyref*` — once-evaluated
    /// lazy reference with shared (reference) copy semantics; the element rides
    /// along for the boxing ABI (bytes/tag) and the `.value` load type.
    case lazyRef(element: IRType)
    /// `Set<T>` (G5): opaque handle `%bk_set*`, ordered unique elements.
    case set(element: IRType)
    /// Labeled tuple (G5 minimal slice): register aggregate `{ ... }`,
    /// member access via extractvalue by label index.
    case tuple(labels: [String?], fieldTypes: [IRType])
    /// Function value: closures / lambdas / named functions used as values. Unified fat-pointer ABI
    /// `{ ptr, ptr }` = { code, env }; the param/return shapes are carried for parity checking only — the
    /// call protocol is fixed (first arg is always the env pointer).
    case function(params: [IRType], returnType: IRType?, usingIndices: Set<Int>)
    /// `*T`: raw pointer, opaque `ptr` in LLVM IR — load/store take the element type, address-of produces
    /// it from an alloca. The element rides along for load/store typing (mirroring the interpreter's
    /// snapshot/decode: `*U8` loads sign-extend to one int value).
    case pointer(element: IRType)

    /// LLVM type spelling used by the emitters.
    public var llvmSpelling: String {
        switch self {
        case .i8, .u8: return "i8"
        case .i32: return "i32"
        case .i64, .u64: return "i64"
        case .f64: return "double"
        case .boolean: return "i1"
        case .string: return "i8*"
        case .char: return "i8*"
        case .result(let ok):
            return "{ i64, \(ok.llvmSpelling), i64 }"
        case .future:
            // Opaque handle, same as the other `bk_*` families: the handle
            // shape is a backend concern and no payload travels through it.
            return "ptr"
        case .array:
            return "%bk_array*"
        case .optional(let wrapped):
            return "{ i64, \(wrapped.llvmSpelling) }"
        case .nominal(let name, let isObject):
            return isObject ? "%object.\(IRName.mangle(name))*" : "%struct.\(IRName.mangle(name))*"
        case .enumeration(let name):
            return "%enum.\(IRName.mangle(name))*"
        case .dict:
            return "%bk_dict*"
        case .set:
            return "%bk_set*"
        case .lazyRef:
            return "%bk_lazyref*"
        case .tuple(_, let fieldTypes):
            return "{ " + fieldTypes.map { $0.llvmSpelling }.joined(separator: ", ") + " }"
        case .function:
            return "{ ptr, ptr }"
        case .pointer:
            return "ptr"
        }
    }

    /// Unpointed aggregate spelling for alloca / GEP (nominal and enum types).
    public var nominalAggregateSpelling: String? {
        switch self {
        case .nominal, .enumeration:
            return String(llvmSpelling.dropLast())
        default:
            return nil
        }
    }

    /// The ok payload type when this is a Result type.
    public var resultOkType: IRType? {
        if case .result(let ok) = self { return ok }
        return nil
    }

    /// The `Result` a join site yields when this is a Future type. A join consumes the handle and produces
    /// the settled value, so the site's type is the Result the Future stood in for; keeping the
    /// translation here means the two types cannot drift.
    public var joinedResultType: IRType? {
        if case .future(let ok) = self { return .result(ok: ok) }
        return nil
    }

    /// The wrapped type when this is an Optional type.
    public var optionalWrapped: IRType? {
        if case .optional(let wrapped) = self { return wrapped }
        return nil
    }

    /// The element type when this is an Array type.
    public var arrayElementType: IRType? {
        if case .array(let element) = self { return element }
        return nil
    }

    /// Whether this is an Array type (any element).
    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    /// 本类型是否属于「字符串面」：`String` 与 `Char`。
    /// 二者共用表示，故凡按「字符串」处理的通道（拼接、拼接式比较、常量池）都按本判定收；
    /// 逐处列 `.string` 漏一处，就会让 `Char` 落到某个 `default:` 上静默走错路。
    public var isStringFaced: Bool {
        switch self {
        case .string, .char: return true
        default: return false
        }
    }

    /// 本类型与给定类型是否构成 `Char` / `String` 相容对（对称）—— 二元运算与比较没有「哪一侧是期望」，
    /// 故不看方向；单方向的加宽判定在类型检查器（`Char → String`，反向拒绝）。
    public func formsCharStringPair(with other: IRType) -> Bool {
        (self == .char && other == .string) || (self == .string && other == .char)
    }

    public var isNumeric: Bool {
        switch self {
        case .i8, .u8, .i32, .i64, .u64, .f64: return true
        case .boolean, .string, .char, .result, .future, .array, .optional, .nominal, .enumeration, .dict, .set, .tuple, .function, .lazyRef, .pointer:
            return false
        }
    }

    /// Whether this is an integer numeric type (every numeric except F64).
    /// Drives declaration width alignment: a float literal in an
    /// integer-typed slot folds to the truncated integer constant.
    public var isIntegerNumeric: Bool {
        switch self {
        case .i8, .u8, .i32, .i64, .u64: return true
        default: return false
        }
    }
}

/// Binary operators in the slice set.
public enum IRBinaryOp: Equatable {
    case add, subtract, multiply, divide, modulo
    case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual
    /// Bitwise family (G15): integer operands; `and`/`or`/`xor`/`shl`/`ashr`
    /// map 1:1 onto LLVM integer instructions. Interpreter parity: int×int
    /// only (bool operands are rejected by the interpreter's eval table).
    case bitwiseAnd, bitwiseOr, bitwiseXor, leftShift, rightShift
    /// `min(a, b)` / `max(a, b)` intrinsics (G9) — I32 select forms.
    case minOf, maxOf

    /// Comparison operators produce `boolean`; the rest produce the operand type.
    public var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            return true
        default:
            return false
        }
    }

    public var llvmPredicate: String? {
        switch self {
        case .equal: return "eq"
        case .notEqual: return "ne"
        case .lessThan: return "slt"
        case .lessThanOrEqual: return "sle"
        case .greaterThan: return "sgt"
        case .greaterThanOrEqual: return "sge"
        default: return nil
        }
    }
}

/// Unary operators in the slice set.
public enum IRUnaryOp: Equatable {
    case negate
    case logicalNot
    /// `~v` — the I32 complement. Distinct from `logicalNot`, which is `!`.
    case bitwiseNot
    /// `abs(v)` (G9) — I32 select(0-v, v<0).
    case abs
}

/// Typed expression tree (slice set).
public indirect enum IRExpr: Equatable {
    case intConst(value: Int, type: IRType)
    case floatConst(value: Double)
    case boolConst(value: Bool)
    case stringConst(value: String)
    /// Load a variable's value; `type` is the declared type of the variable.
    case load(name: String, type: IRType)
    case binary(op: IRBinaryOp, lhs: IRExpr, rhs: IRExpr, type: IRType)
    case unary(op: IRUnaryOp, operand: IRExpr, type: IRType)
    /// Call to a module-level function; `returnType` is nil for void calls.
    case call(function: String, arguments: [IRExpr], returnType: IRType?)
    /// Intrinsic `print(expr)` — one scalar argument, void result.
    case printCall(argument: IRExpr)
    /// `ok(v)` / `err(e)` 的 Result 构造。err 载荷在发射时加宽到一个机器字
    /// （ABI 上类型擦除）。
    case resultConstruct(isOk: Bool, payload: IRExpr, type: IRType)
    /// Array literal `[e1, e2, ...]` (G2). `type` is `.array(element:)`; the
    /// emitter builds the handle via `bk_array_create` + per-element
    /// `bk_array_set` (boxed through the C ABI).
    case arrayLiteral(elements: [IRExpr], type: IRType)
    /// Subscript read `container[index]` (G2). Out-of-bounds panics in the
    /// runtime (`bk_array_get`), matching the interpreter's safe-assert
    /// channel; the tolerant channel (`.get` -> Optional) is a later grid.
    case subscriptGet(container: IRExpr, index: IRExpr, type: IRType)
    /// Intrinsic `len(array)` — runtime `bk_array_len`, i32 result.
    case lenCall(argument: IRExpr)
    /// Tolerant read channel `container.get(index)` (G2): out of bounds
    /// yields `none` (the language-level nil), in bounds `some(value)`.
    /// Emitted as a bounds-checked inline branch around `bk_array_len/get`.
    case optionalGet(container: IRExpr, index: IRExpr, type: IRType)
    /// `Optional` construction (G2b): `isSome=false` is the `none` literal
    /// (the slice-sugar open bound arrives as `Optional.none`); `isSome=true`
    /// carries the wrapped payload. Mirrors `resultConstruct`.
    case optionalConstruct(isSome: Bool, payload: IRExpr?, type: IRType)
    /// `container.slice(start, end)` — the slice-sugar desugaring. `type` is `.array(element:)` or
    /// `.string`; open bounds arrive as `optionalConstruct(isSome: false, ...)`. Semantics are the sunk
    /// stdlib slice: tail-counted negative bounds, clamp to [0, len], empty result when hi < lo.
    case sliceCall(container: IRExpr, start: IRExpr, end: IRExpr, type: IRType)
    /// Nominal constructor `名()` (G3). Fields take their declared defaults
    /// (or zero); constructor arguments are not part of the slice surface.
    /// Objects additionally write the refcount header (= 1).
    case construct(type: IRType)
    /// Enum case construction `Case(p1, p2, ...)` (G4): tag is the case's
    /// declaration-order index; payloads store by value into the typed
    /// slots of the tagged union.
    case enumConstruct(enumName: String, caseName: String, tag: Int, payloads: [IRExpr], payloadTypes: [IRType], type: IRType)
    /// Nominal field read `base.field` (G3). `type` is the field's type.
    case fieldGet(base: IRExpr, field: String, type: IRType)
    /// Dictionary / set literal (G5). Entries carry pre-lowered key/value
    /// pairs; construction goes through the runtime C ABI.
    case dictLiteral(entries: [IRDictEntry], type: IRType)
    case setLiteral(elements: [IRExpr], type: IRType)
    /// Labeled tuple construction (G5 minimal slice).
    case tupleConstruct(labels: [String?], elements: [IRExpr], type: IRType)
    /// Tuple member read `base.label` (G5) — extractvalue by field index.
    case tupleIndexGet(base: IRExpr, index: Int, type: IRType)

    // MARK: G6 closures / higher-order functions

    /// A closure value: the lowered body of a `func` literal plus its creation-point capture list, ordered
    /// by first use, each with its declared type; captures are by reference (the env field points at the
    /// variable's slot). `paramNames` parallels `paramTypes`; an unannotated param takes the inferred one.
    case closureLiteral(
        id: Int, paramNames: [String], paramTypes: [IRType], returnType: IRType?,
        captures: [IRCapture], body: IRBlock, type: IRType)
    /// A named top-level function used as a value (G6): emitted through an
    /// env-ignoring adapter fat pointer (`@__adapter_<mangled>`) so direct
    /// and indirect call sites share one calling convention.
    case functionValue(functionName: String, type: IRType)
    /// Indirect call through a function value (G6): always the closure ABI
    /// `call ret code(ptr env, args...)` — `callee` is a closureLiteral /
    /// functionValue / function-typed variable load.
    case indirectCall(callee: IRExpr, arguments: [IRExpr], returnType: IRType?)

    // MARK: G14 FFI pointer primitives

    /// `load(p)` (G14): read the element value through a `*T` pointer.
    /// `type` is the element IRType (mirrors the interpreter's
    /// decodePointer: U8 loads sign-extend into one unified int value).
    case pointerLoad(pointer: IRExpr, type: IRType)
    /// `store(p, v)` (G14): write the value through a `*T` pointer using
    /// the pointer's element type (mirrors the interpreter's encode:
    /// truncating store for narrow elements). Value expression.
    case pointerStore(pointer: IRExpr, value: IRExpr, type: IRType)
    /// `&x`: the address of a variable's alloca slot — true pointer semantics. The interpreter's snapshot
    /// aliasing gap (write-back does not update the original) is the documented divergence, covered by the
    /// read-only corpus.
    case addressOfVar(name: String, type: IRType)
    /// `print(a, b, ...)`: per-argument stringify joined with a single space on one line; the emitter
    /// realizes the same byte stream (value, space, value, ..., newline).
    case printMulti(arguments: [IRExpr])
    /// `assert(cond)` / `assert(cond, message)`: boolean trap — false raises the runtime panic with the
    /// message. Only needed so `|test` blocks lower; the differential harness never executes them.
    case assertCall(condition: IRExpr, message: IRExpr?)

    // MARK: G15 file IO

    /// `writeFile(path, content)` (G15) — the whole content, written in place
    /// (truncating, following symlinks, failing loud). Yields no value.
    case fileWrite(path: IRExpr, content: IRExpr)
    /// `appendFile(path, content)` — the whole content appended at the end, creating the file when it
    /// does not exist (POSIX "a"), following symlinks, failing loud. Yields no value.
    /// ⛔ A separate node from `fileWrite`, not a flag: the two are opposite when the target exists.
    case fileAppend(path: IRExpr, content: IRExpr)
    /// `readFile(path)`: the whole file, uncapped, yielded as a String. How the read is emitted is an
    /// implementation detail and belongs in the emitter — the node carries no buffer size or cap.
    case fileRead(path: IRExpr)

    // MARK: 可接住的 IO（`Result` 形态）

    /// 三个 `try*` 内建与陷阱版并存，⛔ 不是给陷阱版加开关：同一个操作在「失败怎么办」上有两种答案，
    /// 而答案属于调用者 —— 一次调用只能有一种，选哪种是源码写的名字，不是运行时参数。
    /// 成功载荷：读是文件内容，写与追加是空元组（写成功不产生值，不编造字节数）；载荷类型由类型层推。

    /// `tryWriteFile(path, content)` — 就地截断写；失败**返回** `err` 而不是陷阱。
    case fileTryWrite(path: IRExpr, content: IRExpr)
    /// `tryAppendFile(path, content)` — 追加写（目标不存在则创建）；失败**返回** `err`。
    case fileTryAppend(path: IRExpr, content: IRExpr)
    /// `tryReadFile(path)` — 读全文；失败**返回** `err`，成功载荷是内容。
    case fileTryRead(path: IRExpr)

    // MARK: G17 builtins

    /// `readLine()`: one stdin line, yielded as a String — `fgets` into a 256-byte stack buffer, the buffer
    /// pointer as the value, so a trailing newline is NOT stripped. The interpreter does strip it; that
    /// divergence is registered, and the differential fixture injects newline-free stdin.
    case readLine
    /// `is_ascii_digit(s)`: first byte in ASCII [0-9]. C-string semantics — the empty string reads its NUL
    /// terminator and is false, matching the interpreter's "first grapheme" rule in the ASCII domain;
    /// outside it the grapheme model takes over and the remaining Unicode predicates stay fail-loud.
    case isAsciiDigit(argument: IRExpr)

    // MARK: G9 string deepening

    /// `s.upper()` / `s.lower()` (G9) — byte-wise toupper/tolower over a
    /// memcpy'd copy (the receiver stays untouched).
    case stringCase(isUpper: Bool, receiver: IRExpr)
    /// `s.contains(needle)` (G9) — `strstr != null`, byte semantics.
    case stringContains(receiver: IRExpr, needle: IRExpr)
    /// `s.substring(start, length)` (G9) — memcpy out of the receiver.
    case stringSubstring(receiver: IRExpr, start: IRExpr, length: IRExpr)
    /// `s.split(delim)` —— 真的 `Array<String>`（与解释器同形，不是格式化串）：
    /// strtok 循环把切出的 token 经 strdup 喂给 bk_array_create/set。
    case stringSplit(receiver: IRExpr, delim: IRExpr, type: IRType)
    /// `s.trimLeft()` — strip leading ASCII spaces (U+0020 only; tabs and other whitespace are NOT
    /// stripped). The run is single-grapheme spaces, so a byte-wise scan is exact; the tail is sliced out
    /// in the runtime shim. Returns a new string; the receiver is untouched. All-space input yields "".
    case stringTrimLeft(receiver: IRExpr)
    /// `s.trimRight()` — strip **trailing** ASCII spaces, same rule as
    /// `stringTrimLeft` (U+0020 only; no tab).
    case stringTrimRight(receiver: IRExpr)
    /// `s.indexOf(needle)`: grapheme index of the first occurrence; an empty needle yields 0, absent
    /// yields -1. Same grapheme scan as `stringContains`, but it reports position instead of existence.
    case stringIndexOf(receiver: IRExpr, needle: IRExpr)
    /// `arr.join(sep)` (G9) — string-array elements strcat'd with sep.
    case arrayJoin(receiver: IRExpr, separator: IRExpr)
    /// `s1 + s2` string concatenation (G9) — malloc'd join of the two
    /// C strings (byte semantics, matching the sunk concat channel).
    case stringConcat(lhs: IRExpr, rhs: IRExpr)
    /// String interpolation `"x=\(expr)"`: parts are already-lowered expressions of scalar/string/array
    /// types; each converts to a C string and the pieces strcat into a stack buffer. F64 renders via
    /// `bk_double_to_string` (shortest round-trip), not `%f`.
    case interpString(parts: [IRExpr])

    // MARK: G13 batch 1 — LazyRef

    /// `LazyRef<T>(closure)`: creates the once-evaluated handle via `bk_lazyref_create(wrapper, code, env,
    /// bytes, tag)`. `closure` is the lowered initializer fat pointer; the per-element-type wrapper is
    /// buffered at module end by the emitter.
    case lazyRefConstruct(closure: IRExpr, type: IRType)
    /// `handle.value` (G13): `bk_lazyref_value(handle)` returns the cached
    /// element box; the caller loads the element type out of it.
    case lazyRefValue(handle: IRExpr, type: IRType)

    // MARK: G3c — join

    /// `await f` / `wait f`: the node the suspension semantics hang off. `future` evaluates to a `Future`;
    /// once it resolves the join site deconstructs the carried ok / err, so `type` is the Result it yields.
    /// `form` is which keyword was written — the only thing telling the two apart, and back ends must read it.
    case join(future: IRExpr, type: IRType, form: JoinForm)

    // MARK: - 默认实例取用

    /// 取某类型的默认实例：该实例由类型决定 —— 编译器按类型解析，无运行时查找、无 vtable；
    /// 惰性物化、恰一次、地址稳定；取到的是实例本身（非副本、非模板）。它与 `lazyRefValue` 不是一件事：
    /// 后者是字段内的细粒度缓冲，本条是类型级取用。目前无降载入口，两台引擎起步 fail-loud。
    case givenInstance(type: IRType)
}

/// One nominal type declaration (G3): layout + lowered field defaults +
/// methods (each already self-parameterized, IR name mangled).
public struct IRTypeDecl: Equatable {
    public struct Field: Equatable {
        public let name: String
        public let type: IRType
        public let defaultValue: IRExpr?

        public init(name: String, type: IRType, defaultValue: IRExpr?) {
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
        }
    }

    public let name: String
    public let isObject: Bool
    public let fields: [Field]
    public let methods: [IRFunction]

    public init(name: String, isObject: Bool, fields: [Field], methods: [IRFunction]) {
        self.name = name
        self.isObject = isObject
        self.fields = fields
        self.methods = methods
    }
}

/// One dictionary literal entry (G5). A struct because Swift tuples cannot
/// carry conditional Equatable conformance for the IR tree.
public struct IRDictEntry: Equatable {
    public let key: IRExpr
    public let value: IRExpr

    public init(key: IRExpr, value: IRExpr) {
        self.key = key
        self.value = value
    }
}

/// One reference capture of a closure: the captured outer variable's name and declared type. The env
/// field stores a pointer to the variable's storage slot, so later writes to the outer variable stay
/// visible through the closure (interpreter currentEnv parity).
public struct IRCapture: Equatable {
    public let name: String
    public let type: IRType

    public init(name: String, type: IRType) {
        self.name = name
        self.type = type
    }
}

/// One match arm. `caseName` is the enum-case name the scrutinee's tag is compared against ("some" /
/// "none" for an Optional scrutinee; user enum cases via the same node). `bindings` are the per-payload
/// variable names (`nil` = `_` placeholder), positional by payload index; the arm body sees them scoped.
public struct IRMatchCase: Equatable {
    public let caseName: String
    /// Literal-pattern operand of a bare-scrutinee arm, nil for enum-case and
    /// wildcard arms (those live in `caseName`). See `IRMatchLiteral`.
    public let literal: IRMatchLiteral?
    public let bindings: [String?]
    public let body: IRBlock

    public init(caseName: String, literal: IRMatchLiteral? = nil, bindings: [String?], body: IRBlock) {
        self.caseName = caseName
        self.literal = literal
        self.bindings = bindings
        self.body = body
    }
}

/// Literal-pattern operand of a match arm over a bare (neither Optional nor enum) scrutinee —
/// `case 1:` / `case "hi":` / `case 1.5:` / `case true:`. The interpreter compares such an arm by
/// value, so the emitter must dispatch on it; the operand is carried structurally, not re-parsed.
public enum IRMatchLiteral: Equatable {
    case int(Int)
    case float(Double)
    case string(String)
    case boolean(Bool)
}

/// for-in iterable family (G15): the container kind decides which runtime
/// accessor reads element `i` — `bk_array_get` / `bk_set_at` for 1-field
/// patterns, `bk_dict_key_at` / `bk_dict_val_at` for 2-field `(k, v)`.
public enum IRForIterableKind: Equatable {
    case array, set, dict
}

/// 语句表 + 每条语句的源码位置：`positions` 与 `statements` 平行，未带位置时为空（测试里手搭的 IR），
/// `position(at:)` 那时返回 nil 而不是编一行。位置挂在块级而非每个节点上 —— 只在 `lowerBlock` 落地，
/// 故与解释器同粒度、同起点。`Equatable` 只比语句：让坐标参与比较会让既有结构断言全部依赖位置。
public struct IRBlock: Equatable, ExpressibleByArrayLiteral, RandomAccessCollection {
    public typealias Element = IRStmt
    public typealias Index = Int

    public var statements: [IRStmt]
    /// Parallel to `statements`; empty means "this block carries no positions".
    public var positions: [SourceLocation]

    public init(_ statements: [IRStmt] = [], positions: [SourceLocation] = []) {
        self.statements = statements
        self.positions = positions
    }

    public init(arrayLiteral elements: IRStmt...) {
        self.init(elements)
    }

    /// A block whose every statement carries the same source position — the shape a construct needs when
    /// one source statement lowers into several IR statements. Used by the `defer` body and the try-else
    /// handler, which `lowerStatement` expands in place rather than through `lowerBlock`.
    public static func at(_ statements: [IRStmt], _ location: SourceLocation) -> IRBlock {
        IRBlock(
            statements,
            positions: Array(repeating: location, count: statements.count)
        )
    }

    public var isEmpty: Bool { statements.isEmpty }
    public var count: Int { statements.count }
    public var startIndex: Int { statements.startIndex }
    public var endIndex: Int { statements.endIndex }
    public subscript(position: Int) -> IRStmt { statements[position] }

    /// The source position of the statement at `index`, or `nil` when this
    /// block carries none (or the index is out of range).
    public func position(at index: Int) -> SourceLocation? {
        guard positions.count == statements.count, positions.indices.contains(index) else {
            return nil
        }
        return positions[index]
    }

    /// Statements compared, positions ignored — see the note on the type.
    public static func == (lhs: IRBlock, rhs: IRBlock) -> Bool {
        lhs.statements == rhs.statements
    }
}

public indirect enum IRStmt: Equatable {
    /// Variable slot. Emitting allocates the slot; a non-nil initializer
    /// stores into it right after allocation.
    case allocVar(name: String, type: IRType, mutable: Bool, initializer: IRExpr?)
    /// Store into an existing variable; `type` is the declared variable type.
    case storeVar(name: String, type: IRType, value: IRExpr)
    /// `[label|] if cond: then [else: else]`. `label` makes this an interruptible frame: `break <label>`
    /// may leave the `if` block, while `continue` accepts loop labels only. The label text is never read
    /// at run time — only the resolved depth travels, and `label != nil` is what back ends test.
    case ifStmt(label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?)
    /// `while cond: body [step: block]`. The step block (标签语法反转) runs once
    /// per iteration after the body — on normal completion *and* on
    /// unlabeled `continue` (interpreter parity); `break` skips it.
    case whileStmt(condition: IRExpr, body: IRBlock, step: IRBlock?)
    /// `for (pattern,) in iterable: body [step: block]`. `kind` selects the runtime accessor family;
    /// `elementTypes` are parallel to `pattern` (`"_"` entries still occupy a slot and carry its type).
    /// Break/continue follow the same step contract as `whileStmt`.
    case forInStmt(
        pattern: [String],
        elementTypes: [IRType],
        kind: IRForIterableKind,
        iterable: IRExpr,
        body: IRBlock,
        step: IRBlock?
    )
    /// Slice set: single-value return; nil for void functions.
    case returnStmt(value: IRExpr?)
    case exprStmt(IRExpr)
    /// `defer stmt`: the wrapped statements run LIFO when the enclosing block scope exits (each
    /// loop-iteration end included). A block's scope closes on every exit, so `break` and `return` run
    /// the defers on the unwinding path too.
    case deferStmt(body: IRBlock)
    /// `try operand else errorVar: handler`. The operand's type is `result(ok:)`; the error path binds the
    /// type-erased error word to `errorVar` and runs `handler`. `okTarget` is set for expression position
    /// (the ok payload is stored there) and nil for statement position.
    case tryStmt(operand: IRExpr, errorVar: String, handler: IRBlock, okTarget: String?, type: IRType)
    /// Subscript store `container[index] = value`. The container may be a nested subscript chain (the
    /// emitter walks the COW split chain); compound assignment (`a[i] += k`) lowers to read-modify-write
    /// with the same node. `elementType` is the boxed element's static type.
    case subscriptStore(container: IRExpr, index: IRExpr, value: IRExpr, elementType: IRType)
    /// `break`, with the labeled form. `depth` = how many enclosing loops to unwind (1 = innermost);
    /// labeled `break outer` lowers to the depth the lowerer resolved from the label stack. An unresolvable
    /// target lowers to `panicStmt` instead — the interpreter errors at the top level, so this is fail-loud.
    case breakStmt(depth: Int)
    /// `continue` (G15). `depth` mirrors breakStmt: 1 = innermost loop's
    /// condition re-test; N = the depth-th enclosing loop's header (labeled
    /// continue, 标签语法反转). Unresolvable targets panic like break.
    case continueStmt(depth: Int)
    /// Unconditional runtime trap with a fixed message (G15). Emitted for
    /// control-flow escapes the interpreter only detects at run time
    /// (break/continue outside any loop). The block is terminated.
    case panicStmt(message: String)
    /// `match scrutinee: case name(binding): body ...`. The scrutinee type decides the tag ABI: Optional
    /// arms compare the `{ i64, T }` tag (some=0, none=1); enum scrutinees use their own tag layout through
    /// the same node. Unmatched values panic at runtime (interpreter matchNotExhaustive parity).
    case matchStmt(scrutinee: IRExpr, cases: [IRMatchCase], scrutineeType: IRType)
    /// Nominal field store `base.field = value` (G3). GEP + store through
    /// the base pointer; objects offset past the refcount header.
    case fieldStore(base: IRExpr, field: String, value: IRExpr, fieldType: IRType)
    /// `capture name`: a marker statement inside a closure body. The capture itself resolves at the
    /// closure-literal creation point, so this lowers to nothing — it exists so the statement kind is
    /// accepted inside lowered bodies rather than gated.
    case captureMarker(name: String)
    /// `detach <expr>` — prune the task from its parent, so the parent's return no longer cancels it
    /// (fire-and-forget's only sanctioned exit). The operand must evaluate to a `Future`; a non-future is a
    /// runtime type mismatch, not a lowerer error. No `type` rides along: a statement produces no value.
    case detachStmt(inner: IRExpr)
}
