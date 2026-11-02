import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// How `break` / `continue` / `return` leaves the statement layer: the IR carries an unwind depth, not a label.
/// The lowerer maps labels to depths and turns an unresolvable one into `panicStmt`, so depth is the vocabulary.
/// The AST channel's `ControlSignal` speaks labels, so reusing it would re-decide the mapping inside every loop.
enum IRControlSignal: Error {
    /// Leave the enclosing function with this value; `nil` = void return.
    case returnSignal(Value?)
    /// Unwind `depth` enclosing loops; 1 = the innermost.
    case breakSignal(depth: Int)
    /// Resume the `depth`-th enclosing loop's header; 1 = the innermost.
    case continueSignal(depth: Int)
}

/// The half of a callable a function *value* cannot carry: `Value.function` holds an AST `Block?`, not `[IRStmt]`.
/// So the body sits in a table on the executor; the value keeps identity, its closed-over environment, and its name.
/// No environment field here: it is fixed at creation, belongs with the value, and two closures must not share one.
private struct IRCallableBody {
    /// Parameter names in declaration order — the order the arguments bind in.
    let paramNames: [String]
    let body: IRBlock
    /// Component labels of a declared named-tuple return; empty when the return
    /// carries none, which is what the return-site rule reads.
    let returnLabels: [String?]
    /// `=>` dispatch: this body runs on a worker thread and its caller receives a pending Future, not the value.
    /// A closure body stays false on this channel: the lowered closure node carries no async flag, and no fixture reaches it.
    /// That is a boundary, not an oversight.
    let isAsync: Bool

    init(paramNames: [String], body: IRBlock, returnLabels: [String?], isAsync: Bool = false) {
        self.paramNames = paramNames
        self.body = body
        self.returnLabels = returnLabels
        self.isAsync = isAsync
    }
}

/// What one run of a body produced: two outcomes and no third.
/// A body either reached its end, or it stopped at a join and gave the task up.
/// A caller that cannot tell them apart cannot leave the worker thread — that is `await` versus `wait`.
private enum IRBodyStep {
    case finished(Value)
    case givenUp(IRYieldFrame)
}

/// A body that gave its task up, with everything needed to pick it up.
/// A suspension returns from the Swift call that ran the body, so locals and thread-locals go with it.
/// It carries call depth, call stack and defer stack — else the resume runs no `defer`s — plus the exact environment.
private struct IRYieldFrame {
    /// The callable whose body is part-way through.
    let callable: IRCallableBody
    /// The statement the body stopped in, counted in that body's statement list.
    let index: Int
    /// Finish the statement at `index` with the awaited value, then carry on.
    let finish: (Value) throws -> Value?
    /// The future this body gave the task up for.
    let awaited: FutureValue
    let env: Environment
    /// The environment to hand back to the caller when the body finally ends.
    /// Carried, not recomputed: it belongs to the run, and the resumed Swift caller is a continuation, not the entering frame.
    /// Getting this wrong is quiet: only the next statement on that thread reads a stale environment.
    let previousEnv: Environment
    /// The `lastValue` accumulator at the moment of suspension — see
    /// `driveStatements` for why it is part of where the body was.
    let lastValue: Value
    let callDepth: Int
    let callStackNames: [String]
    let deferStack: [[IRBlock]]
    let currentFuture: FutureValue?
}

/// The statement positions a join may give the task up at: the driver's half of the yield envelope.
/// The lowerer refuses everything else; an unplanned position here would degrade the join to a blocking wait.
/// Hence a `switch` with no `default`: bare statement, `var` initializer, `match` scrutinee, try-else operand.
private enum IRYieldPlan {
    /// S1 — the join is the whole expression statement, so its value is the
    /// statement's value.
    case expressionStatement(operand: IRExpr)
    /// S2 — the join is a `var` initializer.
    case varInitializer(operand: IRExpr, name: String, type: IRType, mutable: Bool)
    /// S3 — the join is a `match` scrutinee.
    case matchScrutinee(operand: IRExpr, cases: [IRMatchCase])
    /// S4 — the join is the operand of a try-else.
    case tryOperand(operand: IRExpr, errorVar: String, handler: IRBlock, okTarget: String?)

    /// The expression whose value is the future: evaluated synchronously, before
    /// any decision to give the task up is made.
    var operand: IRExpr {
        switch self {
        case .expressionStatement(let operand),
            .varInitializer(let operand, _, _, _),
            .matchScrutinee(let operand, _),
            .tryOperand(let operand, _, _, _):
            return operand
        }
    }
}

/// Runs a lowered `IRModule` directly: the third live channel beside the AST interpreter and IR → LLVM.
/// Every node is dispatched with no `default:`; rendering and operators are the interpreter's (`stringifyValue`).
/// 跨线程可达（异步体与就绪循环都捕获本实例）：模块表装载后只读，运行时状态在 ThreadLocal 与 `instanceLock` 内。
public final class IRExecutor: DebugHookHost, @unchecked Sendable {

    // MARK: - Host surface

    /// Line output channel. Mirrors `Interpreter.outputSink` so a caller can
    /// redirect both engines' stdout through the same funnel and diff them.
    public var outputSink: (String) -> Void = { line in print(line) }

    /// Debug pause hook — the other half of `DebugHookHost`, the same type the interpreter exposes.
    /// Consulted in `executeStatements` before each statement, on the line its `positions` entry names, so both engines agree.
    /// A pause with no line reports `noLocation`, and breakpoints match by line, so the hook needs positions.
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    // MARK: - Module state

    /// Module-level functions by name. The IR has no module-level closures: `main` and its peers are the only callables.
    /// Closure values live in `callableBodies`; the lowerer materialises trait default bodies here, not into a type.
    private var functions: [String: IRFunction] = [:]

    /// Type methods by **lowered** name (`方法__类型`), flattened out of every `IRTypeDecl`.
    /// A call to one is an ordinary `.call` — the receiver travels as first argument — so the module table is consulted first.
    /// Keys are the lowered name, never re-derived: a generic type's methods live under `盒_I32`, and re-mangling would drift.
    private var methods: [String: IRFunction] = [:]

    private var types: [String: IRTypeDecl] = [:]
    /// 默认实例的**记忆表**（类型名 → 物化好的实例）。
    /// 首次取用物化并记住，之后直接返回缓存值；与发射层「槽位 + 两级锁」同语义。
    /// 异步体的取用可能落在工作者线程，故用可重入锁包住「查—造—存」整段，保证恰一次。
    private let instanceLock = NSRecursiveLock()
    private var givenInstances: [String: Value] = [:]
    private var enums: [String: IREnumDecl] = [:]

    /// The foreign callees this module declared, from `[名称|foreign]` blocks, keyed by callee name.
    /// The gate matters: otherwise a program that never declared `malloc` could call it here, and the AST channel refuses that.
    /// A map, not a set: a shim miss falls to a raw C binding, and the thunk needs the declared library and signature.
    private var foreignDecls: [String: (library: String, function: IRForeignFunction)] = [:]

    /// 外部数据符号的声明：库名、类型、只读。地址在装载期解析一次，与函数同一时机。
    private var foreignDataDecls: [String: (library: String, type: IRType, isReadonly: Bool)] = [:]
    /// 已解析的符号地址。与声明分开：装载期只填这张表，求值只读它，两者生命周期不同。
    private var foreignDataAddresses: [String: RawPointerValue] = [:]

    /// Library handles for raw C bindings, cached by library name.
    /// Per engine, not process-wide: a shared handle table would make "when is it safe to close" a question with no owner.
    /// Two engines, two caches, one resolution routine.
    private let ffiLoader = FFILoader()

    /// The package's `[ffi]` table, for `search_paths`.
    private let ffiConfig: FFIConfig

    /// Bodies of the function *values* built while running, keyed by value identity.
    /// Not by name: every closure literal is `<anon>`, so a name key would let one closure run another's body.
    /// That is the notion `Value.==` already uses; per-run state, cleared by `prepare`.
    private var callableBodies: [ObjectIdentifier: IRCallableBody] = [:]

    private let globalEnv: Environment

    /// Where an async body is dispatched: the blocking back end, which is the production semantics and not a placeholder.
    /// An injected value wins over the language-side default (`resolveSchedulerFromLanguage`) and skips resolution entirely.
    /// The seam exists so a criterion can stand in a back end that declines to yield and witness the degrade-not-fail rule.
    private let injectedScheduler: Scheduler?

    /// 派发点实际用的后端。**只在 `prepare` 里被改写一次** —— 那之后才可能有工作线程
    /// ⇒ 不需要锁。初值取注入值或主后端，故任何路径上它都不是空的。
    private var scheduler: Scheduler

    // MARK: - Per-thread execution state

    /// These four describe *the thread that is executing*, not the engine.
    /// `=>` dispatch keeps a worker and its joining caller live at once, both touching this state.
    /// The interpreter's same four raced into SIGTRAP/SIGSEGV; `ThreadLocal` fixes it without changing any read's shape.
    private let currentEnvStorage = ThreadLocal<Environment>()
    private let callDepthStorage = ThreadLocal<Int>()
    private let callStackStorage = ThreadLocal<[String]>()
    private let deferStackStorage = ThreadLocal<[[IRBlock]]>()

    /// The task this thread runs inside, when it runs inside one.
    /// Spawn links the new task here, which makes the dispatch tree and the cancellation tree one tree, as on the AST side.
    /// Thread-local: a worker must not adopt its caller's task, or the parent's return would cancel the wrong set.
    private let currentFutureStorage = ThreadLocal<FutureValue>()
    private var currentFuture: FutureValue? {
        get { currentFutureStorage.value }
        set { currentFutureStorage.value = newValue }
    }

    /// The environment the current thread is executing in.
    /// A thread that entered nothing reads the global one; a worker's first act is to enter its own call environment.
    private var currentEnv: Environment {
        get { currentEnvStorage.value ?? globalEnv }
        set { currentEnvStorage.value = newValue }
    }

    /// How many bodies the host is currently inside.
    /// Reported, not decided on: the stack left on the running thread settles whether one more may be entered.
    /// The count once decided that, but heavy shapes smashed the stack first; the depth survives for diagnostics.
    private var callDepth: Int {
        get { callDepthStorage.value ?? 0 }
        set { callDepthStorage.value = newValue }
    }

    /// Names of the functions currently entered, innermost last — the backtrace a debugger reads.
    /// Pushed and popped around a body exactly where `callDepth` is, so a depth never names a hole.
    private var callStackNames: [String] {
        get { callStackStorage.value ?? [] }
        set { callStackStorage.value = newValue }
    }

    /// Open defer scopes, innermost last; a scope holds its `defer` statements in registration order.
    /// Each `defer` holds the group it wraps, so popping runs groups in reverse and statements within one in source order.
    /// A flat reversed list would invert a defer whose body lowered to several nodes.
    private var deferStack: [[IRBlock]] {
        get { deferStackStorage.value ?? [] }
        set { deferStackStorage.value = newValue }
    }

    /// Directory an unprefixed relative IO path resolves against, mirroring `Interpreter.programBase`.
    /// Without it the channels would silently disagree, reading the CWD copy instead of failing.
    /// Optional so an executor that never touches IO, and bare test hosts, behave as before.
    private let programBase: String?

    /// 命令行参数（脚本路径之后的裸参数），与解释器的同名属性同义 ——
    /// `argv()` 内建的唯一来源，镜像而不另造。
    public var processArguments: [String] = []

    public convenience init(programBase: String? = nil, ffiConfig: FFIConfig = .default) {
        self.init(programBase: programBase, ffiConfig: ffiConfig, scheduler: nil)
    }

    /// The engine with an explicit back end, or with `nil` and therefore with the language's own default.
    /// Production passes `nil`; an explicit back end overrides the language's choice, e.g. one answering `0` to `yieldTask()`.
    /// Nothing branches on the difference: the back end answers, the engine obeys.
    init(programBase: String?, ffiConfig: FFIConfig, scheduler: Scheduler?) {
        self.globalEnv = Environment()
        self.programBase = programBase
        self.ffiConfig = ffiConfig
        self.injectedScheduler = scheduler
        self.scheduler = scheduler ?? GCDScheduler.shared
        // `currentEnv` is deliberately not seeded: its per-thread box answers `globalEnv` until a thread enters.
        // A seed would write the same value the hard way, and init-time writes through a computed property read `self` unbuilt.
    }

