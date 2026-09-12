import Foundation

/// Runs a lowered `HIRModule` directly — the third live channel of the LR-4
/// unification, alongside the AST interpreter and HIR → LLVM.
///
/// WHY THIS EXISTS
///
/// The HIR was built to serve the LLVM backend alone (LR-2/LR-3). LR-4 makes it
/// the single IR for *every* backend, so that "the same program means the same
/// thing on every channel" stops being an assumption and becomes testable: this
/// engine and the AST interpreter run the same source, and their output is
/// compared byte for byte. Structure-level trust comes from the HIR contract
/// (ADR-034); execution-level trust comes from that
/// cross-check. Neither replaces the other.
///
/// SCOPE — P1-2 SKELETON
///
/// Two properties, deliberately kept apart:
///
/// 1. **Coverage is a compile-time fact.** Every node in the contract is
///    *dispatched* here, with no `default:`. Adding a case to `HIRExpr` or
///    `HIRStmt` breaks this file until the node is acknowledged, which is what
///    `tools/hir-contract-check.py` asserts from the outside.
/// 2. **Only the minimal core is *implemented*.** The four scalar constants,
///    `load`, `binary`, `unary`, `call`, `printCall`, and the statements
///    `allocVar` / `storeVar` / `ifStmt` / `whileStmt` / `returnStmt` /
///    `exprStmt`. Everything else fails loud (`notImplemented`) naming the node.
///    A silent `.null` would make this engine look finished and let the
///    differential probes compare against a fiction.
///
/// SEMANTIC PARITY
///
/// Value rendering and operator semantics are **not** re-implemented here: they
/// are `Interpreter.stringifyValue` / `binaryValue` / `unaryValue`, extracted to
/// statics in P1-2 for exactly this reuse. There is one place where "what `+`
/// does" and "what a value prints as" are decided, so the channels cannot drift.
/// What stays here is the HIR's own knowledge: which interpreter operator an
/// `HIRBinaryOp` corresponds to (`operatorFor`).
///
/// Execution shape mirrors the interpreter's statement layer as well:
///
/// - Block bodies do **not** push a variable scope — the interpreter's
///   `executeBlock` does not either, so a `let` inside an `if` body leaks to the
///   enclosing function body on both channels. Copied, not fixed: parity first,
///   adjudication later.
/// - A function body that runs off its end yields the value of its last
///   expression statement (`.null` if it has none) — the interpreter's
///   `lastValue` rule in `executeFunctionBody`.
/// - `while`'s step block runs after the body on normal completion *and* on an
///   unlabeled `continue`; an unlabeled `break` returns without running it
///   (ADR-014, `Interpreter.executeWhile`).
///
/// REGISTERED GAPS AT THIS STAGE
///
/// - **No positions.** HIR nodes carry no `SourceLocation` (the type is
///   position-free by design; the LLVM path reports positions at *lowering*
///   time). Every `RuntimeError` case requires one, so diagnostics from here
///   point at `noLocation` — a placeholder, not a line number.
/// - **No struct value-copy.** `Interpreter.copyIfStruct` is an instance method,
///   so `allocVar` does not apply the struct copy rule yet. No struct node is
///   implemented here, so nothing observable depends on it yet.
/// - **No scoped blocks / defer.** P1-2 has no block-scope or defer-stack
///   concept; the statements that need them fail loud.
///
/// This is grid P1-2 of the LR-4 interpreter unification: the HIR (ADR-034)
/// gains an execution engine that is not the LLVM emitter.
///
/// Its debug surface conforms to `DebugHookHost`, the same shape the AST
/// interpreter exposes — see the `debugHook` property for why that surface is
/// declared while still unwired.
public final class HIRExecutor: DebugHookHost {

    // MARK: - Host surface

    /// Line output channel. Mirrors `Interpreter.outputSink` so a caller can
    /// redirect both engines' stdout through the same funnel and diff them.
    public var outputSink: (String) -> Void = { line in print(line) }

