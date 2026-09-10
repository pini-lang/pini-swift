import Foundation

/// High-level intermediate representation for the LLVM backend (LR-2/LR-3).
///
/// The HIR is a **typed tree**: every expression node carries its resolved
/// scalar type, every variable access carries the declared type of the
/// variable. All type decisions live in `HIRLowerer`; consumers (the
/// emitters) translate nodes to IR text mechanically and never re-derive
/// types. This is the structural replacement for the old IRGenerator's
/// shadow type tables.
///
/// Scope note: this is the M4 vertical-slice node set (scalars, arithmetic,
/// control flow, function calls). Aggregate / closure / concurrency / FFI /
/// generics nodes are added grid-by-grid in M5; anything outside the
/// current set is rejected by the single capability gate in `HIRLowerer`.

/// Resolved scalar types carried by HIR nodes (slice set).
public indirect enum HIRType: Equatable {
    case i32
    case i64
    /// `U64` (G14): 64-bit unsigned integer. LLVM has no separate unsigned
    /// spelling — same `i64` as I64; signedness rides on the operations.
    /// Printing mirrors the interpreter (one unified int value, `%d`).
    case u64
    /// `U8` (G14): 8-bit unsigned integer — same `i8` spelling as I8;
    /// signedness rides on the operations.
    case u8
    /// `I8` (G11): 8-bit signed integer. Struct fields / method returns /
    /// field reads are the in-slice surface; arithmetic on i8 widens to i32
    /// at emission (the interpreter models all integers as one int value,
    /// so no i8-specific arithmetic exists to mirror).
    case i8
    case f64
    case boolean
    case string
    /// `Result<T, E>` (ADR-032). Only the ok payload type is statically
    /// carried: Pini's surface form `^T` pins T but leaves E unconstrained
    /// (the checker accepts any err payload), so the error slot is
    /// type-erased to a machine word in the IR ABI (LR-12).
    case result(ok: HIRType)
    /// `Array<T>` (G2). The array itself is an opaque runtime handle
    /// (`%bk_array*`, ADR-008); elements are boxed through the `bk_array_*`
    /// C ABI. Nested arrays recurse via the element type.
    case array(element: HIRType)
    /// `Optional<T>` (G2). Tagged aggregate `{ i64, T }` — tag 0 = some,
    /// 1 = none. The interpreter models Optional as an enum with `some` /
    /// `none` cases; `none` is the language-level nil (user adjudication).
    case optional(wrapped: HIRType)
    /// User nominal type (G3): struct (value layout carried as a stack
    /// pointer, legacy ABI `%struct.<mangled>*`) or object (reference,
    /// `%object.<mangled>*` with an i32 refcount header at field 0).
    case nominal(name: String, isObject: Bool)
    /// User enum (G4): tagged union `%enum.<mangled>*` — i32 tag at field 0,
    /// payload slots typed by the max-arity case (direct by-value store).
    case enumeration(name: String)
    /// `Dictionary<K, V>` (G5): opaque handle `%bk_dict*`, keys/values boxed
    /// through the `bk_dict_*` C ABI.
    case dict(key: HIRType, value: HIRType)
    /// `LazyRef<T>` (G13 batch 1): opaque handle `%bk_lazyref*` — once-evaluated
    /// lazy reference with shared (reference) copy semantics; the element rides
    /// along for the boxing ABI (bytes/tag) and the `.value` load type.
    case lazyRef(element: HIRType)
    /// `Set<T>` (G5): opaque handle `%bk_set*`, ordered unique elements.
    case set(element: HIRType)
    /// Labeled tuple (G5 minimal slice): register aggregate `{ ... }`,
    /// member access via extractvalue by label index.
    case tuple(labels: [String?], fieldTypes: [HIRType])
    /// Function value (G6): closures / lambdas / named functions used as
    /// values. Unified fat-pointer ABI `{ ptr, ptr }` = { code, env }; the
    /// param/return shapes are carried for parity checking only — the IR
    /// call protocol is fixed (first arg is always the env pointer).
    case function(params: [HIRType], returnType: HIRType?)
    /// `*T` (G14, ADR-015 FFI): raw pointer. Opaque `ptr` in LLVM IR —
    /// load/store take the element type; address-of produces it from an
    /// alloca. Element rides along for load/store typing (mirrors the
    /// interpreter's snapshot/decode semantics: `*U8` loads sign-extend to
    /// one int value).
    case pointer(element: HIRType)

    /// LLVM type spelling used by the emitters.
    public var llvmSpelling: String {
        switch self {
        case .i8, .u8: return "i8"
        case .i32: return "i32"
        case .i64, .u64: return "i64"
        case .f64: return "double"
        case .boolean: return "i1"
        case .string: return "i8*"
        case .result(let ok):
            return "{ i64, \(ok.llvmSpelling), i64 }"
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
    public var resultOkType: HIRType? {
        if case .result(let ok) = self { return ok }
        return nil
    }

    /// The wrapped type when this is an Optional type.
    public var optionalWrapped: HIRType? {
        if case .optional(let wrapped) = self { return wrapped }
        return nil
    }

    /// The element type when this is an Array type.
    public var arrayElementType: HIRType? {
        if case .array(let element) = self { return element }
        return nil
    }

    /// Whether this is an Array type (any element).
    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var isNumeric: Bool {
        switch self {
        case .i8, .u8, .i32, .i64, .u64, .f64: return true
        case .boolean, .string, .result, .array, .optional, .nominal, .enumeration, .dict, .set, .tuple, .function, .lazyRef, .pointer:
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
public enum HIRBinaryOp: Equatable {
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
public enum HIRUnaryOp: Equatable {
    case negate
    case logicalNot
    /// `abs(v)` (G9) — I32 select(0-v, v<0).
    case abs
}

/// Typed expression tree (slice set).
public indirect enum HIRExpr: Equatable {
    case intConst(value: Int, type: HIRType)
    case floatConst(value: Double)
    case boolConst(value: Bool)
    case stringConst(value: String)
    /// Load a variable's value; `type` is the declared type of the variable.
    case load(name: String, type: HIRType)
    case binary(op: HIRBinaryOp, lhs: HIRExpr, rhs: HIRExpr, type: HIRType)
    case unary(op: HIRUnaryOp, operand: HIRExpr, type: HIRType)
    /// Call to a module-level function; `returnType` is nil for void calls.
    case call(function: String, arguments: [HIRExpr], returnType: HIRType?)
    /// Intrinsic `print(expr)` — one scalar argument, void result.
    case printCall(argument: HIRExpr)
    /// `ok(v)` / `err(e)` Result case construction. The err payload is
    /// widened to a machine word at emission (type-erased ABI, LR-12).
    case resultConstruct(isOk: Bool, payload: HIRExpr, type: HIRType)
    /// Array literal `[e1, e2, ...]` (G2). `type` is `.array(element:)`; the
    /// emitter builds the handle via `bk_array_create` + per-element
    /// `bk_array_set` (boxed through the C ABI).
    case arrayLiteral(elements: [HIRExpr], type: HIRType)
    /// Subscript read `container[index]` (G2). Out-of-bounds panics in the
    /// runtime (`bk_array_get`), matching the interpreter's safe-assert
    /// channel; the tolerant channel (`.get` -> Optional) is a later grid.
    case subscriptGet(container: HIRExpr, index: HIRExpr, type: HIRType)
    /// Intrinsic `len(array)` — runtime `bk_array_len`, i32 result.
    case lenCall(argument: HIRExpr)
    /// Tolerant read channel `container.get(index)` (G2): out of bounds
    /// yields `none` (the language-level nil), in bounds `some(value)`.
    /// Emitted as a bounds-checked inline branch around `bk_array_len/get`.
    case optionalGet(container: HIRExpr, index: HIRExpr, type: HIRType)
    /// `Optional` construction (G2b): `isSome=false` is the `none` literal
    /// (the slice-sugar open bound arrives as `Optional.none`); `isSome=true`
    /// carries the wrapped payload. Mirrors `resultConstruct`.
    case optionalConstruct(isSome: Bool, payload: HIRExpr?, type: HIRType)
    /// `container.slice(start, end)` (G2b) — the slice-sugar desugaring.
    /// `type` is `.array(element:)` or `.string`; open bounds arrive as
    /// `optionalConstruct(isSome: false, ...)`. Semantics are the sunk
    /// stdlib slice: tail-counted negative bounds, clamp to [0, len],
    /// empty result when hi < lo.
    case sliceCall(container: HIRExpr, start: HIRExpr, end: HIRExpr, type: HIRType)
    /// Nominal constructor `名()` (G3). Fields take their declared defaults
    /// (or zero); constructor arguments are not part of the slice surface.
    /// Objects additionally write the refcount header (= 1).
    case construct(type: HIRType)
    /// Enum case construction `Case(p1, p2, ...)` (G4): tag is the case's
    /// declaration-order index; payloads store by value into the typed
    /// slots of the tagged union.
    case enumConstruct(enumName: String, caseName: String, tag: Int, payloads: [HIRExpr], payloadTypes: [HIRType], type: HIRType)
    /// Nominal field read `base.field` (G3). `type` is the field's type.
    case fieldGet(base: HIRExpr, field: String, type: HIRType)
    /// Dictionary / set literal (G5). Entries carry pre-lowered key/value
    /// pairs; construction goes through the runtime C ABI.
    case dictLiteral(entries: [HIRDictEntry], type: HIRType)
    case setLiteral(elements: [HIRExpr], type: HIRType)
    /// Labeled tuple construction (G5 minimal slice).
    case tupleConstruct(labels: [String?], elements: [HIRExpr], type: HIRType)
    /// Tuple member read `base.label` (G5) — extractvalue by field index.
    case tupleIndexGet(base: HIRExpr, index: Int, type: HIRType)

    // MARK: G6 closures / higher-order functions

    /// A closure value (G6): the lowered body of a `func` literal plus its
    /// creation-point capture list. Captures are reference-captured (the env
    /// field holds a pointer to the captured variable's storage slot, sharing
    /// semantics with the interpreter's currentEnv); `captures` is ordered by
    /// first use in the body and carries each captured variable's declared
    /// type. `paramNames` parallels `paramTypes` (body references go through
    /// these names); an unannotated param adopts the return-annotation
    /// fallback, matching the checker's G29 inference.
    case closureLiteral(id: Int, paramNames: [String], paramTypes: [HIRType], returnType: HIRType?,
                        captures: [HIRCapture], body: [HIRStmt], type: HIRType)
    /// A named top-level function used as a value (G6): emitted through an
    /// env-ignoring adapter fat pointer (`@__adapter_<mangled>`) so direct
    /// and indirect call sites share one calling convention.
    case functionValue(functionName: String, type: HIRType)
    /// Indirect call through a function value (G6): always the closure ABI
    /// `call ret code(ptr env, args...)` — `callee` is a closureLiteral /
    /// functionValue / function-typed variable load.
    case indirectCall(callee: HIRExpr, arguments: [HIRExpr], returnType: HIRType?)

    // MARK: G14 FFI pointer primitives

    /// `load(p)` (G14): read the element value through a `*T` pointer.
    /// `type` is the element HIRType (mirrors the interpreter's
    /// decodePointer: U8 loads sign-extend into one unified int value).
    case pointerLoad(pointer: HIRExpr, type: HIRType)
    /// `store(p, v)` (G14): write the value through a `*T` pointer using
    /// the pointer's element type (mirrors the interpreter's encode:
    /// truncating store for narrow elements). Value expression.
    case pointerStore(pointer: HIRExpr, value: HIRExpr, type: HIRType)
    /// `&x` (G14, D-B adjudication: true pointer semantics): the address of
    /// a variable's alloca slot. The interpreter's snapshot aliasing gap
    /// (write-back does not update the original) is the documented
    /// divergence covered by the read-only corpus.
    case addressOfVar(name: String, type: HIRType)
    /// `print(a, b, ...)` multi-argument form (G14, D-A=A1): the
    /// interpreter's semantics are per-argument stringify joined with a
    /// single space on one line; the emitter realizes the same byte stream
    /// (value, space, value, ..., newline).
    case printMulti(arguments: [HIRExpr])
    /// `assert(cond)` / `assert(cond, message)` (G41 surface): boolean
    /// trap — false raises the runtime panic with the message. Only needed
    /// so `|test` blocks lower; the differential harness never executes
    /// them.
    case assertCall(condition: HIRExpr, message: HIRExpr?)

    // MARK: G15 file IO

    /// `writeFile(path, content)` (G15) — fopen("w") / fwrite / fclose.
    /// Value expression; the legacy emitter yields the fclose i32 result.
    case fileWrite(path: HIRExpr, content: HIRExpr)
    /// `readFile(path)` (G15) — fopen("r") / fread into a 64 KiB stack
    /// buffer / fclose, yielding the buffer pointer as a String. The
    /// buffer size cap is the legacy emitter's (LLI's JIT makes
    /// fseek/ftell/fstat unreliable), so the corpus stays well under it.
    case fileRead(path: HIRExpr)

    // MARK: G17 builtins

    /// `readLine()` (G17) — one stdin line, yielded as a String. Mirrors the
    /// legacy emitter byte for byte: `fgets` into a 256-byte stack buffer and
    /// the buffer pointer as the value, so a trailing newline is NOT stripped.
    /// The interpreter's `readLine()` does strip it; that divergence predates
    /// this grid (the flip preserves the legacy behaviour) and is registered
    /// in the rewrite plan — the differential fixture injects newline-free
    /// stdin, the slice on which byte parity holds.
    case readLine
    /// `is_ascii_digit(s)` (G17) — first byte in ASCII [0-9]. C-string
    /// semantics: the empty string reads its NUL terminator and is false,
    /// matching the interpreter's "first grapheme" rule inside the ASCII
    /// domain (outside it the interpreter's grapheme model takes over and the
    /// remaining Unicode predicates stay fail-loud, ADR-019 D4).
    case isAsciiDigit(argument: HIRExpr)

    // MARK: G9 string deepening

    /// `s.upper()` / `s.lower()` (G9) — byte-wise toupper/tolower over a
    /// memcpy'd copy (the receiver stays untouched).
    case stringCase(isUpper: Bool, receiver: HIRExpr)
    /// `s.contains(needle)` (G9) — `strstr != null`, byte semantics.
    case stringContains(receiver: HIRExpr, needle: HIRExpr)
    /// `s.substring(start, length)` (G9) — memcpy out of the receiver.
    case stringSubstring(receiver: HIRExpr, start: HIRExpr, length: HIRExpr)
    /// `s.split(delim)` (G9) — a REAL `Array<String>` (interpreter parity,
    /// unlike the legacy emitter which renders a formatted string): strtok
    /// loop feeding bk_array_create/set with strdup'd tokens.
    case stringSplit(receiver: HIRExpr, delim: HIRExpr, type: HIRType)
    /// `arr.join(sep)` (G9) — string-array elements strcat'd with sep.
    case arrayJoin(receiver: HIRExpr, separator: HIRExpr)
    /// `s1 + s2` string concatenation (G9) — malloc'd join of the two
    /// C strings (byte semantics, matching the sunk concat channel).
    case stringConcat(lhs: HIRExpr, rhs: HIRExpr)
    /// String interpolation `"x=\(expr)"` (G9): parts are already-lowered
    /// expressions of scalar/string/array types; each converts to a C
    /// string and pieces strcat into a stack buffer. F64 renders via
    /// bk_double_to_string (shortest round-trip — LR-8; the legacy emitter
    /// still uses %f here and diverges from the interpreter).
    case interpString(parts: [HIRExpr])

    // MARK: G13 batch 1 — LazyRef

    /// `LazyRef<T>(closure)` (G13): creates the once-evaluated handle via
    /// `bk_lazyref_create(wrapper, code, env, bytes, tag)`. `closure` is the
    /// lowered initializer fat pointer; the wrapper (per element type,
    /// deduplicated) is buffered at module end by the emitter.
    case lazyRefConstruct(closure: HIRExpr, type: HIRType)
    /// `handle.value` (G13): `bk_lazyref_value(handle)` returns the cached
    /// element box; the caller loads the element type out of it.
    case lazyRefValue(handle: HIRExpr, type: HIRType)
}

/// One nominal type declaration (G3): layout + lowered field defaults +
/// methods (each already self-parameterized, IR name mangled).
public struct HIRTypeDecl: Equatable {
    public struct Field: Equatable {
        public let name: String
        public let type: HIRType
        public let defaultValue: HIRExpr?

        public init(name: String, type: HIRType, defaultValue: HIRExpr?) {
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
        }
    }

    public let name: String
    public let isObject: Bool
    public let fields: [Field]
    public let methods: [HIRFunction]

    public init(name: String, isObject: Bool, fields: [Field], methods: [HIRFunction]) {
        self.name = name
        self.isObject = isObject
        self.fields = fields
        self.methods = methods
    }
}

/// One dictionary literal entry (G5). A struct because Swift tuples cannot
/// carry conditional Equatable conformance for the HIR tree.
public struct HIRDictEntry: Equatable {
    public let key: HIRExpr
    public let value: HIRExpr

    public init(key: HIRExpr, value: HIRExpr) {
        self.key = key
        self.value = value
    }
}

/// One reference capture of a closure (G6): the captured outer variable's
/// name and declared type. The env field stores a pointer to the variable's
/// storage slot (reference capture — later writes to the outer variable are
/// visible through the closure, interpreter currentEnv parity).
public struct HIRCapture: Equatable {
    public let name: String
    public let type: HIRType

    public init(name: String, type: HIRType) {
        self.name = name
        self.type = type
    }
}

/// One match arm (G2 general case skeleton). `caseName` is the enum-case
/// name the scrutinee's tag is compared against ("some" / "none" for an
/// Optional scrutinee; user enum cases via the same node — G4). `bindings`
/// are the per-payload variable names (`nil` = `_` placeholder), positional
/// by payload index; the arm body sees them as scoped variables.
public struct HIRMatchCase: Equatable {
    public let caseName: String
    public let bindings: [String?]
    public let body: [HIRStmt]

    public init(caseName: String, bindings: [String?], body: [HIRStmt]) {
        self.caseName = caseName
        self.bindings = bindings
        self.body = body
    }
}

/// for-in iterable family (G15): the container kind decides which runtime
/// accessor reads element `i` — `bk_array_get` / `bk_set_at` for 1-field
/// patterns, `bk_dict_key_at` / `bk_dict_val_at` for 2-field `(k, v)`.
public enum HIRForIterableKind: Equatable {
    case array, set, dict
}

/// Typed statement tree (slice set).
public indirect enum HIRStmt: Equatable {
    /// Variable slot. Emitting allocates the slot; a non-nil initializer
    /// stores into it right after allocation.
    case allocVar(name: String, type: HIRType, mutable: Bool, initializer: HIRExpr?)
    /// Store into an existing variable; `type` is the declared variable type.
    case storeVar(name: String, type: HIRType, value: HIRExpr)
    case ifStmt(condition: HIRExpr, thenBody: [HIRStmt], elseBody: [HIRStmt]?)
    /// `while cond: body [step: block]`. The step block (ADR-014) runs once
    /// per iteration after the body — on normal completion *and* on
    /// unlabeled `continue` (interpreter parity); `break` skips it.
    case whileStmt(condition: HIRExpr, body: [HIRStmt], step: [HIRStmt]?)
    /// `for (pattern,) in iterable: body [step: block]` (G15).
    /// `kind` selects the runtime accessor family; `elementTypes` are
    /// parallel to `pattern` (`"_"` entries still occupy a slot and carry
    /// the slot's type). Break/continue follow the same step contract as
    /// whileStmt.
    case forInStmt(
        pattern: [String],
        elementTypes: [HIRType],
        kind: HIRForIterableKind,
        iterable: HIRExpr,
        body: [HIRStmt],
        step: [HIRStmt]?
    )
    /// Slice set: single-value return; nil for void functions.
    case returnStmt(value: HIRExpr?)
    case exprStmt(HIRExpr)
    /// `defer stmt` (G9): the wrapped statements run LIFO when the
    /// enclosing block scope exits (each loop-iteration end included).
    /// Emission runs them at normal block end; break/return interplay is
    /// not in the corpus (unexercised = ungated surface, recorded).
    case deferStmt(body: [HIRStmt])
    /// `try operand else errorVar: handler` (ADR-032). The operand's type is
    /// `result(ok:)`; the error path binds the type-erased error word to
    /// `errorVar` and runs `handler`. `okTarget` is set for expression
    /// position (the ok payload is stored into that variable); nil for
    /// statement position.
    case tryStmt(operand: HIRExpr, errorVar: String, handler: [HIRStmt], okTarget: String?, type: HIRType)
    /// Subscript store `container[index] = value` (G2). The container may be
    /// a nested subscript chain (the emitter walks the COW split chain);
    /// compound assignment (`a[i] += k`) lowers to read-modify-write with the
    /// same node. `elementType` is the boxed element's static type.
    case subscriptStore(container: HIRExpr, index: HIRExpr, value: HIRExpr, elementType: HIRType)
    /// `break` (G2; labeled form G15). `depth` = how many enclosing loops to
    /// unwind (1 = innermost). Labeled `break outer` lowers to the depth the
    /// lowerer resolved from the label stack (ADR-014). An *unresolvable*
    /// target (bare break with no enclosing loop, or a label that matches no
    /// enclosing loop) lowers to `panicStmt` instead — the interpreter lets
    /// the signal escape and errors at the top level, so this is fail-loud
    /// parity, not a silent skip.
    case breakStmt(depth: Int)
    /// `continue` (G15). `depth` mirrors breakStmt: 1 = innermost loop's
    /// condition re-test; N = the depth-th enclosing loop's header (labeled
    /// continue, ADR-014). Unresolvable targets panic like break.
    case continueStmt(depth: Int)
    /// Unconditional runtime trap with a fixed message (G15). Emitted for
    /// control-flow escapes the interpreter only detects at run time
    /// (break/continue outside any loop). The block is terminated.
    case panicStmt(message: String)
    /// `match scrutinee: case name(binding): body ...` (G2 general skeleton).
    /// The scrutinee type decides the tag ABI: Optional arms compare the
    /// `{ i64, T }` tag (some=0, none=1); enum scrutinees join their own grid
    /// through the same node. Unmatched scrutinee values panic at runtime
    /// (interpreter matchNotExhaustive parity).
    case matchStmt(scrutinee: HIRExpr, cases: [HIRMatchCase], scrutineeType: HIRType)
    /// Nominal field store `base.field = value` (G3). GEP + store through
    /// the base pointer; objects offset past the refcount header.
    case fieldStore(base: HIRExpr, field: String, value: HIRExpr, fieldType: HIRType)
    /// `capture name` (G6): a marker statement inside a closure body. The
    /// capture itself is resolved at the closure-literal creation point
    /// (HIRLowerer free-variable analysis mirrors the checker's G29 set),
    /// so this lowers to nothing — it exists so the statement kind is
    /// accepted inside lowered closure bodies rather than gated.
    case captureMarker(name: String)
}
