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

    /// LLVM type spelling used by the emitters.
    public var llvmSpelling: String {
        switch self {
        case .i32: return "i32"
        case .i64: return "i64"
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
        case .i32, .i64, .f64: return true
        case .boolean, .string, .result, .array, .optional, .nominal, .enumeration: return false
        }
    }
}

/// Binary operators in the slice set.
public enum HIRBinaryOp: Equatable {
    case add, subtract, multiply, divide, modulo
    case equal, notEqual, lessThan, lessThanOrEqual, greaterThan, greaterThanOrEqual

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

/// Typed statement tree (slice set).
public indirect enum HIRStmt: Equatable {
    /// Variable slot. Emitting allocates the slot; a non-nil initializer
    /// stores into it right after allocation.
    case allocVar(name: String, type: HIRType, mutable: Bool, initializer: HIRExpr?)
    /// Store into an existing variable; `type` is the declared variable type.
    case storeVar(name: String, type: HIRType, value: HIRExpr)
    case ifStmt(condition: HIRExpr, thenBody: [HIRStmt], elseBody: [HIRStmt]?)
    case whileStmt(condition: HIRExpr, body: [HIRStmt])
    /// Slice set: single-value return; nil for void functions.
    case returnStmt(value: HIRExpr?)
    case exprStmt(HIRExpr)
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
    /// `break` (G2). The emitter targets the nearest enclosing while loop;
    /// with no enclosing loop it lowers to a runtime panic — the interpreter
    /// errors on a bare break that escapes to the top level (probe-verified),
    /// so this is fail-loud parity, not a silent skip.
    case breakStmt
    /// `match scrutinee: case name(binding): body ...` (G2 general skeleton).
    /// The scrutinee type decides the tag ABI: Optional arms compare the
    /// `{ i64, T }` tag (some=0, none=1); enum scrutinees join their own grid
    /// through the same node. Unmatched scrutinee values panic at runtime
    /// (interpreter matchNotExhaustive parity).
    case matchStmt(scrutinee: HIRExpr, cases: [HIRMatchCase], scrutineeType: HIRType)
    /// Nominal field store `base.field = value` (G3). GEP + store through
    /// the base pointer; objects offset past the refcount header.
    case fieldStore(base: HIRExpr, field: String, value: HIRExpr, fieldType: HIRType)
}