    /// Debug pause hook — the other half of the surface `DebugHookHost` names,
    /// and the same type the interpreter exposes.
    ///
    /// **Declared but not wired** (P1-5 S1). Nothing in this engine consults it,
    /// because the HIR carries no source position — see the class header's "no
    /// positions" gap. A pause site here today would have to report
    /// `noLocation`, and the debugger matches a breakpoint by line equality, so
    /// no breakpoint could ever fire while entry-stop and stepping would stop at
    /// a line that does not exist. That is a debugger lying about where the
    /// program is, which is worse than a debugger that is not there yet.
    ///
    /// The surface is declared now so that the debugger subsystem is already
    /// engine-agnostic when positions land: wiring this becomes a call at the
    /// statement loop plus nothing else. The dormancy is asserted by
    /// `HIRExecutorTests`, so adding that call before positions exist fails a
    /// test instead of shipping silently.
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    // MARK: - Module state

    /// Module-level functions by name. The HIR carries no closures at module
    /// level: `main` and its peers are the only callables (G6 closure values are
    /// a separate node family, not implemented yet).
    private var functions: [String: HIRFunction] = [:]
    private var types: [String: HIRTypeDecl] = [:]
    private var enums: [String: HIREnumDecl] = [:]

    private let globalEnv: Environment
    private var currentEnv: Environment

    /// Call-depth guard, same value as the interpreter's (`Interpreter.maxCallDepth`).
    ///
    /// Unbounded recursion must end in a diagnosable error, not in a thread-stack
    /// smash with no output — that failure mode is exactly G-P9 (SIGSEGV,
    /// unbounded recursion) and a new execution path must not reintroduce it.
    private var callDepth = 0
    private static let maxCallDepth = 120

    public init() {
        let env = Environment()
        self.globalEnv = env
        self.currentEnv = env
    }

    // MARK: - Entry points

    /// Register a module without running it. Mirrors
    /// `Interpreter.prepare(module:)`; lower-then-run is *not* folded into one
    /// call on purpose — lowering stays the caller's explicit step
    /// (`HIRLowerer.lower(module:typeInference:)`), same split as the
    /// interpreter taking an already-checked AST.
    public func prepare(module: HIRModule) {
        for function in module.functions { functions[function.name] = function }
        for decl in module.types { types[decl.name] = decl }
        for decl in module.enums { enums[decl.name] = decl }
    }

    /// Run a module's `main`, mirroring `Interpreter.run(module:)`.
    public func run(module: HIRModule) throws {
        prepare(module: module)
        try executeMain()
    }

    private func executeMain() throws {
        guard let main = functions["main"] else {
            throw RuntimeError.mainNotFound(location: HIRExecutor.noLocation)
        }
        _ = try call(main, args: [])
    }

    // MARK: - Diagnostics

    /// Placeholder position for every diagnostic out of this engine.
    ///
    /// The file name says `<hir>` rather than `""` so that a diagnostic cannot be
    /// mistaken for one with a real (if empty) file attached. See the class
    /// header's "no positions" gap.
    static let noLocation = SourceLocation(line: 0, column: 0, fileName: "<hir>")