    // MARK: - Entry points

    /// 派发点当前后端的**能力自述**（只读，供诊断与判据），是语言侧接线 `resolveSchedulerFromLanguage` 的读侧。
    /// 降级后的程序结果不变，故光看输出区分不出「声明被读到了」与「引擎根本没理那句声明」。
    /// 没有本属性，「派发点用语言侧那个调度器」这句话就没有可观测面。
    var dispatchBackEndCapabilities: ConcurrencyCapabilities { scheduler.capabilities }

    public func prepare(module: IRModule) throws {
        /// 结构不变量先过一遍：解释器与发射器同样按槽名、字段名、用例名取用，破了不该等运行时撞。
        try IRValidator.check(module)
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
        foreignDataDecls = [:]
        for block in module.foreigns {
            for function in block.funcs {
                foreignDecls[function.name] = (library: block.name, function: function)
            }
            for entry in block.data {
                foreignDataDecls[entry.name] = (
                    library: block.name, type: entry.type, isReadonly: entry.isReadonly)
            }
        }
        try resolveForeignsEagerly()
        // 派发点的后端由语言侧决定（`resolveSchedulerFromLanguage`）：解析落在这里，因为那份声明要等类型表装好才读得到。
        // 也正因为落在装载期、任何工作线程出现之前，`scheduler` 那个 `var` 不需要锁。
        // 注入值在场时不解析：注入是宿主在构造期说的，判据正是经它摆进替身后端的。
        if injectedScheduler == nil {
            scheduler = resolveSchedulerFromLanguage()
        }
    }

    /// Resolves every declared foreign symbol now: libc shim table first, then a raw `dlsym`, as the interpreter does.
    /// The interpreter fails at registration with `symbolNotFound`; resolving only at call sites would defer that failure.
    /// `FFILoader` caches handles, so the call sites do not repeat the work.
    private func resolveForeignsEagerly() throws {
        for (name, foreign) in foreignDecls where RuntimeOps.libcShims[name] == nil {
            _ = try ffiLoader.resolve(
                library: foreign.library, symbol: name,
                searchPaths: ffiConfig.searchPaths, location: IRExecutor.noLocation
            )
        }
        /// 数据符号没有 shim 表可让位：声明了就必须解析得到，否则读到的地址无处可来。
        foreignDataAddresses = [:]
        for (name, entry) in foreignDataDecls {
            let symbol = try ffiLoader.resolve(
                library: entry.library, symbol: name,
                searchPaths: ffiConfig.searchPaths, location: IRExecutor.noLocation
            )
            foreignDataAddresses[name] = RawPointerValue(
                pointer: symbol, elemType: annotation(for: entry.type), freesMemory: false)
        }
    }

    /// 外部数据符号的字节读写按声明宽度走，而指针原语吃 `TypeAnnotation`。
    /// 只映射 C 兼容标量与指针：其余类型在语义期已被 FFI 顶层校验拒掉，落到 nil 即报错。
    private func annotation(for type: IRType) -> TypeAnnotation? {
        let loc = IRExecutor.noLocation
        switch type {
        case .i8: return .simple(name: "I8", location: loc)
        case .u8: return .simple(name: "U8", location: loc)
        case .i32: return .simple(name: "I32", location: loc)
        case .i64: return .simple(name: "I64", location: loc)
        case .u64: return .simple(name: "U64", location: loc)
        case .f64: return .simple(name: "F64", location: loc)
        case .boolean: return .simple(name: "Bool", location: loc)
        case .pointer(let element):
            guard let inner = annotation(for: element) else { return nil }
            return .pointer(element: inner, location: loc)
        default:
            return nil
        }
    }

    /// 跑模块的 `main`，与 `Interpreter.run(module:)` 镜像。
    /// 本入口是解释器后端唯一「跑一个程序」的地方，故让出读数的挂点也在这里：用 `defer` 与对侧的进程退出钩子同一时刻报，否则出错那次两份读数不可比。
    /// 代价：`prepare` 就抛出时也会打一行，读数是上一次运行留下的累计值；闸门只由「一进程一程序」的器械置位，故今天不可达。
    public func run(module: IRModule) throws {
        defer { reportInterpreterYieldsIfGated() }
        try prepare(module: module)
        try executeMain()
    }

    private func executeMain() throws {
        guard let main = functions["main"] else {
            throw RuntimeError.mainNotFound(location: IRExecutor.noLocation)
        }
        _ = try call(main, args: [])
    }

