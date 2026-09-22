import Foundation

/// How a `break` / `continue` / `return` leaves the statement layer.
///
/// The HIR carries an unwind **depth** (`breakStmt(depth:)`), never a label: the
/// lowerer resolves labels to depths (标签语法反转) and turns a target it cannot
/// resolve into a `panicStmt`. So this engine's control vocabulary is depths, and
/// it deliberately does *not* reuse the AST channel's `ControlSignal`, whose
/// vocabulary is labels — squeezing a depth into a label field would mean
/// re-deciding the mapping inside every loop, which is how two channels drift
/// apart while both look correct.
enum HIRControlSignal: Error {
    /// Leave the enclosing function with this value; `nil` = void return.
    case returnSignal(Value?)
    /// Unwind `depth` enclosing loops; 1 = the innermost.
    case breakSignal(depth: Int)
    /// Resume the `depth`-th enclosing loop's header; 1 = the innermost.
    case continueSignal(depth: Int)
}

/// The half of a callable that a function *value* cannot carry.
///
/// `Value.function` holds a `FunctionValue`, and a `FunctionValue` holds an AST
/// `Block?` — it has no room for the lowered `[HIRStmt]` a closure body is. So
/// the body lives beside the value, in a table on the executor, and the value
/// keeps only what it is good for here: identity, the environment it closes
/// over, and the name a `print` shows.
///
/// No environment field: a closure's environment is fixed at the moment the
/// closure is created, so it belongs with the value rather than with the body,
/// and two closures over the same body must not share one.
private struct HIRCallableBody {
    /// Parameter names in declaration order — the order the arguments bind in.
    let paramNames: [String]
    let body: HIRBlock
    /// Component labels of a declared named-tuple return; empty when the return
    /// carries none, which is what the return-site rule reads.
    let returnLabels: [String?]
    /// `=>` dispatch: this body runs on a worker thread and its caller receives
    /// a pending Future instead of the body's value.
    ///
    /// A closure body stays false on this channel: the lowered closure node
    /// carries no async flag, and plumbing one in would change the node's shape
    /// for a form no fixture reaches. That is a boundary, not an oversight —
    /// recorded here so the next reader finds it rather than deduces it.
    let isAsync: Bool

    init(paramNames: [String], body: HIRBlock, returnLabels: [String?], isAsync: Bool = false) {
        self.paramNames = paramNames
        self.body = body
        self.returnLabels = returnLabels
        self.isAsync = isAsync
    }
}

/// What one run of a body produced.
///
/// Two outcomes and no third: a body either reached its end, or it stopped at a
/// join and gave the task up. The distinction has to exist *somewhere* above the
/// statement loop, because a caller that cannot tell them apart has no way to
/// leave the worker thread — which is the whole difference between `await` and
/// `wait`.
private enum HIRBodyStep {
    case finished(Value)
    case givenUp(HIRYieldFrame)
}

/// A body that gave its task up, together with everything needed to pick it up.
///
/// WHY THE CONTEXT IS IN HERE
///
/// A suspension returns from the Swift call that was running the body, so every
/// piece of execution state that lived in Swift locals or thread-locals goes away
/// with it. Thread-locals are the sharp edge: giving up does not unwind them the
/// way a normal return does (the enclosing `defer`s in `invokeBodyStep` are
/// deliberately not taken on this path), so if the frame did not carry them, the
/// body would resume with empty call-depth, empty call stack and — worse —
/// an empty defer stack, and its `defer`s would never run.
///
/// The environment is here for the same reason, plus one of its own: it is not
/// actually lost, it is *reachable* from the frame, and the resume path must put
/// back the exact one the body was using rather than one rebuilt from arguments.
private struct HIRYieldFrame {
    /// The callable whose body is part-way through.
    let callable: HIRCallableBody
    /// The statement the body stopped in, counted in that body's statement list.
    let index: Int
    /// Finish the statement at `index` with the awaited value, then carry on.
    let finish: (Value) throws -> Value?
    /// The future this body gave the task up for.
    let awaited: FutureValue
    let env: Environment
    /// The environment to hand back to the caller when the body finally ends.
    ///
    /// In the frame rather than recomputed, because it belongs to the *run* and
    /// not to the body: a resumed run's Swift caller is a continuation, not the
    /// frame that entered the body, so there is nothing left to restore to unless
    /// the value travelled. Getting this wrong is quiet — the body completes and
    /// returns correctly, and only the *next* statement on that thread reads a
    /// stale environment.
    let previousEnv: Environment
    /// The `lastValue` accumulator at the moment of suspension — see
    /// `driveStatements` for why it is part of where the body was.
    let lastValue: Value
    let callDepth: Int
    let callStackNames: [String]
    let deferStack: [[HIRBlock]]
    let currentFuture: FutureValue?
}

/// The statement positions a join may actually give the task up at.
///
/// This is the driver's half of the yield envelope; the lowerer's half is the
/// refusal that keeps anything else from ever arriving here. The two must agree,
/// and the agreement is load-bearing in one direction only: if the lowerer admits
/// a position the driver has no plan for, the join silently degrades to a blocking
/// wait — which is exactly the failure the envelope exists to prevent. So the
/// driver is written as a `switch` with no `default` over the positions it plans
/// for, and anything else falls through to ordinary execution only because the
/// lowerer has already refused it.
///
/// The two halves cover the four shapes the corpus actually uses: a bare
/// statement, a `var` initializer, a `match` scrutinee, and the operand of a
/// try-else. See the proposal's section 7.5.8.2 for the measurement.
private enum HIRYieldPlan {
    /// S1 — the join is the whole expression statement, so its value is the
    /// statement's value.
    case expressionStatement(operand: HIRExpr)
    /// S2 — the join is a `var` initializer.
    case varInitializer(operand: HIRExpr, name: String, type: HIRType, mutable: Bool)
    /// S3 — the join is a `match` scrutinee.
    case matchScrutinee(operand: HIRExpr, cases: [HIRMatchCase])
    /// S4 — the join is the operand of a try-else.
    case tryOperand(operand: HIRExpr, errorVar: String, handler: HIRBlock, okTarget: String?)

    /// The expression whose value is the future: evaluated synchronously, before
    /// any decision to give the task up is made.
    var operand: HIRExpr {
        switch self {
        case .expressionStatement(let operand),
            .varInitializer(let operand, _, _, _),
            .matchScrutinee(let operand, _),
            .tryOperand(let operand, _, _, _):
            return operand
        }
    }
}

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
/// (HIR 契约); execution-level trust comes from that
/// cross-check. Neither replaces the other.
///
/// GRID NUMBERS — TWO SCHEMES, ONE LETTER
///
/// The grids named in this file are the **P2 plan's** node-family grids (G1…G9,
/// the ones P2a and P2b work through in order). They are *not* the grid numbers
/// of the LLVM rewrite plan, which use the same letters for different work, and
/// the two schemes collide head-on: `G2` is "tuples" here and "Array / Optional"
/// there, `G3` is "closures" here and "named types" there, `G6` is the enum
/// family here and the closure family there.
///
/// This file carries 25 grid references. 23 of them mean the P2 scheme; 2 — the
/// `min` / `max` and `abs` notes beside the operator mapping — mean the LLVM
/// one, because they say what the *emitter* does with an operator this engine
/// reaches through a shared interpreter helper. Every reference here now says
/// which scheme it means. The LLVM-side files are deliberately left alone: that
/// scheme has its own home in the rewrite plan, and relabelling it from here
/// would be one file's opinion about another file's plan.
///
/// SCOPE — P1-2 SKELETON
///
/// Two properties, deliberately kept apart:
///
/// 1. **Coverage is a compile-time fact.** Every node in the contract is
///    *dispatched* here, with no `default:`. Adding a case to `HIRExpr` or
///    `HIRStmt` breaks this file until the node is acknowledged, which is what
///    `tools/hir-contract-check.py` asserts from the outside.
/// 2. **Only the delivered node set is *implemented*.** Grids land here a family
///    at a time: P1-2 (the scalar core — the four constants, `load`, `binary`,
///    `unary`, `call`, `printCall`, and `allocVar` / `storeVar` / `ifStmt` /
///    `whileStmt` / `returnStmt` / `exprStmt`), P2a G4 (collections and
///    subscripts), P2a G2 (tuples and their label model), P2a G1 (control flow —
///    `forInStmt`, `deferStmt`, `breakStmt`, `continueStmt`, `panicStmt`, plus
///    the `stringConcat` the defer fixtures need to build their expected string),
///    P2a G6 (enums, Optional, Result and try — `resultConstruct`,
///    `optionalConstruct`, `optionalGet`, `enumConstruct`, `tryStmt`,
///    `matchStmt`, which also carried the two Optional nodes the slice and
///    value-format fixtures reach through, so those fixtures keep corpus
///    coverage rather than validating nothing — decision `D-P2-5`),
///    P2a G5 (nominal types and fields — `construct`, `fieldGet`, `fieldStore`),
///    and P2a G3 (closures and function values — `closureLiteral`,
///    `functionValue`, `indirectCall`).
///    That grid is what makes a struct or object method call observable at all:
///    method dispatch is itself an ordinary `call` whose receiver travels as the
///    first argument (the lowerer mangles `接收者.方法(…)` into `call(方法__类型, …)`),
///    so the grid also had to teach `call` to consult a type-method table after
///    the module-level one. That widening is a **range correction** of the same
///    shape as the `stringConcat` grid P2a G1 turned up.
///    P2a G3 is what makes a *function* a value: until it landed every callable
///    this engine could reach was a declaration it looked up by name, so the call
///    engine could reach was a declaration it looked up by name, so the call
///    path could assume its callee's environment was the global one. A closure
///    carries the environment it was created in, so the grid parameterised that
///    path (`invoke`) rather than adding a second one, and gave function values
///    somewhere to keep a lowered body — `Value.function` holds an AST `Block?`,
///    which is not a shape a lowered body fits into.
///    Everything else failed loud, naming the node, until P2b G9 implemented the
///    last three (`fileWrite` / `fileRead` / `readLine`) and that mechanism went
///    with them. A silent `.null` would have made this engine look finished and
///    let the differential probes compare against a fiction.
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
/// P2a grid G6 added two more shared semantics rather than restating them:
/// `Interpreter.matchArmMatches` ("does this arm fire on this value" — the
/// value-level core the AST pattern predicate, the CPS evaluator and this engine
/// all call) and `Interpreter.builtinGet` (the Optional read rules: negative
/// tail-count, dictionary key equality, out-of-range → `none`). What the HIR
/// knows on its own is only the *shape*: an arm is "literal, wildcard, or case
/// name" and a `match` scrutinee's static type, both of which the lowerer
/// resolved already.
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
///   (标签语法反转, `Interpreter.executeWhile`).
/// - Control-flow bodies and both `if` branches run through `executeBlock`,
///   which opens a **defer scope** exactly where the interpreter's `executeBlock`
///   does; a function body opens one too, mirroring `executeFunctionBody`. Block
///   bodies still push no *variable* scope — the two are separate on both
///   channels, and only the defer one is new here.
/// - `break` / `continue` carry an unwind **depth**, not a label. This engine
///   consumes depth 1 and rethrows `depth - 1` with the current loop's step
///   skipped — which is exactly what a label mismatch does on the AST channel,
///   so the depth is the same contract expressed in the vocabulary the HIR has.
///
/// REGISTERED GAPS AT THIS STAGE
///
/// - **Positions live on the block, not on the node** (P4-3). `HIRBlock`
///   carries a parallel `positions` array the lowerer fills, so a pause can name
///   the line a statement came from — the same `Statement.location` the
///   interpreter reports. Nodes stay position-free by design (the LLVM path
///   reports positions at *lowering* time), so a `RuntimeError` raised outside a
///   statement loop — and HIR built by hand — still points at `noLocation`,
///   which remains a placeholder rather than a line number.
/// - ~~**No struct value-copy.**~~ ✅ **CLOSED** — re-measured `G-6c`, 2026-09-18.
///   The rule lives in `RuntimeOps.copyIfStruct` and **is** applied at all four
///   sites this entry used to list as missing (`allocVar` / `storeVar` /
///   `fieldStore` / `subscriptStore`). The gap's own minimal witness — `var b = a`
///   on a struct, then `b.x = 99`, then printing `a.x` — printed `99` while the
///   hole was open and prints `1` now. The ticket that carried it is closed with
///   that evidence.
///   ⚠️ One caveat kept rather than tidied away: its *second* witness (a struct
///   written into a struct-typed field) was **not** reproduced during the
///   re-check — the reconstructed fixture is rejected with a type error — so that
///   site rests on the applied call alone, not on a witness.
/// - **`panicStmt`'s text has no cross-channel counterpart.** The node is
///   compiler-generated (an unresolvable `break`/`continue`), and on the AST
///   channel the same program ends in an escaped `ControlSignal` whose top-level
///   rendering is Foundation's, not the language's — so no byte-equality claim
///   is made for it, and the corpus never reaches it (`panic` occurs in the
///   fixtures only inside comments). Gated for "fails loud with its message",
///   registered as an unexercised parity surface.
/// - **The `try` error binding is type-erased on the other channel.** `err` binds
///   the error *payload* here — what the interpreter binds — while the LLVM
///   emitter stores an `i64` word in the err slot and fails loud if it is printed
///   (`E6-004`). Byte-for-byte parity therefore covers every use except printing
///   it. That is the emitter's ABI boundary (LR-12), not a difference to align
///   away from this side.
/// - **`match` exhaustiveness is a checker duty.** A run-time miss on an enum
///   value is `matchNotExhaustive` (the interpreter's rule, and the emitter's
///   `bk_panic`); the engine does not try to prove coverage statically.
///
/// This is grid P1-2 of the LR-4 interpreter unification, extended by
/// P2a G4 (collections), P2a G2 (tuples), P2a G1 (control flow), P2a G6 (enums
/// and the error model), P2a G5 (nominal types and fields) and P2a G3 (closures
/// and function values): the HIR (HIR 契约) gains an execution engine that is not
/// the LLVM emitter.
///
/// Its debug surface conforms to `DebugHookHost`, the same shape the AST
/// interpreter exposes, and both halves of it are live: `outputSink`, and a
/// `debugHook` consulted before each statement on that statement's source line.
public final class HIRExecutor: DebugHookHost {

    // MARK: - Host surface

    /// Line output channel. Mirrors `Interpreter.outputSink` so a caller can
    /// redirect both engines' stdout through the same funnel and diff them.
    public var outputSink: (String) -> Void = { line in print(line) }