    /// Fail loud on a node that is dispatched but not executed yet.
    ///
    /// The node's name is in the message because visibility *is* the feature:
    /// this is how a probe run tells "the engine cannot do this yet" apart from
    /// "the engine did this and got it wrong".
    private func notImplemented(_ node: String) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "HIR executor: node '\(node)' is dispatched but not implemented yet "
                + "(P1-2 skeleton)",
            location: HIRExecutor.noLocation
        )
    }

    // MARK: - Expressions

    private func evaluate(_ expr: HIRExpr) throws -> Value {
        switch expr {

        // MARK: Scalar constants
        // All integer widths collapse onto one runtime `int`, exactly as the
        // interpreter models them (HIRType.u8/i8/u64 are ABI widths, not runtime
        // distinctions) — so `intConst` ignores its carried type here.

        case .intConst(let value, _):
            return .int(value)

        case .floatConst(let value):
            return .float(value)

        case .boolConst(let value):
            return .bool(value)

        case .stringConst(let value):
            return .string(value)

        case .load(let name, _):
            return try currentEnv.get(name: name)

        case .binary(let op, let lhs, let rhs, _):
            guard let mapped = HIRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: binary operator '\(op)' has no interpreter "
                        + "counterpart (min/max are builtin calls on the AST channel)",
                    location: HIRExecutor.noLocation
                )
            }
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            return try Interpreter.binaryValue(left, mapped, right)

        case .unary(let op, let operand, _):
            guard let mapped = HIRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: unary operator '\(op)' has no interpreter "
                        + "counterpart (`abs` is a builtin call on the AST channel)",
                    location: HIRExecutor.noLocation
                )
            }
            return try Interpreter.unaryValue(mapped, try evaluate(operand))

        case .call(let name, let arguments, _):
            guard let target = functions[name] else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: no module-level function named '\(name)' "
                        + "(stdlib methods are resolved through the interpreter's Pini-source "
                        + "member table and have no HIR surface yet)",
                    location: HIRExecutor.noLocation
                )
            }
            let args = try arguments.map { try evaluate($0) }
            return try call(target, args: args)

        case .printCall(let argument):
            // Mirrors the interpreter's `print` funnel for the one-argument form:
            // stringify, then hand the whole line to the sink at once.
            outputSink(Interpreter.stringifyValue(try evaluate(argument)))
            return .null

        // MARK: Collections (grid G4)

        case .arrayLiteral(let elements, _):
            // Source order, one fresh array. No `copyIfStruct` here: the
            // interpreter applies it at the *binding* sites (`varDecl`, member
            // assignment), not while building a literal.
            return .array(try elements.map { try evaluate($0) })

        case .dictLiteral(let entries, _):
            // Entry order as written; the formatting of `print(dict)` follows it.
            return .dictionary(try entries.map { entry in
                (try evaluate(entry.key), try evaluate(entry.value))
            })

        case .setLiteral(let elements, _):
            // Insertion order, first occurrence wins, compared by value — copied
            // from the interpreter's `setLiteral` rather than "improved", because
            // the printed order of `{2, 3, 3, 5}` is an observable result.
            var unique: [Value] = []
            for element in elements {
                let value = try evaluate(element)
                if !unique.contains(value) { unique.append(value) }
            }
            return .set(unique)

        case .subscriptGet(let container, let index, _):
            // The read rules (negative tail-count, out-of-range panics) live in
            // one place only — the interpreter's strategy table. Re-deciding
            // them here is how the two engines would drift apart.
            return try SubscriptReadStrategy.read(
                container: try evaluate(container),
                index: try evaluate(index),
                location: HIRExecutor.noLocation
            )

        case .lenCall(let argument):
            // Shared with the interpreter's `len` builtin — see the note there.
            return try Interpreter.containerLength(try evaluate(argument))

        case .sliceCall(let container, let start, let end, _):
            return try sliceValue(
                container: try evaluate(container),
                start: try evaluate(start),
                end: try evaluate(end)
            )

        // MARK: Tuples (grid G2)

        case .tupleConstruct(let labels, let elements, _):
            // Source order, labels passed through verbatim. A positional literal
            // keeps its `nil` labels — relabelling from a declared annotation is
            // the binding site's rule and is not applied at the literal.
            var values: [Value] = []
            for element in elements { values.append(try evaluate(element)) }
            return .tuple(labels: labels, elements: values)

        case .tupleIndexGet(let base, let index, _):
            // The bound is resolved statically by the lowerer — `.0` and the
            // labelled `.name` form both arrive here as an integer — so this arm
            // only has to agree with the interpreter on what indexing a tuple
            // *means*. It does that by calling the interpreter's rule instead of
            // restating it, which is also what keeps the interpreter's own
            // diagnostic for a base the static type called a tuple and is not.
            return try Interpreter.tupleElement(
                try evaluate(base),
                index: index,
                location: HIRExecutor.noLocation
            )

        // MARK: Not implemented yet — fail loud, named.


        case .resultConstruct: throw notImplemented("resultConstruct")
        case .optionalGet: throw notImplemented("optionalGet")
        case .optionalConstruct: throw notImplemented("optionalConstruct")
        case .construct: throw notImplemented("construct")
        case .enumConstruct: throw notImplemented("enumConstruct")
        case .fieldGet: throw notImplemented("fieldGet")
        case .closureLiteral: throw notImplemented("closureLiteral")
        case .functionValue: throw notImplemented("functionValue")
        case .indirectCall: throw notImplemented("indirectCall")
        case .pointerLoad: throw notImplemented("pointerLoad")
        case .pointerStore: throw notImplemented("pointerStore")
        case .addressOfVar: throw notImplemented("addressOfVar")
        case .printMulti: throw notImplemented("printMulti")
        case .assertCall: throw notImplemented("assertCall")
        case .fileWrite: throw notImplemented("fileWrite")
        case .fileRead: throw notImplemented("fileRead")
        case .readLine: throw notImplemented("readLine")
        case .isAsciiDigit: throw notImplemented("isAsciiDigit")
        case .stringCase: throw notImplemented("stringCase")
        case .stringContains: throw notImplemented("stringContains")
        case .stringSubstring: throw notImplemented("stringSubstring")
        case .stringSplit: throw notImplemented("stringSplit")
        case .arrayJoin: throw notImplemented("arrayJoin")
        case .stringConcat: throw notImplemented("stringConcat")
        case .interpString: throw notImplemented("interpString")
        case .lazyRefConstruct: throw notImplemented("lazyRefConstruct")
        case .lazyRefValue: throw notImplemented("lazyRefValue")
        }
    }

    /// `container.slice(start, end)` — the slice-sugar semantics.
    ///
    /// The AST channel does **not** implement this in Swift: `slice` sank to the
    /// language-level stdlib (`StdlibPini.source`, the `((String))` and
    /// `((Array))` blocks, ADR-020 D2), so its reference implementation is Pini
    /// source this engine cannot run. The bodies below are a native mirror of
    /// that source, and the two are held together by the differential probe
    /// rather than by shared code:
    ///
    /// - an open bound (`none`, or `.null`) means "the whole container" on that
    ///   side, which is how the slice sugar spells `a[:2]` / `a[3:]` / `a[:]`;
    /// - an integer bound is tail-counted when negative;
    /// - both bounds are clamped to `[0, len]`, and `hi < lo` yields empty;
    /// - `String` walks **grapheme clusters** (the AST channel's `self[k]` is a
    ///   grapheme subscript), which is the contract (`ADR-019 D1`). The LLVM side
    ///   still slices bytes — the registered B-group deviation, and not something
    ///   to "align" from this engine.
    private func sliceValue(container: Value, start: Value, end: Value) throws -> Value {
        switch container {
        case .array(let elements):
            let lower = try sliceBound(start, count: elements.count, defaultWhenOpen: 0)
            let upper = try sliceBound(end, count: elements.count, defaultWhenOpen: elements.count)
            let lo = Swift.max(0, Swift.min(lower, elements.count))
            let hi = Swift.max(0, Swift.min(upper, elements.count))
            return .array(lo < hi ? Array(elements[lo..<hi]) : [])

        case .string(let text):
            let characters = Array(text)
            let lower = try sliceBound(start, count: characters.count, defaultWhenOpen: 0)
            let upper = try sliceBound(end, count: characters.count, defaultWhenOpen: characters.count)
            let lo = Swift.max(0, Swift.min(lower, characters.count))
            let hi = Swift.max(0, Swift.min(upper, characters.count))
            return .string(lo < hi ? String(characters[lo..<hi]) : "")

        default:
            throw RuntimeError.invalidOperation(
                reason: "slice needs an Array or String receiver, got \(container)",
                location: HIRExecutor.noLocation
            )
        }
    }

    /// One slice bound: `none` / `.null` is the open form; an integer is
    /// tail-counted when negative; anything else is rejected. Mirrors
    /// `StdlibPini`'s per-bound `match` and the interpreter's `sliceBound`.
    private func sliceBound(_ bound: Value, count: Int, defaultWhenOpen: Int) throws -> Int {
        if case .enumValue(let optional) = bound, optional.caseName == "none" {
            return defaultWhenOpen
        }
        if case .null = bound { return defaultWhenOpen }
        guard case .int(let offset) = bound else {
            throw RuntimeError.invalidOperation(
                reason: "slice bound must be an integer or the open-bound none, got \(bound)",
                location: HIRExecutor.noLocation
            )
        }
        return offset < 0 ? count + offset : offset
    }

    /// `HIRBinaryOp` → `BinaryOperator`, or nil when the AST channel serves the
    /// operation through a builtin call instead of an operator.
    ///
    /// This mapping is HIR vocabulary and lives here; the *meaning* of each
    /// operator lives in `Interpreter.binaryValue`, so the two channels cannot
    /// drift into two semantics.
    static func operatorFor(_ op: HIRBinaryOp) -> BinaryOperator? {
        switch op {
        case .add: return .plus
        case .subtract: return .minus
        case .multiply: return .multiply
        case .divide: return .divide
        case .modulo: return .modulo
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .lessThan: return .lessThan
        case .lessThanOrEqual: return .lessThanOrEqual
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqual: return .greaterThanOrEqual
        case .bitwiseAnd: return .bitwiseAnd
        case .bitwiseOr: return .bitwiseOr
        case .bitwiseXor: return .bitwiseXor
        case .leftShift: return .leftShift
        case .rightShift: return .rightShift
        // G9 min/max lower to LLVM selects; the interpreter reaches them as
        // builtin function calls, so there is no operator to map onto.
        case .minOf, .maxOf: return nil
        }
    }

    /// `HIRUnaryOp` → `UnaryOperator`; see `operatorFor(_ op: HIRBinaryOp)`.
    static func operatorFor(_ op: HIRUnaryOp) -> UnaryOperator? {
        switch op {
        case .negate: return .minus
        case .logicalNot: return .not
        // G9 `abs` is a builtin call on the AST channel, not a unary operator.
        case .abs: return nil
        }
    }

    // MARK: - Statements

    /// Runs a statement list in order, yielding the value of the last expression
    /// statement (`.null` when there is none).
    ///
    /// This is the interpreter's `lastValue` rule from `executeFunctionBody`, and
    /// it is why control-flow bodies and function bodies can share one runner: a
    /// body that is not a function body simply discards the result.
    @discardableResult
    private func executeStatements(_ statements: [HIRStmt]) throws -> Value {
        var lastValue: Value = .null
        for statement in statements {
            if case .exprStmt(let expr) = statement {
                lastValue = try evaluate(expr)
            } else {
                try execute(statement)
            }
        }
        return lastValue
    }

    private func execute(_ statement: HIRStmt) throws {
        switch statement {

        case .allocVar(let name, let type, let mutable, let initializer):
            // Registered even without an initializer, as `.null` — the
            // interpreter's `varDecl` does the same, so an uninitialized read is
            // a value, not an "undefined variable" error, on both channels.
            var value = try initializer.map { try evaluate($0) } ?? .null
            // G2: binding-site relabel — the second of the interpreter's two
            // label rules (`applyTypeAnnotationLabels`, which its `varDecl`
            // calls). A value bound to a slot type that names components
            // adopts those names; the declaration is the only thing that can
            // supply them, since the literal wrote `(3, 2)` and meant it.
            //
            // The test is "the slot type names at least one component", not
            // "the label array is non-empty": an unlabelled tuple type still
            // carries one entry per field (`[nil, nil]`), and relabelling with
            // those nils would *wipe* names the value already had. Which slot
            // types arrive here named is decided at lowering time
            // (`HIRLowerer.slotType`), because only there is the initializer's
            // static type still visible — the deciding fact is whether the
            // declaration names more than the value-producing expression's own
            // type does, and two bindings otherwise identical can differ on it.
            //
            // Synthetic allocVars (destructure slots, loop variables, try
            // targets) carry types derived from the value itself, so their
            // labels already agree and this is a no-op for them.
            if case .tuple(let labels, _) = type, labels.contains(where: { $0 != nil }) {
                value = Interpreter.relabelled(value, with: labels)
            }
            currentEnv.define(name: name, value: value, isMutable: mutable)

        case .storeVar(let name, _, let value):
            try currentEnv.assign(name: name, value: try evaluate(value))

        case .ifStmt(let condition, let thenBody, let elseBody):
            if try evaluateCondition(condition) {
                try executeStatements(thenBody)
            } else if let elseBody = elseBody {
                try executeStatements(elseBody)
            }

        case .whileStmt(let condition, let body, let step):
            try executeWhile(condition: condition, body: body, step: step)

        case .returnStmt(let value):
            throw ControlSignal.returnSignal(try value.map { try evaluate($0) })

        case .exprStmt(let expr):
            // Dropped here; `executeStatements` is what captures it as the body's
            // result value on the path where that matters.
            _ = try evaluate(expr)

        case .captureMarker(let name):
            // Not "unimplemented": the contract says this node lowers to nothing.
            // Captures are resolved at the closure-literal creation point by
            // free-variable analysis, and the interpreter's `captureStatement` is
            // likewise a no-op (H-1: `capture` is a static purity declaration).
            // Failing loud here would misreport a defined no-op as a gap.
            _ = name

        case .subscriptStore(let container, let index, let value, _):
            // Order copied from the interpreter's `.assign` on a subscript target:
            // the VALUE is evaluated first, then the index, then the container
            // chain. Side-effecting subexpressions (a call that prints) can
            // observe the order, so it is mirrored rather than chosen.
            let newValue = try evaluate(value)
            let targetIndex = try evaluate(index)
            try storeSubscript(target: container, index: targetIndex, newValue: newValue)

        // MARK: Not implemented yet — fail loud, named.

        case .forInStmt: throw notImplemented("forInStmt")
        case .deferStmt: throw notImplemented("deferStmt")
        case .tryStmt: throw notImplemented("tryStmt")
        case .breakStmt: throw notImplemented("breakStmt")
        case .continueStmt: throw notImplemented("continueStmt")
        case .panicStmt: throw notImplemented("panicStmt")
        case .matchStmt: throw notImplemented("matchStmt")
        case .fieldStore: throw notImplemented("fieldStore")
        }
    }

    /// `target[index] = newValue`, with the container value semantics the
    /// interpreter uses: containers are values, so one write yields a **new**
    /// container that is rebound at every level of the chain.
    ///
    /// Mirrors `Interpreter.writeSubscript` arm for arm:
    ///
    /// - variable target → rebind through `Environment.assign`, so an immutable
    ///   binding is rejected here for the same reason and with the same error;
    /// - nested target → write into the inner container, then recursively store
    ///   that new inner value at the enclosing level. The inner index is
    ///   evaluated *before* the inner container and therefore twice in total —
    ///   that double evaluation is the interpreter's shape, kept as-is.
    ///
    /// The LLVM side reaches the same observable state by a different mechanism
    /// (top-down COW: `bk_handle_ensure_unique` on the root slot, in-place
    /// `*_ensure_unique_at` for the intermediate levels). The two chains are
    /// compared on the output, not on the mechanism.
    private func storeSubscript(target: HIRExpr, index: Value, newValue: Value) throws {
        switch target {
        case .load(let name, _):
            let current = try currentEnv.get(name: name)
            let updated = try SubscriptWriteStrategy.write(
                container: current,
                index: index,
                newValue: newValue,
                location: HIRExecutor.noLocation
            )
            try currentEnv.assign(name: name, value: updated)

        case .subscriptGet(let inner, let innerIndex, _):
            let innerIndexValue = try evaluate(innerIndex)
            let innerContainer = try evaluate(target)
            let updated = try SubscriptWriteStrategy.write(
                container: innerContainer,
                index: index,
                newValue: newValue,
                location: HIRExecutor.noLocation
            )
            try storeSubscript(target: inner, index: innerIndexValue, newValue: updated)

        default:
            // `obj.field[i] = v` needs a field write-back, which the interpreter
            // reaches through its `.member` arm. That is the named-field grid's
            // job (`fieldStore`), so it fails loud here instead of silently
            // writing into a copy.
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: subscript store target is neither a variable nor a "
                    + "nested subscript (field targets arrive with fieldStore)",
                location: HIRExecutor.noLocation
            )
        }
    }

    /// Evaluate a condition and insist on `Bool`, mirroring the interpreter's
    /// `guard case .bool` at both `executeIfBody` and `executeWhile` (a non-bool
    /// condition is a `typeMismatch`, not a truthiness coercion).
    private func evaluateCondition(_ expr: HIRExpr) throws -> Bool {
        let value = try evaluate(expr)
        guard case .bool(let flag) = value else {
            throw RuntimeError.typeMismatch(
                expected: "bool",
                got: "\(value)",
                location: HIRExecutor.noLocation
            )
        }
        return flag
    }

    /// Mirrors `Interpreter.executeWhile` (ADR-014 step contract):
    ///
    /// - body completes normally → step runs;
    /// - unlabeled `continue` → step runs;
    /// - unlabeled `break` → return without running step;
    /// - a labeled signal or a `return` propagates unchanged (this skeleton has
    ///   no labeled loops, but propagating rather than swallowing keeps the
    ///   shape ready for them).
    private func executeWhile(condition: HIRExpr, body: [HIRStmt], step: [HIRStmt]?) throws {
        while true {
            if try !evaluateCondition(condition) { break }

            do {
                try executeStatements(body)
            } catch let signal as ControlSignal {
                switch signal {
                case .breakSignal(let label) where label == nil:
                    return
                case .continueSignal(let label) where label == nil:
                    break
                default:
                    throw signal
                }
            }

            if let step = step {
                do {
                    try executeStatements(step)
                } catch let signal as ControlSignal {
                    switch signal {
                    case .breakSignal(let label) where label == nil:
                        return
                    case .continueSignal(let label) where label == nil:
                        continue
                    default:
                        throw signal
                    }
                }
            }
        }
    }

    // MARK: - Calls

    /// Call a module-level function.
    ///
    /// Argument binding mirrors `Interpreter.executeFunctionBody`: a fresh
    /// environment hanging off `globalEnv`, parameters bound mutable, `return`
    /// caught here and unwrapped to the returned value (`nil` → `.null`).
    /// The component names a declared return type carries, when it is a named
    /// tuple (`-> (商: I32, 余: I32,)`). A scalar, a positional tuple and a
    /// void return all yield nothing, and `applyReturnLabels` then leaves the
    /// value untouched.
    private static func declaredReturnLabels(_ type: HIRType?) -> [String?] {
        guard let type = type, case .tuple(let labels, _) = type else { return [] }
        return labels
    }

    private func call(_ function: HIRFunction, args: [Value]) throws -> Value {
        guard function.params.count == args.count else {
            throw RuntimeError.arityMismatch(
                expected: function.params.count,
                got: args.count,
                location: HIRExecutor.noLocation
            )
        }

        guard callDepth < HIRExecutor.maxCallDepth else {
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: call depth exceeded \(HIRExecutor.maxCallDepth) "
                    + "(runaway recursion)",
                location: HIRExecutor.noLocation
            )
        }
        callDepth += 1
        defer { callDepth -= 1 }

        let callEnv = Environment(enclosing: globalEnv)
        for (index, param) in function.params.enumerated() {
            callEnv.define(name: param.name, value: args[index], isMutable: true)
        }

        let previousEnv = currentEnv
        currentEnv = callEnv
        defer { currentEnv = previousEnv }

        do {
            return try executeStatements(function.body)
        } catch let signal as ControlSignal {
            if case .returnSignal(let value) = signal {
                // G2: the interpreter's return-site rule, fed from the declared
                // return type instead of the AST's `returnLabels` (the engine
                // has no AST). Only the explicit `return` path is relabelled:
                // an implicit trailing expression is left alone because the
                // interpreter leaves it alone too, and relabelling it here
                // would invent a difference rather than remove one.
                return Interpreter.applyReturnLabels(
                    HIRExecutor.declaredReturnLabels(function.returnType),
                    to: value ?? .null
                )
            }
            throw signal
        }
    }
}