    /// Call one module-level function by name.
    /// `run(module:)` reaches `main` only; a test run reaches every `|test` function, hence per-name entry.
    /// Same `invoke` and argument protocol as any call, so a test body meets the same runtime; `prepare` must run first.
    public func callFunction(named name: String, args: [Value]) throws -> Value {
        guard let function = functions[name] else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: no module-level function named \(name) to call",
                location: IRExecutor.noLocation
            )
        }
        return try call(function, args: args)
    }

    // MARK: - Diagnostics

    /// Placeholder position for every diagnostic out of this engine.
    /// The file name is `<ir>` rather than `""`, so a diagnostic cannot be mistaken for one with a real, empty file attached.
    static let noLocation = SourceLocation(line: 0, column: 0, fileName: "<ir>")

    // MARK: - Expressions

    private func evaluate(_ expr: IRExpr) throws -> Value {
        switch expr {

        // All integer widths collapse onto one runtime `int`, as the interpreter models them: u8/i8/u64 are ABI widths.
        // `intConst` therefore ignores its carried type.

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
            // min/max lower to IR operators but reach the interpreter as
            // builtin calls, so they have no operator to map onto. Call the
            // shared builtin instead of failing.
            switch op {
            case .minOf: return try RuntimeOps.builtinMin(left, right)
            case .maxOf: return try RuntimeOps.builtinMax(left, right)
            default: break
            }
            guard let mapped = IRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: binary operator '\(op)' has no interpreter "
                        + "counterpart (min/max are builtin calls on the AST channel)",
                    location: IRExecutor.noLocation
                )
            }
            return try RuntimeOps.binaryValue(left, mapped, right)

        case .unary(let op, let operand, _):
            // same reason as min/max above -- abs lowers to an IR unary
            // operator but is a builtin call on the interpreter channel.
            if case .abs = op {
                return try RuntimeOps.builtinAbs(try evaluate(operand))
            }
            guard let mapped = IRExecutor.operatorFor(op) else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: unary operator '\(op)' has no interpreter "
                        + "counterpart (`abs` is a builtin call on the AST channel)",
                    location: IRExecutor.noLocation
                )
            }
            return try RuntimeOps.unaryValue(mapped, try evaluate(operand))

        case .call(let name, let arguments, _):
            // The callee is resolved before the arguments are evaluated, so an unknown name is reported without running any argument.
            // Three kinds share one node shape: module-level function, type method mangled to `方法__类型`, and builtin.
            // Functions and methods execute here; builtins come from the shared `RuntimeOps` tables, not a live interpreter.
            if let target = functions[name] ?? methods[name] {
                return try call(target, args: try arguments.map { try evaluate($0) })
            }
            // A callee declared in a `[名称|foreign]` block resolves in two stages, in the interpreter's order.
            // The libc shim table comes first — shared with the AST channel, one definition for two engines.
            // Otherwise it is a raw C binding: `dlsym` against the block name, then a per-signature thunk over the address.
            if let foreign = foreignDecls[name] {
                let args = try arguments.map { try evaluate($0) }
                if let shim = RuntimeOps.libcShims[name] { return try shim(args) }
                let symbol = try ffiLoader.resolve(
                    library: foreign.library, symbol: name,
                    searchPaths: ffiConfig.searchPaths, location: IRExecutor.noLocation
                )
                let thunk = try ForeignThunk.make(
                    symbol: symbol, name: name,
                    paramTypes: try foreign.function.paramTypes.map { type in
                        guard let annotation = ForeignThunk.annotation(for: type) else {
                            throw RuntimeError.invalidOperation(
                                reason: "IR executor: foreign callee \(name) has a parameter "
                                    + "type that is not a C top-level type",
                                location: IRExecutor.noLocation
                            )
                        }
                        return annotation
                    },
                    returnTypes: try foreign.function.returnType.map { type -> [TypeAnnotation] in
                        guard let annotation = ForeignThunk.annotation(for: type) else {
                            throw RuntimeError.invalidOperation(
                                reason: "IR executor: foreign callee \(name) has a return "
                                    + "type that is not a C top-level type",
                                location: IRExecutor.noLocation
                            )
                        }
                        return [annotation]
                    } ?? [],
                    location: IRExecutor.noLocation
                )
                return try thunk(args)
            }
            // sin / cos arrive as `llvm.sin.f64` / `llvm.cos.f64`, and `tan` as a division between the two.
            // They are answered from the shared trigonometric builtins, not reported as a missing module-level function.
            if name.hasPrefix("llvm.") {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: intrinsic \(name) expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                switch name {
                case "llvm.sin.f64": return try RuntimeOps.builtinSin(args[0])
                case "llvm.cos.f64": return try RuntimeOps.builtinCos(args[0])
                default:
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: intrinsic \(name) has no interpreter counterpart",
                        location: IRExecutor.noLocation
                    )
                }
            }
            // The character builtins, answered from the same implementation
            // the AST channel calls -- one definition, two engines.
            if let character = RuntimeOps.characterBuiltins[name] {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: \(name) expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return try character(args)
            }

            // The concurrency builtins a plain call can carry, answered from the same table the lowerer's whitelist reads.
            // `sleep` blocks this thread and yields nothing: that is its whole IR-side semantics here.
            // Cancellation checkpoints are a no-op here — no task handle — so the shared rule takes one as a parameter.
            if let concurrency = RuntimeOps.concurrencyBuiltins[name] {
                let args = try arguments.map { try evaluate($0) }
                return try concurrency(args)
            }

            // The Future-valued concurrency builtins: matched here, not in the shared table, because they need a task handle.
            // The lowerer matches the same names for the same reason, so the two sides are read together.
            // Waiting, aggregating and the leaked-failure flip live in `RuntimeOps`: one definition for both engines.
            if name == "isCancel" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: isCancel expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return .bool(RuntimeOps.isCancelErrorValue(args[0]))
            }
            // err 槽的另一个读口：字 → 消息。名字带点 ⇒ 不是语言内建、也不可能是用户函数
            // 名；它与 LLVM 侧的 `bk_error_message` 是同一条语义的两个落点。
            if name == "pini.err.message" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: pini.err.message expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return .string(RuntimeOps.errorMessage(args[0]))
            }
            if name == "joinAll" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: joinAll expects exactly one argument",
                        location: IRExecutor.noLocation
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
                        reason: "IR executor: joinWithin expects exactly two arguments",
                        location: IRExecutor.noLocation
                    )
                }
                guard case .future(let fut) = args[0] else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(args[0]),
                        location: IRExecutor.noLocation
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
                        reason: "IR executor: cancel expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                guard case .future(let fut) = args[0] else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(args[0]),
                        location: IRExecutor.noLocation
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
                        reason: "IR executor: F64 expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return try RuntimeOps.builtinF64(args[0])
            }
            // The Array member face (`append` / `last` / `pop`): the same rules the AST walk applies, one definition for two engines.
            // The receiver rides as the first argument.
            if let arrayMethod = RuntimeOps.arrayMethods[name] {
                let args = try arguments.map { try evaluate($0) }
                return try arrayMethod(args)
            }
            if name == "sqrt" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: sqrt expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return try RuntimeOps.builtinSqrt(args[0])
            }
            // 宿主环境查询内建。两行都与解释器的同名内建**逐字同义**（镜像，不另造）：
            // 参数数组直接来自执行器持有的 `processArguments`；模块根即程序基准，
            // 未注入基准时如实返回进程 CWD，不伪造。
            if name == "argv" || name == "moduleRoot" {
                guard arguments.isEmpty else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: \(name) takes no arguments",
                        location: IRExecutor.noLocation
                    )
                }
                if name == "argv" {
                    return .array(processArguments.map { .string($0) })
                }
                return .string(programBase ?? FileManager.default.currentDirectoryPath)
            }
            // 目录枚举：条目只给**名字**（不含目录部分）—— 调用方知道目录，自己拼路径比让这里代猜更灵活。
            // 路径按 IO 三段式解析，相对路径相对**程序基准**而非进程 CWD；排序钉在 UTF-8 字节序升序，否则依赖顺序的判据会假绿。
            // 不截断：列不全时**报错**，不返回半个目录。
            if name == "listDir" {
                guard arguments.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: listDir expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                let rawPath = try requireString(try evaluate(arguments[0]), for: "listDir")
                let dirPath = RuntimeOps.resolveIOPath(rawPath, programBase: programBase)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dirPath, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw RuntimeError.invalidOperation(
                        reason: "IO 错误: 不是目录或不存在 \(dirPath)",
                        location: IRExecutor.noLocation
                    )
                }
                let entries: [String]
                do {
                    entries = try FileManager.default.contentsOfDirectory(atPath: dirPath)
                } catch {
                    throw RuntimeError.invalidOperation(
                        reason: "IO 错误: 无法列出目录 \(dirPath): \(error.localizedDescription)",
                        location: IRExecutor.noLocation
                    )
                }
                let ordered = entries.sorted {
                    Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
                }
                return .array(ordered.map { .string($0) })
            }
            // 探测类： 行不通  不 panic —— 路径不存在是该类的正常答案，不是错误。
            // 路径解析与上面两条同口径；`isDir` 对「不存在」与「是文件」同答 false。
            if name == "exists" || name == "isDir" {
                guard arguments.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: \(name) expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                let rawPath = try requireString(try evaluate(arguments[0]), for: name)
                let path = RuntimeOps.resolveIOPath(rawPath, programBase: programBase)
                var isDirectory: ObjCBool = false
                let present = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                if name == "exists" {
                    return .bool(present)
                }
                return .bool(present && isDirectory.boolValue)
            }
            throw RuntimeError.invalidOperation(
                reason: "IR executor: no module-level function named '\(name)' and no "
                    + "type method lowered under that name. Builtin callees are not "
                    + "answered by this engine (no delegation to the interpreter — see "
                    + "the note on `call`), and stdlib methods are resolved through the "
                    + "interpreter's Pini-source member table with no IR surface yet",
                location: IRExecutor.noLocation
            )

        case .printCall(let argument):
            // Mirrors the interpreter's `print` funnel for the one-argument form:
            // stringify, then hand the whole line to the sink at once.
            outputSink(RuntimeOps.stringifyValue(try evaluate(argument)))
            return .null

        // MARK: Collections

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
                location: IRExecutor.noLocation
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

        // MARK: Tuples

        case .tupleConstruct(let labels, let elements, _):
            // Source order, labels passed through verbatim. A positional literal
            // keeps its `nil` labels — relabelling from a declared annotation is
            // the binding site's rule and is not applied at the literal.
            var values: [Value] = []
            for element in elements { values.append(try evaluate(element)) }
            return .tuple(labels: labels, elements: values)

        case .tupleIndexGet(let base, let index, _):
            // The bound is resolved statically: `.0` and the labelled `.name` form both arrive here as an integer.
            // So this arm only agrees on what indexing means, by calling the interpreter's rule rather than restating it.
            return try RuntimeOps.tupleElement(
                try evaluate(base),
                index: index,
                location: IRExecutor.noLocation
            )

        // MARK: Strings

        case .stringConcat(let lhs, let rhs):
            // `s1 + s2` has one meaning and it is the interpreter's: this arm routes through the same `binaryValue`.
            // The node is separate from `.binary` because the contract sinks concatenation to a byte-semantics channel.
            // It sits in this grid because the defer fixtures build their expected string by concatenating.
            return try RuntimeOps.binaryValue(
                try evaluate(lhs), .plus, try evaluate(rhs)
            )

        // MARK: Optional / Result / enum values

        case .resultConstruct(let isOk, let payload, _, _):
            // The one `makeResult`, so the two channels cannot disagree on what a Result *is*.
            // The err payload is one type-erased machine word on the LLVM side; reads go through the same `pini.err.message` name.
            return RuntimeOps.makeResult(
                caseName: isOk ? "ok" : "err",
                payload: try evaluate(payload)
            )

        case .optionalConstruct(let isSome, let payload, _):
            // The runtime form of an Optional *is* the two cases `some` / `none`, with no parent enum.
            // Same value for `nil`, `Optional.none`, a `.get` past the end, and the open-bound slice spelling.
            guard isSome else {
                return .enumValue(EnumValue(caseName: "none", associatedValues: []))
            }
            guard let payload = payload else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: optionalConstruct says some but carries no payload",
                    location: IRExecutor.noLocation
                )
            }
            return .enumValue(EnumValue(caseName: "some", associatedValues: [try evaluate(payload)]))

        case .optionalGet(let container, let index, _):
            // The rule lives in the interpreter's `builtinGet`: negative tail-count, dictionary key equality, out-of-range → `none`.
            // This node is the *named* spelling of `.get(i)`; the lowerer emits it for Array and String only, always checked.
            return try RuntimeOps.builtinGet(
                receiver: try evaluate(container),
                index: try evaluate(index),
                checked: true,
                location: IRExecutor.noLocation
            )

        case .enumConstruct(let enumName, let caseName, let tag, let payloads, _, _):
            // Associated-value names come from the declaration, the same order the interpreter writes on the constructor value.
            // The same single reader consumes them — `match` named bindings; rendering never looks at them.
            guard let enumCase = resolveEnumCase(enumName: enumName, caseName: caseName, tag: tag)
            else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: enum construct '\(enumName).\(caseName)' has no "
                        + "declaration in this module (the lowerer registers it at lowering time)",
                    location: IRExecutor.noLocation
                )
            }
            return .enumValue(
                EnumValue(
                    caseName: enumCase.name,
                    associatedValues: try payloads.map { try evaluate($0) },
                    paramNames: enumCase.paramNames,
                    parentEnum: enumName
                ))

        // MARK: Nominal instances and their fields

        case .construct(let type):
            return try constructValue(type)

        case .fieldGet(let base, let field, _):
            // The static type travels in the node and is dropped here: the
            // receiver's own value kind decides which field table is read, the
            // way `Interpreter.evaluateMember` decides it.
            return try fieldRead(from: try evaluate(base), field: field)

        // MARK: Closures and function values

        case .closureLiteral(_, let paramNames, _, _, _, let body, _):
            // The closure id and capture list are deliberately unused: the id keys the compiled side's registry.
            // An environment here *is* a reference, so hanging the value off the current one captures every name by reference.
            // Same as the interpreter's func-literal arm: later writes to a captured name stay visible; a list would snapshot.
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
                    reason: "IR executor: function value '\(name)' names no module-level "
                        + "function in this module",
                    location: IRExecutor.noLocation
                )
            }
            // A named function closes over nothing: the interpreter registers its value against the global environment.
            // This mirrors that rather than inventing a creation-point environment there is none of.
            return makeFunctionValue(
                name: name,
                paramNames: target.params.map { $0.name },
                body: target.body,
                returnLabels: IRExecutor.declaredReturnLabels(target.returnType),
                closure: globalEnv
            )

        case .indirectCall(let callee, let arguments, _):
            // Callee before arguments, the interpreter's own order at its indirect-call arm.
            // Argument evaluation is observable, so the order is semantics rather than an implementation detail.
            let calleeValue = try evaluate(callee)
            guard case .function(let function) = calleeValue else {
                throw RuntimeError.notCallable(location: IRExecutor.noLocation)
            }
            return try callFunctionValue(function, args: try arguments.map { try evaluate($0) })

        // MARK: Strings and builtins

        case .interpString(let parts):
            // Mirrors the interpreter's `.stringInterpolation` arm; the lowerer has already flattened the segments.
            // Literals arrive as `stringConst`, expressions as their own node, an all-literal run already folded into one.
            // A string renders verbatim under `stringifyValue`, so a literal segment contributes its text unchanged.
            var text = ""
            for part in parts {
                text += RuntimeOps.stringifyValue(try evaluate(part))
            }
            return .string(text)

        case .isAsciiDigit(let argument):
            // Mirrors the interpreter's `is_ascii_digit` arm, including its non-fail-loud behaviour outside ASCII.
            // Every non-ASCII scalar compares above "9", so no second range check is needed; the empty string is false.
            let s = try requireChar(try evaluate(argument), for: "is_ascii_digit")
            guard let first = s.first else { return .bool(false) }
            return .bool(first >= "0" && first <= "9")

        case .printMulti(let arguments):
            // The interpreter's multi-argument `print`: every value rendered, joined with one space, handed to the sink as one line.
            // One line, so a concurrent task cannot interleave inside it; arguments are evaluated left to right, which is observable.
            let values = try arguments.map { try evaluate($0) }
            outputSink(values.map { RuntimeOps.stringifyValue($0) }.joined(separator: " "))
            return .null

        case .assertCall(let condition, let message):
            // Mirrors the interpreter's `assert` arm: both operands are evaluated before the condition is judged.
            // The interpreter evaluates arguments at the call site, and only then does the arm look at the values.
            let conditionValue = try evaluate(condition)
            let messageValue = try message.map { try evaluate($0) }
            guard case .bool(let passed) = conditionValue else {
                throw RuntimeError.invalidOperation(
                    reason: "assert 的参数 1 必须是 Bool（条件）",
                    location: IRExecutor.noLocation
                )
            }
            guard !passed else { return .null }
            let text: String
            if let messageValue = messageValue {
                guard case .string(let m) = messageValue else {
                    throw RuntimeError.invalidOperation(
                        reason: "assert 的参数 2 必须是 String（消息）",
                        location: IRExecutor.noLocation
                    )
                }
                text = m
            } else {
                text = "assert failed"
            }
            throw RuntimeError.assertionFailed(message: text, location: IRExecutor.noLocation)

        case .arrayJoin(let receiver, let separator):
            // Mirrors the interpreter's `join` arm: stringify each element and interpose the separator.
            // The shared renderer runs unconditionally: the lowerer requires `[String]`, but the array holds whatever it holds.
            guard case .array(let elements) = try evaluate(receiver) else {
                throw RuntimeError.invalidOperation(
                    reason: "join needs an Array receiver",
                    location: IRExecutor.noLocation
                )
            }
            let sep = try requireString(try evaluate(separator), for: "join")
            return .string(elements.map { RuntimeOps.stringifyValue($0) }.joined(separator: sep))

        case .stringCase(let isUpper, let receiver):
            // Contract §2.36: **Unicode-aware**, and the receiver is unchanged.
            // The authority is the interpreter's `upper` / `lower` arms — `String.uppercased()` / `.lowercased()`.
            // The emitter's ASCII-only byte pass is the deviating side, so this mirrors the contract, not a third reading.
            let text = try requireString(try evaluate(receiver), for: "upper/lower")
            return .string(isUpper ? text.uppercased() : text.lowercased())

        case .stringContains(let receiver, let needle):
            // `contains` is served on the AST channel from `StdlibPini` (内建双层结构 sank it), so that source is the authority.
            // The loop below is the same algorithm: empty needle is true, otherwise scan for a grapheme-wise match.
            // A sunk method costs this second copy, which cannot call Pini from here; both-channel fixtures catch it drifting.
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
            // Contract §2.38: the second argument is an **end**, not a length, though the emitter still reads a length.
            // Authority is `StdlibPini.substring`: negative bounds tail-count, both bounds clamp into `[0, len]`.
            // `hi < lo` yields the empty string; counting and slicing go through `GraphemeCursor`, so slicing is O(n), not O(n²).
            let receiverText = try requireString(try evaluate(receiver), for: "substring")
            let n = GraphemeCursor.count(of: receiverText)
            var lo = try requireInt(try evaluate(start), for: "substring start")
            var hi = try requireInt(try evaluate(end), for: "substring end")
            if lo < 0 { lo = n + lo }
            if hi < 0 { hi = n + hi }
            if lo < 0 { lo = 0 }
            if lo > n { lo = n }
            if hi < 0 { hi = 0 }
            if hi > n { hi = n }
            guard hi > lo else { return .string("") }
            return .string(GraphemeCursor.slice(of: receiverText, from: lo, to: hi))

        case .stringSplit(let receiver, let delim, _):
            // Contract §2.39: a **real `Array<String>`** with empty tokens skipped, as the LLVM `strtok` loop does.
            // The interpreter keeps them; aligning that is the `stringSplit` grid's job, so this node follows the contract.
            // An empty separator yields one element per grapheme, as `StdlibPini`'s explicit `m == 0` branch does.
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

        case .stringTrimLeft(let receiver):
            // U+0020 only — a tab is NOT stripped. Character-wise drop over
            // the leading space run (each space is one grapheme, so the
            // grapheme walk costs nothing extra).
            let text = try requireString(try evaluate(receiver), for: "trimLeft")
            return .string(String(text.drop(while: { $0 == " " })))

        case .stringTrimRight(let receiver):
            // Same rule as trimLeft, from the tail: walk back over the
            // trailing space run and prefix up to it.
            let text = try requireString(try evaluate(receiver), for: "trimRight")
            var end = text.endIndex
            while end > text.startIndex && text[text.index(before: end)] == " " {
                end = text.index(before: end)
            }
            return .string(String(text[..<end]))

        case .stringIndexOf(let receiver, let needle):
            // Grapheme-indexed first occurrence — same scan as
            // `.stringContains`, reporting position instead of existence.
            // Empty needle yields 0; absent yields -1.
            let text = try requireString(try evaluate(receiver), for: "indexOf")
            let needleText = try requireString(try evaluate(needle), for: "indexOf")
            if needleText.isEmpty { return .int(0) }
            let chars = Array(text)
            let needleChars = Array(needleText)
            let n = chars.count
            let m = needleChars.count
            var i = 0
            while i + m <= n {
                var j = 0
                var matched = true
                while j < m {
                    if chars[i + j] != needleChars[j] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched { return .int(i) }
                i += 1
            }
            return .int(-1)

        // MARK: Not implemented yet — fail loud, named.

        // MARK: Pointers and LazyRef

        case .pointerLoad(let pointer, _):
            // Mirrors the interpreter's `load` builtin: the element type comes from the pointer, not this node's `type` payload.
            // The lowerer derives that payload from the same argument, so the pointer stays the single source.
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerLoad expects a *T pointer operand",
                    location: IRExecutor.noLocation
                )
            }
            return try RuntimeOps.decodePointer(raw)

        case .pointerStore(let pointer, let value, _):
            // Mirrors the interpreter's `store` builtin: encode by the pointer's
            // element type, truncating for narrow elements.
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerStore expects a *T pointer operand",
                    location: IRExecutor.noLocation
                )
            }
            try RuntimeOps.encode(try evaluate(value), to: raw.pointer, type: raw.elemType)
            return .null

        case .foreignDataAddress(let name, _):
            /// 符号地址本身，不是快照：写进去的值外部可见，外部写的值这里读得到。
            guard let address = foreignDataAddresses[name] else {
                throw RuntimeError.invalidOperation(
                    reason: "外部数据符号 '\(name)' 没有解析到地址", location: IRExecutor.noLocation)
            }
            return .rawPointer(address)

        case .addressOfVar(let name, _):
            // Interpreter parity: `&x` snapshots the value into fresh memory, so a write through the pointer misses the variable.
            // True-reference semantics belongs to the address-of grid; taking it here would disagree with the frozen AST arm.
            return try RuntimeOps.snapshotPointer(
                of: try currentEnv.get(name: name),
                location: IRExecutor.noLocation
            )

        case .lazyRefConstruct(let closure, _):
            // Mirrors `Interpreter.makeLazyRefBox`: the argument is the
            // initialiser closure, and the box itself carries the once-only rule.
            guard case .function(let function) = try evaluate(closure) else {
                throw RuntimeError.invalidOperation(
                    reason: "lazyRefConstruct expects an initialiser closure",
                    location: IRExecutor.noLocation
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
                    location: IRExecutor.noLocation
                )
            }
            return try box.value { function in
                try self.callFunctionValue(function, args: [])
            }

        case .fileWrite(let pathExpr, let contentExpr):
            // Writes in place, truncating an existing file; not an atomic replace.
            // The path resolves against the program base. Failing to open or write
            // raises here, so a successful call yields `()`.
            let rawWritePath = try requireString(evaluate(pathExpr), for: "writeFile")
            let content = try requireString(evaluate(contentExpr), for: "writeFile")
            let writePath = RuntimeOps.resolveIOPath(rawWritePath, programBase: programBase)
            do {
                try content.write(toFile: writePath, atomically: false, encoding: .utf8)
                return .null
            } catch {
                throw RuntimeError.invalidOperation(
                    reason: "IO 错误: 无法写入文件 \(writePath): \(error.localizedDescription)",
                    location: IRExecutor.noLocation
                )
            }

        case .fileAppend(let pathExpr, let contentExpr):
            // Appends at the end, creating the target when it is missing (POSIX "a").
            // The path resolves against the program base. A failed open or short write
            // raises here, so a successful call yields `()`.
            let rawAppendPath = try requireString(evaluate(pathExpr), for: "appendFile")
            let appended = try requireString(evaluate(contentExpr), for: "appendFile")
            let appendPath = RuntimeOps.resolveIOPath(rawAppendPath, programBase: programBase)
            guard let handle = fopen(appendPath, "a") else {
                throw RuntimeError.invalidOperation(
                    reason: "IO 错误: 无法打开文件以追加 \(appendPath): \(String(cString: strerror(errno)))",
                    location: IRExecutor.noLocation
                )
            }
            defer { fclose(handle) }
            let appendBytes = Array(appended.utf8)
            if !appendBytes.isEmpty {
                let written = appendBytes.withUnsafeBufferPointer {
                    fwrite($0.baseAddress, 1, appendBytes.count, handle)
                }
                guard written == appendBytes.count else {
                    throw RuntimeError.invalidOperation(
                        reason:
                            "IO 错误: 无法追加到文件 \(appendPath): \(String(cString: strerror(errno)))",
                        location: IRExecutor.noLocation
                    )
                }
            }
            return .null

        case .fileRead(let pathExpr):
            // The whole file, uncapped: nothing is dropped and no truncation is silent.
            // Both channels read it out whole, so a source file is never unreadable by the language for no stated reason.
            let rawReadPath = try requireString(evaluate(pathExpr), for: "readFile")
            let readPath = RuntimeOps.resolveIOPath(rawReadPath, programBase: programBase)
            do {
                return .string(try String(contentsOfFile: readPath, encoding: .utf8))
            } catch {
                throw RuntimeError.invalidOperation(
                    reason: "IO 错误: 无法读取文件 \(readPath): \(error.localizedDescription)",
                    location: IRExecutor.noLocation
                )
            }

        case .fileTryWrite(let pathExpr, let contentExpr):
            // 与 `.fileWrite` **同一个写入调用、同一个路径解析**，唯一的差别是失败去向：
            // 这里造一个错误值返回， 行不通  不抛。诊断文案与陷阱版同形 —— 两条路的用户看到
            // 同一句话，只是其中一条把它当值、另一条把它当终止理由。
            let rawTryWritePath = try requireString(evaluate(pathExpr), for: "tryWriteFile")
            let tryWriteContent = try requireString(evaluate(contentExpr), for: "tryWriteFile")
            let tryWritePath = RuntimeOps.resolveIOPath(rawTryWritePath, programBase: programBase)
            do {
                try tryWriteContent.write(toFile: tryWritePath, atomically: false, encoding: .utf8)
                return RuntimeOps.makeResult(
                    caseName: "ok", payload: .tuple(labels: [], elements: []))
            } catch {
                return RuntimeOps.makeResult(
                    caseName: "err",
                    payload: RuntimeOps.makeError(
                        "IO 错误: 无法写入文件 \(tryWritePath): \(error.localizedDescription)"))
            }

        case .fileTryAppend(let pathExpr, let contentExpr):
            let rawTryAppendPath = try requireString(evaluate(pathExpr), for: "tryAppendFile")
            let tryAppendContent = try requireString(evaluate(contentExpr), for: "tryAppendFile")
            let tryAppendPath = RuntimeOps.resolveIOPath(
                rawTryAppendPath, programBase: programBase)
            guard let tryHandle = fopen(tryAppendPath, "a") else {
                return RuntimeOps.makeResult(
                    caseName: "err",
                    payload: RuntimeOps.makeError(
                        "IO 错误: 无法打开文件以追加 \(tryAppendPath): "
                            + String(cString: strerror(errno))))
            }
            defer { fclose(tryHandle) }
            let tryAppendBytes = Array(tryAppendContent.utf8)
            if !tryAppendBytes.isEmpty {
                let tryWritten = tryAppendBytes.withUnsafeBufferPointer {
                    fwrite($0.baseAddress, 1, tryAppendBytes.count, tryHandle)
                }
                guard tryWritten == tryAppendBytes.count else {
                    return RuntimeOps.makeResult(
                        caseName: "err",
                        payload: RuntimeOps.makeError(
                            "IO 错误: 无法追加到文件 \(tryAppendPath): "
                                + String(cString: strerror(errno))))
                }
            }
            return RuntimeOps.makeResult(
                caseName: "ok", payload: .tuple(labels: [], elements: []))

        case .fileTryRead(let pathExpr):
            let rawTryReadPath = try requireString(evaluate(pathExpr), for: "tryReadFile")
            let tryReadPath = RuntimeOps.resolveIOPath(rawTryReadPath, programBase: programBase)
            do {
                return RuntimeOps.makeResult(
                    caseName: "ok",
                    payload: .string(try String(contentsOfFile: tryReadPath, encoding: .utf8)))
            } catch {
                return RuntimeOps.makeResult(
                    caseName: "err",
                    payload: RuntimeOps.makeError(
                        "IO 错误: 无法读取文件 \(tryReadPath): \(error.localizedDescription)"))
            }

        case .readLine:
            // Mirrors the interpreter's arm: the terminator is kept and the line is capped at the contract's byte limit.
            // EOF is the empty string, distinguishable from an empty line precisely because the terminator is not stripped.
            guard let line = readLine(strippingNewline: false) else {
                return .string("")
            }
            return .string(IOLimits.truncateToLineLimit(line))

        // MARK: join

        // `await f` / `wait f`: the suspension engine is the CPS evaluator, which this engine does not have.
        // The arm exists because the node set and the contract entry move together — the coverage check reads both directions.
        // It fails loud rather than returning a silent `.null`, so a lowerer rule without an engine shows up as an error.
        case .join(let futureExpr, _, let form):
            // `await f` / `wait f`: evaluate the operand, wait for it to resolve, then deconstruct the carried ok / err.
            // `form` records which keyword the site used; both forms wait the same way — giving the task up needs a resumable body.
            // A `join` that is not given a future is a run-time type mismatch.
            let operand = try evaluate(futureExpr)
            guard case .future(let fut) = operand else {
                throw RuntimeError.typeMismatch(
                    expected: "Future<T, Error>",
                    got: RuntimeOps.describeValueKind(operand),
                    location: IRExecutor.noLocation
                )
            }
            return RuntimeOps.joinFuture(fut, timeoutMs: nil, form: form)

        // MARK: 默认实例取用

        // 取某类型的默认实例（契约 §2.46）。本臂**没有降载入口** ⇒ 当前不可达，但必须存在：契约器械的覆盖检查双向对账。
        // 故 fail-loud，不静默返回一个看起来合理的值；物化面属 `P2b`。
        case .givenInstance(let type):
            // 物化面：与发射层同语义（惰性 · 恰一次 · 取副本）。
            return try materializeGivenInstance(type)
        }
    }

    // MARK: - G7 operand helpers

    // One `String` operand, or a loud error naming the caller.
    // The AST channel typechecks first; a wrong type here means the module did not come from the lowerer, so it fails loud.
    private func requireString(_ value: Value, for what: String) throws -> String {
        guard case .string(let text) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects a String operand, got \(value)",
                location: IRExecutor.noLocation
            )
        }
        return text
    }

    // One `Char` operand as its grapheme text, or a loud error naming the caller.
    // `Char` and `String` share a representation and widening is legal, so a `String` is accepted too: still one grapheme.
    private func requireChar(_ value: Value, for what: String) throws -> String {
        switch value {
        case .char(let text), .string(let text): return text
        default:
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects a Char operand, got \(value)",
                location: IRExecutor.noLocation
            )
        }
    }

    /// One `I32` operand, or a loud error naming the caller. See `requireString`.
    private func requireInt(_ value: Value, for what: String) throws -> Int {
        guard case .int(let number) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects an integer operand, got \(value)",
                location: IRExecutor.noLocation
            )
        }
        return number
    }

    // The declaration an `enumConstruct` names, by case name with the tag as a fallback.
    // The lowerer carries both, so a miss on both is a real inconsistency: a hand-built module, or a dropped declaration.
    // The caller fails loud rather than inventing an empty associated-value list.
    private func resolveEnumCase(enumName: String, caseName: String, tag: Int) -> IREnumCase? {
        guard let decl = enums[enumName] else { return nil }
        if let named = decl.cases.first(where: { $0.name == caseName }) { return named }
        guard decl.cases.indices.contains(tag) else { return nil }
        return decl.cases[tag]
    }

    // MARK: - Nominal instances

    // 默认实例的物化（解释器臂）—— 名义类型才可物化，其余报错。
    // 物化复用 `constructValue`，本函数只多管「记住」与「取副本」：命中缓存即返回，否则构造后入表。
    // `Value.structInstance` 是值类型，返回缓存值即得一份拷贝；写实例自身字段不留痕，经引用字段往下写则对所有取用点可见。
    private func materializeGivenInstance(_ type: IRType) throws -> Value {
        guard case .nominal(let name, _) = type else {
            throw RuntimeError.invalidOperation(
                reason: "givenInstance 需要一个名义类型，实为 '\(type.llvmSpelling)'",
                location: IRExecutor.noLocation
            )
        }
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if let cached = givenInstances[name] { return cached }
        let materialized = try constructValue(type)
        givenInstances[name] = materialized
        return materialized
    }

    /// 派发点的后端从**语言侧的默认声明**解析而来：程序在语言里说明它的调度器（预置给定块），派发点读它。
    /// **只读声明，不物化实例**：本函数跑在装载期，而装载期只注册不运行，此处求值会碰尚未就绪的执行状态。
    /// 读法刻意宽容：字段缺席、或值不是布尔字面量，一律取语言默认（可让出），否则等于拿「没写」去罚「没改」。
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

    private func constructValue(_ type: IRType) throws -> Value {
        guard case .nominal(let name, let isObject) = type else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: construct needs a nominal type, got '\(type)'",
                location: IRExecutor.noLocation
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

    /// `base.field` — the read half of the interpreter's member branch; a miss reports the disagreement, never `.null`.
    /// A missing field is unreachable: the lowerer resolves the field statically and refuses to build this node.
    /// Not mirrored: the `_`-visibility gate and the bound-method fallback — the checker and the lowerer reject both.
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
                reason: "IR executor: field read '.\(field)' needs a nominal receiver, got "
                    + "\(RuntimeOps.describeValueKind(base))",
                location: IRExecutor.noLocation
            )
        }
    }

    /// `base.field = value` — the write half of the interpreter's `performMemberAssign`, arm for arm.
    /// The `let`-bound struct rule triggers on a receiver written as an identifier other than `self`; `self` is exempt.
    /// Not mirrored: the deep copy of the incoming value (no fixture observes it) and the `_` gate (rejected statically).
    private func storeField(base: IRExpr, field: String, value: Value) throws {
        try storeField(on: try evaluate(base), base: base, field: field, value: value)
    }

    /// `storeField` 的**已求值接收者**那一半：让 `obj.field[i] = v` 复用**同一次**接收者求值。
    /// 那里若改调 `storeField(base:…)`，接收者会被求值两次，带副作用时（`f().xs[i] = v`）会多跑一次调用。
    /// 发射侧只求值一次，故两腿不等价 —— 拆分正是为了避免这一点。
    private func storeField(on receiver: Value, base: IRExpr, field: String, value: Value) throws {
        if case .load(let rootName, _) = base, rootName != "self",
            case .structInstance = receiver,
            let mutable = currentEnv.isMutable(name: rootName), !mutable
        {
            throw RuntimeError.immutableVariable(name: rootName, location: IRExecutor.noLocation)
        }
        switch receiver {
        case .structInstance(let instance):
            instance.fields[field] = value
        case .objectReference(let object):
            object.fields[field] = value
        default:
            throw RuntimeError.invalidOperation(
                reason: "无法赋值的对象类型",
                location: IRExecutor.noLocation
            )
        }
    }

    private func missingField(_ field: String, on typeName: String) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "IR executor: '\(typeName)' carries no field '\(field)' "
                + "(the lowerer resolves fields statically, so this is an internal "
                + "inconsistency, not a gap in this engine)",
            location: IRExecutor.noLocation
        )
    }

    /// `container.slice(start, end)` — the slice-sugar semantics.
    /// `slice` sank to `StdlibPini`, whose Pini source this engine cannot call, so the bodies below mirror it.
    /// Open bound = whole, negative = tail-count, clamp to `[0, len]`, `hi < lo` empty; `String` slices graphemes.
    private func sliceValue(container: Value, start: Value, end: Value) throws -> Value {
        switch container {
        case .array(let elements):
            let lower = try sliceBound(start, count: elements.count, defaultWhenOpen: 0)
            let upper = try sliceBound(end, count: elements.count, defaultWhenOpen: elements.count)
            let lo = Swift.max(0, Swift.min(lower, elements.count))
            let hi = Swift.max(0, Swift.min(upper, elements.count))
            return .array(lo < hi ? Array(elements[lo..<hi]) : [])

        case .string(let text):
            //  注意  同 `stringSubstring`：计数与切片都走 `GraphemeCursor`，
            //    代价从 O(整串长) 降到 O(切片长)。夹取规则一字未改。
            let n = GraphemeCursor.count(of: text)
            let lower = try sliceBound(start, count: n, defaultWhenOpen: 0)
            let upper = try sliceBound(end, count: n, defaultWhenOpen: n)
            let lo = Swift.max(0, Swift.min(lower, n))
            let hi = Swift.max(0, Swift.min(upper, n))
            return .string(lo < hi ? GraphemeCursor.slice(of: text, from: lo, to: hi) : "")

        default:
            throw RuntimeError.invalidOperation(
                reason: "slice needs an Array or String receiver, got \(container)",
                location: IRExecutor.noLocation
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
                location: IRExecutor.noLocation
            )
        }
        return offset < 0 ? count + offset : offset
    }

    /// `IRBinaryOp` → `BinaryOperator`, or nil when the AST channel serves the operation through a builtin call instead.
    /// The mapping is IR vocabulary; each operator's meaning lives in `Interpreter.binaryValue`, so the channels cannot drift.
    static func operatorFor(_ op: IRBinaryOp) -> BinaryOperator? {
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
        // LLVM: min/max lower to selects; the interpreter reaches them as
        // builtin calls, so there is no operator to map onto.
        case .minOf, .maxOf: return nil
        }
    }

    /// `IRUnaryOp` → `UnaryOperator`; see `operatorFor(_ op: IRBinaryOp)`.
    static func operatorFor(_ op: IRUnaryOp) -> UnaryOperator? {
        switch op {
        case .negate: return .minus
        case .logicalNot: return .not
        // `~` maps to the interpreter's own `.bitwiseNot`, so both
        // engines reach the shared `RuntimeOps.unaryValue` entry.
        case .bitwiseNot: return .bitwiseNot
        // `abs` is a builtin call on the AST channel, not a unary operator.
        case .abs: return nil
        }
    }

    // MARK: - Defer scopes

    /// Mirror of `Interpreter.pushDeferScope`.
    private func pushDeferScope() {
        deferStack.append([])
    }

    /// Mirror of `Interpreter.popDeferScope`: run this scope's defers LIFO.
    /// The scope is removed before its defers run, so a `defer` inside a deferred statement registers in the enclosing scope.
    /// The caller swallows whatever the defers throw — see `executeBlock`.
    private func popDeferScope() throws {
        guard !deferStack.isEmpty else { return }
        let groups = deferStack.removeLast()
        for group in groups.reversed() {
            for statement in group { try execute(statement) }
        }
    }

    /// Run a statement list as a **block**: open a defer scope, run, close it on every exit path.
    /// Called at `executeBlock`'s boundaries — `if` / `else`, `while`, `for-in`; a function body opens its own scope inline.
    /// The `try?` on the close is deliberate: a deferred signal is discarded and the error already unwinding keeps unwinding.
    private func executeBlock(_ block: IRBlock) throws {
        pushDeferScope()
        defer { try? popDeferScope() }
        try executeStatements(block)
    }

    // MARK: - Statements

    /// Runs a statement list in order, yielding the value of the last expression statement (`.null` when there is none).
    /// The interpreter's `lastValue` rule, so control-flow and function bodies share one runner; others discard it.
    /// Also the pause site: a block with no position is skipped, never stopped at an invented line.
    @discardableResult
    private func executeStatements(_ block: IRBlock) throws -> Value {
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
    /// Mirrors `Interpreter.debugPause(at:)`: the position comes from the caller, not the node, so shape does not matter.
    /// `.quit` unwinds as `DebuggerError.quit`; the hook is tested first, so an engine with no debugger pays nothing.
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

    private func execute(_ statement: IRStmt) throws {
        switch statement {

        case .allocVar(let name, let type, let mutable, let initializer, _):
            // Registered even without an initializer, as `.null`: an uninitialized read is a value, not an undefined-variable error.
            // Structs are copied field by field; without it a write through the copy reaches the original, silently.
            var value = try initializer.map { RuntimeOps.copyIfStruct(try evaluate($0)) } ?? .null
            // Binding-site relabel: a value bound to a slot type that names components adopts those names.
            // The test is "at least one named", not "non-empty": `[nil, nil]` would wipe names the value already had.
            // Which slots arrive named is decided at lowering; for synthetic `allocVar`s this is a no-op.
            if case .tuple(let labels, _) = type, labels.contains(where: { $0 != nil }) {
                value = RuntimeOps.relabelled(value, with: labels)
            }
            currentEnv.define(name: name, value: value, isMutable: mutable)

        case .storeVar(let name, _, let value, _, _):
            // Structs are copied field by field, the interpreter's rule at the same point.
            // Without it both engines share one storage, and a write through the copy surfaces in the original, silently.
            try currentEnv.assign(name: name, value: RuntimeOps.copyIfStruct(try evaluate(value)))

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            // Each branch is its own defer scope: `elif` chains fold into a nested `ifStmt`, so three branches are three scopes.
            // 标签 break 定向范围: a labeled `if` is an interruptible frame, so its branch runs under a catch.
            // An unlabeled `if` runs bare — catching for it would swallow a depth-1 signal aimed at an enclosing loop.
            if label == nil {
                try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
            } else {
                do {
                    try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
                } catch let signal as IRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        // `depth == 1` ⇒ this frame is the target: the `break` leaves the block and control resumes after the `if`.
                        // Anything deeper belongs to an enclosing frame and is rethrown one level shallower.
                        if depth > 1 { throw IRControlSignal.breakSignal(depth: depth - 1) }
                    case .continueSignal(let depth):
                        // An `if` frame is never a `continue` target — `continue` resolves to loop frames only.
                        // So a signal reaching here is aimed further out, and its residual depth is >= 2.
                        throw IRControlSignal.continueSignal(depth: depth - 1)
                    default:
                        throw signal
                    }
                }
            }

        case .whileStmt(let condition, let body, let step):
            try executeWhile(condition: condition, body: body, step: step)

        case .returnStmt(let value, _):
            throw IRControlSignal.returnSignal(try value.map { try evaluate($0) })

        case .exprStmt(let expr):
            // Dropped here; `executeStatements` is what captures it as the body's
            // result value on the path where that matters.
            _ = try evaluate(expr)

        case .captureMarker(let name):
            // Not "unimplemented": the contract says this node lowers to nothing.
            // Captures are resolved at the closure literal by free-variable analysis; `captureStatement` is likewise a no-op.
            // Failing loud here would misreport a defined no-op as a gap.
            _ = name

        case .subscriptStore(let container, let index, let value, _, _):
            // Order copied from the interpreter: value first, then index, then the container chain — side effects observe it.
            // Structs are copied field by field; without it a write through the copy surfaces in the original.
            let newValue = RuntimeOps.copyIfStruct(try evaluate(value))
            let targetIndex = try evaluate(index)
            try storeSubscript(target: container, index: targetIndex, newValue: newValue)

        // MARK: Control flow

        case .forInStmt(let pattern, _, let kind, let iterable, let body, let step):
            // `elementTypes` is lowering-time only: the row decomposition at run time is the interpreter's, reused not restated.
            try executeForIn(
                pattern: pattern, kind: kind, iterable: iterable,
                body: body, step: step
            )

        case .deferStmt(let body):
            // Registered, not run: LIFO order belongs to the scope (`popDeferScope`).
            // The guard is the interpreter's: a `defer` with no enclosing scope is an error, and lowered source cannot reach it.
            guard !deferStack.isEmpty else {
                throw RuntimeError.invalidOperation(
                    reason: "defer 必须在块作用域内使用",
                    location: IRExecutor.noLocation
                )
            }
            deferStack[deferStack.count - 1].append(body)

        case .breakStmt(let depth):
            throw IRControlSignal.breakSignal(depth: depth)

        case .continueStmt(let depth):
            throw IRControlSignal.continueSignal(depth: depth)

        case .detachStmt(let inner):
            // `detach <expr>`: prune the task from its parent so its return stops cancelling it — fire-and-forget's sanctioned exit.
            // The operand is evaluated first, and a non-future is a run-time type mismatch, exactly where the interpreter reports it.
            // Refusing it at lowering would move the error off the run-time boundary the two engines are kept equal across.
            let operand = try evaluate(inner)
            guard case .future(let fut) = operand else {
                throw RuntimeError.typeMismatch(
                    expected: "Future<T, Error>",
                    got: RuntimeOps.describeValueKind(operand),
                    location: IRExecutor.noLocation
                )
            }
            fut.detachFromParent()

        case .panicStmt(let message):
            // The message is the lowerer's — it names the escape the interpreter
            // only discovers at run time — and is passed through verbatim.
            throw RuntimeError.invalidOperation(
                reason: message,
                location: IRExecutor.noLocation
            )

        // MARK: Try / match

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, _):
            // Mirrors the interpreter's `tryExpression`: `ok` yields the payload, `err` binds it and runs the handler.
            // The handler statements run here, not as a block, so their `return` / `break` / `continue` leave as signals.
            // Their bare `pass` terminator just ends the statement — both are the interpreter's shape.
            let result = try evaluate(operand)
            try runTryResult(result, errorVar: errorVar, handler: handler, okTarget: okTarget)

        case .matchStmt(let scrutinee, let cases, _):
            // The carried `scrutineeType` is deliberately not consulted: the interpreter's rule is value-based.
            // The static type already chose the arm family; reading it here would risk a second, disagreeing dispatch.
            let scrutineeValue = try evaluate(scrutinee)
            try runMatch(cases, scrutinee: scrutineeValue)

        // MARK: Nominal field store

        case .fieldStore(let base, let field, let value, _, _, _):
            // Right-hand side first, receiver second — the order the interpreter's assignment path uses.
            // Observable only when both have effects, which is exactly when a guessed mirror would be caught late.
            // Structs are copied field by field; without it a write through the copy reaches the original, silently.
            try storeField(base: base, field: field, value: RuntimeOps.copyIfStruct(try evaluate(value)))
        }
    }

    /// One `match` arm, run the way `Interpreter.executeMatch` runs one.
    /// Bindings live in a fresh chained environment and the body is a *block*; a `defer` drops the arm env on every exit.
    /// Bindings are positional by payload index — the lowerer resolved declaration order — and `nil` is the `_` placeholder.
    private func executeArm(_ arm: IRMatchCase, scrutinee value: Value) throws {
        let caseEnv = Environment(enclosing: currentEnv)
        if case .enumValue(let ev) = value {
            // The interpreter's arity gate: mismatched bindings are a run-time error, not a silent `.null`.
            // An arm with no bindings (a zero-payload case, a literal, a wildcard) is exempt.
            guard arm.bindings.isEmpty || arm.bindings.count == ev.associatedValues.count else {
                throw RuntimeError.arityMismatch(
                    expected: ev.associatedValues.count,
                    got: arm.bindings.count,
                    location: IRExecutor.noLocation
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

    /// `target[index] = newValue`, with value semantics: a write yields a **new** container rebound at every level.
    /// Mirrors `Interpreter.writeSubscript`: a variable target rebinds via `Environment.assign`, so `let` is rejected.
    /// Nested: write into the inner container, store it back; the inner index is evaluated twice, as the interpreter does.
    private func storeSubscript(target: IRExpr, index: Value, newValue: Value) throws {
        switch target {
        case .load(let name, _):
            let current = try currentEnv.get(name: name)
            let updated = try SubscriptWriteStrategy.write(
                container: current,
                index: index,
                newValue: newValue,
                location: IRExecutor.noLocation
            )
            try currentEnv.assign(name: name, value: updated)

        case .subscriptGet(let inner, let innerIndex, _):
            let innerIndexValue = try evaluate(innerIndex)
            let innerContainer = try evaluate(target)
            let updated = try SubscriptWriteStrategy.write(
                container: innerContainer,
                index: index,
                newValue: newValue,
                location: IRExecutor.noLocation
            )
            try storeSubscript(target: inner, index: innerIndexValue, newValue: updated)

        case .fieldGet(let baseExpr, let field, _):
            // `obj.field[i] = v` —— 对**字段值**写下标，再把新容器**写回该字段**。
            // 写回是必需的：容器写入可能分裂出新句柄，不回写则那次写会**静默丢失**。
            // `base` 只求值**一次**（同一接收者用于读字段与写回），理由见 `storeField(on:base:field:value:)`。
            let receiver = try evaluate(baseExpr)
            let containerValue = try fieldRead(from: receiver, field: field)
            let updated = try SubscriptWriteStrategy.write(
                container: containerValue,
                index: index,
                newValue: newValue,
                location: IRExecutor.noLocation
            )
            try storeField(on: receiver, base: baseExpr, field: field, value: updated)

        default:
            // 兜底：本引擎到此仍不认的目标形态（既非变量、非嵌套下标、也非字段）。
            //  注意  它**不再是**「字段目标还没做」那条说明 —— 字段目标现在走上面那一臂，
            //   `fieldGet` 不再落到这里。留着它是为了**响亮**：写成静默会丢一次写。
            throw RuntimeError.invalidOperation(
                reason: "IR executor: subscript store target is neither a variable, a "
                    + "nested subscript, nor a field get",
                location: IRExecutor.noLocation
            )
        }
    }

    /// A `match` arm selection, once the scrutinee value is in hand.
    /// Extracted so the yield driver finishes a suspended `match` through the same code; the tail rule is too subtle to copy.
    /// A copy would drift into two engines disagreeing about whether an unmatched enum is an error.
    private func runMatch(_ cases: [IRMatchCase], scrutinee value: Value) throws {
        for arm in cases {
            guard
                RuntimeOps.matchArmMatches(
                    caseName: arm.caseName, literal: arm.literal, value: value
                )
            else { continue }
            try executeArm(arm, scrutinee: value)
            return
        }
        // No arm fired: an enum value means the match was not exhaustive at run time, and says so with its case name.
        // A bare value falls through silently, since a literal's value space is infinite and `case _:` spells the rest.
        // Exhaustiveness is a checker duty (`E3-007`), so an enum reaching here was not statically coverable.
        if case .enumValue(let ev) = value {
            throw RuntimeError.matchNotExhaustive(
                value: ev.caseName, location: IRExecutor.noLocation
            )
        }
    }

    /// A try-else's outcome, once the operand's `Result` is in hand. Extracted
    /// for the same reason as `runMatch`, and by the same rule.
    private func runTryResult(
        _ result: Value,
        errorVar: String,
        handler: IRBlock,
        okTarget: String?
    ) throws {
        guard case .enumValue(let ev) = result,
            ev.parentEnum == RuntimeOps.builtinResultEnumName
        else {
            throw RuntimeError.typeMismatch(
                expected: "Result",
                got: RuntimeOps.describeValueKind(result),
                location: IRExecutor.noLocation
            )
        }
        let payload = ev.associatedValues.first ?? .null

        if ev.caseName == "ok" {
            // Expression position arrives as `allocVar(x, initializer: nil)` plus this node carrying `okTarget: x`.
            // So this write is the *initialization* of a declared slot; `assign` would misread it as assigning to a `let`.
            if let okTarget = okTarget {
                try currentEnv.initialize(name: okTarget, value: payload)
            }
            return
        }

        // The handler statements run *here*, not as a block, so `return` / `break` / `continue` leave as signals.
        // Their bare `pass` terminator just ends the statement.
        let handlerEnv = Environment(enclosing: currentEnv)
        handlerEnv.define(name: errorVar, value: payload, isMutable: true)
        let previousEnv = currentEnv
        currentEnv = handlerEnv
        defer { currentEnv = previousEnv }
        for statement in handler { try execute(statement) }
    }

    private func evaluateCondition(_ expr: IRExpr) throws -> Bool {
        let value = try evaluate(expr)
        guard case .bool(let flag) = value else {
            throw RuntimeError.typeMismatch(
                expected: "bool",
                got: "\(value)",
                location: IRExecutor.noLocation
            )
        }
        return flag
    }

    /// Select and run one `if`/`elif`/`else` branch. Extracted so the frame
    /// layer in the `ifStmt` case can wrap the selection without restating it
    /// — the selection is the same whether or not the `if` carries a label.
    private func executeIfBranch(
        condition: IRExpr,
        thenBody: IRBlock,
        elseBody: IRBlock?
    ) throws {
        if try evaluateCondition(condition) {
            try executeBlock(thenBody)
        } else if let elseBody = elseBody {
            try executeBlock(elseBody)
        }
    }

    /// Mirrors `Interpreter.executeWhile`, with unwind spoken in depths instead of labels.
    /// Body completes normally, or a `continue` for this loop → step runs; a `break` for this loop → return without it.
    /// A signal aimed at an outer loop is rethrown shallower with this step skipped, and a `return` propagates unchanged.
    private func executeWhile(condition: IRExpr, body: IRBlock, step: IRBlock?) throws {
        while true {
            if try !evaluateCondition(condition) { break }

            var shouldRunStep = true
            do {
                try executeBlock(body)
            } catch let signal as IRControlSignal {
                switch signal {
                case .breakSignal(let depth):
                    if depth == 1 { return }
                    throw IRControlSignal.breakSignal(depth: depth - 1)
                case .continueSignal(let depth):
                    if depth == 1 {
                        shouldRunStep = true
                    } else {
                        throw IRControlSignal.continueSignal(depth: depth - 1)
                    }
                default:
                    throw signal
                }
            }

            if shouldRunStep, let step = step {
                do {
                    try executeBlock(step)
                } catch let signal as IRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        if depth == 1 { return }
                        throw IRControlSignal.breakSignal(depth: depth - 1)
                    case .continueSignal(let depth):
                        if depth == 1 { continue }
                        throw IRControlSignal.continueSignal(depth: depth - 1)
                    default:
                        throw signal
                    }
                }
            }
        }
    }

    /// Mirrors `Interpreter.executeFor`: the iterable is decomposed first, so an arity mismatch errors even when empty.
    /// A dictionary row is `(key, value)` and skips the per-element decomposition; that 2-field guard is its only arity check.
    /// Each iteration gets a fresh chained environment; the step runs inside it, and the unwind follows `executeWhile`'s rule.
    private func executeForIn(
        pattern: [String],
        kind: IRForIterableKind,
        iterable: IRExpr,
        body: IRBlock,
        step: IRBlock?
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
                    $0, patternCount: pattern.count, location: IRExecutor.noLocation
                )
            }
        case (.dict, .dictionary(let pairs)):
            guard pattern.count == 2 else {
                throw RuntimeError.typeMismatch(
                    expected: "字典迭代需 2 字段模式元组 (k, v)",
                    got: "\(pattern.count) 字段",
                    location: IRExecutor.noLocation
                )
            }
            rows = pairs.map { [$0.0, $0.1] }
        default:
            throw RuntimeError.typeMismatch(
                expected: "可迭代集合（数组/字典/集合）",
                got: "\(iterValue)",
                location: IRExecutor.noLocation
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
            } catch let signal as IRControlSignal {
                switch signal {
                case .breakSignal(let depth):
                    currentEnv = previousEnv
                    if depth == 1 { return }
                    throw IRControlSignal.breakSignal(depth: depth - 1)
                case .continueSignal(let depth):
                    if depth > 1 {
                        currentEnv = previousEnv
                        throw IRControlSignal.continueSignal(depth: depth - 1)
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
                } catch let signal as IRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        currentEnv = previousEnv
                        if depth == 1 { return }
                        throw IRControlSignal.breakSignal(depth: depth - 1)
                    case .continueSignal(let depth):
                        currentEnv = previousEnv
                        if depth == 1 { continue }
                        throw IRControlSignal.continueSignal(depth: depth - 1)
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
    /// The one place a function value is created, so the halves cannot be built apart.
    /// A lookup miss therefore means the value came from elsewhere — a hand-built module — not a missing `make` call.
    private func makeFunctionValue(
        name: String,
        paramNames: [String],
        body: IRBlock,
        returnLabels: [String?],
        closure: Environment
    ) -> Value {
        let function = FunctionValue(
            name: name,
            params: paramNames.map { Parameter(name: $0) },
            closure: closure
        )
        callableBodies[ObjectIdentifier(function)] = IRCallableBody(
            paramNames: paramNames,
            body: body,
            returnLabels: returnLabels
        )
        return .function(function)
    }

    /// The component names a declared return type carries, when it is a named tuple (`-> (商: I32, 余: I32,)`).
    /// A scalar, a positional tuple and a void return yield nothing, and `applyReturnLabels` leaves the value untouched.
    private static func declaredReturnLabels(_ type: IRType?) -> [String?] {
        guard let type = type, case .tuple(let labels, _) = type else { return [] }
        return labels
    }

    /// Call a module-level function by its declaration.
    /// Its parent is the global environment and its labels come from its return type — an ordinary case of the call path.
    /// With the function-value case in `evaluate` this is the whole of how a call happens.
    private func call(_ function: IRFunction, args: [Value]) throws -> Value {
        try invoke(
            IRCallableBody(
                paramNames: function.params.map { $0.name },
                body: function.body,
                returnLabels: IRExecutor.declaredReturnLabels(function.returnType),
                isAsync: function.isAsync
            ),
            parent: globalEnv,
            args: args,
            name: function.name
        )
    }

    /// Calls a function value the engine holds a body for: keyed by identity, since every anonymous `func` is `<anon>`.
    /// Its parent is the value's own environment, not global — the one rule separating a closure call from a module-level one.
    /// Both go through `invoke`, so arity, depth guard, defer scope, return labels and the trailing-expression rule exist once.
    private func callFunctionValue(_ function: FunctionValue, args: [Value]) throws -> Value {
        guard let callable = callableBodies[ObjectIdentifier(function)] else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: a function value with no registered body "
                    + "(hand-built, or carried in from another run) cannot be called",
                location: IRExecutor.noLocation
            )
        }
        return try invoke(callable, parent: function.closure, args: args, name: function.name)
    }

    private func invoke(
        _ callable: IRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> Value {
        guard callable.paramNames.count == args.count else {
            throw RuntimeError.arityMismatch(
                expected: callable.paramNames.count,
                got: args.count,
                location: IRExecutor.noLocation
            )
        }

        // The arity check stays above the dispatch on purpose: it is a property of the call, not of the thread the body lands on.
        // Below the dispatch, a spawned body's arity error would surface as a rejected Future the caller may never inspect.
        if callable.isAsync {
            return try spawnAsync(callable, parent: parent, args: args, name: name)
        }
        return try invokeBody(callable, parent: parent, args: args, name: name)
    }

    /// Run an async body on a worker thread; hand the caller a pending Future.
    /// Mirrors the interpreter's `isAsync` branch: link the child before the body runs, put the handle on the worker.
    /// Closing the scope on both exits is the third such rule; getting it wrong leaks or drops a failure silently.
    private func spawnAsync(
        _ callable: IRCallableBody, parent: Environment, args: [Value], name: String
    ) throws -> Value {
        let future = FutureValue()
        currentFuture?.addChild(future)
        let captured = callable
        let boundArgs = args
        let work = WorkHandoff { [weak self] in
            guard let self = self else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: the engine was released while an async body ran",
                    location: IRExecutor.noLocation
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
                    return .finished(IRExecutor.closeTask(future, value: result))
                case .givenUp(let frame):
                    // The thread goes back to the pool with nothing sent to the future: the body is not done.
                    // The resumer owns completion from here — that is the entire content of "the task was given up".
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
        scheduler.spawn(future) { try work.run() }
        return .future(future)
    }

    /// The closing act a task performs once, however many runs it took.
    private static func closeTask(_ future: FutureValue, value: Value) -> Value {
        RuntimeOps.flipIfLeaked(value, leaked: future.closeScope())
    }

    /// The synchronous body path: bind the arguments, run the statements, unwrap the return signal.
    /// A wrapper over `invokeBodyStep` for a shared prologue and exit rule; the unwrap is the whole of what synchronous means.
    /// A suspension arriving here is a driver defect, since a sync body keeps the thread at a join, so it is named.
    private func invokeBody(
        _ callable: IRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> Value {
        switch try invokeBodyStep(callable, parent: parent, args: args, name: name) {
        case .finished(let value):
            return value
        case .givenUp:
            throw RuntimeError.invalidOperation(
                reason: "IR executor: a synchronous body gave its task up at a join "
                    + "— the yield envelope and the driver disagree about what can suspend",
                location: IRExecutor.noLocation
            )
        }
    }

    /// Enter a body and run it, reporting a suspension rather than hiding it.
    /// The prologue is `invokeBody`'s: stack guard, argument binding, environment, defer scope; what differs is the exit.
    /// A given-up body must not unwind: its `defer`s would run at a suspension; `standDown` leaves the thread clean.
    private func invokeBodyStep(
        _ callable: IRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> IRBodyStep {
        guard RuntimeOps.mayEnterAnotherBody(depth: callDepth) else {
            throw RuntimeOps.recursionGuardError(depth: callDepth)
        }
        callDepth += 1
        callStackNames.append(name)

        let callEnv = Environment(enclosing: parent)
        for (index, name) in callable.paramNames.enumerated() {
            callEnv.define(name: name, value: args[index], isMutable: true)
        }

        let previousEnv = currentEnv
        currentEnv = callEnv

        // A function body is a defer scope of its own, as in `executeFunctionBody`, since it also owns `lastValue`.
        // Defers run before the environment restore, so they still see the function's own environment.
        // `exitBody` spells that out instead of two `defer`s, because a suspended body must not take either.
        pushDeferScope()

        let step: IRBodyStep
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

    /// Pick a given-up body back up, on whichever thread the awaited future settled on.
    /// No prologue: the arguments were bound before the suspension and their environment is the one in the frame.
    /// Re-entering the prologue would rebind them over a body already past them, restarting it with fresh parameters.
    private func resumeBody(_ frame: IRYieldFrame, awaited: Value) throws -> IRBodyStep {
        currentEnv = frame.env
        callDepth = frame.callDepth
        callStackNames = frame.callStackNames
        deferStack = frame.deferStack
        currentFuture = frame.currentFuture

        let step: IRBodyStep
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
    /// The four thread-locals are *cleared*, not restored: a suspended body has no outer frame on that thread.
    /// Left set, the next task inherits a stranger's depth, backtrace and defers; the frame carries the real values.
    private func standDown() {
        callDepthStorage.value = nil
        callStackNames = []
        deferStack = []
        currentEnvStorage.value = nil
    }

    /// The body loop's signal rule, shared so the first run and every resume apply it once.
    /// A `return` is the body's own and becomes the value, with return-site labels applied; every other signal is rethrown.
    private func bodyOutcome(
        returnLabels: [String?],
        _ run: () throws -> IRBodyStep
    ) throws -> IRBodyStep {
        do {
            return try run()
        } catch let signal as IRControlSignal {
            if case .returnSignal(let value) = signal {
                // The interpreter's return-site rule, fed from the declared return type instead of the AST's `returnLabels`.
                // Only the explicit `return` path is relabelled; an implicit trailing expression is left alone, as the interpreter does.
                // A closure passes no labels, mirroring a `FunctionValue` built with no declaration attached.
                return .finished(RuntimeOps.applyReturnLabels(returnLabels, to: value ?? .null))
            }
            throw signal
        }
    }

    /// Run a body's statements, reporting a suspension; `lastValue` travels in the frame, since it is where the body was.
    /// `pending` rejoins a resumed run: the statement at `from` is finished with the awaited value, then the loop carries on.
    /// - Parameter yieldable: only an async body may give the task up; a sync body keeps the thread, exactly as `wait` does.
    private func driveStatements(
        _ callable: IRCallableBody,
        previousEnv: Environment,
        from index: Int,
        lastValue: Value,
        yieldable: Bool,
        pending: (resume: (Value) throws -> Value?, value: Value)?
    ) throws -> IRBodyStep {
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
                // The operand is evaluated synchronously and deliberately: it *produces* the future, so it cannot wait on one.
                // A join nested inside it is refused by the lowerer, which keeps this call off the recursive path.
                let operand = try evaluate(plan.operand)
                guard case .future(let fut) = operand else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(operand),
                        location: IRExecutor.noLocation
                    )
                }

                // A settled future is no reason to give the task up: taking the value keeps `await` on `wait`'s path, with no task switch.
                // The third case is the back end saying "not this time": compliant, not broken, so the wait occupies the thread silently.
                // Suspending there would deadlock, which is not a reduced reading of `await` but a program that stops.
                if fut.isFinished {
                    let value = RuntimeOps.joinFuture(fut, timeoutMs: nil, form: .awaits)
                    if let updated = try finishYield(plan, value: value) { last = updated }
                } else if scheduler.yieldTask() == 1 {
                    return .givenUp(
                        IRYieldFrame(
                            callable: callable,
                            index: position,
                            finish: { [weak self] value in
                                guard let self = self else { return nil }
                                // The child's lifetime is consumed here, and this is the one way into `finishYield` that must say so itself.
                                // Without it the child stays in this body's scope, so the return boundary reads a waited-for failure as unjoined.
                                // Then the body's own `ok` comes out as `err(aggregate)` and whatever it did with the error is discarded.
                                fut.detachFromParent()
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
    /// only those. See `IRYieldPlan` for why this is a whitelist.
    private func yieldPlan(for statement: IRStmt) -> IRYieldPlan? {
        let plan: IRYieldPlan?
        switch statement {
        case .exprStmt(.join(let operand, _, .awaits)):
            plan = .expressionStatement(operand: operand)

        case .allocVar(let name, let type, let mutable, .some(.join(let operand, _, .awaits)), _):
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
    /// The `var` case replays the arm's whole tail — the struct copy and the relabel — which a naive resume would skip.
    /// Returning `nil` means the statement contributed no value, as `lastValue` counts only expression statements.
    private func finishYield(_ plan: IRYieldPlan, value: Value) throws -> Value? {
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

    // MARK: - 就绪队列的驱动面（`Q-3`：结果决出 ⇒ 入队，而非直接重入体）

    /// 一个**已决出、待续跑**的任务 —— 策略层队列里那个句柄所指的东西。
    /// 它是**驱动层的私面**：队列元素只是不透明标量句柄，句柄映射到哪件东西由驱动层决定。
    /// ⇒ 策略层不必认识任务，也不必认识帧。
    private struct ReadyItem {
        let task: FutureValue
        let frame: IRYieldFrame
        /// 让出时等到的那个值 —— 推进它时随调用带进去（本后端的取值形态）。
        let value: Value
    }

    /// 这次去问策略层，得到了什么。
    /// 「空」与「缺陷」必须分开：前者是正常状态（刚建好的队列就是空的），后者是策略给了个从没发出去过的句柄。
    /// 混成一个读数会把缺陷读成「暂时没活」，于是静默什么都不做 —— 那是本引擎最不能出的结果。
    private enum ReadyTake {
        case item(ReadyItem)
        case empty
        case unknown(Int)
    }

    /// 句柄 → 待续跑项。
    /// **跨线程共享**：谁把结果决出就由谁入队，故写入方是多条工作线程，读取方是驱动循环。
    /// 由 `readyLock` 守护 —— 「同族既有状态已有隔离」这条推不到新状态上。
    private var readyItems: [Int: ReadyItem] = [:]

    /// 下一个要发的句柄。
    /// 「没有下一个」在降载后是一个**整数零** ⇒ 这里保留 `0`、真任务从 `1` 起。
    /// 不引入指针承载：队列元素只是**不透明标量**，换成地址反而要自己管生命周期。
    private var nextReadyHandle = 1

    /// 「趟」的两笔账：**有人要挑**、**已经有一趟在挑**。
    /// 一批任务全部入队后才请挑选循环，而请挑选可能落在另一条线程上（同一时刻可能有多批）。
    /// ⇒ 用「已有循环在跑就只记一笔」收成同一时刻只跑一趟，那一笔由收工的那趟兑现。
    private var readyDrainRequested = false
    private var readyDrainScheduled = false
    private var readyDraining = false
    private let readyLock = NSLock()

    /// 一批待续跑项：**同一个被等的未来**上挂着的全部帧，帧与任务**成对**存（一个任务同时只有一个未决帧）。
    /// 一个未来只挂一个回调，是「顺序由策略决定」成立的前提：漏了它，挑选顺序会退回决出顺序。
    /// 故按「被等的未来」并批：一个回调负责把这一批**先全部入队、再挑**。
    private struct PendingFrame {
        let frame: IRYieldFrame
        let task: FutureValue
    }
    private var framesAwaitingSettle: [ObjectIdentifier: [PendingFrame]] = [:]

    /// 调策略层那两个方法的**串行面**。
    /// 那两个方法碰的是同一个对象：入队来自决出方、取一个来自驱动循环 ⇒ 两条线程会同时碰它。
    /// 队列仍归策略层，本锁只管**调用不重叠**。
    private let strategyLock = NSLock()

    /// 语言层那句「没有下一个」在运行期的样子。
    private static let emptyHandle = 0

    /// 策略层那两个方法在方法表里的键。
    /// 键用**降载器同一个改名函数**算，不在这里手写拼法：手写的那份改名时不出声，错时的症状是找不到自己程序里的方法。
    private var strategyMethodKeys: (accept: String, pick: String) {
        let typeName = IRName.mangle(PredefinedDecls.schedulerTypeName)
        return (
            "\(IRName.mangle(PredefinedDecls.acceptMethodName))__\(typeName)",
            "\(IRName.mangle(PredefinedDecls.pickMethodName))__\(typeName)"
        )
    }

    /// 策略层那个值。 重要  **运行期物化** —— 装载期的契约是「只注册、不运行」，
    /// 故它不能在 `prepare` 里求（那条路的代价已经实测过一次）。
    private func strategyInstance() throws -> Value {
        try materializeGivenInstance(
            .nominal(name: PredefinedDecls.schedulerTypeName, isObject: false)
        )
    }

    /// 把一件待续跑的任务交给策略层。**入队是同步的** ⇒ 调用方可以「先入完一批、再挑」。
    ///
    /// - Returns: 真的入队了 ⇒ `true`（入不了队时已就地处置，见下）。
    @discardableResult
    private func offerToStrategy(frame: IRYieldFrame, task: FutureValue, value: Value) -> Bool {
        readyLock.lock()
        let handle = nextReadyHandle
        nextReadyHandle += 1
        readyItems[handle] = ReadyItem(task: task, frame: frame, value: value)
        readyLock.unlock()

        do {
            try strategyAccept(handle: handle)
        } catch {
            // 入不了队 ⇒ 这件任务**永远不会被推进**，而它手里的等待者会一直等下去。
            //  行不通  不静默丢掉：当作那个任务自己的一次失败交出去，让调用方看得见。
            readyLock.lock()
            readyItems.removeValue(forKey: handle)
            readyLock.unlock()
            _ = task.closeScope()
            task.reject(GCDScheduler.coerce(error))
            return false
        }
        return true
    }

    /// 调策略层的「收下」。接收者走**首个实参位** —— 类型方法的既定调用形态。
    private func strategyAccept(handle: Int) throws {
        guard let accept = methods[strategyMethodKeys.accept] else {
            throw IRExecutor.missingStrategyMethod(PredefinedDecls.acceptMethodName)
        }
        strategyLock.lock()
        defer { strategyLock.unlock() }
        _ = try call(accept, args: [try strategyInstance(), .int(handle)])
    }

    /// 问策略层「下一个是谁」，并把答案落成一件待推进项。
    private func strategyPick() throws -> ReadyTake {
        guard let pick = methods[strategyMethodKeys.pick] else {
            throw IRExecutor.missingStrategyMethod(PredefinedDecls.pickMethodName)
        }
        strategyLock.lock()
        let answered: Value
        do {
            answered = try call(pick, args: [try strategyInstance()])
            strategyLock.unlock()
        } catch {
            strategyLock.unlock()
            throw error
        }
        guard let handle = IRExecutor.handleNumber(answered) else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: the scheduler's '选择下一个任务' answered \(answered),"
                    + " which is not a handle",
                location: IRExecutor.noLocation
            )
        }
        guard handle != IRExecutor.emptyHandle else { return .empty }
        readyLock.lock()
        let item = readyItems.removeValue(forKey: handle)
        readyLock.unlock()
        guard let item = item else { return .unknown(handle) }
        return .item(item)
    }

    private static func missingStrategyMethod(_ name: String) -> RuntimeError {
        RuntimeError.invalidOperation(
            reason: "IR executor: the scheduler has no '\(name)' method — "
                + "the preset declaration or the program's replacement lacks it",
            location: IRExecutor.noLocation
        )
    }

    /// 把一个策略层给的答案读成句柄号。
    /// 那一格的声明是**单元素元组**，而「单元素返回」在本语言里不写括号 ⇒ 两种形态都得认。
    /// 认不出就报缺陷 —— 静默当成「没有下一个」会把「策略坏了」读成「暂时没活」。
    private static func handleNumber(_ value: Value) -> Int? {
        if case .int(let handle) = value { return handle }
        if case .tuple(_, let elements) = value, elements.count == 1,
            case .int(let handle) = elements[0] {
            return handle
        }
        return nil
    }

    /// 请一趟驱动循环来把这批活挑完。**同一时刻只排一趟**。
    ///
    ///  注意  排的是**另起一趟**而不是就地跑 —— 理由见 `readyDrainRequested` 的说明。
    private func scheduleReadyDrain() {
        readyLock.lock()
        if readyDraining || readyDrainScheduled {
            readyDrainRequested = true
            readyLock.unlock()
            return
        }
        readyDrainScheduled = true
        readyLock.unlock()
        DispatchQueue.global().async { [weak self] in self?.runReadyLoop() }
    }

    /// 驱动循环：**问策略要一个 ⇒ 推进它一次**，直到策略说没有下一个。
    private func runReadyLoop() {
        readyLock.lock()
        readyDrainScheduled = false
        readyDraining = true
        readyLock.unlock()

        //  注意  策略给的答案**可不可信**要分开记：不可信时**不得**再排下一趟，
        // 否则「策略每次都答同一个我们不认识的句柄」会转成一个不停循环。
        var trustworthy = true
        drain: while true {
            let take: ReadyTake
            do {
                take = try strategyPick()
            } catch {
                trustworthy = false
                IRExecutor.reportStrategyDefect("\(error)")
                break drain
            }
            switch take {
            case .item(let item):
                //  注意  在队列里等着的这段时间里它可能被取消 ⇒ **出队即丢弃**：
                // 一个从未被进入的体没有检查点，取消只能在**这里**被看见。
                if item.task.isCancelled { continue drain }
                completeResumedRun(item.frame, task: item.task, value: item.value)
            case .empty:
                break drain
            case .unknown(let handle):
                trustworthy = false
                IRExecutor.reportStrategyDefect(
                    "it named handle \(handle), which was never handed out")
                break drain
            }
        }

        readyLock.lock()
        readyDraining = false
        // 关掉那道窗：本循环据「策略说没有」收工时，另一边可能刚入了队、
        // 又因为「已经有一趟在跑」而只记了一笔 ⇒ 那一笔在这里兑现。
        let again = trustworthy && readyDrainRequested && !readyDrainScheduled
        readyDrainRequested = false
        if again { readyDrainScheduled = true }
        readyLock.unlock()
        if again {
            DispatchQueue.global().async { [weak self] in self?.runReadyLoop() }
        }
    }

    /// 策略层坏了 —— 响亮说， 行不通  不静默降级成「没有下一个」。
    private static func reportStrategyDefect(_ detail: String) {
        print("[scheduler]  行不通  策略层给出的答案不可用，就绪队列停止驱动：\(detail)")
    }

    /// Wait for the future a body gave the task up on, and hand the bodies to the policy when it settles.
    /// Settling offers the task to the scheduler's queue rather than resuming it, so the policy's order decides.
    /// Registration is per awaited future, not per frame, and no thread is held while the body waits.
    private func attachResume(_ frame: IRYieldFrame, task: FutureValue) {
        let key = ObjectIdentifier(frame.awaited)
        readyLock.lock()
        let isFirstOfBatch = framesAwaitingSettle[key] == nil
        framesAwaitingSettle[key, default: []].append(PendingFrame(frame: frame, task: task))
        readyLock.unlock()

        guard isFirstOfBatch else { return }
        frame.awaited.whenResolved { [weak self] outcome in
            guard let self = self else { return }
            self.settleBatch(key: key, outcome: outcome)
        }
    }

    /// 一个被等的未来有了结果（或失败）⇒ 处置它名下那一批。
    /// 顺序是「**先全部入队、再请挑选**」，两步分开且都在这一个回调里。
    /// ⇒ 策略层看到的是**整批**，而不是「先醒来的那一个」。
    private func settleBatch(key: ObjectIdentifier, outcome: Result<Value, RuntimeError>) {
        readyLock.lock()
        let batch = framesAwaitingSettle.removeValue(forKey: key) ?? []
        readyLock.unlock()

        switch outcome {
        case .success(let value):
            var enqueuedAny = false
            for item in batch {
                if offerToStrategy(frame: item.frame, task: item.task, value: value) {
                    enqueuedAny = true
                }
            }
            guard enqueuedAny else { return }
            scheduleReadyDrain()
        case .failure(let error):
            // The body never gets its value, so it never reaches its closing act; the scope is closed here or children keep running.
            // Leaks the close reports are dropped: this task fails on its own account, and an aggregate would replace that reason.
            for item in batch {
                _ = item.task.closeScope()
                item.task.reject(error)
            }
        }
    }

    /// Run a resumed body to its next stopping point and settle the task.
    private func completeResumedRun(_ frame: IRYieldFrame, task: FutureValue, value: Value) {
        do {
            switch try resumeBody(frame, awaited: value) {
            case .finished(let result):
                task.resolve(IRExecutor.closeTask(task, value: result))
            case .givenUp(let next):
                // 续跑这一趟也让出了，而它不由派发口驱动 ⇒ 记账要在这里补一次。
                // 漏掉这一句，本后端就只数得到**首跑那一趟**，而 LLVM 后端数的是每一次。
                // 各后端在「一个体内让出多次」的语料上会分岔，且两边各自的数都看不出错。
                scheduler.noteYield()
                attachResume(next, task: task)
            }
        } catch {
            // `resumeBody` turns a return signal into a value, so a control signal here escaped past its body — a driver defect.
            // It is reported as such, not read as an await failure; leaked children are dropped for the same reason as above.
            _ = task.closeScope()
            task.reject(GCDScheduler.coerce(error))
        }
    }
}