    /// Debug pause hook — the other half of the surface `DebugHookHost` names,
    /// and the same type the interpreter exposes.
    ///
    /// Consulted from `executeStatements` before each statement runs: the same
    /// point in the control flow the interpreter uses, with the same context and
    /// the same `.quit` contract. The line comes from that statement's entry in
    /// the block's `positions`, which the lowerer filled from
    /// `Statement.location` — the very thing the interpreter's pause site reads.
    /// The two engines therefore stop on the same lines by construction rather
    /// than by agreement, and `DebuggerTests` asserts it for both engines at once.
    ///
    /// This was declared in P1-5 S1 and deliberately left unwired until
    /// positions existed: a pause that cannot name a line reports `noLocation`,
    /// and since the debugger matches a breakpoint by line equality, no
    /// breakpoint could fire while entry-stop and stepping would stop at a line
    /// that does not exist — a debugger lying about where the program is, which
    /// is worse than a debugger that is not there yet. Wiring it was a call at
    /// the statement loop plus the position carrier, and the dormancy assertion
    /// in `HIRExecutorTests` was inverted when that landed, so the boundary
    /// stays witnessed from both sides rather than being crossed silently.
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    // MARK: - Module state

    /// Module-level functions by name. The HIR carries no closures at module
    /// level: `main` and its peers are the only callables. Closure values are
    /// their own node family and live in `callableBodies` instead.
    ///
    /// Trait default bodies arrive here too: the lowerer materialises them into
    /// module-level functions rather than into a type's method list.
    private var functions: [String: HIRFunction] = [:]

    /// Type methods by **lowered** name (`方法__类型`), flattened out of every
    /// `HIRTypeDecl`.
    ///
    /// A method is not a module-level function and is kept in its own table for
    /// that reason — but a call to one is an ordinary `.call`, because the
    /// lowerer mangles `接收者.方法(…)` into `call(方法__类型, [接收者, …])` and
    /// the receiver travels as the first argument. So this table exists to answer
    /// the question the call node asks, and the two are consulted in that order.
    ///
    /// Keys come from each `HIRFunction.name` as lowered, never re-derived here:
    /// a generic type's methods live under its specialised name (`盒_I32`), and
    /// re-mangling on this side would be a second, drifting source of truth.
    private var methods: [String: HIRFunction] = [:]

    private var types: [String: HIRTypeDecl] = [:]
    /// ADR-001 `P2b`：默认实例的**记忆表**（类型名 → 物化好的实例）。
    ///
    /// 「恰一次」在这里是**自然**的：走查单线 ⇒ 首次取用物化并记住，之后直接返回缓存值。
    /// 与发射层那张「槽位 + 两级锁」的表同一语义，只是一个靠锁、一个靠单线。
    /// ⚠️ 表挂在走查器实例上 ⇒ 生命周期 = 一次运行，与「程序级唯一」在解释器语境下等价
    /// （一次 `run` 就是一个程序）。
    private var givenInstances: [String: Value] = [:]
    private var enums: [String: HIREnumDecl] = [:]

    /// The foreign callees this module declared, from `[名称|foreign]` blocks,
    /// keyed by callee name.
    ///
    /// The gate matters: these names are answered by the shared libc shim
    /// table, and answering them unconditionally would let a program that never
    /// declared `malloc` call it here while the AST channel rejects the same
    /// program. Declared-foreign beats the generic builtin guesses below
    /// because it is the program's own declaration.
    ///
    /// A map and not a set because the second resolution stage needs the
    /// **library**: a shim miss means a raw C binding, resolved with `dlsym`
    /// against the block name (`[ffilib|foreign]` → `libffilib.dylib`), and the
    /// thunk wrapping the address needs the declared signature. A set could
    /// answer "is this foreign" but not "foreign to what, and shaped how".
    private var foreignDecls: [String: (library: String, function: HIRForeignFunction)] = [:]

    /// Library handles for raw C bindings, cached by library name.
    ///
    /// Per engine, not process-wide. The interpreter keeps its own `FFILoader`
    /// on its instance; sharing one handle table between engines would make a
    /// handle's lifetime — and so "when is it safe to close" — a cross-engine
    /// question with no owner. Two engines, two caches, one resolution routine.
    private let ffiLoader = FFILoader()

    /// The package's `[ffi]` table, for `search_paths`.
    private let ffiConfig: FFIConfig

    /// Bodies of the function *values* built while running, keyed by value
    /// identity — see `HIRCallableBody` for why the body cannot travel inside
    /// the value itself.
    ///
    /// Identity is the key, not the name: a closure literal has no name of its
    /// own (`<anon>` is what the parser gives every one of them), so a program
    /// with three closures would have three entries under one key and two of
    /// them would silently call the third's body. Identity is also what this
    /// codebase already means by "the same function value" — `Value.==` decides
    /// two function values are equal exactly when they are the same reference.
    ///
    /// Per-run state, not module state: the values in it are created during
    /// execution, so `prepare` clears it and nothing here survives a run.
    private var callableBodies: [ObjectIdentifier: HIRCallableBody] = [:]

    private let globalEnv: Environment

    /// Where an async body is dispatched (G-3c-1).
    ///
    /// The **blocking** back end, and that is the production semantics rather
    /// than a simplification: the flag that selected the alternative had no
    /// assignment point anywhere in `Sources/` — every assignment lived in the
    /// tests — so no published program ever took anything but the blocking join.
    /// `挂起模式退役` retired that alternative along with the walk it was built on.
    /// This is what the language does; it is not a placeholder for a suspend
    /// branch that has yet to arrive.
    /// Injected rather than hardcoded so a criterion can stand a back end in that
    /// declines to yield. That is not a test seam for its own sake: "a back end
    /// that cannot hand the thread back degrades instead of failing" is a
    /// normative discipline (DE-1 §6.2), and a discipline with no criterion on it
    /// is a sentence, not a rule.
    ///
    /// ⭐ **派发点与语言侧接线**：生产路径上后端**不再硬编码**，而是由语言侧的默认实例
    /// 解析而来（见 `resolveSchedulerFromLanguage`）—— 那就是「派发点用哪个调度器」这条
    /// 语言侧表面的内容。本属性只剩**注入覆盖**这一职：非空时它赢，解析不发生。
    ///
    /// ⚠️ 为什么注入要先于解析：注入是宿主在**构造期**说的，而语言侧实例要到
    /// 模块装载后才取得到。若有注入值仍去解析，判据就再也摆不进一个替身后端 ——
    /// 而「降级而不失败」这条纪律的判据正是那么摆进去的。
    private let injectedScheduler: Scheduler?

    /// 派发点实际用的后端。**只在 `prepare` 里被改写一次** —— 那之后才可能有工作线程
    /// ⇒ 不需要锁。初值取注入值或主后端，故任何路径上它都不是空的。
    private var scheduler: Scheduler

    // MARK: - Per-thread execution state

    /// These four describe *the thread that is executing*, not the engine.
    ///
    /// `=>` dispatch puts a body on a worker thread while its caller waits in the
    /// join, so both are live at once and both touch this state. As plain
    /// instance properties they were correct only while nothing spawned; the
    /// moment one does, they are a shared mutable context. The failure is not
    /// hypothetical: the AST interpreter already paid for it, and its own note
    /// records what it cost (unconditional `+=` / `-=` from worker threads
    /// racing the main thread's, ending in SIGTRAP/SIGSEGV), which is why it
    /// moved the same four behind `ThreadLocal`.
    ///
    /// Wrapping the storage rather than renaming the properties is deliberate:
    /// a computed property over a per-thread box means every existing read and
    /// write kept its shape, so the fix did not have to travel through the whole
    /// file.
    private let currentEnvStorage = ThreadLocal<Environment>()
    private let callDepthStorage = ThreadLocal<Int>()
    private let callStackStorage = ThreadLocal<[String]>()
    private let deferStackStorage = ThreadLocal<[[HIRBlock]]>()

    /// The task this thread runs inside, when it runs inside one.
    ///
    /// Spawn links the new task here, which is what makes the dispatch tree and
    /// the cancellation tree one tree — the same job it does on the AST side.
    /// Thread-local for the same reason as the four below: a worker must not
    /// adopt its caller's task, or a child would be booked under the wrong
    /// parent and the parent's return would cancel the wrong set.
    private let currentFutureStorage = ThreadLocal<FutureValue>()
    private var currentFuture: FutureValue? {
        get { currentFutureStorage.value }
        set { currentFutureStorage.value = newValue }
    }

    /// The environment the current thread is executing in. A thread that has not
    /// entered anything yet reads the global one — a worker's first act is to
    /// enter its own call environment, so the seed is only ever what a read
    /// before any entry deserves.
    private var currentEnv: Environment {
        get { currentEnvStorage.value ?? globalEnv }
        set { currentEnvStorage.value = newValue }
    }

    /// Call-depth guard, same value as the interpreter's (`Interpreter.maxCallDepth`).
    ///
    /// Unbounded recursion must end in a diagnosable error, not in a thread-stack
    /// smash with no output — that failure mode is exactly G-P9 (SIGSEGV,
    /// unbounded recursion) and a new execution path must not reintroduce it.
    private var callDepth: Int {
        get { callDepthStorage.value ?? 0 }
        set { callDepthStorage.value = newValue }
    }
    private static let maxCallDepth = 120

    /// Names of the functions currently entered, innermost last.
    ///
    /// Mirrors `Interpreter.callStackNames` — the list a debugger reads for a
    /// backtrace. Pushed and popped around a body exactly where `callDepth` is,
    /// so the two cannot drift out of step: a depth without a name would be a
    /// backtrace with a hole in it.
    private var callStackNames: [String] {
        get { callStackStorage.value ?? [] }
        set { callStackStorage.value = newValue }
    }

    /// Open defer scopes, innermost last: a scope holds its `defer` statements in
    /// registration order, and each `defer` holds the **group** of statements it
    /// wraps.
    ///
    /// The grouping is what keeps LIFO honest. Popping runs the *groups* in
    /// reverse and, inside one group, its statements in source order; a flat
    /// reversed list would also invert a defer whose body lowered to more than
    /// one node — a difference that only shows up once such a body exists, which
    /// is the worst time to find it.
    private var deferStack: [[HIRBlock]] {
        get { deferStackStorage.value ?? [] }
        set { deferStackStorage.value = newValue }
    }

    /// Directory an unprefixed relative IO path resolves against, mirroring
    /// `Interpreter.programBase`. The emitter already carries this base; the
    /// engine needs it too, or the two channels disagree about which file a
    /// program named with a bare relative path means — and they would disagree
    /// silently, by reading the CWD copy instead of failing.
    ///
    /// Defaulted to nil so an executor that never touches IO behaves exactly as
    /// before, and so the many test hosts that construct one bare keep working.
    private let programBase: String?

    /// P4-1b: 命令行参数（脚本路径之后的裸参数），与解释器的同名属性同义 ——
    /// `argv()` 内建的唯一来源，镜像而不另造。
    public var processArguments: [String] = []

    public convenience init(programBase: String? = nil, ffiConfig: FFIConfig = .default) {
        self.init(programBase: programBase, ffiConfig: ffiConfig, scheduler: nil)
    }

    /// The engine with an explicit back end, or with `nil` and therefore with the
    /// language's own default (see `resolveSchedulerFromLanguage`).
    ///
    /// Production takes the line above with `nil`; passing a back end overrides the
    /// language's choice — which is how a criterion stands in one that answers `0`
    /// to `yieldTask()`. Nothing branches on the difference: the back end answers,
    /// the engine obeys.
    init(programBase: String?, ffiConfig: FFIConfig, scheduler: Scheduler?) {
        self.globalEnv = Environment()
        self.programBase = programBase
        self.ffiConfig = ffiConfig
        self.injectedScheduler = scheduler
        self.scheduler = scheduler ?? GCDScheduler.shared
        // `currentEnv` is deliberately not seeded here. Its per-thread box
        // answers `globalEnv` until a thread enters something, so a seed would
        // be the same value written the hard way — and writing through the
        // computed property during initialisation reads `self` before every
        // stored property is in place, which the compiler refuses outright.
    }

    // MARK: - Entry points

    /// Register a module without running it. Mirrors
    /// `Interpreter.prepare(module:)`; lower-then-run is *not* folded into one
    /// call on purpose — lowering stays the caller's explicit step
    /// (`HIRLowerer.lower(module:typeInference:)`), same split as the
    /// interpreter taking an already-checked AST.
    /// 派发点当前后端的**能力自述**（只读，供诊断与判据）。
    ///
    /// 它是语言侧接线（`resolveSchedulerFromLanguage`）的**读侧**，而这一侧不是可有可无的：
    /// 降级后的程序**结果不变**（那是「语义保持、只降执行策略」的内容）
    /// ⇒ 光看程序的输出，区分不出「声明被读到了」与「引擎根本没理那句声明」。
    /// 没有本属性，「派发点用语言侧那个调度器」这句话就**没有可观测面**。
    var dispatchBackEndCapabilities: ConcurrencyCapabilities { scheduler.capabilities }

    public func prepare(module: HIRModule) throws {
        callableBodies.removeAll()
        for function in module.functions { functions[function.name] = function }
        for decl in module.types {
            types[decl.name] = decl
            for method in decl.methods { methods[method.name] = method }
        }
        for decl in module.enums { enums[decl.name] = decl }
        // One name maps to one declaration. A name declared in two blocks
        // would be ambiguous and the semantic layer already rejects that; were
        // it ever to arrive, last-wins is the rule the function tables use.
        foreignDecls = [:]
        for block in module.foreigns {
            for function in block.funcs {
                foreignDecls[function.name] = (library: block.name, function: function)
            }
        }
        try resolveForeignsEagerly()
        // 派发点的后端由**语言侧**决定（见 `resolveSchedulerFromLanguage`）。解析落在这里，
        // 因为语言侧那份声明要到本模块的类型表装好之后才读得到 —— 构造器里没有它可读。
        // ⇒ 也正因为落在装载期、任何工作线程出现之前，`scheduler` 那个 `var` 不需要锁。
        // 注入值在场时不解析：注入是宿主在构造期说的，而判据正是经它摆进替身后端的。
        if injectedScheduler == nil {
            scheduler = resolveSchedulerFromLanguage()
        }
    }

    /// Resolves every declared foreign symbol now, in the interpreter's order:
    /// the shared libc shim table first, then a raw `dlsym`.
    ///
    /// The interpreter resolves these while registering declarations, so a name
    /// that does not resolve fails there — and `symbolNotFound` is a
    /// registration-time code. Resolving only at the call site instead let the
    /// same program pass silently until its first call, which diverges from the
    /// interpreter on the *failure* behaviour of one program rather than on
    /// what it can do. `FFILoader` caches resolved handles, so the work here is
    /// not repeated by the call sites below.
    ///
    /// The shim table is consulted first for the same reason the call site
    /// does: those names have no C symbol to find, so asking `dlsym` for them
    /// would report a failure for a declaration that is perfectly resolvable.
    private func resolveForeignsEagerly() throws {
        for (name, foreign) in foreignDecls where RuntimeOps.libcShims[name] == nil {
            _ = try ffiLoader.resolve(
                library: foreign.library, symbol: name,
                searchPaths: ffiConfig.searchPaths, location: HIRExecutor.noLocation
            )
        }
    }

    /// Run a module's `main`, mirroring `Interpreter.run(module:)`.
    public func run(module: HIRModule) throws {
        try prepare(module: module)
        try executeMain()
    }

    private func executeMain() throws {
        guard let main = functions["main"] else {
            throw RuntimeError.mainNotFound(location: HIRExecutor.noLocation)
        }
        _ = try call(main, args: [])
    }

    /// Call one module-level function by name.
    ///
    /// `run(module:)` reaches exactly one function and it is always `main`; a
    /// test run reaches every `|test` function instead, so the entry point has
    /// to be per-name rather than fixed. Nothing else differs — same `invoke`,
    /// same argument protocol — which is what makes a test body meet the same
    /// runtime an ordinary call would, rather than a second execution mode.
    ///
    /// The caller must have called `prepare(module:)` first, exactly as for
    /// `run(module:)`; lowering stays the caller's explicit step on this engine.
    public func callFunction(named name: String, args: [Value]) throws -> Value {
        guard let function = functions[name] else {
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: no module-level function named \(name) to call",
                location: HIRExecutor.noLocation
            )
        }
        return try call(function, args: args)
    }

    // MARK: - Diagnostics

    /// Placeholder position for every diagnostic out of this engine.
    ///
    /// The file name says `<hir>` rather than `""` so that a diagnostic cannot be
    /// mistaken for one with a real (if empty) file attached. See the class
    /// header's "no positions" gap.
    static let noLocation = SourceLocation(line: 0, column: 0, fileName: "<hir>")

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
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            // P4-0: min/max lower to HIR operators but reach the interpreter as
            // builtin calls, so they have no operator to map onto. Call the
            // shared builtin instead of failing.
            switch op {
            case .minOf: return try RuntimeOps.builtinMin(left, right)
            case .maxOf: return try RuntimeOps.builtinMax(left, right)
            default: break
            }
            guard let mapped = HIRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: binary operator '\(op)' has no interpreter "
                        + "counterpart (min/max are builtin calls on the AST channel)",
                    location: HIRExecutor.noLocation
                )
            }
            return try RuntimeOps.binaryValue(left, mapped, right)

        case .unary(let op, let operand, _):
            // P4-0: same reason as min/max above -- abs lowers to a HIR unary
            // operator but is a builtin call on the interpreter channel.
            if case .abs = op {
                return try RuntimeOps.builtinAbs(try evaluate(operand))
            }
            guard let mapped = HIRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: unary operator '\(op)' has no interpreter "
                        + "counterpart (`abs` is a builtin call on the AST channel)",
                    location: HIRExecutor.noLocation
                )
            }
            return try RuntimeOps.unaryValue(mapped, try evaluate(operand))

        case .call(let name, let arguments, _):
            // The callee is resolved **before** the arguments are evaluated, so an
            // unknown name is reported without running any argument expression —
            // the same order the interpreter uses.
            //
            // Three kinds of callee reach this node, and the HIR does not
            // distinguish them (the lowerer emits one node shape):
            //
            // - a module-level function, including the trait default bodies the
            //   lowerer materialises into that table;
            // - a type method, mangled into `方法__类型` with the receiver
            //   prepended to the arguments;
            // - a registered builtin (`sqrt`, `abs`, `argv`, the file IO …),
            //   whose bodies live in the interpreter's `if fv.name == …` chain
            //   rather than anywhere in the HIR.
            //
            // The first two are executed here. The third is **not answered, on
            // purpose** — a scope decision of this grid, not an oversight:
            // delegating the callee to a live `Interpreter` would run genuine
            // builtin semantics, file IO included, inside a channel whose own IO
            // semantics are still one of the four unsettled decision grids; and
            // reimplementing a builtin here would be a second definition of it.
            // Two fixtures need a bare builtin (a `sqrt` call) and stay pending
            // because of this — recorded at closeout as a boundary that **no grid
            // of P2a owns**, since the nine grids are divided by node families and
            // this is a callee-resolution rule.
            if let target = functions[name] ?? methods[name] {
                return try call(target, args: try arguments.map { try evaluate($0) })
            }
            // P4-0: sqrt is intrinsic on this channel -- the LLVM side declares
            // @sqrt and the interpreter answers it as a builtin. Call the shared
            // builtin rather than delegating the callee to a live interpreter,
            // which is what the note above rules out.
            // A callee declared in a `[名称|foreign]` block resolves in two
            // stages, and this engine now runs both in the interpreter's order:
            //
            //   ① the libc shim table, shared with the AST channel — one
            //      definition, two engines;
            //   ② otherwise a raw C binding: `dlsym` against the block name,
            //      then a per-signature thunk over the resolved address.
            //
            // Stage ② used to fail loud here, because the loader lived only on
            // the interpreter instance. Running the same chain on both channels
            // is the point of doing it at all: a shim added on one side and not
            // the other, or a symbol resolving differently between them, is
            // exactly the class of divergence this migration exists to remove.
            if let foreign = foreignDecls[name] {
                let args = try arguments.map { try evaluate($0) }
                if let shim = RuntimeOps.libcShims[name] { return try shim(args) }
                let symbol = try ffiLoader.resolve(
                    library: foreign.library, symbol: name,
                    searchPaths: ffiConfig.searchPaths, location: HIRExecutor.noLocation
                )
                let thunk = try ForeignThunk.make(
                    symbol: symbol, name: name,
                    paramTypes: try foreign.function.paramTypes.map { type in
                        guard let annotation = ForeignThunk.annotation(for: type) else {
                            throw RuntimeError.invalidOperation(
                                reason: "HIR executor: foreign callee \(name) has a parameter "
                                    + "type that is not a C top-level type",
                                location: HIRExecutor.noLocation
                            )
                        }
                        return annotation
                    },
                    returnTypes: try foreign.function.returnType.map { type -> [TypeAnnotation] in
                        guard let annotation = ForeignThunk.annotation(for: type) else {
                            throw RuntimeError.invalidOperation(
                                reason: "HIR executor: foreign callee \(name) has a return "
                                    + "type that is not a C top-level type",
                                location: HIRExecutor.noLocation
                            )
                        }
                        return [annotation]
                    } ?? [],
                    location: HIRExecutor.noLocation
                )
                return try thunk(args)
            }
            // P4-0: sin/cos lower to LLVM intrinsics, so the names that arrive here
            // are `llvm.sin.f64` / `llvm.cos.f64` and `tan` arrives as a division
            // between the two. Answer them from the shared trigonometric builtins
            // instead of reporting a missing module-level function.
            if name.hasPrefix("llvm.") {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: intrinsic \(name) expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                switch name {
                case "llvm.sin.f64": return try RuntimeOps.builtinSin(args[0])
                case "llvm.cos.f64": return try RuntimeOps.builtinCos(args[0])
                default:
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: intrinsic \(name) has no interpreter counterpart",
                        location: HIRExecutor.noLocation
                    )
                }
            }
            // G-2a: the character builtins, answered from the same implementation
            // the AST channel calls -- one definition, two engines.
            if let character = RuntimeOps.characterBuiltins[name] {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: \(name) expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                return try character(args)
            }

            // G-3a: the concurrency builtins a plain call can carry, answered from the
            // same table the lowerer's whitelist reads -- one definition, two engines,
            // exactly like the character builtins above.
            //
            // `sleep` blocks this thread and yields nothing; that is the whole of its
            // HIR-side semantics. Its cancellation checkpoints are a no-op here, and
            // deliberately so: this engine is single-threaded and holds no task
            // handle, so there is no context to check against. The shared rule takes
            // the checkpoint as a parameter precisely so the suspension grid can plug
            // a real one in without touching the sleeping loop.
            if let concurrency = RuntimeOps.concurrencyBuiltins[name] {
                let args = try arguments.map { try evaluate($0) }
                return try concurrency(args)
            }

            // G-3c-1: the Future-valued concurrency builtins. They are matched
            // here rather than added to the shared table above because deciding
            // them needs a scheduler and a task handle, which a stateless
            // closure cannot reach — the lowerer matches the same names for the
            // same reason, so the two sides are read together.
            //
            // What they compute lives in `RuntimeOps`: waiting, aggregating and
            // the leaked-failure flip are one definition used by both engines.
            if name == "isCancel" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: isCancel expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                return .bool(RuntimeOps.isCancelErrorValue(args[0]))
            }
            if name == "joinAll" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: joinAll expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                let owner = currentFuture
                return try RuntimeOps.makeJoinAllFuture(
                    argument: args[0],
                    scheduler: scheduler,
                    owner: owner,
                    enterTask: { task in
                        let previous = self.currentFuture
                        self.currentFuture = task
                        return { self.currentFuture = previous }
                    },
                    checkpoint: { try RuntimeOps.checkCancellation($0) }
                )
            }
            if name == "joinWithin" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 2 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: joinWithin expects exactly two arguments",
                        location: HIRExecutor.noLocation
                    )
                }
                guard case .future(let fut) = args[0] else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(args[0]),
                        location: HIRExecutor.noLocation
                    )
                }
                let milliseconds = try requireInt(args[1], for: "joinWithin timeout")
                // A builtin, not a keyword site: `joinWithin` has no `await` form,
                // so it takes the occupying stance by construction.
                return RuntimeOps.joinFuture(fut, timeoutMs: milliseconds, form: .waits)
            }
            if name == "cancel" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: cancel expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                guard case .future(let fut) = args[0] else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(args[0]),
                        location: HIRExecutor.noLocation
                    )
                }
                fut.cancel()
                return .null
            }
            // G-2R: the numeric constructor, answered from the same rule the
            // AST walk uses (`RuntimeOps.builtinF64`) -- one definition, two
            // engines, exactly like the character builtins above.
            if name == "F64" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: F64 expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                return try RuntimeOps.builtinF64(args[0])
            }
            // G-2S: the Array member face (`append` / `last` / `pop`), answered
            // from the same rules the AST walk applies -- one definition, two
            // engines, exactly like the character builtins above. The receiver
            // rides as the first argument.
            if let arrayMethod = RuntimeOps.arrayMethods[name] {
                let args = try arguments.map { try evaluate($0) }
                return try arrayMethod(args)
            }
            if name == "sqrt" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: sqrt expects exactly one argument",
                        location: HIRExecutor.noLocation
                    )
                }
                return try RuntimeOps.builtinSqrt(args[0])
            }
            // P4-1b: 宿主环境查询内建。两行都与解释器的同名内建**逐字同义**（镜像，不另造）：
            // 参数数组直接来自执行器持有的 `processArguments`；模块根即程序基准，
            // 未注入基准时如实返回进程 CWD，不伪造。
            if name == "argv" || name == "moduleRoot" {
                guard arguments.isEmpty else {
                    throw RuntimeError.invalidOperation(
                        reason: "HIR executor: \(name) takes no arguments",
                        location: HIRExecutor.noLocation
                    )
                }
                if name == "argv" {
                    return .array(processArguments.map { .string($0) })
                }
                return .string(programBase ?? FileManager.default.currentDirectoryPath)
            }
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: no module-level function named '\(name)' and no "
                    + "type method lowered under that name. Builtin callees are not "
                    + "answered by this engine (no delegation to the interpreter — see "
                    + "the note on `call`), and stdlib methods are resolved through the "
                    + "interpreter's Pini-source member table with no HIR surface yet",
                location: HIRExecutor.noLocation
            )

        case .printCall(let argument):
            // Mirrors the interpreter's `print` funnel for the one-argument form:
            // stringify, then hand the whole line to the sink at once.
            outputSink(RuntimeOps.stringifyValue(try evaluate(argument)))
            return .null

        // MARK: Collections (P2a grid G4)

        case .arrayLiteral(let elements, _):
            // Source order, one fresh array. No `copyIfStruct` here: the
            // interpreter applies it at the *binding* sites (`varDecl`, member
            // assignment), not while building a literal.
            return .array(try elements.map { try evaluate($0) })

        case .dictLiteral(let entries, _):
            // Entry order as written; the formatting of `print(dict)` follows it.
            return .dictionary(
                try entries.map { entry in
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
            return try RuntimeOps.containerLength(try evaluate(argument))

        case .sliceCall(let container, let start, let end, _):
            return try sliceValue(
                container: try evaluate(container),
                start: try evaluate(start),
                end: try evaluate(end)
            )

        // MARK: Tuples (P2a grid G2)

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
            return try RuntimeOps.tupleElement(
                try evaluate(base),
                index: index,
                location: HIRExecutor.noLocation
            )

        // MARK: Strings

        case .stringConcat(let lhs, let rhs):
            // `s1 + s2` has one meaning, and it is the interpreter's: this arm
            // routes through the same `binaryValue` the `.binary` arm uses, so
            // "what `+` does to two strings" is decided in one place.
            //
            // The node exists separately from `.binary` because the contract
            // sinks concatenation to a byte-semantics channel (contract row 41,
            // group C — same results, different allocation). It is in *this*
            // grid because the defer fixtures build their expected string by
            // concatenating, so the P2a G1 fixtures cannot flip without it.
            return try RuntimeOps.binaryValue(
                try evaluate(lhs), .plus, try evaluate(rhs)
            )

        // MARK: Optional / Result / enum values (P2a grid G6)

        case .resultConstruct(let isOk, let payload, _):
            // Same value the interpreter's `ok` / `err` builtins build — the one
            // `makeResult`, so the two channels cannot disagree on what a Result
            // *is*. The err payload is one type-erased machine word on the LLVM
            // side (LR-12); see the class header's P2a G6 boundary note.
            return RuntimeOps.makeResult(
                caseName: isOk ? "ok" : "err",
                payload: try evaluate(payload)
            )

        case .optionalConstruct(let isSome, let payload, _):
            // The runtime form of an Optional *is* the two cases `some` / `none`
            // (no parent enum), the same value the interpreter builds for a `nil`
            // literal, for `Optional.none`, and for `.get` falling off the end.
            // The open-bound spelling in slice syntax arrives here as `none` too.
            guard isSome else {
                return .enumValue(EnumValue(caseName: "none", associatedValues: []))
            }
            guard let payload = payload else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: optionalConstruct says some but carries no payload",
                    location: HIRExecutor.noLocation
                )
            }
            return .enumValue(EnumValue(caseName: "some", associatedValues: [try evaluate(payload)]))

        case .optionalGet(let container, let index, _):
            // The rule lives in the interpreter (`builtinGet`): negative tail-count,
            // dictionary key equality, out-of-range → `none`. This node is the
            // *named* spelling of `.get(i)` and the lowerer emits it for Array and
            // String only, always the checked arm — hence `checked: true`.
            return try RuntimeOps.builtinGet(
                receiver: try evaluate(container),
                index: try evaluate(index),
                checked: true,
                location: HIRExecutor.noLocation
            )

        case .enumConstruct(let enumName, let caseName, let tag, let payloads, _, _):
            // Associated-value names come from the declaration, matching what the
            // interpreter writes on the constructor value
            // (`fv.params.map { $0.name }`) — the same declaration order, and the
            // same single reader (`match` named bindings; rendering never looks at
            // them, per the project's naming decision).
            guard let enumCase = resolveEnumCase(enumName: enumName, caseName: caseName, tag: tag)
            else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: enum construct '\(enumName).\(caseName)' has no "
                        + "declaration in this module (the lowerer registers it at lowering time)",
                    location: HIRExecutor.noLocation
                )
            }
            return .enumValue(
                EnumValue(
                    caseName: enumCase.name,
                    associatedValues: try payloads.map { try evaluate($0) },
                    paramNames: enumCase.paramNames,
                    parentEnum: enumName
                ))

        // MARK: Nominal instances and their fields (P2a grid G5)

        case .construct(let type):
            return try constructValue(type)

        case .fieldGet(let base, let field, _):
            // The static type travels in the node and is dropped here: the
            // receiver's own value kind decides which field table is read, the
            // way `Interpreter.evaluateMember` decides it.
            return try fieldRead(from: try evaluate(base), field: field)

        // MARK: Closures and function values (P2a grid G3)

        case .closureLiteral(_, let paramNames, _, _, _, let body, _):
            // The node's own closure id and capture list are deliberately unused
            // here, and neither is an oversight. The id is the compiled side's
            // registry key. The capture list describes the env struct a compiled
            // closure carries — but an environment on this side *is* a reference,
            // so hanging the value off the environment current at this point
            // captures every name in scope, by reference, with nothing copied:
            // exactly what `Interpreter`'s own func-literal arm does, and what
            // makes a write to a captured variable after creation stay visible
            // through the closure. Building a capture list into a fresh
            // environment instead would be a second, snapshot-shaped model of
            // the same thing.
            return makeFunctionValue(
                name: "<anon>",
                paramNames: paramNames,
                body: body,
                returnLabels: [],
                closure: currentEnv
            )

        case .functionValue(let name, _):
            // The lowerer builds this node only for a name it resolved in the
            // module's signature table, so a miss here means the module and the
            // engine disagree — not a program error to be tolerated quietly.
            guard let target = functions[name] else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: function value '\(name)' names no module-level "
                        + "function in this module",
                    location: HIRExecutor.noLocation
                )
            }
            // A named function closes over nothing: the interpreter registers
            // its value against the global environment, and this mirrors that
            // rather than inventing a creation-point environment there is none
            // of.
            return makeFunctionValue(
                name: name,
                paramNames: target.params.map { $0.name },
                body: target.body,
                returnLabels: HIRExecutor.declaredReturnLabels(target.returnType),
                closure: globalEnv
            )

        case .indirectCall(let callee, let arguments, _):
            // Callee before arguments, which is the interpreter's order at its
            // own indirect-call arm; argument evaluation is observable, so the
            // order is part of the semantics rather than an implementation
            // detail.
            let calleeValue = try evaluate(callee)
            guard case .function(let function) = calleeValue else {
                throw RuntimeError.notCallable(location: HIRExecutor.noLocation)
            }
            return try callFunctionValue(function, args: try arguments.map { try evaluate($0) })

        // MARK: Strings and builtins (P2b grid G7)

        case .interpString(let parts):
            // Mirrors the interpreter's `.stringInterpolation` arm. The lowerer
            // has already flattened the segment list: literal segments arrive as
            // `stringConst`, expression segments as their own node, and an
            // all-literal run was folded into one constant before it got here.
            // `stringifyValue` is the interpreter's own rendering, and a string
            // value renders verbatim, so a literal segment contributes its text
            // unchanged — which is what the interpreter's `.literal` branch does.
            var text = ""
            for part in parts {
                text += RuntimeOps.stringifyValue(try evaluate(part))
            }
            return .string(text)

        case .isAsciiDigit(let argument):
            // Mirrors `Interpreter`'s `is_ascii_digit` arm verbatim, including
            // its non-fail-loud behaviour outside the ASCII domain: `Character`
            // comparison puts every non-ASCII scalar above "9", so the predicate
            // is effectively ASCII-only without a second range check. The empty
            // string is false, not an error.
            // G67: the parameter face moved from `String` to `Char`; `requireChar`
            // takes either, because the two share a representation.
            let s = try requireChar(try evaluate(argument), for: "is_ascii_digit")
            guard let first = s.first else { return .bool(false) }
            return .bool(first >= "0" && first <= "9")

        case .printMulti(let arguments):
            // The interpreter's multi-argument `print`: every value rendered,
            // joined with a single space, handed to the sink as one line (so a
            // concurrent task cannot interleave inside it). Arguments are
            // evaluated left to right — their evaluation is observable.
            let values = try arguments.map { try evaluate($0) }
            outputSink(values.map { RuntimeOps.stringifyValue($0) }.joined(separator: " "))
            return .null

        case .assertCall(let condition, let message):
            // Mirrors the interpreter's `assert` arm. Both operands are
            // evaluated before the condition is judged, because that is what the
            // interpreter does — argument evaluation happens at the call site,
            // and only then does the arm look at the values.
            let conditionValue = try evaluate(condition)
            let messageValue = try message.map { try evaluate($0) }
            guard case .bool(let passed) = conditionValue else {
                throw RuntimeError.invalidOperation(
                    reason: "assert 的参数 1 必须是 Bool（条件）",
                    location: HIRExecutor.noLocation
                )
            }
            guard !passed else { return .null }
            let text: String
            if let messageValue = messageValue {
                guard case .string(let m) = messageValue else {
                    throw RuntimeError.invalidOperation(
                        reason: "assert 的参数 2 必须是 String（消息）",
                        location: HIRExecutor.noLocation
                    )
                }
                text = m
            } else {
                text = "assert failed"
            }
            throw RuntimeError.assertionFailed(message: text, location: HIRExecutor.noLocation)

        case .arrayJoin(let receiver, let separator):
            // Mirrors the interpreter's `join` arm: `stringify` each element and
            // interpose the separator. Elements are stringified with the shared
            // renderer rather than assumed to be strings — `[String]` is what the
            // lowerer requires, but the value that arrives is whatever the array
            // holds, and the interpreter stringifies unconditionally.
            guard case .array(let elements) = try evaluate(receiver) else {
                throw RuntimeError.invalidOperation(
                    reason: "join needs an Array receiver",
                    location: HIRExecutor.noLocation
                )
            }
            let sep = try requireString(try evaluate(separator), for: "join")
            return .string(elements.map { RuntimeOps.stringifyValue($0) }.joined(separator: sep))

        case .stringCase(let isUpper, let receiver):
            // Contract §2.36: **Unicode-aware**, and the receiver is unchanged.
            // The authority is the interpreter's `upper`/`lower` arms
            // (`Interpreter.swift`, the `fv.name == "upper"` / `"lower"`
            // branches), which are `String.uppercased()` / `.lowercased()`; the
            // LLVM emitter's byte-wise ASCII-only pass is the deviating side and
            // is filed as a B-group defect. Mirroring the contract here is
            // therefore mirroring the interpreter, not choosing a third reading.
            let text = try requireString(try evaluate(receiver), for: "upper/lower")
            return .string(isUpper ? text.uppercased() : text.lowercased())

        case .stringContains(let receiver, let needle):
            // The AST channel serves `contains` from `StdlibPini`'s Pini source
            // (内建双层结构 sank it), so *that* file is the authority, not a Swift
            // arm — the interpreter's native chain has a standing instruction not
            // to reintroduce a by-name branch for a sunk method. The loop below is
            // the same algorithm over `[Character]` (graphemes, 字符模型 = Grapheme Cluster):
            // empty needle is true, otherwise scan for a grapheme-wise match.
            //
            // This is the structural cost of a sunk method: the authority is Pini
            // source, which cannot be called from here without a cross-engine
            // call, so the grid carries a second copy of the algorithm. The copy
            // is guarded by `HIRExecutorTests`' both-channel fixtures, which fail
            // the moment the two readings drift. Same shape as G4's `sliceCall`.
            let haystack = Array(try requireString(try evaluate(receiver), for: "contains"))
            let needleChars = Array(try requireString(try evaluate(needle), for: "contains"))
            if needleChars.isEmpty { return .bool(true) }
            var i = 0
            while i + needleChars.count <= haystack.count {
                var j = 0
                var matched = true
                while j < needleChars.count {
                    if haystack[i + j] != needleChars[j] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched { return .bool(true) }
                i += 1
            }
            return .bool(false)

        case .stringSubstring(let receiver, let start, let end):
            // Contract §2.38: the second argument is an **end**, not a length —
            // the registry declares `paramNames: ["start", "end"]` and the
            // contract's note records that the emitter still reads it as a length
            // (a filed B-group deviation). The enum's label is the misleading
            // one; the binding is named `end` so the rule below is readable.
            //
            // Authority is `StdlibPini.substring`: negative bounds tail-count,
            // both bounds clamp into `[0, len]`, and `hi < lo` yields the empty
            // string. `len` is the grapheme count.
            let characters = Array(try requireString(try evaluate(receiver), for: "substring"))
            let n = characters.count
            var lo = try requireInt(try evaluate(start), for: "substring start")
            var hi = try requireInt(try evaluate(end), for: "substring end")
            if lo < 0 { lo = n + lo }
            if hi < 0 { hi = n + hi }
            if lo < 0 { lo = 0 }
            if lo > n { lo = n }
            if hi < 0 { hi = 0 }
            if hi > n { hi = n }
            guard hi > lo else { return .string("") }
            return .string(String(characters[lo..<hi]))

        case .stringSplit(let receiver, let delim, _):
            // Contract §2.39 (A4): the result is a **real `Array<String>`** and
            // **empty tokens are skipped**, which is what the LLVM arm's `strtok`
            // loop already does. Stated as a decision, not a preference: the
            // interpreter-side alignment (it currently keeps the empty segments —
            // `StdlibPini.split` appends unconditionally) is the `stringSplit`
            // grid's job and is registered there. This node follows the contract,
            // which is where the authority sits.
            //
            // An empty separator yields one element per grapheme, mirroring
            // `StdlibPini`'s explicit `m == 0` branch.
            let text = try requireString(try evaluate(receiver), for: "split")
            let characters = Array(text)
            let delimChars = Array(try requireString(try evaluate(delim), for: "split"))
            var parts: [Value] = []
            if delimChars.isEmpty {
                return .array(characters.map { .string(String($0)) })
            }
            var current = ""
            var i = 0
            while i < characters.count {
                var j = 0
                var hit = true
                while j < delimChars.count {
                    if i + j >= characters.count || characters[i + j] != delimChars[j] {
                        hit = false
                        break
                    }
                    j += 1
                }
                if hit {
                    if !current.isEmpty { parts.append(.string(current)) }
                    current = ""
                    i += delimChars.count
                } else {
                    current.append(characters[i])
                    i += 1
                }
            }
            if !current.isEmpty { parts.append(.string(current)) }
            return .array(parts)

        // MARK: Not implemented yet — fail loud, named.

        // MARK: Pointers and LazyRef (P2b grid G8)

        case .pointerLoad(let pointer, _):
            // Mirrors the interpreter's `load` builtin. The element type comes
            // from the pointer value rather than this node's own `type`
            // payload: the lowerer derives that payload from the same argument,
            // so the pointer stays the single source and the two cannot drift.
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerLoad expects a *T pointer operand",
                    location: HIRExecutor.noLocation
                )
            }
            return try RuntimeOps.decodePointer(raw)

        case .pointerStore(let pointer, let value, _):
            // Mirrors the interpreter's `store` builtin: encode by the pointer's
            // element type, truncating for narrow elements.
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerStore expects a *T pointer operand",
                    location: HIRExecutor.noLocation
                )
            }
            try RuntimeOps.encode(try evaluate(value), to: raw.pointer, type: raw.elemType)
            return .null

        case .addressOfVar(let name, _):
            // Interpreter parity: `&x` snapshots the value into fresh memory, so
            // writing through the pointer does not reach the variable. The
            // contract's true-reference semantics is the address-of grid's
            // delivery and is deliberately not taken here — taking it would put
            // this arm in disagreement with the frozen AST arm and turn a
            // non-blocking slot into a flip blocker.
            return try RuntimeOps.snapshotPointer(
                of: try currentEnv.get(name: name),
                location: HIRExecutor.noLocation
            )

        case .lazyRefConstruct(let closure, _):
            // Mirrors `Interpreter.makeLazyRefBox`: the argument is the
            // initialiser closure, and the box itself carries the once-only rule.
            guard case .function(let function) = try evaluate(closure) else {
                throw RuntimeError.invalidOperation(
                    reason: "lazyRefConstruct expects an initialiser closure",
                    location: HIRExecutor.noLocation
                )
            }
            return .lazyRef(LazyRefBox(initializer: function))

        case .lazyRefValue(let handle, _):
            // Mirrors the interpreter's `.value` member access. The box owns
            // "evaluate once, then cache", so this arm supplies only the compute
            // step — the same division of labour the AST side uses.
            guard case .lazyRef(let box) = try evaluate(handle) else {
                throw RuntimeError.invalidOperation(
                    reason: "lazyRefValue expects a LazyRef handle",
                    location: HIRExecutor.noLocation
                )
            }
            return try box.value { function in
                try self.callFunctionValue(function, args: [])
            }

        case .fileWrite(let pathExpr, let contentExpr):
            // Mirrors the interpreter's `writeFile` arm: the path resolves
            // against the program base, and the value is the write's integer
            // result code. A failed write raises here, so a successful return is
            // the only reachable one and zero is its code.
            let rawWritePath = try requireString(evaluate(pathExpr), for: "writeFile")
            let content = try requireString(evaluate(contentExpr), for: "writeFile")
            let writePath = RuntimeOps.resolveIOPath(rawWritePath, programBase: programBase)
            do {
                try content.write(toFile: writePath, atomically: true, encoding: .utf8)
                return .int(0)
            } catch {
                throw RuntimeError.invalidOperation(
                    reason: "IO 错误: 无法写入文件 \(writePath): \(error.localizedDescription)",
                    location: HIRExecutor.noLocation
                )
            }

        case .fileRead(let pathExpr):
            // Mirrors the interpreter's arm, cap included: the contract fixes the
            // read limit and the channel that deviates is named there, so this
            // side takes the same `IOLimits` truncation rather than restating the
            // number.
            let rawReadPath = try requireString(evaluate(pathExpr), for: "readFile")
            let readPath = RuntimeOps.resolveIOPath(rawReadPath, programBase: programBase)
            do {
                let content = try String(contentsOfFile: readPath, encoding: .utf8)
                return .string(IOLimits.truncateToFileLimit(content))
            } catch {
                throw RuntimeError.invalidOperation(
                    reason: "IO 错误: 无法读取文件 \(readPath): \(error.localizedDescription)",
                    location: HIRExecutor.noLocation
                )
            }

        case .readLine:
            // Mirrors the interpreter's arm: the terminator is kept and the line
            // is capped at the contract's byte limit. EOF is the empty string,
            // which is distinguishable from an empty line precisely because the
            // terminator is no longer stripped.
            guard let line = readLine(strippingNewline: false) else {
                return .string("")
            }
            return .string(IOLimits.truncateToLineLimit(line))

        // MARK: join

        /// `await f` / `wait f`: the suspension engine is the CPS evaluator,
        /// which this engine does not have. The arm is here because the node
        /// set and the contract entry move together — the coverage check reads
        /// both directions, so an unacknowledged node fails the build rather
        /// than sliding through. It fails loud instead of returning a silent
        /// `.null`: a lowerer rule without the engine behind it must show up
        /// as an error, not as a plausible-looking wrong value.
        case .join(let futureExpr, _, let form):
            // `await f` / `wait f` (G-3c-1): evaluate the operand, then wait for it
            // to resolve and deconstruct the carried ok / err.
            //
            // `form` says which keyword the site was written with, and that is now
            // the only thing that can: the mode flag the retired implementation
            // consulted had no assignment point outside the tests, and it left with
            // the walk. Both forms still wait the same way — giving the task up
            // across a join needs a body that can be resumed part-way through, and
            // this engine walks the body on the machine stack. The form is carried
            // through anyway so the difference has somewhere to land, and so a
            // reader can tell the two apart at the one place that matters.
            //
            // A `join` that is not given a future is a run-time type mismatch.
            let operand = try evaluate(futureExpr)
            guard case .future(let fut) = operand else {
                throw RuntimeError.typeMismatch(
                    expected: "Future<T, Error>",
                    got: RuntimeOps.describeValueKind(operand),
                    location: HIRExecutor.noLocation
                )
            }
            return RuntimeOps.joinFuture(fut, timeoutMs: nil, form: form)

        // MARK: 默认实例取用（ADR-001）

        /// 取某类型的默认实例（契约 §2.46）。`P2a` 只落节点面：**没有降载入口**
        /// ⇒ 本臂当前不可达，而它必须存在 —— 契约器械的覆盖检查**双向对账**
        /// （未认领的节点直接让构建失败）。故这里 **fail-loud**、不静默返回一个
        /// 看起来合理的值：物化面（存放位 + once + `bk_given_get`）属 `P2b`。
        case .givenInstance(let type):
            // ADR-001 `P2b`：物化面已落 —— 与发射层同语义（惰性 · 恰一次 · 取副本）。
            return try materializeGivenInstance(type)
        }
    }

    // MARK: - G7 operand helpers

    /// One `String` operand, or a loud error naming the caller.
    ///
    /// The AST channel reaches these as builtin/member calls that typecheck the
    /// argument before the arm reads it; this engine only has the value. A wrong
    /// type is a genuine inconsistency (a module not produced by the lowerer),
    /// so it fails loud rather than coercing.
    private func requireString(_ value: Value, for what: String) throws -> String {
        guard case .string(let text) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects a String operand, got \(value)",
                location: HIRExecutor.noLocation
            )
        }
        return text
    }

    /// One `Char` operand as its grapheme text, or a loud error naming the caller.
    ///
    /// G67: `Char` and `String` share a representation, and `Char` widening to
    /// `String` is legal (see the implicit-conversion rule), so a `String` value
    /// is accepted here too — a `Char`-faced operand that reached us through a
    /// `String` position is still the same one grapheme.
    private func requireChar(_ value: Value, for what: String) throws -> String {
        switch value {
        case .char(let text), .string(let text): return text
        default:
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects a Char operand, got \(value)",
                location: HIRExecutor.noLocation
            )
        }
    }

    /// One `I32` operand, or a loud error naming the caller. See `requireString`.
    private func requireInt(_ value: Value, for what: String) throws -> Int {
        guard case .int(let number) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects an integer operand, got \(value)",
                location: HIRExecutor.noLocation
            )
        }
        return number
    }

    /// The declaration an `enumConstruct` names, by case name with the tag as a
    /// fallback.
    ///
    /// The lowerer carries both because they come from the same declaration; a
    /// miss on both is a real inconsistency (a module assembled by hand, or a
    /// declaration dropped between lowering and execution), so the caller fails
    /// loud rather than inventing an empty associated-value list.
    private func resolveEnumCase(enumName: String, caseName: String, tag: Int) -> HIREnumCase? {
        guard let decl = enums[enumName] else { return nil }
        if let named = decl.cases.first(where: { $0.name == caseName }) { return named }
        guard decl.cases.indices.contains(tag) else { return nil }
        return decl.cases[tag]
    }

    // MARK: - Nominal instances (P2a grid G5)

    /// The implicit constructor `名()`: one fresh instance whose fields hold
    /// their declared defaults, and `.null` where a field declares none.
    ///
    /// Mirrors `Interpreter.createInstance` — including *where* the default
    /// expressions run: the interpreter evaluates a field initializer against
    /// the environment current at the construction site, so this does too. (The
    /// lowerer compiles every field default in a scratch context with no
    /// parameters, so a default can only be a closed expression; the site is
    /// still the mirror of the interpreter's, not a free choice.)
    ///
    /// The value/reference split comes from the declaration: `isObject` picks
    /// `ObjectReference` (whose refcount starts at 1) over `StructInstance`.
    /// The interpreter registers such an object with its ARC manager so that
    /// `WeakRef.isAlive` has something to answer; this engine has no ARC
    /// surface at all (`weakRef` nodes are not implemented), so nothing here
    /// reads that registry and nothing is registered in it. Recorded with the
    /// grid rather than guessed at.
    ///
    /// A nominal with no declaration in this module yields an instance with no
    /// fields — the interpreter's behaviour when its type registry has no entry
    /// either, not a silent success invented here.
    /// ADR-001 `P2b`：默认实例的物化（解释器臂）。
    ///
    /// 物化本身**复用 `constructValue`** —— 给定块的字段初值走的就是普通复合类型那条路，
    /// 没有第二条算法（这是本批刻意做的：两条算法必然漂）。本函数只多管「记住」与「取副本」。
    ///
    /// ⚠️ 取副本是**白拿**的：`Value.structInstance` 是值类型，返回缓存值即得一份拷贝
    /// （用户 2026-09-19 裁定：取实参的副本，与函数传参一致）。写实例自身字段因此不留痕，
    /// 而经引用字段往下写对所有取用点可见 —— 与发射层逐字同语义。
    private func materializeGivenInstance(_ type: HIRType) throws -> Value {
        guard case .nominal(let name, _) = type else {
            throw RuntimeError.invalidOperation(
                reason: "givenInstance 需要一个名义类型，实为 '\(type.llvmSpelling)'",
                location: HIRExecutor.noLocation
            )
        }
        if let cached = givenInstances[name] { return cached }
        let materialized = try constructValue(type)
        givenInstances[name] = materialized
        return materialized
    }

    /// 派发点的后端：从**语言侧的默认声明**解析而来。
    ///
    /// 这条接线的内容 —— 程序可以在语言里说明它的调度器（那个预置给定块），而派发点读它：
    /// 于是「用哪个调度器、它能做什么」由**程序**说了算，而不是由引擎写死一个常量。
    /// 在此之前，唯一能改动派发点后端的办法是宿主注入一个替身，而那种改动**语言看不见**。
    ///
    /// ⚠️ **只读声明，不物化实例** —— 这不是优化，是正确性要求。
    /// 本函数跑在装载期，而装载期的契约是**只注册、不运行**：
    /// 在这里求值（哪怕只是读一个字段初值）会去碰一套**尚未就绪**的执行状态。
    /// 实测代价是响亮的：改成本实现之前的那版在装载期物化实例，
    /// 让同进程里另一条「取用默认实例」的判据**超时**、整个测试进程**段错误**。
    /// ⇒ 读字段的**声明值**（一个已折叠的字面量）而不是它的**运行值**。
    ///
    /// ⚠️ **读法刻意宽容**：字段缺席、或它的值不是布尔字面量，一律取**语言默认**（可让出）。
    /// 理由不是省事 —— 用户可以整块替换那份声明，若他替换时没提到这个字段就判红，
    /// 等于拿一处**没写**去罚一处**没改**的地方，而这类名字的处置有一条承诺是「零破坏性」。
    /// ⇒ 判据的区分力不靠这条路：靠的是「显式声明不能让出」那条，它会真的变红。
    ///
    /// ⚠️ 内层仍是宿主那**唯一**的后端（原语层的事，语言今天说不了）。
    /// 本函数换的不是后端本体，而是**它按谁的声明作答**。
    private func resolveSchedulerFromLanguage() -> Scheduler {
        SchedulerWithDeclaredCapability(
            inner: GCDScheduler.shared, canYield: declaredYieldCapability())
    }

    /// 语言侧那份声明说这个调度器能不能让出。**只读字面量，不求值。**
    private func declaredYieldCapability() -> Bool {
        guard let declaration = types[PredefinedDecls.schedulerTypeName],
            let field = declaration.fields.first(
                where: { $0.name == PredefinedDecls.yieldCapabilityField }),
            let declared = field.defaultValue,
            case .boolConst(let canYield) = declared
        else { return true }
        return canYield
    }

    private func constructValue(_ type: HIRType) throws -> Value {
        guard case .nominal(let name, let isObject) = type else {
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: construct needs a nominal type, got '\(type)'",
                location: HIRExecutor.noLocation
            )
        }
        var fieldValues: [String: Value] = [:]
        if let declaration = types[name] {
            for field in declaration.fields {
                if let defaultValue = field.defaultValue {
                    fieldValues[field.name] = try evaluate(defaultValue)
                } else {
                    fieldValues[field.name] = .null
                }
            }
        }
        if isObject || types[name]?.isObject == true {
            return .objectReference(ObjectReference(typeName: name, fields: fieldValues))
        }
        return .structInstance(StructInstance(typeName: name, fields: fieldValues))
    }

    /// `base.field` — the read half of `Interpreter.evaluateMember`'s member
    /// branch, for the two receivers that carry fields.
    ///
    /// A read of a field the receiver does not carry is *unreachable from Pini
    /// source*: the lowerer resolves the field statically and refuses to build
    /// this node when the nominal declares no such field. Reaching it here
    /// therefore means the module and the engine disagree, and it says so
    /// instead of yielding `.null` — a silently wrong value is the one outcome
    /// this engine must never produce.
    ///
    /// Two interpreter rules are deliberately NOT mirrored, and both are
    /// unreachable from a program that *typechecks* — not merely absent from the
    /// corpus:
    ///
    /// - the type-private gate on `_`-prefixed names
    ///   (`RuntimeError.inaccessibleField`): the checker already enforces it on
    ///   **both** sides of the member rule (`TypeChecker.enforceFieldVisibility`,
    ///   read and write), reporting `E3-012`, so mirroring it here would be a
    ///   duplicate of a static rejection. The checker skips the gate when it
    ///   cannot infer the receiver's static type, which is the one slit through
    ///   which a program could still reach this node — recorded with the grid's
    ///   judging gaps rather than implemented unverified.
    /// - the bound-method fallback (reading a method as a value): the lowerer
    ///   rejects a method outside call position, so no such node is ever built.
    private func fieldRead(from base: Value, field: String) throws -> Value {
        switch base {
        case .structInstance(let instance):
            guard let value = instance.fields[field] else {
                throw missingField(field, on: instance.typeName)
            }
            return value
        case .objectReference(let object):
            guard let value = object.fields[field] else {
                throw missingField(field, on: object.typeName)
            }
            return value
        default:
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: field read '.\(field)' needs a nominal receiver, got "
                    + "\(RuntimeOps.describeValueKind(base))",
                location: HIRExecutor.noLocation
            )
        }
    }

    /// `base.field = value` — the write half of the interpreter's
    /// `performMemberAssign`, arm for arm.
    ///
    /// The `let`-bound struct rule is here with the interpreter's own trigger:
    /// only a receiver written as an identifier other than `self`. `self` is
    /// exempt on purpose — a method body exists to write its receiver's fields,
    /// and its binding is immutable by construction.
    ///
    /// The interpreter does two more things on this path and neither is
    /// mirrored here, both recorded with the grid:
    ///
    /// - it deep-copies the incoming value (`copyIfStruct`). No differential
    ///   fixture stores a struct into a field, so the rule has no observable
    ///   consequence *today* on either channel; it is a real hole the moment
    ///   HIR replaces the AST engine, which is why it is filed as a defect
    ///   instead of either implemented blind or left unmentioned.
    /// - it applies the type-private gate to `_`-prefixed names — unreachable
    ///   for the reason `fieldRead` records (the checker rejects it statically,
    ///   `E3-012`), so it is not duplicated here.
    ///
    /// This node is only ever reached for the nominal family: the lowerer
    /// resolves the base and refuses non-nominal receivers, so the trailing
    /// branch reports an internal inconsistency with the interpreter's own
    /// wording, not a new rule.
    private func storeField(base: HIRExpr, field: String, value: Value) throws {
        let receiver = try evaluate(base)
        if case .load(let rootName, _) = base, rootName != "self",
            case .structInstance = receiver,
            let mutable = currentEnv.isMutable(name: rootName), !mutable
        {
            throw RuntimeError.immutableVariable(name: rootName, location: HIRExecutor.noLocation)
        }
        switch receiver {
        case .structInstance(let instance):
            instance.fields[field] = value
        case .objectReference(let object):
            object.fields[field] = value
        default:
            throw RuntimeError.invalidOperation(
                reason: "无法赋值的对象类型",
                location: HIRExecutor.noLocation
            )
        }
    }

    private func missingField(_ field: String, on typeName: String) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "HIR executor: '\(typeName)' carries no field '\(field)' "
                + "(the lowerer resolves fields statically, so this is an internal "
                + "inconsistency, not a gap in this engine)",
            location: HIRExecutor.noLocation
        )
    }

    /// `container.slice(start, end)` — the slice-sugar semantics.
    ///
    /// The AST channel does **not** implement this in Swift: `slice` sank to the
    /// language-level stdlib (`StdlibPini.source`, the `((String))` and
    /// `((Array))` blocks, 内建双层结构), so its reference implementation is Pini
    /// source this engine cannot run. The bodies below are a native mirror of
    /// that source, and the two are held together by the differential probe
    /// rather than by shared code:
    ///
    /// - an open bound (`none`, or `.null`) means "the whole container" on that
    ///   side, which is how the slice sugar spells `a[:2]` / `a[3:]` / `a[:]`;
    /// - an integer bound is tail-counted when negative;
    /// - both bounds are clamped to `[0, len]`, and `hi < lo` yields empty;
    /// - `String` walks **grapheme clusters** (the AST channel's `self[k]` is a
    ///   grapheme subscript), which is the contract (`字符模型 = Grapheme Cluster`). The LLVM side
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
        // LLVM grid G9: min/max lower to LLVM selects; the interpreter reaches
        // them as builtin function calls, so there is no operator to map onto.
        case .minOf, .maxOf: return nil
        }
    }

    /// `HIRUnaryOp` → `UnaryOperator`; see `operatorFor(_ op: HIRBinaryOp)`.
    static func operatorFor(_ op: HIRUnaryOp) -> UnaryOperator? {
        switch op {
        case .negate: return .minus
        case .logicalNot: return .not
        // G-2c: `~` maps to the interpreter's own `.bitwiseNot`, so both
        // engines reach the shared `RuntimeOps.unaryValue` entry.
        case .bitwiseNot: return .bitwiseNot
        // LLVM grid G9: `abs` is a builtin call on the AST channel, not a unary
        // operator.
        case .abs: return nil
        }
    }

    // MARK: - Defer scopes

    /// Mirror of `Interpreter.pushDeferScope`.
    private func pushDeferScope() {
        deferStack.append([])
    }

    /// Mirror of `Interpreter.popDeferScope`: run this scope's defers LIFO.
    ///
    /// Two details are copied rather than chosen, because both are observable.
    /// The scope is removed *before* its defers run, so a `defer` inside a
    /// deferred statement registers in the scope that encloses this one (or
    /// errors, if there is none). And the caller swallows whatever the defers
    /// throw — see `executeBlock`.
    private func popDeferScope() throws {
        guard !deferStack.isEmpty else { return }
        let groups = deferStack.removeLast()
        for group in groups.reversed() {
            for statement in group { try execute(statement) }
        }
    }

    /// Run a statement list as a **block**: open a defer scope, run, close it on
    /// every exit path.
    ///
    /// This is the interpreter's `executeBlock`, and it is called at exactly the
    /// same boundaries — `if` / `else` branches, and `while` and `for-in` bodies
    /// and steps. The function-body path does *not* come through here: it opens
    /// its own scope inline, as `executeFunctionBody` does, because that path also
    /// owns the `lastValue` rule and the environment restore.
    ///
    /// The `try?` on the close is deliberate. It is what the interpreter does, and
    /// what it means is: a signal thrown by a deferred statement is discarded, and
    /// whatever error is already unwinding keeps unwinding. "Fixing" this into a
    /// propagated error would invent a divergence rather than remove one.
    private func executeBlock(_ block: HIRBlock) throws {
        pushDeferScope()
        defer { try? popDeferScope() }
        try executeStatements(block)
    }

    // MARK: - Statements

    /// Runs a statement list in order, yielding the value of the last expression
    /// statement (`.null` when there is none).
    ///
    /// This is the interpreter's `lastValue` rule from `executeFunctionBody`, and
    /// it is why control-flow bodies and function bodies can share one runner: a
    /// body that is not a function body simply discards the result.
    ///
    /// This is also the pause site. The interpreter consults its debug hook
    /// before each statement it is about to run, and so does this: same point in
    /// the control flow, same context, same `.quit` contract — which is what
    /// makes "the debugger works the same on both engines" a fact rather than a
    /// hope. The position comes from the block, not from the node: a block that
    /// carries none is skipped rather than reported with an invented line, so an
    /// unwired block can never make the debugger stop somewhere fictional.
    @discardableResult
    private func executeStatements(_ block: HIRBlock) throws -> Value {
        var lastValue: Value = .null
        for (index, statement) in block.enumerated() {
            if debugHook != nil, let location = block.position(at: index) {
                try debugPause(at: location)
            }
            if case .exprStmt(let expr) = statement {
                lastValue = try evaluate(expr)
            } else {
                try execute(statement)
            }
        }
        return lastValue
    }

    /// Consult the debugger before a statement runs.
    ///
    /// Mirrors `Interpreter.debugPause(at:)`: the position is given by the
    /// caller rather than read off a node, so the pause action does not depend
    /// on statement shape — that is the half of the debug surface the two
    /// engines genuinely share. `.quit` unwinds as `DebuggerError.quit`, the
    /// same signal the interpreter throws.
    ///
    /// The hook is tested before the context is built, so an engine with no
    /// debugger attached pays nothing — the interpreter's guard buys the same.
    private func debugPause(at location: SourceLocation) throws {
        guard let hook = debugHook else { return }
        let context = DebugContext(
            location: location,
            depth: callDepth,
            callStack: callStackNames,
            variables: currentEnv.listBindings().map {
                ($0.name, RuntimeOps.stringifyValue($0.value))
            }
        )
        if try hook(context) == .quit {
            throw DebuggerError.quit
        }
    }

    private func execute(_ statement: HIRStmt) throws {
        switch statement {

        case .allocVar(let name, let type, let mutable, let initializer):
            // Registered even without an initializer, as `.null` — the
            // interpreter's `varDecl` does the same, so an uninitialized read is
            // a value, not an "undefined variable" error, on both channels.
            // Value-type copy (LR-4 G-2R): a struct reaching a slot is copied
            // field by field -- the rule the interpreter applies at the same
            // point. Without it both engines share one storage, and a write
            // through the copy surfaces in the original, silently.
            var value = try initializer.map { RuntimeOps.copyIfStruct(try evaluate($0)) } ?? .null
            // P2a G2: binding-site relabel — the second of the interpreter's two
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
                value = RuntimeOps.relabelled(value, with: labels)
            }
            currentEnv.define(name: name, value: value, isMutable: mutable)

        case .storeVar(let name, _, let value):
            // Value-type copy (LR-4 G-2R): a struct reaching a slot is copied
            // field by field -- the rule the interpreter applies at the same
            // point. Without it both engines share one storage, and a write
            // through the copy surfaces in the original, silently.
            try currentEnv.assign(name: name, value: RuntimeOps.copyIfStruct(try evaluate(value)))

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            // Each branch is its own defer scope. The HIR folds `elif` chains
            // into a nested `ifStmt` in `elseBody`, so a chain of three branches
            // is three scopes here for the same reason it is three on the AST
            // channel — the interpreter reaches each `Block` through
            // `executeBlock` too.
            //
            // 标签 break 定向范围: a labeled `if` is an interruptible frame, so its branch
            // runs under a catch — mirroring `Interpreter.executeIf`, which
            // wraps `executeIfBody` for exactly this reason. An unlabeled `if`
            // runs bare: it has no signal of its own to consume, and catching
            // for it would swallow a depth-1 signal aimed at an enclosing loop.
            if label == nil {
                try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
            } else {
                do {
                    try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
                } catch let signal as HIRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        // `depth == 1` ⇒ this frame is the target: the `break`
                        // leaves the block and control resumes after the `if`.
                        // Anything deeper belongs to an enclosing frame and is
                        // rethrown one level shallower.
                        if depth > 1 { throw HIRControlSignal.breakSignal(depth: depth - 1) }
                    case .continueSignal(let depth):
                        // An `if` frame is never a `continue` target
                        // (`continue` resolves to loop frames only), so a
                        // signal reaching here is aimed further out and its
                        // residual depth is >= 2.
                        throw HIRControlSignal.continueSignal(depth: depth - 1)
                    default:
                        throw signal
                    }
                }
            }

        case .whileStmt(let condition, let body, let step):
            try executeWhile(condition: condition, body: body, step: step)

        case .returnStmt(let value):
            throw HIRControlSignal.returnSignal(try value.map { try evaluate($0) })

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
            // Value-type copy (LR-4 G-2R): a struct reaching a slot is copied
            // field by field -- the rule the interpreter applies at the same
            // point. Without it both engines share one storage, and a write
            // through the copy surfaces in the original, silently.
            let newValue = RuntimeOps.copyIfStruct(try evaluate(value))
            let targetIndex = try evaluate(index)
            try storeSubscript(target: container, index: targetIndex, newValue: newValue)

        // MARK: Control flow (P2a grid G1)

        case .forInStmt(let pattern, _, let kind, let iterable, let body, let step):
            // `elementTypes` is lowering-time information only. The contract's
            // "`_` still occupies a slot and carries its type" is about the
            // lowerer's arity check; at run time the row decomposition is the
            // interpreter's, reused rather than restated.
            try executeForIn(
                pattern: pattern, kind: kind, iterable: iterable,
                body: body, step: step
            )

        case .deferStmt(let body):
            // Registered, not run: LIFO order belongs to the scope
            // (`popDeferScope`). The guard is the interpreter's — a `defer` with
            // no enclosing block scope is an error, not a silent no-op — and it
            // cannot fire for lowered source, since a function body is a scope.
            guard !deferStack.isEmpty else {
                throw RuntimeError.invalidOperation(
                    reason: "defer 必须在块作用域内使用",
                    location: HIRExecutor.noLocation
                )
            }
            deferStack[deferStack.count - 1].append(body)

        case .breakStmt(let depth):
            throw HIRControlSignal.breakSignal(depth: depth)

        case .continueStmt(let depth):
            throw HIRControlSignal.continueSignal(depth: depth)

        case .detachStmt(let inner):
            // `detach <expr>` (G-3c-1): prune the task from its parent so the
            // parent's return stops cancelling it — fire-and-forget's only
            // sanctioned exit, and the counterpart the strict structured rule
            // needs to stay reversible.
            //
            // The operand is evaluated first and a non-future one is a run-time
            // type mismatch, exactly where the interpreter reports it: refusing
            // it at lowering time would place the error on the wrong side of
            // the run-time boundary the two engines are being kept equal across.
            let operand = try evaluate(inner)
            guard case .future(let fut) = operand else {
                throw RuntimeError.typeMismatch(
                    expected: "Future<T, Error>",
                    got: RuntimeOps.describeValueKind(operand),
                    location: HIRExecutor.noLocation
                )
            }
            fut.detachFromParent()

        case .panicStmt(let message):
            // The message is the lowerer's — it names the escape the interpreter
            // only discovers at run time — and is passed through verbatim.
            throw RuntimeError.invalidOperation(
                reason: message,
                location: HIRExecutor.noLocation
            )

        // MARK: Try / match (P2a grid G6)

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, _):
            // Mirrors the interpreter's `Expression.tryExpression` — the sole error
            // propagation primitive since the try-else migration: the operand is
            // statically a `Result`; `ok` yields its payload, `err` binds the
            // payload and runs the handler. The handler statements run *here*
            // (not as a block), so `return` / `break` / `continue` inside it leave
            // as signals for the enclosing function or loop to catch, and their
            // bare `pass` terminator just ends the statement — both are the
            // interpreter's shape.
            let result = try evaluate(operand)
            try runTryResult(result, errorVar: errorVar, handler: handler, okTarget: okTarget)

        case .matchStmt(let scrutinee, let cases, _):
            // The carried `scrutineeType` is deliberately not consulted: the
            // interpreter's rule is value-based (what the value *is* decides which
            // arm fires), and the static type has already done its work in the
            // lowerer, where it chose which arm family to build. Reading it here
            // would create a second dispatch that could disagree with the value.
            let scrutineeValue = try evaluate(scrutinee)
            try runMatch(cases, scrutinee: scrutineeValue)

        // MARK: Nominal field store (P2a grid G5)

        case .fieldStore(let base, let field, let value, _):
            // Right-hand side first, receiver second — the order the interpreter's
            // assignment path uses (it evaluates the value, then the member base).
            // Observable only when both have effects, which is exactly when a
            // mirror that guessed would be caught late.
            // Value-type copy (LR-4 G-2R): a struct reaching a slot is copied
            // field by field -- the rule the interpreter applies at the same
            // point. Without it both engines share one storage, and a write
            // through the copy surfaces in the original, silently.
            try storeField(base: base, field: field, value: RuntimeOps.copyIfStruct(try evaluate(value)))
        }
    }

    /// One `match` arm, run the way `Interpreter.executeMatch` runs one: the arm's
    /// bindings live in a fresh environment chained to the current one, the body
    /// is a *block* (its defers run LIFO when it ends), and the arm environment is
    /// dropped on **every** exit path — normal end, `return`, and the loop
    /// signals, which is why the restore is a `defer` and not a trailing
    /// statement.
    ///
    /// Bindings are positional by payload index: the lowerer already resolved
    /// `case c(名: x)` to declaration order and rejected the out-of-order forms,
    /// so the interpreter's run-time name lookup has no counterpart here. `nil` is
    /// the `_` placeholder — it holds a position without binding anything.
    private func executeArm(_ arm: HIRMatchCase, scrutinee value: Value) throws {
        let caseEnv = Environment(enclosing: currentEnv)
        if case .enumValue(let ev) = value {
            // The interpreter's arity gate, kept: bindings that do not line up with
            // the associated values are a run-time error, not a silent `.null`
            // (ADR named-associated-value decision, 2026-08-29). An arm with no
            // bindings (a zero-payload case, a literal, a wildcard) is exempt.
            guard arm.bindings.isEmpty || arm.bindings.count == ev.associatedValues.count else {
                throw RuntimeError.arityMismatch(
                    expected: ev.associatedValues.count,
                    got: arm.bindings.count,
                    location: HIRExecutor.noLocation
                )
            }
            for (index, name) in arm.bindings.enumerated() {
                guard let name = name else { continue }
                caseEnv.define(name: name, value: ev.associatedValues[index], isMutable: true)
            }
        }
        let previousEnv = currentEnv
        currentEnv = caseEnv
        defer { currentEnv = previousEnv }
        try executeBlock(arm.body)
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
    /// A `match`'s arm selection, once the scrutinee value is in hand.
    ///
    /// Extracted from the `matchStmt` arm so the yield driver can finish a
    /// suspended `match` by calling the same code rather than a second copy of
    /// it. That matters more than it looks: the tail rule below is subtle enough
    /// that a copy would be free to differ, and the difference would show up as
    /// two engines disagreeing about whether an unmatched enum is an error —
    /// exactly the kind of drift the LR-4 unification exists to prevent.
    ///
    /// The carried `scrutineeType` is deliberately not consulted: the
    /// interpreter's rule is value-based (what the value *is* decides which arm
    /// fires), and the static type has already done its work in the lowerer,
    /// where it chose which arm family to build. Reading it here would create a
    /// second dispatch that could disagree with the value.
    private func runMatch(_ cases: [HIRMatchCase], scrutinee value: Value) throws {
        for arm in cases {
            guard
                RuntimeOps.matchArmMatches(
                    caseName: arm.caseName, literal: arm.literal, value: value
                )
            else { continue }
            try executeArm(arm, scrutinee: value)
            return
        }
        // No arm fired — the interpreter's tail rule (D3①, R3): an enum value
        // means the match was not exhaustive *at run time*, and says so with the
        // case name; a bare value keeps the silent fall-through, because a
        // literal's value space is infinite and `case _:` is how the language
        // spells "everything else". Exhaustiveness itself is a checker duty
        // (E3-007), so a shape that reaches here with an enum was not statically
        // coverable.
        if case .enumValue(let ev) = value {
            throw RuntimeError.matchNotExhaustive(
                value: ev.caseName, location: HIRExecutor.noLocation
            )
        }
    }

    /// A try-else's outcome, once the operand's `Result` is in hand. Extracted
    /// for the same reason as `runMatch`, and by the same rule.
    private func runTryResult(
        _ result: Value,
        errorVar: String,
        handler: HIRBlock,
        okTarget: String?
    ) throws {
        guard case .enumValue(let ev) = result,
            ev.parentEnum == RuntimeOps.builtinResultEnumName
        else {
            throw RuntimeError.typeMismatch(
                expected: "Result",
                got: RuntimeOps.describeValueKind(result),
                location: HIRExecutor.noLocation
            )
        }
        let payload = ev.associatedValues.first ?? .null

        if ev.caseName == "ok" {
            // Expression position (`let x = try f() else e: return`) arrives as
            // `allocVar(x, initializer: nil)` followed by this node with
            // `okTarget: x`, so this write is the *initialization* of an
            // already-declared slot. `assign` would misread it as assigning to
            // a `let` and reject a legal program.
            if let okTarget = okTarget {
                try currentEnv.initialize(name: okTarget, value: payload)
            }
            return
        }

        // The handler statements run *here* (not as a block), so `return` /
        // `break` / `continue` inside them leave as signals for the enclosing
        // function or loop to catch, and their bare `pass` terminator just ends
        // the statement.
        let handlerEnv = Environment(enclosing: currentEnv)
        handlerEnv.define(name: errorVar, value: payload, isMutable: true)
        let previousEnv = currentEnv
        currentEnv = handlerEnv
        defer { currentEnv = previousEnv }
        for statement in handler { try execute(statement) }
    }

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

    /// Select and run one `if`/`elif`/`else` branch. Extracted so the frame
    /// layer in the `ifStmt` case can wrap the selection without restating it
    /// — the selection is the same whether or not the `if` carries a label.
    private func executeIfBranch(
        condition: HIRExpr,
        thenBody: HIRBlock,
        elseBody: HIRBlock?
    ) throws {
        if try evaluateCondition(condition) {
            try executeBlock(thenBody)
        } else if let elseBody = elseBody {
            try executeBlock(elseBody)
        }
    }

    /// Mirrors `Interpreter.executeWhile` (标签语法反转 step contract), with the
    /// unwind spoken in depths instead of labels:
    ///
    /// - body completes normally → step runs;
    /// - `continue` for this loop → step runs;
    /// - `break` for this loop → return without running step;
    /// - a `break`/`continue` aimed at an **outer** loop → rethrown one level
    ///   shallower, and this loop's step is skipped. That skip is not an
    ///   oversight: on the AST channel such a signal arrives with a label this
    ///   loop does not match, and a mismatched label is rethrown from the body
    ///   or the step without the step ever running.
    /// - a `return` propagates unchanged, depths being a loop affair only.
    private func executeWhile(condition: HIRExpr, body: HIRBlock, step: HIRBlock?) throws {
        while true {
            if try !evaluateCondition(condition) { break }

            var shouldRunStep = true
            do {
                try executeBlock(body)
            } catch let signal as HIRControlSignal {
                switch signal {
                case .breakSignal(let depth):
                    if depth == 1 { return }
                    throw HIRControlSignal.breakSignal(depth: depth - 1)
                case .continueSignal(let depth):
                    if depth == 1 {
                        shouldRunStep = true
                    } else {
                        throw HIRControlSignal.continueSignal(depth: depth - 1)
                    }
                default:
                    throw signal
                }
            }

            if shouldRunStep, let step = step {
                do {
                    try executeBlock(step)
                } catch let signal as HIRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        if depth == 1 { return }
                        throw HIRControlSignal.breakSignal(depth: depth - 1)
                    case .continueSignal(let depth):
                        if depth == 1 { continue }
                        throw HIRControlSignal.continueSignal(depth: depth - 1)
                    default:
                        throw signal
                    }
                }
            }
        }
    }

    /// Mirrors `Interpreter.executeFor`:
    ///
    /// - the whole iterable is decomposed **before** the first iteration, so a
    ///   pattern/element arity mismatch is an error even over an empty
    ///   collection (that is why `decomposePatternRow` is shared, not restated);
    /// - a dictionary row is `(key, value)` positionally and is *not* run
    ///   through the per-element decomposition, so its 2-field guard is the only
    ///   arity check on that path;
    /// - each iteration gets a fresh `Environment` chained onto the current one,
    ///   with `_` slots binding nothing and pattern names bound mutable;
    /// - the step block runs **inside that same environment**, so a pattern name
    ///   is still visible there (`testDiffStep` pins it);
    /// - `break` skips the step of the loop being left, `continue` runs it, and
    ///   an outer-aimed signal is rethrown shallower with this step skipped —
    ///   the same rule as `executeWhile`, so the two loops are one contract.
    private func executeForIn(
        pattern: [String],
        kind: HIRForIterableKind,
        iterable: HIRExpr,
        body: HIRBlock,
        step: HIRBlock?
    ) throws {
        let iterValue = try evaluate(iterable)
        var rows: [[Value]] = []
        // `kind` is the contract's ("`kind` decides how elements are read") and
        // the runtime shape is the interpreter's check; requiring them to agree
        // is what keeps this from being a second, looser, semantics.
        switch (kind, iterValue) {
        case (.array, .array(let elements)), (.set, .set(let elements)):
            rows = try elements.map {
                try RuntimeOps.decomposePatternRow(
                    $0, patternCount: pattern.count, location: HIRExecutor.noLocation
                )
            }
        case (.dict, .dictionary(let pairs)):
            guard pattern.count == 2 else {
                throw RuntimeError.typeMismatch(
                    expected: "字典迭代需 2 字段模式元组 (k, v)",
                    got: "\(pattern.count) 字段",
                    location: HIRExecutor.noLocation
                )
            }
            rows = pairs.map { [$0.0, $0.1] }
        default:
            throw RuntimeError.typeMismatch(
                expected: "可迭代集合（数组/字典/集合）",
                got: "\(iterValue)",
                location: HIRExecutor.noLocation
            )
        }

        for row in rows {
            let loopEnv = Environment(enclosing: currentEnv)
            for (index, name) in pattern.enumerated() where name != "_" {
                loopEnv.define(name: name, value: row[index], isMutable: true)
            }
            let previousEnv = currentEnv
            currentEnv = loopEnv

            do {
                try executeBlock(body)
            } catch let signal as HIRControlSignal {
                switch signal {
                case .breakSignal(let depth):
                    currentEnv = previousEnv
                    if depth == 1 { return }
                    throw HIRControlSignal.breakSignal(depth: depth - 1)
                case .continueSignal(let depth):
                    if depth > 1 {
                        currentEnv = previousEnv
                        throw HIRControlSignal.continueSignal(depth: depth - 1)
                    }
                // Aimed at this loop: the step still runs, and it runs in
                // the loop environment — so `currentEnv` deliberately stays
                // on `loopEnv` across this catch.
                default:
                    currentEnv = previousEnv
                    throw signal
                }
            }

            if let step = step {
                do {
                    try executeBlock(step)
                } catch let signal as HIRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        currentEnv = previousEnv
                        if depth == 1 { return }
                        throw HIRControlSignal.breakSignal(depth: depth - 1)
                    case .continueSignal(let depth):
                        currentEnv = previousEnv
                        if depth == 1 { continue }
                        throw HIRControlSignal.continueSignal(depth: depth - 1)
                    default:
                        currentEnv = previousEnv
                        throw signal
                    }
                }
            }

            currentEnv = previousEnv
        }
    }

    // MARK: - Calls

    /// Build the value half of a callable and register its body half beside it.
    ///
    /// The one place a function value is created, so the two halves cannot be
    /// built apart: every `.function` that reaches the engine's own lookup was
    /// registered here, and the lookup failing therefore means the value came
    /// from somewhere else (a hand-built module) rather than from a missing
    /// `make` call somewhere.
    private func makeFunctionValue(
        name: String,
        paramNames: [String],
        body: HIRBlock,
        returnLabels: [String?],
        closure: Environment
    ) -> Value {
        let function = FunctionValue(
            name: name,
            params: paramNames.map { Parameter(name: $0) },
            closure: closure
        )
        callableBodies[ObjectIdentifier(function)] = HIRCallableBody(
            paramNames: paramNames,
            body: body,
            returnLabels: returnLabels
        )
        return .function(function)
    }

    /// The component names a declared return type carries, when it is a named
    /// tuple (`-> (商: I32, 余: I32,)`). A scalar, a positional tuple and a
    /// void return all yield nothing, and `applyReturnLabels` then leaves the
    /// value untouched.
    private static func declaredReturnLabels(_ type: HIRType?) -> [String?] {
        guard let type = type, case .tuple(let labels, _) = type else { return [] }
        return labels
    }

    /// Call a module-level function by its declaration.
    ///
    /// A module-level function is an ordinary case of the call path: its parent
    /// environment is the global one and its labels come from its declared
    /// return type. Together with the function-value case in `evaluate` this is
    /// the whole of "how a call happens" — see `invoke` for why that matters.
    private func call(_ function: HIRFunction, args: [Value]) throws -> Value {
        try invoke(
            HIRCallableBody(
                paramNames: function.params.map { $0.name },
                body: function.body,
                returnLabels: HIRExecutor.declaredReturnLabels(function.returnType),
                isAsync: function.isAsync
            ),
            parent: globalEnv,
            args: args,
            name: function.name
        )
    }

    /// Run a lowered body against an argument list — the single call path,
    /// shared by module-level functions and by function values.
    ///
    /// This was `call` until P2a grid G3, and it could be `call` because every
    /// callable was a module-level function and its parent environment could be
    /// written down as the global one. A closure's parent is the environment it
    /// closed over instead, so the parent became a parameter. Extracting the
    /// path rather than writing a second one is the point: the arity check, the
    /// depth guard, the defer scope, the return-label rule and the trailing
    /// expression rule are each a rule that two call paths would otherwise be
    /// free to disagree about, and the disagreement would show up as one channel
    /// computing something the other cannot.
    ///
    /// Argument binding mirrors `Interpreter.executeFunctionBody`: parameters
    /// bound mutable, `return` caught here and unwrapped to the returned value
    /// (`nil` → `.null`). The one deliberate difference from the module-level
    /// case is *where the parent comes from*, and that is the caller's argument.
    /// Calls a function value the engine holds a body for.
    ///
    /// The body is keyed by identity rather than by name: the parser gives every
    /// anonymous `func` the name `<anon>`, so a name index would let two
    /// closures overwrite each other. The parent environment is the value's own,
    /// not the global one — that is the single rule separating a closure call
    /// from a module-level one, and the reason the call path is parameterised
    /// rather than copied.
    ///
    /// Shared by the indirect-call arm and `lazyRefValue`: the latter is the
    /// same operation with a different trigger, so giving it its own copy would
    /// create a second place for the rule to be got wrong.
    private func callFunctionValue(_ function: FunctionValue, args: [Value]) throws -> Value {
        guard let callable = callableBodies[ObjectIdentifier(function)] else {
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: a function value with no registered body "
                    + "(hand-built, or carried in from another run) cannot be called",
                location: HIRExecutor.noLocation
            )
        }
        return try invoke(callable, parent: function.closure, args: args, name: function.name)
    }

    private func invoke(
        _ callable: HIRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> Value {
        guard callable.paramNames.count == args.count else {
            throw RuntimeError.arityMismatch(
                expected: callable.paramNames.count,
                got: args.count,
                location: HIRExecutor.noLocation
            )
        }

        // The arity check stays above the dispatch on purpose: it is a property
        // of the call, not of the thread the body ends up on, and a spawned
        // body's arity error would otherwise surface as a rejected Future the
        // caller may never inspect rather than as a failure at the call site.
        if callable.isAsync {
            return try spawnAsync(callable, parent: parent, args: args, name: name)
        }
        return try invokeBody(callable, parent: parent, args: args, name: name)
    }

    /// Run an async body on a worker thread; hand the caller a pending Future.
    ///
    /// Mirrors the interpreter's `isAsync` branch, because the two engines have
    /// to agree about more than the value: linking the child to its parent
    /// *before* the body can run, setting the task handle on the worker rather
    /// than the caller, and closing the scope on **both** exits are each a rule
    /// a second copy would be free to get wrong — and getting the scope close
    /// wrong shows up as a leak warning at best and a silently dropped failure
    /// at worst.
    private func spawnAsync(
        _ callable: HIRCallableBody, parent: Environment, args: [Value], name: String
    ) throws -> Value {
        let future = FutureValue()
        currentFuture?.addChild(future)
        let captured = callable
        let boundArgs = args
        scheduler.spawn(future) { [weak self] in
            guard let self = self else {
                throw RuntimeError.invalidOperation(
                    reason: "HIR executor: the engine was released while an async body ran",
                    location: HIRExecutor.noLocation
                )
            }
            let previousFuture = self.currentFuture
            self.currentFuture = future
            defer { self.currentFuture = previousFuture }
            do {
                try RuntimeOps.checkCancellation(self.currentFuture)
                switch try self.invokeBodyStep(
                    captured, parent: parent, args: boundArgs, name: name
                ) {
                case .finished(let result):
                    // The strict structured rule's closing act: cancel whatever
                    // was never joined, and let a failure that nobody consumed
                    // surface at this boundary instead of vanishing.
                    return .finished(HIRExecutor.closeTask(future, value: result))
                case .givenUp(let frame):
                    // The thread goes back to the pool with nothing sent to the
                    // future. The body is not done, and the resumer owns
                    // completion from here — which is the entire content of
                    // "the task was given up".
                    self.attachResume(frame, task: future)
                    return .suspended
                }
            } catch {
                // The throwing path closes the scope too — a body that dies must
                // not leave its children running.
                future.closeScope()
                throw error
            }
        }
        return .future(future)
    }

    /// The closing act a task performs once, however many runs it took.
    private static func closeTask(_ future: FutureValue, value: Value) -> Value {
        RuntimeOps.flipIfLeaked(value, leaked: future.closeScope())
    }

    /// The synchronous body path: bind the arguments, run the statements, unwrap
    /// the return signal.
    ///
    /// Since `DE-2b` this is a wrapper over `invokeBodyStep` rather than the body
    /// loop itself, so that the two callers share one prologue and one exit rule.
    /// The unwrap below is the whole of what being synchronous means here, and
    /// since the driver tries yielding only inside an async body it can no longer
    /// fire on a program: a synchronous body keeps occupying the thread at a
    /// join, `await` and `wait` alike. It stays as a guard on this engine rather
    /// than on its inputs — a suspension arriving here means the driver offered a
    /// resume where none can exist, which is a defect in the driver and not a
    /// program outcome, so it is named rather than papered over.
    private func invokeBody(
        _ callable: HIRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> Value {
        switch try invokeBodyStep(callable, parent: parent, args: args, name: name) {
        case .finished(let value):
            return value
        case .givenUp:
            throw RuntimeError.invalidOperation(
                reason: "HIR executor: a synchronous body gave its task up at a join "
                    + "— the yield envelope and the driver disagree about what can suspend",
                location: HIRExecutor.noLocation
            )
        }
    }

    /// Enter a body and run it, reporting a suspension rather than hiding it.
    ///
    /// The prologue is `invokeBody`'s, unchanged: depth guard, argument binding,
    /// environment, defer scope. What differs is the exit. A body that finished
    /// unwinds exactly as before. A body that gave the task up must **not** unwind
    /// — running its `defer`s at a suspension would be a semantic change, not a
    /// cleanup — and must leave the worker thread clean, which `standDown` does
    /// and the comment there explains.
    private func invokeBodyStep(
        _ callable: HIRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> HIRBodyStep {
        guard callDepth < RuntimeOps.maxCallDepth else {
            throw RuntimeOps.recursionGuardError()
        }
        callDepth += 1
        callStackNames.append(name)

        let callEnv = Environment(enclosing: parent)
        for (index, name) in callable.paramNames.enumerated() {
            callEnv.define(name: name, value: args[index], isMutable: true)
        }

        let previousEnv = currentEnv
        currentEnv = callEnv

        // A function body is a defer scope of its own — the interpreter opens one
        // in `executeFunctionBody` rather than routing through `executeBlock`,
        // because it also owns the `lastValue` rule. Registration order is the
        // interpreter's and is load-bearing: the defers run *before* the
        // environment restore, so they still see the function's own environment.
        // That order is now spelled out in `exitBody` instead of by two Swift
        // `defer`s, because a suspended body must not take either of them.
        pushDeferScope()

        let step: HIRBodyStep
        do {
            step = try bodyOutcome(returnLabels: callable.returnLabels) {
                try self.driveStatements(
                    callable, previousEnv: previousEnv, from: 0, lastValue: .null,
                    yieldable: callable.isAsync, pending: nil
                )
            }
        } catch {
            // A body that dies leaves nothing behind: the scope closes and the
            // context unwinds exactly as it does on a normal return.
            try? popDeferScope()
            currentEnv = previousEnv
            callDepth -= 1
            callStackNames.removeLast()
            throw error
        }

        switch step {
        case .finished:
            try? popDeferScope()
            currentEnv = previousEnv
            callDepth -= 1
            callStackNames.removeLast()
        case .givenUp:
            standDown()
        }
        return step
    }

    /// Pick a given-up body back up, on whichever thread the awaited future
    /// settled on.
    ///
    /// No prologue: the arguments were bound before the body gave the task up,
    /// and their environment is the one in the frame. Re-entering through the
    /// prologue would rebind them over a body that has already moved past them,
    /// which is how a resumed body would quietly restart with fresh parameters.
    private func resumeBody(_ frame: HIRYieldFrame, awaited: Value) throws -> HIRBodyStep {
        currentEnv = frame.env
        callDepth = frame.callDepth
        callStackNames = frame.callStackNames
        deferStack = frame.deferStack
        currentFuture = frame.currentFuture

        let step: HIRBodyStep
        do {
            step = try bodyOutcome(returnLabels: frame.callable.returnLabels) {
                try self.driveStatements(
                    frame.callable, previousEnv: frame.previousEnv, from: frame.index,
                    lastValue: frame.lastValue, yieldable: frame.callable.isAsync,
                    pending: (resume: frame.finish, value: awaited)
                )
            }
        } catch {
            try? popDeferScope()
            currentEnv = frame.previousEnv
            callDepth -= 1
            callStackNames.removeLast()
            throw error
        }

        switch step {
        case .finished:
            try? popDeferScope()
            currentEnv = frame.previousEnv
            callDepth -= 1
            callStackNames.removeLast()
        case .givenUp:
            standDown()
        }
        return step
    }

    /// Leave the worker thread with nothing of this body left on it.
    ///
    /// The four thread-locals are *cleared* rather than restored, and that is not
    /// tidiness: a suspended body has no outer frame to restore to, because the
    /// thread it was on goes back to the pool and the body continues somewhere
    /// else. Leaving them set would let the next task to land on this thread
    /// enter with a non-zero call depth, a stranger's backtrace and a stranger's
    /// defer scopes — and the depth one would present as a recursion-guard error
    /// on an unrelated task, which is about the least diagnosable shape a bug can
    /// take. The frame carries the real values, so nothing is lost by clearing.
    private func standDown() {
        callDepthStorage.value = nil
        callStackNames = []
        deferStack = []
        currentEnvStorage.value = nil
    }

    /// The body loop's signal rule, shared so the first run and every resumed run
    /// apply it once instead of twice: a `return` is the body's own and becomes
    /// the value, with the interpreter's return-site labels applied; every other
    /// signal belongs to a loop or a function further out and is rethrown intact.
    private func bodyOutcome(
        returnLabels: [String?],
        _ run: () throws -> HIRBodyStep
    ) throws -> HIRBodyStep {
        do {
            return try run()
        } catch let signal as HIRControlSignal {
            if case .returnSignal(let value) = signal {
                // P2a G2: the interpreter's return-site rule, fed from the declared
                // return type instead of the AST's `returnLabels` (the engine
                // has no AST). Only the explicit `return` path is relabelled:
                // an implicit trailing expression is left alone because the
                // interpreter leaves it alone too, and relabelling it here
                // would invent a difference rather than remove one.
                //
                // A closure passes no labels, and that is a mirror rather than a
                // shortcut: the interpreter builds a closure's `FunctionValue`
                // with no declaration attached, so its return-label list is empty
                // and the rule has nothing to apply there either.
                return .finished(RuntimeOps.applyReturnLabels(returnLabels, to: value ?? .null))
            }
            throw signal
        }
    }

    /// Run a body's statements, and report a suspension instead of causing one.
    ///
    /// `pending` is how a resumed run rejoins the loop: the statement at `from`
    /// was already started before the task was given up, so it is finished with
    /// the awaited value and the loop carries on from the statement after it. The
    /// `lastValue` accumulator travels in the frame for the same reason the index
    /// does — it is part of where the body was, and a resumed body that dropped it
    /// would return the wrong value for a body whose last statement is an
    /// expression.
    /// - Parameter yieldable: whether the body this loop belongs to may give the
    ///   task up at all. Only an async body may, and the reason is semantic rather
    ///   than mechanical: `await` says the *site* may yield, but yielding needs a
    ///   body that can be resumed part-way, and only an async body has a task to
    ///   give up in the first place. A synchronous body has none, so an `await`
    ///   written there keeps the older behaviour — it occupies the thread, exactly
    ///   as `wait` does. That is not a fallback invented here: an existing
    ///   criterion pins it (`ConcurrencyJoinFormTests`, "both forms agree while
    ///   yielding is absent"), so treating it as an error would have this batch
    ///   change a program's meaning instead of adding a capability to it.
    private func driveStatements(
        _ callable: HIRCallableBody,
        previousEnv: Environment,
        from index: Int,
        lastValue: Value,
        yieldable: Bool,
        pending: (resume: (Value) throws -> Value?, value: Value)?
    ) throws -> HIRBodyStep {
        let body = callable.body
        var last = lastValue
        var position = index
        if let pending = pending {
            if let updated = try pending.resume(pending.value) { last = updated }
            position = index + 1
        }

        while position < body.count {
            let statement = body[position]
            if debugHook != nil, let location = body.position(at: position) {
                try debugPause(at: location)
            }

            if yieldable, let plan = yieldPlan(for: statement) {
                // The operand is evaluated synchronously and deliberately: it is
                // the thing that *produces* the future, so it cannot itself be
                // waiting on one. A join nested inside it is refused by the
                // lowerer, which is what keeps this call off the recursive path.
                let operand = try evaluate(plan.operand)
                guard case .future(let fut) = operand else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(operand),
                        location: HIRExecutor.noLocation
                    )
                }

                // A settled future is not a reason to give the task up. Taking
                // the value straight away keeps `await` on the same path as `wait`
                // whenever there is nothing to wait for — which is both cheaper
                // and observably calmer, since it costs no task switch to collect
                // a child that has already finished.
                //
                // The third case is the back end answering "not this time". `await`
                // promises to give the task up, but that promise needs a back end
                // that can hand the OS thread back, and a back end that cannot is
                // not a broken configuration — it is a compliant one (DE-1 §6.2
                // discipline 3: degrade, do not fail). So the wait is taken
                // occupying the thread instead, exactly as `wait` would, and
                // nothing is reported. Giving the task up here would be worse than
                // degrading: a suspended body whose future can only be settled by
                // someone this back end will never schedule is a deadlock, and a
                // deadlock is not a "supported with reduced semantics" reading of
                // `await` — it is a program that stops.
                if fut.isFinished {
                    let value = RuntimeOps.joinFuture(fut, timeoutMs: nil, form: .awaits)
                    if let updated = try finishYield(plan, value: value) { last = updated }
                } else if scheduler.yieldTask() == 1 {
                    return .givenUp(
                        HIRYieldFrame(
                            callable: callable,
                            index: position,
                            finish: { [weak self] value in
                                guard let self = self else { return nil }
                                return try self.finishYield(plan, value: value)
                            },
                            awaited: fut,
                            env: currentEnv,
                            previousEnv: previousEnv,
                            lastValue: last,
                            callDepth: callDepth,
                            callStackNames: callStackNames,
                            deferStack: deferStack,
                            currentFuture: currentFuture
                        )
                    )
                } else {
                    let value = RuntimeOps.joinFuture(fut, timeoutMs: nil, form: .awaits)
                    if let updated = try finishYield(plan, value: value) { last = updated }
                }
            } else if case .exprStmt(let expr) = statement {
                last = try evaluate(expr)
            } else {
                try execute(statement)
            }
            position += 1
        }
        return .finished(last)
    }

    /// The statement positions the driver knows how to give the task up at, and
    /// only those. See `HIRYieldPlan` for why this is a whitelist.
    private func yieldPlan(for statement: HIRStmt) -> HIRYieldPlan? {
        let plan: HIRYieldPlan?
        switch statement {
        case .exprStmt(.join(let operand, _, .awaits)):
            plan = .expressionStatement(operand: operand)

        case .allocVar(let name, let type, let mutable, .some(.join(let operand, _, .awaits))):
            plan = .varInitializer(operand: operand, name: name, type: type, mutable: mutable)

        case .matchStmt(.join(let operand, _, .awaits), let cases, _):
            plan = .matchScrutinee(operand: operand, cases: cases)

        case .tryStmt(.join(let operand, _, .awaits), let errorVar, let handler, let okTarget, _):
            plan = .tryOperand(operand: operand, errorVar: errorVar, handler: handler, okTarget: okTarget)

        default:
            plan = nil
        }
        return plan
    }

    /// Finish the statement a given-up body stopped in, from the awaited value.
    ///
    /// The `var` case is the one that is not a one-liner, and it is the one worth
    /// reading. The initializer is **not** the last thing that statement does:
    /// two further steps follow it inside the same arm — the value-type copy and
    /// the binding-site relabel — and both are load-bearing. A resume that only
    /// remembered "the initializer is done" would skip them and bind a value that
    /// is neither copied nor relabelled, and the difference would not show up in
    /// the output of an ordinary program: it surfaces only where a value type
    /// shares storage with its copy. So the whole tail of the arm is replayed
    /// here, and this function is the one place that knows it.
    ///
    /// Returning `nil` means "this statement did not contribute a value", which is
    /// the loop's `lastValue` rule: only an expression statement does.
    private func finishYield(_ plan: HIRYieldPlan, value: Value) throws -> Value? {
        switch plan {
        case .expressionStatement:
            return value

        case .varInitializer(_, let name, let type, let mutable):
            var bound = RuntimeOps.copyIfStruct(value)
            if case .tuple(let labels, _) = type, labels.contains(where: { $0 != nil }) {
                bound = RuntimeOps.relabelled(bound, with: labels)
            }
            currentEnv.define(name: name, value: bound, isMutable: mutable)
            return nil

        case .matchScrutinee(_, let cases):
            try runMatch(cases, scrutinee: value)
            return nil

        case .tryOperand(_, let errorVar, let handler, let okTarget):
            try runTryResult(value, errorVar: errorVar, handler: handler, okTarget: okTarget)
            return nil
        }
    }

    /// Wait for the future a body gave the task up on, and pick the body up when
    /// it settles.
    ///
    /// The resumption runs on whichever thread settled that future. That is the
    /// point rather than a side effect: no thread is held on this side while the
    /// body waits, so a task that awaits a child costs a continuation instead of
    /// a worker — which is what makes the bounded pool a bound rather than a
    /// queue of parked threads.
    private func attachResume(_ frame: HIRYieldFrame, task: FutureValue) {
        frame.awaited.whenResolved { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .success(let value):
                self.completeResumedRun(frame, task: task, value: value)
            case .failure(let error):
                // The body never gets its value, so it never reaches its own
                // closing act; the scope has to be closed here or its children
                // keep running under a task that is already over. Whatever the
                // close reports as leaked is dropped on purpose: this task is
                // failing on its own account, and folding an aggregate of
                // nobody-joined children into the error would replace the reason
                // the await failed with a list of bystanders.
                _ = task.closeScope()
                task.reject(error)
            }
        }
    }

    /// Run a resumed body to its next stopping point and settle the task.
    private func completeResumedRun(_ frame: HIRYieldFrame, task: FutureValue, value: Value) {
        do {
            switch try resumeBody(frame, awaited: value) {
            case .finished(let result):
                task.resolve(HIRExecutor.closeTask(task, value: result))
            case .givenUp(let next):
                attachResume(next, task: task)
            }
        } catch {
            // `resumeBody` turns a return signal into a value, so a control
            // signal arriving here is one that escaped past the body it belonged
            // to — a defect in the driver rather than a program outcome. It is
            // reported as such instead of being read as a failure of the await.
            // Leaked children are dropped for the same reason as above.
            _ = task.closeScope()
            task.reject(GCDScheduler.coerce(error))
        }
    }
}
