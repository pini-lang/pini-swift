import Foundation

/// HIR -> LLVM IR text emitter for the M4 vertical slice (LR-2/LR-3).
///
/// The emitter is a mechanical translation: every type decision was already
/// made by `HIRLowerer` (the single capability gate), so this file contains no
/// type inference, no shadow type tables, and no unsupported paths — the
/// slice node set is emitted in full. State is per-emission: create one fresh
/// emitter per module; nothing is shared with the legacy `IRGenerator`.
///
/// Output contract: LLVM IR text that `lli`/`clang` execute with stdout
/// semantics matching the interpreter (print = value + newline; bool as
/// true/false; double via %f — see the print-format parity note in
/// issue-llvm-rewrite-plan-2026-09-07 for the known F64 divergence).
public final class IREmitter {

    // MARK: - Per-function state

    /// Block-nested variable slots: scopes.last is the innermost block.
    /// Mirrors the HIR tree nesting so shadowing declarations resolve
    /// innermost-first at emit time.
    private var scopes: [[String: String]] = []

    /// Per-function slot-name counters so shadowing declarations get fresh
    /// allocas instead of colliding with the outer slot.
    private var slotCounters: [String: Int] = [:]

    /// Current block terminated by `ret`; later statements in the block are
    /// unreachable and must not be emitted (instructions after a terminator
    /// are invalid IR).
    private var terminated = false

    /// Enclosing loop labels, innermost last. `break` targets `exit`;
    /// `continue` targets `continueTarget` (the step entry when the loop has
    /// a step block, else the header) — labeled forms (depth > 1, ADR-014)
    /// target the depth-th frame's `header`. With an empty stack both lower
    /// to a runtime panic (interpreter parity: a bare break/continue
    /// escaping to the top level errors).
    private struct LoopFrame {
        let exit: String
        let header: String
        let continueTarget: String
        /// Index of the loop BODY's defer frame in `pendingDefers` (the
        /// frame pushed after this loop frame was pushed). A break/continue
        /// out of this loop flushes defer frames from the innermost one down
        /// to this index, both included — leaving the loop's body block runs
        /// its defers (interpreter: the signal unwinds through
        /// executeBlock's own popDeferScope).
        let deferBase: Int
    }

    private var loopStack: [LoopFrame] = []

    /// Index in `pendingDefers` where the current function's (or closure's)
    /// defer frames begin. A `return` flushes defer frames down to this
    /// base and no further — a return inside a closure must not run the
    /// enclosing function's defers.
    private var deferScopeBase = 0

    private var currentIsMain = false
    private var currentReturnType: HIRType? = nil

    private var builder = IRBuilder()
    private var bodyIR = ""

    /// Nominal type declarations of the module being emitted (G3) — field
    /// layouts for constructor / field-access GEPs.
    private var moduleTypes: [HIRTypeDecl] = []

    /// Enum declarations of the module being emitted (G4) — case tags and
    /// payload types for construction and match dispatch.
    private var moduleEnums: [HIREnumDecl] = []

    // MARK: - Module-level collected pieces

    private var stringConstantDefs: [String] = []
    private var stringConstants: [String: (name: String, length: Int)] = [:]
    private var usesStrCmp = false

    // MARK: G6 closure / higher-order state

    /// Deferred closure `define` bodies (legacy `closureDefsIR` contract):
    /// buffered during function emission, appended at module end so the SSA
    /// namespace of the main body stays intact.
    private var closureDefs: [String] = []
    /// Deferred env struct type declarations, referenced by creation-point
    /// GEPs before the closure bodies are appended (forward refs legal).
    private var closureEnvTypeDecls: [String] = []
    /// Env-ignoring adapter definitions for named functions used as values
    /// (`@__adapter_<mangled>`), deduplicated by mangled name.
    private var adapterDefs: [String] = []
    private var adapterNames: Set<String> = []
    /// Captured-variable slot pointers active inside the closure body being
    /// emitted: capture name -> register holding the variable's slot pointer.
    /// Registered like scope slots so `load`/`storeVar` inside the body are
    /// slot-based (reference capture: all accesses go through the slot).
    private var captureSlots: [String: String] = [:]
    /// Module function registry by mangled IR name (G6): adapter generation
    /// reads the original ABI (params/return) from here.
    private var moduleFunctions: [String: HIRFunction] = [:]
    /// G13 batch 1: `%bk_lazyref` handle type + `bk_lazyref_*` C ABI used —
    /// the header declares are appended conditionally (legacy
    /// `usesLazyRef` contract, golden-IR stability for modules that
    /// never touch LazyRef).
    private var usesLazyRef = false
    /// G15: `writeFile`/`readFile` pull in the stdio declares and the
    /// mode-string constants. Conditional for the same golden-IR reason
    /// as the other optional headers.
    private var usesFileIO = false
    /// G17: `readLine` pulls in the `fgets` declare and the stdin stream
    /// global. Conditional for the same golden-IR reason as the other
    /// optional headers.
    private var usesReadLine = false
    /// G13 batch 1: type-specialized `@__lazyref_wrapper_<T>` define buffer,
    /// deduplicated by element IR spelling; appended after the adapter defs.
    private var lazyrefWrappers: [String] = []
    private var lazyrefWrapperNames: Set<String> = []

    /// Program base for compile-time IO path baking — the new-pipeline
    /// counterpart of the legacy generator's knob of the same name, which
    /// fed its own IO emitter. An unprefixed relative path *literal* is
    /// written into the IR as `base + "/" + path`; absolute paths and `./`
    /// `../` prefixed ones stay as written (the runtime CWD resolves those),
    /// exactly mirroring both the legacy emitter and the interpreter's
    /// runtime resolution rule.
    ///
    /// Default nil, so an emitter without a configured base — every
    /// pre-existing test that drives the pipeline directly — behaves as
    /// before and its golden IR is unchanged. Code generation needs the base
    /// because the emitted program has no runtime notion of where its source
    /// lived; a non-literal path expression cannot be baked either way and
    /// keeps resolving against the CWD (known v1 limitation).
    ///
    /// This sits in the emitter rather than in the HIR tree on purpose: it is
    /// a code-generation environment input, not a language-semantics
    /// decision, and the HIR tree stays a pure lowering of the source.
    public var programBase: String?

    public init() {}

    // MARK: - Module

    public func emit(module: HIRModule) -> String {
        var header = "; Pini LLVM IR (HIR pipeline, M4 slice)\n"
        header += "declare i32 @printf(ptr, ...)\n"
        header += "declare ptr @bk_double_to_string(double)\n"
        header += "declare ptr @free(ptr)\n"
        header += "declare double @sqrt(double)\n"
        header += "@fmt_int = private constant [3 x i8] c\"%d\\00\"\n"
        header += "@fmt_bool_true = private constant [6 x i8] c\"true\\00\\00\"\n"
        header += "@fmt_bool_false = private constant [7 x i8] c\"false\\00\\00\"\n"
        header += "@fmt_string = private constant [3 x i8] c\"%s\\00\"\n"
        header += "@fmt_newline = private constant [2 x i8] c\"\\0A\\00\"\n"
        // Array family (G2): opaque handle type + runtime C ABI declares.
        // Forward references are legal in LLVM IR modules (same contract as
        // the legacy IRGenerator header), so declares are unconditional.
        header += "%bk_array = type { ptr }\n"
        header += "declare ptr @bk_array_create(i32)\n"
        header += "declare i32 @bk_array_len(ptr)\n"
        header += "declare ptr @bk_array_get(ptr, i32)\n"
        header += "declare ptr @bk_array_set(ptr, i32, ptr, i32, i32)\n"
        header += "declare void @bk_handle_retain(ptr)\n"
        header += "declare ptr @bk_handle_ensure_unique(ptr)\n"
        header += "declare ptr @bk_array_ensure_unique_at(ptr, i32)\n"
        header += "declare void @bk_panic(ptr) noreturn\n"
        // Dict / set family (G5): opaque handles + runtime C ABI declares.
        header += "%bk_dict = type { ptr }\n"
        header += "%bk_set = type { ptr }\n"
        header += "declare ptr @bk_dict_create()\n"
        header += "declare i32 @bk_dict_len(ptr)\n"
        header += "declare ptr @bk_dict_get(ptr, ptr, i32, i32)\n"
        header += "declare ptr @bk_dict_set(ptr, ptr, i32, i32, ptr, i32, i32)\n"
        header += "declare ptr @bk_dict_ensure_unique_at(ptr, ptr, i32, i32)\n"
        header += "declare ptr @bk_dict_key_at(ptr, i32)\n"
        header += "declare ptr @bk_dict_val_at(ptr, i32)\n"
        header += "declare ptr @bk_set_create()\n"
        header += "declare i32 @bk_set_len(ptr)\n"
        header += "declare ptr @bk_set_add(ptr, ptr, i32, i32)\n"
        header += "declare ptr @bk_set_at(ptr, i32)\n"
        // libc + LLVM intrinsics (G9 string deepening / math intrinsics).
        header += "declare i64 @strlen(ptr)\n"
        header += "declare ptr @strcat(ptr, ptr)\n"
        header += "declare ptr @strcpy(ptr, ptr)\n"
        header += "declare ptr @memcpy(ptr, ptr, i64)\n"
        header += "declare ptr @strtok(ptr, ptr)\n"
        header += "declare ptr @strstr(ptr, ptr)\n"
        header += "declare i32 @toupper(i32)\n"
        header += "declare i32 @tolower(i32)\n"
        header += "declare i32 @snprintf(ptr, i64, ptr, ...)\n"
        header += "declare ptr @malloc(i64)\n"
        header += "declare double @llvm.sin.f64(double)\n"
        header += "declare double @llvm.cos.f64(double)\n"
        // G14: foreign blocks declare their external signatures. Symbols
        // resolve at JIT link time (libc via the process image inside lli;
        // dlopened libraries via lli --dlopen=... in the test harness).
        // Symbols already declared by the fixed header (malloc/free/strlen)
        // are skipped — LLVM rejects redefinition.
        let predeclared: Set<String> = ["printf", "malloc", "free", "strlen", "memcpy"]
        // Runtime-provided shims: not libc, resolved from the runtime dylib
        // (--dlopen in the harness). Emit the bk_ symbol declare.
        let runtimeShims: Set<String> = ["cstr"]
        for foreignBlock in module.foreigns {
            for func_ in foreignBlock.funcs where !predeclared.contains(func_.name) {
                let symbol = runtimeShims.contains(func_.name) ? "bk_\(func_.name)" : IRName.mangle(func_.name)
                let params = func_.paramTypes.map { $0.llvmSpelling }.joined(separator: ", ")
                let ret = func_.returnType?.llvmSpelling ?? "void"
                header += "declare \(ret) @\(symbol)(\(params))\n"
            }
        }
        header += "\n"

        bodyIR = ""
        stringConstantDefs = []
        stringConstants = [:]
        usesStrCmp = false
        usesLazyRef = false
        usesReadLine = false
        lazyrefWrappers = []
        lazyrefWrapperNames = []
        moduleTypes = module.types
        moduleEnums = module.enums
        // G6: record every top-level function's ABI by mangled IR name so
        // adapter generation can mirror the original signature.
        moduleFunctions = [:]
        for function in module.functions {
            moduleFunctions[Self.mangle(function.name)] = function
        }
        for typeDecl in module.types {
            for method in typeDecl.methods {
                moduleFunctions[Self.mangle(method.name)] = method
            }
        }
        // Nominal type definitions (G3): `%struct.X = type { ... }` /
        // `%object.X = type { i32 (refcount), ... }` come first so field GEPs
        // verify against complete types. Enums (G4): tagged unions —
        // `%enum.X = type { i32, <max-arity case payload types> }`.
        for typeDecl in module.types {
            let aggregate = "%\(typeDecl.isObject ? "object" : "struct").\(IRName.mangle(typeDecl.name))"
            var fieldTypes = typeDecl.isObject ? ["i32"] : []
            fieldTypes.append(contentsOf: typeDecl.fields.map { $0.type.llvmSpelling })
            bodyIR += "\(aggregate) = type { \(fieldTypes.joined(separator: ", ")) }\n"
        }
        for enumDecl in module.enums {
            let aggregate = "%enum.\(IRName.mangle(enumDecl.name))"
            var fieldTypes = ["i32"]
            fieldTypes.append(contentsOf: enumDecl.slotTypes.map { $0.llvmSpelling })
            bodyIR += "\(aggregate) = type { \(fieldTypes.joined(separator: ", ")) }\n"
        }
        if !module.types.isEmpty || !module.enums.isEmpty {
            bodyIR += "\n"
        }
        for function in module.functions {
            emitFunction(function)
        }
        for typeDecl in module.types {
            for method in typeDecl.methods {
                emitFunction(method)
            }
        }

        var tail = ""
        for def in stringConstantDefs {
            tail += def + "\n"
        }
        if usesStrCmp {
            tail += "declare i32 @strcmp(ptr, ptr)\n"
        }
        // G13 batch 1: LazyRef handle type + C ABI declares, appended only
        // when the module actually creates/reads a lazy reference (the
        // legacy emitter's conditional-header contract).
        if usesLazyRef {
            tail += "%bk_lazyref = type { ptr }\n"
            tail += "declare ptr @bk_lazyref_create(ptr, ptr, ptr, i32, i32)\n"
            tail += "declare ptr @bk_lazyref_value(ptr)\n"
        }
        // G15: file IO declares + mode-string constants, appended only for
        // modules that actually call writeFile/readFile.
        if usesFileIO {
            tail += "declare ptr @fopen(ptr, ptr)\n"
            tail += "declare i64 @fwrite(ptr, i64, i64, ptr)\n"
            tail += "declare i64 @fread(ptr, i64, i64, ptr)\n"
            tail += "declare i32 @fclose(ptr)\n"
            tail += "@.fopen_w = private constant [2 x i8] c\"w\\00\"\n"
            tail += "@.fopen_r = private constant [2 x i8] c\"r\\00\"\n"
        }
        // G17: `readLine` pulls in the libc line reader and the stdin stream
        // global (macOS `__stdinp`, the legacy module header's spelling).
        if usesReadLine {
            tail += "declare ptr @fgets(ptr, i32, ptr)\n"
            tail += "@__stdinp = external global ptr\n"
        }
        // G6: env struct type declarations must precede their uses — the
        // creation-point GEPs live in the function bodies, and lli requires
        // a sized base element at the GEP (the legacy emitter also placed
        // these in the header). Closure/adapter defines trail the module.
        var closureTail = ""
        for def in closureDefs {
            closureTail += def
        }
        for def in adapterDefs {
            closureTail += def
        }
        for def in lazyrefWrappers {
            closureTail += def
        }
        var envHeader = ""
        for envDecl in closureEnvTypeDecls {
            envHeader += envDecl + "\n"
        }
        if !closureEnvTypeDecls.isEmpty {
            envHeader += "\n"
        }
        return header + envHeader + tail + "\n" + bodyIR + closureTail
    }

    // MARK: - Functions

    private func emitFunction(_ function: HIRFunction) {
        builder.reset()
        scopes = [[:]]
        slotCounters = [:]
        loopStack = []
        deferScopeBase = 0
        pendingDefers.removeAll()
        terminated = false
        currentIsMain = function.name == "main"
        currentReturnType = function.returnType

        // main is the process entry: emitted with i32 return regardless of
        // the Pini-level void signature (bare returns become `ret i32 0`).
        let returnSpelling = currentIsMain
            ? "i32"
            : (function.returnType?.llvmSpelling ?? "void")
        let params = function.params.map { "\($0.type.llvmSpelling) %\(Self.mangle($0.name))" }
        bodyIR += "define \(returnSpelling) @\(Self.mangle(function.name))(\(params.joined(separator: ", "))) {\n"

        for param in function.params {
            let spelling = param.type.llvmSpelling
            let slot = "%\(Self.mangle(param.name))_slot"
            bodyIR += builder.fmtAlloca(name: slot, type: spelling) + "\n"
            bodyIR += builder.fmtStore(value: "%\(Self.mangle(param.name))", type: spelling, ptr: slot) + "\n"
            scopes[scopes.count - 1][param.name] = slot
        }

        emitBlock(function.body)

        if !terminated {
            bodyIR += builder.fmtBr(labelName: "exit_block") + "\n"
            bodyIR += "exit_block:\n"
            if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else if let returnType = function.returnType {
                bodyIR += " ret \(returnType.llvmSpelling) undef\n"
            } else {
                bodyIR += " ret void\n"
            }
        }
        bodyIR += "}\n\n"
    }

    // MARK: - Statements

    private func emitBlock(_ statements: [HIRStmt]) {
        // G9 defer protocol: defers registered in this block run LIFO at
        // the block's normal end (loop bodies: every iteration). When the
        // block ends in a terminator the defers have already run — the
        // terminator's emitter flushed them right before emitting the jump —
        // or must not run at all (a runtime panic skips defers). A
        // return/break/continue flush pops the frames of every block it
        // unwinds through, so this block's own frame may already be gone;
        // only drop it here when it is still on the stack.
        let frameBase = pendingDefers.count
        pendingDefers.append([])
        for statement in statements {
            if terminated { break }
            emitStatement(statement)
        }
        if terminated {
            // A panic never runs defers — drop the frame. A return/break/
            // continue already flushed copies of the frames it unwound
            // through before its jump, and the block tail is unreachable.
            _ = pendingDefers.removeLast()
        } else {
            flushDefers(downTo: frameBase)
            _ = pendingDefers.removeLast()
        }
    }

    /// Emit one copy of the defer frames from the innermost one down to
    /// `base` (both included), each frame's bodies in LIFO order, at the
    /// current insertion point — WITHOUT popping the frames. A terminator
    /// and a block tail are separate runtime paths over the same statically
    /// emitted code, so each may need its own copy of the same defer bodies:
    /// a `break` inside a loop body flushes the loop's defers before its
    /// jump, while the body block's tail emits the same defers again for
    /// iterations that end normally. Frame ownership stays with the
    /// `emitBlock` that pushed it; a runtime panic is the one exit that
    /// never flushes (its frame is dropped instead).
    private func flushDefers(downTo base: Int) {
        let wasTerminated = terminated
        terminated = false
        for frame in pendingDefers[base...].reversed() {
            for deferredBody in frame.reversed() {
                for statement in deferredBody {
                    if terminated { break }
                    emitStatement(statement)
                }
            }
        }
        terminated = wasTerminated
    }

    /// Deferred statement bodies per open block scope (G9 deferStmt):
    /// scope -> defer (LIFO at scope end) -> wrapped statements.
    private var pendingDefers: [[[HIRStmt]]] = []

    private func emitStatement(_ statement: HIRStmt) {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            let slot = freshSlot(for: name)
            bodyIR += builder.fmtAlloca(name: slot, type: type.llvmSpelling) + "\n"
            scopes[scopes.count - 1][name] = slot
            if let initializer = initializer {
                let value = emitExpr(initializer)
                bodyIR += builder.fmtStore(value: value.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"
                emitRetainIfAliased(initializer, value)
            }

        case .storeVar(let name, let type, let value):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: store to undeclared variable '\(name)' (HIRLowerer guarantees declarations)")
            }
            let lowered = emitExpr(value)
            bodyIR += builder.fmtStore(value: lowered.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"
            emitRetainIfAliased(value, lowered)

        case .ifStmt(let condition, let thenBody, let elseBody):
            emitIf(condition: condition, thenBody: thenBody, elseBody: elseBody)

        case .whileStmt(let condition, let loopBody, let step):
            emitWhile(condition: condition, loopBody: loopBody, step: step)

        case .forInStmt(let pattern, let elementTypes, let kind, let iterable, let body, let step):
            emitForIn(
                pattern: pattern, elementTypes: elementTypes, kind: kind,
                iterable: iterable, body: body, step: step
            )

        case .returnStmt(let value):
            // Defers of every open block of this function run before the
            // return (interpreter: the signal unwinds through each
            // executeBlock's popDeferScope, innermost first).
            flushDefers(downTo: deferScopeBase)
            if let value = value {
                let lowered = emitExpr(value)
                bodyIR += " ret \(lowered.llvmType) \(lowered.ssaName)\n"
            } else if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else {
                bodyIR += " ret void\n"
            }
            terminated = true

        case .exprStmt(let expr):
            _ = emitExpr(expr)

        case .deferStmt(let body):
            pendingDefers[pendingDefers.count - 1].append(body)

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, let type):
            emitTry(operand: operand, errorVar: errorVar, handler: handler, okTarget: okTarget, type: type)

        case .subscriptStore(let container, let index, let value, let elementType):
            emitSubscriptStore(container: container, index: index, value: value, elementType: elementType)

        case .breakStmt(let depth):
            emitBreak(depth: depth)

        case .continueStmt(let depth):
            emitContinue(depth: depth)

        case .panicStmt(let message):
            let rendered = emitStringConstant(message)
            bodyIR += " call void @bk_panic(ptr \(rendered.ssaName))\n"
            bodyIR += " unreachable\n"
            terminated = true

        case .matchStmt(let scrutinee, let cases, let scrutineeType):
            emitMatch(scrutinee: scrutinee, cases: cases, scrutineeType: scrutineeType)

        case .fieldStore(let base, let field, let value, let fieldType):
            let baseValue = emitExpr(base)
            let loweredValue = emitExpr(value)
            emitRetainIfAliased(value, loweredValue)
            let (aggregate, _, fieldIndex) = fieldLayout(of: base, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName, indices: [0, fieldIndex]) + "\n"
            bodyIR += builder.fmtStore(value: loweredValue.ssaName, type: fieldType.llvmSpelling, ptr: fieldPtr) + "\n"

        case .captureMarker:
            // Marker only — captures are materialized by the closure literal
            // emission (env slot pointers), nothing to emit here.
            break
        }
    }

    /// `break`: the depth-th enclosing loop's exit (1 = innermost); without
    /// enough enclosing loops, a runtime panic — the interpreter errors when
    /// a break escapes to the top level (probe-verified), so this is
    /// fail-loud parity, not a silent skip. Leaving the loop also leaves its
    /// body block, so the defer frames down to the loop body's own frame run
    /// before the jump.
    private func emitBreak(depth: Int) {
        if loopStack.count >= depth {
            let frame = loopStack[loopStack.count - depth]
            flushDefers(downTo: frame.deferBase)
            bodyIR += builder.fmtBr(labelName: frame.exit) + "\n"
        } else {
            let message = emitStringConstant("Pini runtime error: break outside loop")
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"
        }
        terminated = true
    }

    /// `continue` (G15): unlabeled jumps to the innermost frame's
    /// continue-target (step entry when present, else the header); a labeled
    /// form (depth > 1) jumps to the depth-th frame's header (interpreter
    /// parity: a matching label resumes that loop). The checker rejects a
    /// continue outside any loop, so the panic here is fail-loud parity.
    /// Ending the iteration leaves the loop's body block, so the defer
    /// frames down to that block's frame run before the jump.
    private func emitContinue(depth: Int) {
        if loopStack.count >= depth {
            let frame = loopStack[loopStack.count - depth]
            flushDefers(downTo: frame.deferBase)
            let target = depth == 1 ? frame.continueTarget : frame.header
            bodyIR += builder.fmtBr(labelName: target) + "\n"
        } else {
            let message = emitStringConstant("Pini runtime error: continue outside loop")
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"
        }
        terminated = true
    }

    /// `match scrutinee: case name(binding): body ...` — dispatch by the
    /// scrutinee's kind: Optional arms compare the `{ i64, T }` tag
    /// (some=0, none=1) with payloads via extractvalue (the aggregate is a
    /// register value); enum arms compare the i32 tag of the tagged union
    /// (`%enum.X*` pointer) with payloads via GEP + load. Unmatched
    /// scrutinee values panic at runtime (interpreter matchNotExhaustive
    /// parity). `break` inside an arm is NOT caught by the match — the
    /// interpreter propagates the signal outward.
    private func emitMatch(scrutinee: HIRExpr, cases: [HIRMatchCase], scrutineeType: HIRType) {
        switch scrutineeType {
        case .optional(let wrapped):
            let aggregate = scrutineeType.llvmSpelling
            emitTaggedMatch(
                scrutinee: scrutinee, cases: cases, aggregate: aggregate, tagType: "i64",
                tagFor: { $0.caseName == "some" ? "0" : "1" },
                payloadSpelling: { _, _ in wrapped.llvmSpelling },
                loadTag: { [self] base in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), 0\n"
                    return IRValue(llvmType: "i64", ssaName: value)
                },
                loadPayload: { [self] base, slot, spelling in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), \(slot + 1)\n"
                    return IRValue(llvmType: spelling, ssaName: value)
                }
            )
        case .enumeration(let enumName):
            guard let aggregate = scrutineeType.nominalAggregateSpelling,
                  let enumDecl = moduleEnums.first(where: { $0.name == enumName }) else {
                fatalError("IREmitter: match on unregistered enum (HIRLowerer guarantees)")
            }
            emitTaggedMatch(
                scrutinee: scrutinee, cases: cases, aggregate: aggregate, tagType: "i32",
                tagFor: { arm in
                    guard let enumCase = enumDecl.cases.first(where: { $0.name == arm.caseName }) else {
                        fatalError("IREmitter: match case '\(arm.caseName)' not in enum decl (HIRLowerer guarantees)")
                    }
                    return String(enumCase.tag)
                },
                payloadSpelling: { (arm, slot) in
                    guard let enumCase = enumDecl.cases.first(where: { $0.name == arm.caseName }) else {
                        fatalError("IREmitter: match case '\(arm.caseName)' not in enum decl (HIRLowerer guarantees)")
                    }
                    return enumCase.payloadTypes[slot].llvmSpelling
                },
                loadTag: { [self] base in
                    let tagPtr = builder.freshTemp()
                    bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: base, indices: [0, 0]) + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: "i32", ptr: tagPtr) + "\n"
                    return IRValue(llvmType: "i32", ssaName: value)
                },
                loadPayload: { [self] base, slot, spelling in
                    let fieldPtr = builder.freshTemp()
                    bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: base, indices: [0, slot + 1]) + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: spelling, ptr: fieldPtr) + "\n"
                    return IRValue(llvmType: spelling, ssaName: value)
                }
            )
        default:
            // Bare scrutinee — neither Optional nor enum (a direct subscript
            // read yields a plain value there). Literal arms (`case 1:`,
            // `case "hi":`) compare by value and need real dispatch; enum-case
            // arms cannot match a bare value, so when no literal arm is
            // present there is nothing to dispatch on and every arm is dead
            // (G11 multidim parity: the match falls through silently — the
            // interpreter reports a non-exhaustive match for enum values
            // only). In that case emit the scrutinee for its side effects and
            // skip the arms; their bodies were lowered only for scope
            // resolution.
            if cases.contains(where: { $0.literal != nil }) {
                emitScalarMatch(scrutinee: scrutinee, cases: cases)
            } else {
                _ = emitExpr(scrutinee)
            }
        }
    }

    /// Bare-scrutinee match carrying literal arms: a source-ordered chain of
    /// value comparisons (the interpreter's `executeMatch` scans arms in
    /// order and the first match wins). Strings compare via strcmp, floats via
    /// ordered fcmp, integers and bools via icmp. Enum-case arms cannot match
    /// a bare value and are skipped; the wildcard arm is the fallback.
    /// Falling off the chain with no wildcard arm is a silent no-op
    /// (interpreter parity: a non-exhaustive match is an error for enum values
    /// only), so the default block simply branches to the end label.
    private func emitScalarMatch(scrutinee: HIRExpr, cases: [HIRMatchCase]) {
        let scrutineeValue = emitExpr(scrutinee)
        let id = builder.freshLabel()
        let endLabel = "match.end.\(id)"
        let defaultLabel = "match.default.\(id)"
        func checkLabel(_ index: Int) -> String { "match.check.\(id).\(index)" }

        let literalArms = cases.enumerated().filter { $0.element.literal != nil }
        let wildcardArm = cases.first { $0.caseName == "_" }

        bodyIR += builder.fmtBr(labelName: checkLabel(literalArms[0].offset)) + "\n"

        for (position, entry) in literalArms.enumerated() {
            let (index, matchCase) = entry
            let armLabel = "match.arm.\(id).\(index)"
            let nextLabel = position + 1 < literalArms.count
                ? checkLabel(literalArms[position + 1].offset)
                : defaultLabel
            bodyIR += "\(checkLabel(index)):\n"
            guard let literal = matchCase.literal,
                  let comparison = emitLiteralComparison(literal, scrutinee: scrutineeValue) else {
                // The operand does not fit the scrutinee's value type — the
                // interpreter never matches such an arm either, so skip it
                // rather than fabricate an operand.
                bodyIR += builder.fmtBr(labelName: nextLabel) + "\n"
                continue
            }
            bodyIR += builder.fmtCondBr(cond: comparison, thenLabelName: armLabel, elseLabelName: nextLabel) + "\n"
            bodyIR += "\(armLabel):\n"
            terminated = false
            scopes.append([:])
            emitBlock(matchCase.body)
            if !terminated {
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
            }
            scopes.removeLast()
        }

        bodyIR += "\(defaultLabel):\n"
        terminated = false
        scopes.append([:])
        if let wildcardArm = wildcardArm {
            emitBlock(wildcardArm.body)
        }
        if !terminated {
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        }
        scopes.removeLast()
        bodyIR += "\(endLabel):\n"
        terminated = false
    }

    /// One literal arm's comparison against the bare scrutinee value. Returns
    /// the i1 temp, or nil when the operand does not fit the scrutinee's value
    /// type (the caller skips such an arm — the interpreter never matches it
    /// either, and inventing an operand would emit invalid IR).
    private func emitLiteralComparison(_ literal: HIRMatchLiteral, scrutinee: IRValue) -> String? {
        switch (scrutinee.llvmType, literal) {
        case ("i8*", .string(let value)):
            usesStrCmp = true
            let literalValue = emitStringConstant(value)
            let ordering = builder.freshTemp()
            bodyIR += " \(ordering) = call i32 @strcmp(ptr \(scrutinee.ssaName), ptr \(literalValue.ssaName))\n"
            let result = builder.freshTemp()
            bodyIR += " \(result) = icmp eq i32 \(ordering), 0\n"
            return result
        case (let spelling, .int(let value))
            where spelling == "i8" || spelling == "i32" || spelling == "i64":
            let result = builder.freshTemp()
            bodyIR += " \(result) = icmp eq \(spelling) \(scrutinee.ssaName), \(value)\n"
            return result
        case ("double", .float(let value)):
            let result = builder.freshTemp()
            bodyIR += " \(result) = fcmp oeq double \(scrutinee.ssaName), \(doubleLiteral(value))\n"
            return result
        case ("i1", .boolean(let value)):
            let result = builder.freshTemp()
            bodyIR += " \(result) = icmp eq i1 \(scrutinee.ssaName), \(value ? "true" : "false")\n"
            return result
        default:
            return nil
        }
    }

    /// Shared tag-dispatch skeleton for Optional and enum scrutinees.
    /// Arms chain by tag comparison; each arm's bindings become scoped
    /// variables; a scrutinee matching no arm reaches the panic block.
    private func emitTaggedMatch(
        scrutinee: HIRExpr,
        cases: [HIRMatchCase],
        aggregate: String,
        tagType: String,
        tagFor: (HIRMatchCase) -> String,
        payloadSpelling: (HIRMatchCase, Int) -> String,
        loadTag: (String) -> IRValue,
        loadPayload: (String, Int, String) -> IRValue
    ) {
        let scrutineeValue = emitExpr(scrutinee)
        let tag = loadTag(scrutineeValue.ssaName)
        let id = builder.freshLabel()
        let endLabel = "match.end.\(id)"
        let panicLabel = "match.fail.\(id)"
        for (caseIndex, matchCase) in cases.enumerated() {
            let armLabel = "match.arm.\(id).\(caseIndex)"
            let fallthroughLabel = caseIndex + 1 < cases.count
                ? "match.next.\(id).\(caseIndex)"
                : panicLabel
            if matchCase.caseName == "_" {
                // Wildcard arm: matches unconditionally (the lowerer enforces
                // it is the last arm, mirroring the interpreter scan order).
                bodyIR += builder.fmtBr(labelName: armLabel) + "\n"
            } else {
                let comparison = builder.freshTemp()
                bodyIR += " \(comparison) = icmp eq \(tagType) \(tag.ssaName), \(tagFor(matchCase))\n"
                bodyIR += builder.fmtCondBr(cond: comparison, thenLabelName: armLabel, elseLabelName: fallthroughLabel) + "\n"
            }

            bodyIR += "\(armLabel):\n"
            scopes.append([:])
            terminated = false
            for (slot, bindingName) in matchCase.bindings.enumerated() {
                guard let bindingName = bindingName else { continue }
                let spelling = payloadSpelling(matchCase, slot)
                let value = loadPayload(scrutineeValue.ssaName, slot, spelling)
                let slotName = freshSlot(for: bindingName)
                bodyIR += builder.fmtAlloca(name: slotName, type: spelling) + "\n"
                bodyIR += builder.fmtStore(value: value.ssaName, type: spelling, ptr: slotName) + "\n"
                scopes[scopes.count - 1][bindingName] = slotName
            }
            emitBlock(matchCase.body)
            if !terminated {
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
            }
            scopes.removeLast()
            if caseIndex + 1 < cases.count {
                bodyIR += "match.next.\(id).\(caseIndex):\n"
                terminated = false
            }
        }
        bodyIR += "\(panicLabel):\n"
        let message = emitStringConstant("Pini runtime error: match value matched no case")
        bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
        bodyIR += " unreachable\n"
        bodyIR += "\(endLabel):\n"
        terminated = false
    }

    /// Subscript store `container[index] = value` (G2 batch 2), mirroring the
    /// legacy emitter's COW contract:
    /// - nested containers (`m[0][1] = v`) take the top-down ensure-unique
    ///   chain first (`bk_handle_ensure_unique` at the root, then
    ///   `bk_array_ensure_unique_at` per level — order is mandatory: the
    ///   runtime requires an exclusive parent before splitting the child);
    /// - plain variable containers keep the legacy shape (bk_array_set's own
    ///   ensure_unique plus the slot write-back below);
    /// - a `.load` value (aliasing an existing array variable) retains one
    ///   share before the box move (ownership contract 3);
    /// - the split handle returned by `bk_array_set` is written back to the
    ///   owning variable slot, or the write would be silently lost.
    private func emitSubscriptStore(container: HIRExpr, index: HIRExpr, value: HIRExpr, elementType: HIRType) {
        // Dictionary store (G5): keys/values boxed by their own types; the
        // returned handle is written back to the owning slot (COW parity).
        if case .dict(let keyType, let valueType) = hirType(of: container) {
            // A nested dict target (`a["k"]["j"] = v`) joins the same top-down
            // chain the array branch below uses. Handing bk_dict_set a bare
            // emitExpr handle would let it write through a shared box and
            // silently mutate every alias — the failure the legacy emitter
            // avoids by splitting here too.
            let containerValue: IRValue
            if case .subscriptGet = container {
                containerValue = emitUniqueContainerHandle(container)
            } else {
                containerValue = emitExpr(container)
            }
            let indexValue = emitExpr(index)
            let loweredValue = emitExpr(value)
            emitRetainIfAliased(value, loweredValue)
            let (keySpelling, keyWidth, keyTag) = arrayElementABI(keyType)
            let (valueSpelling, valueWidth, valueTag) = arrayElementABI(valueType)
            let keyBox = boxValue(indexValue, spelling: keySpelling)
            let valueBox = boxValue(loweredValue, spelling: valueSpelling)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(containerValue.ssaName) to ptr\n"
            let newRaw = builder.freshTemp()
            bodyIR += " \(newRaw) = call ptr @bk_dict_set(ptr \(raw), ptr \(keyBox), i32 \(keyWidth), i32 \(keyTag), ptr \(valueBox), i32 \(valueWidth), i32 \(valueTag))\n"
            if case .load(let name, let slotType) = container, slotType.llvmSpelling == "%bk_dict*" {
                guard let slot = lookupSlot(name) else {
                    fatalError("IREmitter: dict store to undeclared container '\(name)' (HIRLowerer guarantees)")
                }
                let typed = builder.freshTemp()
                bodyIR += " \(typed) = bitcast ptr \(newRaw) to %bk_dict*\n"
                bodyIR += builder.fmtStore(value: typed, type: "%bk_dict*", ptr: slot) + "\n"
            }
            return
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        let containerValue: IRValue
        if case .subscriptGet = container {
            containerValue = emitUniqueContainerHandle(container)
        } else {
            containerValue = emitExpr(container)
        }
        let indexValue = emitExpr(index)
        let loweredValue = emitExpr(value)
        emitRetainIfAliased(value, loweredValue)
        let boxPtr = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
        bodyIR += builder.fmtStore(value: loweredValue.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(containerValue.ssaName) to ptr\n"
        let newRaw = builder.freshTemp()
        bodyIR += " \(newRaw) = call ptr @bk_array_set(ptr \(raw), i32 \(indexValue.ssaName), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
        if case .load(let name, let slotType) = container, slotType.llvmSpelling == "%bk_array*" {
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: subscript store to undeclared container '\(name)' (HIRLowerer guarantees declarations)")
            }
            let typed = builder.freshTemp()
            bodyIR += " \(typed) = bitcast ptr \(newRaw) to %bk_array*\n"
            bodyIR += builder.fmtStore(value: typed, type: "%bk_array*", ptr: slot) + "\n"
        }
    }

    /// Top-down COW split for nested container writes (`m[0][1] = v`).
    /// Returns the exclusive innermost handle. The root variable's split
    /// handle is written back to its slot; intermediate levels are rewritten
    /// in place by `bk_array_ensure_unique_at` / `bk_dict_ensure_unique_at`
    /// (which deliberately do not release the old child handle — see the
    /// runtime's UAF note).
    ///
    /// Handles are typed per level: the array and dict families are distinct
    /// opaque aggregates, and the dict split additionally takes the key boxed
    /// with its width and tag. The legacy emitter dispatches on those same
    /// three pieces, so both chains stay step-for-step equivalent.
    private func emitUniqueContainerHandle(_ container: HIRExpr) -> IRValue {
        switch container {
        case .load(let name, let slotType):
            let handleSpelling = slotType.llvmSpelling
            let value = emitExpr(container)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast \(handleSpelling) \(value.ssaName) to ptr\n"
            let newRaw = builder.freshTemp()
            bodyIR += " \(newRaw) = call ptr @bk_handle_ensure_unique(ptr \(raw))\n"
            let typed = builder.freshTemp()
            bodyIR += " \(typed) = bitcast ptr \(newRaw) to \(handleSpelling)\n"
            if let slot = lookupSlot(name) {
                bodyIR += builder.fmtStore(value: typed, type: handleSpelling, ptr: slot) + "\n"
            }
            return IRValue(llvmType: handleSpelling, ssaName: typed)
        case .subscriptGet(let inner, let index, let resultType):
            let parent = emitUniqueContainerHandle(inner)
            let parentRaw = builder.freshTemp()
            bodyIR += " \(parentRaw) = bitcast \(parent.llvmType) \(parent.ssaName) to ptr\n"
            let childRaw = builder.freshTemp()
            switch parent.llvmType {
            case "%bk_dict*":
                let keyValue = emitExpr(index)
                let (keySpelling, keyWidth, keyTag) = arrayElementABI(hirType(of: index))
                let keyBox = boxValue(keyValue, spelling: keySpelling)
                bodyIR += " \(childRaw) = call ptr @bk_dict_ensure_unique_at(ptr \(parentRaw), ptr \(keyBox), i32 \(keyWidth), i32 \(keyTag))\n"
            default:
                let indexValue = emitExpr(index)
                bodyIR += " \(childRaw) = call ptr @bk_array_ensure_unique_at(ptr \(parentRaw), i32 \(indexValue.ssaName))\n"
            }
            let childSpelling = resultType.llvmSpelling
            let typed = builder.freshTemp()
            bodyIR += " \(typed) = bitcast ptr \(childRaw) to \(childSpelling)\n"
            return IRValue(llvmType: childSpelling, ssaName: typed)
        default:
            return emitExpr(container)
        }
    }

    /// `try operand else errorVar: handler` — the err slot of the Result
    /// aggregate is a type-erased machine word (LR-12); the ok slot carries
    /// the payload type exactly. The error binding's slot is allocated at the
    /// try site and the handler runs as its own block scope; when the handler
    /// does not terminate (statement position / pass), control falls into the
    /// ok label, which stores the payload when this is expression position.
    private func emitTry(operand: HIRExpr, errorVar: String, handler: [HIRStmt], okTarget: String?, type: HIRType) {
        let errSlot = freshSlot(for: errorVar)
        bodyIR += builder.fmtAlloca(name: errSlot, type: "i64") + "\n"
        scopes[scopes.count - 1][errorVar] = errSlot

        let resultValue = emitExpr(operand)
        let aggregate = resultValue.llvmType
        let tag = builder.freshTemp()
        bodyIR += " \(tag) = extractvalue \(aggregate) \(resultValue.ssaName), 0\n"
        let isOk = builder.freshTemp()
        bodyIR += " \(isOk) = icmp eq i64 \(tag), 0\n"
        let id = builder.freshLabel()
        let okLabel = "try.ok.\(id)"
        let errLabel = "try.err.\(id)"
        bodyIR += builder.fmtCondBr(cond: isOk, thenLabelName: okLabel, elseLabelName: errLabel) + "\n"

        bodyIR += "\(errLabel):\n"
        scopes.append([:])
        terminated = false
        let errWord = builder.freshTemp()
        bodyIR += " \(errWord) = extractvalue \(aggregate) \(resultValue.ssaName), 2\n"
        bodyIR += builder.fmtStore(value: errWord, type: "i64", ptr: errSlot) + "\n"
        emitBlock(handler)
        let handlerTerminated = terminated
        if !handlerTerminated {
            bodyIR += builder.fmtBr(labelName: okLabel) + "\n"
        }
        scopes.removeLast()

        bodyIR += "\(okLabel):\n"
        if let okTarget = okTarget {
            guard let okSlot = lookupSlot(okTarget) else {
                fatalError("IREmitter: try ok target '\(okTarget)' undeclared (HIRLowerer guarantees the allocation)")
            }
            guard case .result(let okType) = type else {
                fatalError("IREmitter: tryStmt type is not a Result (HIRLowerer guarantees)")
            }
            terminated = false
            let payload = builder.freshTemp()
            bodyIR += " \(payload) = extractvalue \(aggregate) \(resultValue.ssaName), 1\n"
            bodyIR += builder.fmtStore(value: payload, type: okType.llvmSpelling, ptr: okSlot) + "\n"
        } else {
            terminated = false
        }
    }

    private func emitIf(condition: HIRExpr, thenBody: [HIRStmt], elseBody: [HIRStmt]?) {
        let cond = emitExpr(condition)
        let id = builder.freshLabel()
        let thenLabel = "if.then.\(id)"
        let endLabel = "if.end.\(id)"
        let elseLabel = elseBody != nil ? "if.else.\(id)" : endLabel
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: thenLabel, elseLabelName: elseLabel) + "\n"

        bodyIR += "\(thenLabel):\n"
        scopes.append([:])
        terminated = false
        emitBlock(thenBody)
        let thenTerminated = terminated
        if !thenTerminated {
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        }
        scopes.removeLast()

        var elseTerminated = false
        if let elseBody = elseBody {
            bodyIR += "\(elseLabel):\n"
            scopes.append([:])
            terminated = false
            emitBlock(elseBody)
            elseTerminated = terminated
            if !elseTerminated {
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
            }
            scopes.removeLast()
        }

        // The merge block is skippable only when both branches are covered by
        // an else and both returned. Without an else, the condition's false
        // edge targets the merge label, so it must always be emitted.
        if elseBody != nil && thenTerminated && elseTerminated {
            terminated = true
        } else {
            bodyIR += "\(endLabel):\n"
            terminated = false
        }
    }

    /// `while cond: body [step: block]` (step: G15, ADR-014).
    ///
    /// Layout — the step block sits between body and the back edge, so an
    /// unlabeled `continue` inside the body lands on the **step entry**
    /// (interpreter parity: `shouldRunStep = true` on continue), while a
    /// `continue` inside the step lands on the step's end. `break` targets
    /// the loop exit from either block and skips the step.
    private func emitWhile(condition: HIRExpr, loopBody: [HIRStmt], step: [HIRStmt]?) {
        let id = builder.freshLabel()
        let condLabel = "while.cond.\(id)"
        let bodyLabel = "while.body.\(id)"
        let stepLabel = "while.step.\(id)"
        let stepEndLabel = "while.step.end.\(id)"
        let exitLabel = "while.end.\(id)"

        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        bodyIR += "\(condLabel):\n"
        let cond = emitExpr(condition)
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: bodyLabel, elseLabelName: exitLabel) + "\n"

        bodyIR += "\(bodyLabel):\n"
        let continueTarget = step != nil ? stepLabel : condLabel
        loopStack.append(LoopFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, deferBase: pendingDefers.count))
        scopes.append([:])
        terminated = false
        emitBlock(loopBody)
        loopStack.removeLast()
        if !terminated {
            bodyIR += builder.fmtBr(labelName: step != nil ? stepLabel : condLabel) + "\n"
        }
        scopes.removeLast()

        if let step = step {
            bodyIR += "\(stepLabel):\n"
            // Inside the step, an unlabeled continue goes to its own end
            // (interpreter: continue in the step block → next iteration).
            loopStack.append(LoopFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, deferBase: pendingDefers.count))
            scopes.append([:])
            terminated = false
            emitBlock(step)
            loopStack.removeLast()
            if !terminated {
                bodyIR += builder.fmtBr(labelName: stepEndLabel) + "\n"
            }
            scopes.removeLast()
            bodyIR += "\(stepEndLabel):\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        }

        // A loop's exit is always reachable (zero iterations), so control
        // flow resumes there regardless of body termination.
        bodyIR += "\(exitLabel):\n"
        terminated = false
    }

    /// `for (pattern,) in iterable: body [step: block]` (G15).
    ///
    /// Mirrors the legacy `generateForStatement` shape: the iterable is
    /// evaluated once, its length read via the kind's runtime accessor, and
    /// the loop walks a hidden i32 index slot. Each iteration re-evaluates
    /// the element accessor and re-binds the pattern variables in a fresh
    /// loop scope (the interpreter's per-iteration Environment). Step and
    /// break/continue follow the whileStmt contract.
    private func emitForIn(
        pattern: [String],
        elementTypes: [HIRType],
        kind: HIRForIterableKind,
        iterable: HIRExpr,
        body: [HIRStmt],
        step: [HIRStmt]?
    ) {
        let id = builder.freshLabel()
        let condLabel = "for.cond.\(id)"
        let bodyLabel = "for.body.\(id)"
        let stepLabel = "for.step.\(id)"
        let stepEndLabel = "for.step.end.\(id)"
        let incLabel = "for.inc.\(id)"
        let exitLabel = "for.end.\(id)"

        let iterableValue = emitExpr(iterable)
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(iterableValue.llvmType) \(iterableValue.ssaName) to ptr\n"
        let lenFn: String
        switch kind {
        case .array: lenFn = "bk_array_len"
        case .set: lenFn = "bk_set_len"
        case .dict: lenFn = "bk_dict_len"
        }
        let len = builder.freshTemp()
        bodyIR += " \(len) = call i32 @\(lenFn)(ptr \(raw))\n"

        let indexSlot = freshSlot(for: "for.index")
        bodyIR += builder.fmtAlloca(name: indexSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: indexSlot) + "\n"

        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        bodyIR += "\(condLabel):\n"
        let indexValue = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: indexValue, type: "i32", ptr: indexSlot) + "\n"
        let inBounds = builder.freshTemp()
        bodyIR += " \(inBounds) = icmp slt i32 \(indexValue), \(len)\n"
        bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: exitLabel) + "\n"

        bodyIR += "\(bodyLabel):\n"
        let continueTarget = step != nil ? stepLabel : incLabel
        loopStack.append(LoopFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, deferBase: pendingDefers.count))
        scopes.append([:])
        terminated = false
        // Pattern bindings: a fresh slot per iteration (the loop scope makes
        // the previous iteration's binding unreachable, matching the
        // interpreter's per-iteration Environment).
        let indexForBind = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: indexForBind, type: "i32", ptr: indexSlot) + "\n"
        for (position, name) in pattern.enumerated() {
            guard name != "_" else { continue }
            let elementType = elementTypes[position]
            let accessor: String
            switch kind {
            case .array: accessor = "bk_array_get"
            case .set: accessor = "bk_set_at"
            case .dict: accessor = position == 0 ? "bk_dict_key_at" : "bk_dict_val_at"
            }
            let box = builder.freshTemp()
            bodyIR += " \(box) = call ptr @\(accessor)(ptr \(raw), i32 \(indexForBind))\n"
            let spelling = elementType.llvmSpelling
            let loaded = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: loaded, type: spelling, ptr: box) + "\n"
            let slot = freshSlot(for: name)
            bodyIR += " \(slot) = alloca \(spelling)\n"
            bodyIR += builder.fmtStore(value: loaded, type: spelling, ptr: slot) + "\n"
            scopes[scopes.count - 1][name] = slot
        }
        // The step block shares the loop environment in the interpreter
        // (executeFor runs it with currentEnv = loopEnv), so the pattern
        // variables stay visible there — a bare `v` in `step:` resolves to
        // the body's slot. Hand the same bindings to the step scope.
        let patternBindings = scopes[scopes.count - 1]
        emitBlock(body)
        loopStack.removeLast()
        if !terminated {
            bodyIR += builder.fmtBr(labelName: step != nil ? stepLabel : incLabel) + "\n"
        }
        scopes.removeLast()

        if let step = step {
            bodyIR += "\(stepLabel):\n"
            loopStack.append(LoopFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, deferBase: pendingDefers.count))
            scopes.append(patternBindings)
            terminated = false
            emitBlock(step)
            loopStack.removeLast()
            if !terminated {
                bodyIR += builder.fmtBr(labelName: stepEndLabel) + "\n"
            }
            scopes.removeLast()
            bodyIR += "\(stepEndLabel):\n"
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"
        }

        // Index increment: every back edge (body tail / continue / step tail)
        // funnels through here before re-testing the condition.
        bodyIR += "\(incLabel):\n"
        let current = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: current, type: "i32", ptr: indexSlot) + "\n"
        let next = builder.freshTemp()
        bodyIR += " \(next) = add i32 \(current), 1\n"
        bodyIR += builder.fmtStore(value: next, type: "i32", ptr: indexSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

        bodyIR += "\(exitLabel):\n"
        terminated = false
    }

    // MARK: - Expressions

    private func emitExpr(_ expr: HIRExpr) -> IRValue {
        switch expr {
        case .intConst(let value, let type):
            return IRValue(llvmType: type.llvmSpelling, ssaName: String(value))

        case .floatConst(let value):
            return IRValue(llvmType: "double", ssaName: doubleLiteral(value))

        case .boolConst(let value):
            return IRValue(llvmType: "i1", ssaName: value ? "true" : "false")

        case .stringConst(let value):
            return emitStringConstant(value)

        case .load(let name, let type):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: load of undeclared variable '\(name)' (HIRLowerer guarantees declarations)")
            }
            let temp = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: temp, type: type.llvmSpelling, ptr: slot) + "\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: temp)

        case .binary(let op, let lhs, let rhs, let type):
            return emitBinary(op: op, lhs: lhs, rhs: rhs, type: type)

        case .unary(let op, let operand, let type):
            let lowered = emitExpr(operand)
            let temp = builder.freshTemp()
            switch op {
            case .negate:
                if lowered.llvmType == "double" {
                    bodyIR += " \(temp) = fneg double \(lowered.ssaName)\n"
                } else {
                    bodyIR += " \(temp) = sub \(lowered.llvmType) 0, \(lowered.ssaName)\n"
                }
            case .logicalNot:
                bodyIR += " \(temp) = xor i1 \(lowered.ssaName), 1\n"
            case .abs:
                let neg = builder.freshTemp()
                bodyIR += " \(neg) = sub \(lowered.llvmType) 0, \(lowered.ssaName)\n"
                let cond = builder.freshTemp()
                bodyIR += " \(cond) = icmp slt \(lowered.llvmType) \(lowered.ssaName), 0\n"
                bodyIR += " \(temp) = select i1 \(cond), \(lowered.llvmType) \(neg), \(lowered.llvmType) \(lowered.ssaName)\n"
            }
            return IRValue(llvmType: type.llvmSpelling, ssaName: temp)

        case .call(let function, let arguments, let returnType):
            let args = arguments.map { emitExpr($0) }
            let argList = args.map { "\($0.llvmType) \($0.ssaName)" }.joined(separator: ", ")
            // G14: runtime-shimmed foreign symbols call their bk_ name
            // (the declare pass emits the matching bk_ symbol).
            let symbolName: String
            if function == "cstr" {
                symbolName = "bk_cstr"
            } else {
                symbolName = Self.mangle(function)
            }
            let callee = "@\(symbolName)"
            if let returnType = returnType {
                let temp = builder.freshTemp()
                bodyIR += " \(temp) = call \(returnType.llvmSpelling) \(callee)(\(argList))\n"
                return IRValue(llvmType: returnType.llvmSpelling, ssaName: temp)
            }
            bodyIR += " call void \(callee)(\(argList))\n"
            return IRValue(llvmType: "void", ssaName: "")

        case .printCall(let argument):
            return emitPrint(argument)

        case .closureLiteral(let id, let paramNames, let paramTypes, let returnType, let captures, let body, let type):
            return emitClosureLiteral(
                id: id, paramNames: paramNames, paramTypes: paramTypes,
                returnType: returnType, captures: captures, body: body, type: type
            )

        case .functionValue(let functionName, _):
            return emitFunctionValue(functionName: functionName)

        case .indirectCall(let callee, let arguments, let returnType):
            return emitIndirectCall(callee: callee, arguments: arguments, returnType: returnType)

        case .resultConstruct(let isOk, let payload, let type):
            guard case .result = type else {
                fatalError("IREmitter: resultConstruct type is not a Result (HIRLowerer guarantees)")
            }
            let p = emitExpr(payload)
            let aggregate = type.llvmSpelling
            let withTag = builder.freshTemp()
            bodyIR += " \(withTag) = insertvalue \(aggregate) undef, i64 \(isOk ? 0 : 1), 0\n"
            let filled = builder.freshTemp()
            if isOk {
                bodyIR += " \(filled) = insertvalue \(aggregate) \(withTag), \(p.llvmType) \(p.ssaName), 1\n"
            } else {
                let word = widenToWord(p)
                bodyIR += " \(filled) = insertvalue \(aggregate) \(withTag), i64 \(word.ssaName), 2\n"
            }
            return IRValue(llvmType: aggregate, ssaName: filled)

        case .arrayLiteral(let elements, let type):
            return emitArrayLiteral(elements: elements, type: type)

        case .subscriptGet(let container, let index, let type):
            return emitSubscriptGet(container: container, index: index, type: type)

        case .lenCall(let argument):
            return emitLen(argument)

        case .optionalGet(let container, let index, let type):
            return emitOptionalGet(container: container, index: index, type: type)

        case .optionalConstruct(let isSome, let payload, let type):
            guard case .optional = type else {
                fatalError("IREmitter: optionalConstruct type is not Optional (HIRLowerer guarantees)")
            }
            let aggregate = type.llvmSpelling
            let withTag = builder.freshTemp()
            bodyIR += " \(withTag) = insertvalue \(aggregate) undef, i64 \(isSome ? 0 : 1), 0\n"
            guard isSome, let payload = payload else {
                return IRValue(llvmType: aggregate, ssaName: withTag)
            }
            let p = emitExpr(payload)
            let filled = builder.freshTemp()
            bodyIR += " \(filled) = insertvalue \(aggregate) \(withTag), \(p.llvmType) \(p.ssaName), 1\n"
            return IRValue(llvmType: aggregate, ssaName: filled)

        case .sliceCall(let container, let start, let end, let type):
            return emitSliceCall(container: container, start: start, end: end, type: type)

        case .construct(let type):
            return emitConstruct(type: type)

        case .enumConstruct(let enumName, _, let tag, let payloads, let payloadTypes, let type):
            guard let aggregate = type.nominalAggregateSpelling else {
                fatalError("IREmitter: enumConstruct on non-enum type (HIRLowerer guarantees)")
            }
            let ptr = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: ptr, type: aggregate) + "\n"
            let tagPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: ptr, indices: [0, 0]) + "\n"
            bodyIR += builder.fmtStore(value: String(tag), type: "i32", ptr: tagPtr) + "\n"
            for (index, payload) in payloads.enumerated() {
                let value = emitExpr(payload)
                let fieldPtr = builder.freshTemp()
                bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: ptr, indices: [0, index + 1]) + "\n"
                bodyIR += builder.fmtStore(value: value.ssaName, type: payloadTypes[index].llvmSpelling, ptr: fieldPtr) + "\n"
            }
            return IRValue(llvmType: type.llvmSpelling, ssaName: ptr)

        case .dictLiteral(let entries, let type):
            return emitDictLiteral(entries: entries, type: type)

        case .setLiteral(let elements, let type):
            return emitSetLiteral(elements: elements, type: type)

        case .tupleConstruct(let labels, let elements, let type):
            let aggregate = type.llvmSpelling
            var assembled = "undef"
            for (index, element) in elements.enumerated() {
                let value = emitExpr(element)
                let next = builder.freshTemp()
                bodyIR += " \(next) = insertvalue \(aggregate) \(assembled), \(value.llvmType) \(value.ssaName), \(index)\n"
                assembled = next
            }
            return IRValue(llvmType: aggregate, ssaName: assembled)

        case .tupleIndexGet(let base, let index, let type):
            let baseValue = emitExpr(base)
            let value = builder.freshTemp()
            bodyIR += " \(value) = extractvalue \(baseValue.llvmType) \(baseValue.ssaName), \(index)\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: value)

        case .fieldGet(let base, let field, let type):
            let baseValue = emitExpr(base)
            let (aggregate, _, fieldIndex) = fieldLayout(of: base, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName, indices: [0, fieldIndex]) + "\n"
            let value = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: value, type: type.llvmSpelling, ptr: fieldPtr) + "\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: value)

        case .stringCase(let isUpper, let receiver):
            let receiverValue = emitExpr(receiver)
            return emitStringCase(isUpper: isUpper, source: receiverValue.ssaName)

        case .stringContains(let receiver, let needle):
            let receiverValue = emitExpr(receiver)
            let needleValue = emitExpr(needle)
            let hit = builder.freshTemp()
            bodyIR += " \(hit) = call ptr @strstr(ptr \(receiverValue.ssaName), ptr \(needleValue.ssaName))\n"
            let found = builder.freshTemp()
            bodyIR += " \(found) = icmp ne ptr \(hit), null\n"
            return IRValue(llvmType: "i1", ssaName: found)

        case .stringSubstring(let receiver, let start, let length):
            let receiverValue = emitExpr(receiver)
            let startValue = emitExpr(start)
            let lengthValue = emitExpr(length)
            let sz = builder.freshTemp()
            bodyIR += " \(sz) = sext i32 \(lengthValue.ssaName) to i64\n"
            let sz1 = builder.freshTemp()
            bodyIR += " \(sz1) = add i64 \(sz), 1\n"
            let buf = builder.freshTemp()
            bodyIR += " \(buf) = alloca i8, i64 \(sz1)\n"
            let srcOfs = builder.freshTemp()
            bodyIR += " \(srcOfs) = sext i32 \(startValue.ssaName) to i64\n"
            let src = builder.freshTemp()
            bodyIR += " \(src) = getelementptr i8, ptr \(receiverValue.ssaName), i64 \(srcOfs)\n"
            bodyIR += " call ptr @memcpy(ptr \(buf), ptr \(src), i64 \(sz))\n"
            let nl = builder.freshTemp()
            bodyIR += " \(nl) = getelementptr i8, ptr \(buf), i64 \(sz)\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: nl) + "\n"
            return IRValue(llvmType: "i8*", ssaName: buf)

        case .stringSplit(let receiver, let delim, let type):
            let receiverValue = emitExpr(receiver)
            let delimValue = emitExpr(delim)
            return emitStringSplit(source: receiverValue.ssaName, delim: delimValue.ssaName, type: type)

        case .arrayJoin(let receiver, let separator):
            let receiverValue = emitExpr(receiver)
            let separatorValue = emitExpr(separator)
            return emitArrayJoin(array: receiverValue, sep: separatorValue.ssaName)

        case .stringConcat(let lhs, let rhs):
            let lhsValue = emitExpr(lhs)
            let rhsValue = emitExpr(rhs)
            let llen = builder.freshTemp()
            bodyIR += " \(llen) = call i64 @strlen(ptr \(lhsValue.ssaName))\n"
            let rlen = builder.freshTemp()
            bodyIR += " \(rlen) = call i64 @strlen(ptr \(rhsValue.ssaName))\n"
            let total = builder.freshTemp()
            bodyIR += " \(total) = add i64 \(llen), \(rlen)\n"
            let sz1 = builder.freshTemp()
            bodyIR += " \(sz1) = add i64 \(total), 1\n"
            let buf = builder.freshTemp()
            bodyIR += " \(buf) = call ptr @malloc(i64 \(sz1))\n"
            bodyIR += " call ptr @strcpy(ptr \(buf), ptr \(lhsValue.ssaName))\n"
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(rhsValue.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: buf)

        case .interpString(let parts):
            return emitInterpString(parts: parts)

        case .lazyRefConstruct(let closure, let type):
            return emitLazyRefConstruct(closure: closure, type: type)

        case .lazyRefValue(let handle, let type):
            return emitLazyRefValue(handle: handle, element: type)

        case .pointerLoad(let pointer, let type):
            return emitPointerLoad(pointer: pointer, element: type)

        case .pointerStore(let pointer, let value, let type):
            return emitPointerStore(pointer: pointer, value: value, element: type)

        case .addressOfVar(let name, let type):
            return emitAddressOfVar(name: name, type: type)

        case .printMulti(let arguments):
            return emitPrintMulti(arguments: arguments)

        case .assertCall(let condition, let message):
            return emitAssertCall(condition: condition, message: message)

        case .fileWrite(let path, let content):
            return emitFileWrite(path: path, content: content)

        case .fileRead(let path):
            return emitFileRead(path: path)

        case .readLine:
            return emitReadLine()

        case .isAsciiDigit(let argument):
            return emitIsAsciiDigit(argument)
        }
    }

    /// Bake a path *literal* against the program base (see `programBase`).
    /// Non-literals and paths that the rule exempts come back untouched, so
    /// every caller can route its path argument through this unconditionally.
    private func bakedIOPath(_ path: HIRExpr) -> HIRExpr {
        guard let base = programBase,
              case .stringConst(let value) = path,
              !value.hasPrefix("/"),
              !value.hasPrefix("./"),
              !value.hasPrefix("../") else {
            return path
        }
        return .stringConst(value: base + "/" + value)
    }

    /// `fopen` yields NULL whenever the file cannot be opened, and the legacy
    /// emitter hands that NULL straight to `fread`/`fwrite`, which traps
    /// inside libc with no message at all. Fail loud through the same panic
    /// channel the other runtime guards use, so the failure names the builtin
    /// instead of surfacing as an opaque crash. The path is deliberately not
    /// interpolated: a non-literal argument cannot be folded into a constant
    /// here, and a message that only covers some call shapes would be worse
    /// than one that covers none.
    private func emitFopenNullGuard(handle: String, builtin: String) {
        let failed = builder.freshTemp()
        bodyIR += " \(failed) = icmp eq ptr \(handle), null\n"
        let id = builder.freshLabel()
        let failLabel = "io.fail.\(id)"
        let openLabel = "io.open.\(id)"
        bodyIR += builder.fmtCondBr(cond: failed, thenLabelName: failLabel, elseLabelName: openLabel) + "\n"
        bodyIR += "\(failLabel):\n"
        let message = emitStringConstant("Pini runtime error: \(builtin) could not open the file")
        bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
        bodyIR += " unreachable\n"
        bodyIR += "\(openLabel):\n"
    }

    /// `writeFile(path, content)` (G15): fopen(path, "w") / strlen /
    /// fwrite / fclose. Mirrors the legacy emitter byte for byte — no
    /// trailing newline is appended, matching the interpreter's
    /// `String.write(toFile:)`. Yields the fclose i32 as the value. The one
    /// deliberate divergence is the NULL guard: the legacy emitter has none.
    private func emitFileWrite(path: HIRExpr, content: HIRExpr) -> IRValue {
        usesFileIO = true
        let pathValue = emitExpr(bakedIOPath(path))
        let contentValue = emitExpr(content)
        let mode = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: mode, aggregate: "[2 x i8]", base: "@.fopen_w", indices: [0, 0]) + "\n"
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = call ptr @fopen(ptr \(pathValue.ssaName), ptr \(mode))\n"
        emitFopenNullGuard(handle: handle, builtin: "writeFile")
        let length = builder.freshTemp()
        bodyIR += " \(length) = call i64 @strlen(ptr \(contentValue.ssaName))\n"
        let written = builder.freshTemp()
        bodyIR += " \(written) = call i64 @fwrite(ptr \(contentValue.ssaName), i64 1, i64 \(length), ptr \(handle))\n"
        let closed = builder.freshTemp()
        bodyIR += " \(closed) = call i32 @fclose(ptr \(handle))\n"
        return IRValue(llvmType: "i32", ssaName: closed)
    }

    /// `readFile(path)` (G15): fopen(path, "r") / fread into a fixed
    /// 64 KiB stack buffer / NUL-terminate / fclose. Yields the buffer
    /// pointer as a String. The fixed cap is the legacy emitter's —
    /// LLI's JIT makes fseek/ftell/fstat unreliable — and the IO corpus
    /// stays far below it. The NULL guard is the second divergence from the
    /// legacy emitter, and the one that matters most here: a missing file is
    /// reachable from ordinary source, unlike the write path's.
    private func emitFileRead(path: HIRExpr) -> IRValue {
        usesFileIO = true
        let pathValue = emitExpr(bakedIOPath(path))
        let mode = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: mode, aggregate: "[2 x i8]", base: "@.fopen_r", indices: [0, 0]) + "\n"
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = call ptr @fopen(ptr \(pathValue.ssaName), ptr \(mode))\n"
        emitFopenNullGuard(handle: handle, builtin: "readFile")
        let buffer = freshSlot(for: "file.buffer")
        bodyIR += builder.fmtAlloca(name: buffer, type: "[65536 x i8]") + "\n"
        let base = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: base, aggregate: "[65536 x i8]", base: buffer, indices: [0, 0]) + "\n"
        let read = builder.freshTemp()
        bodyIR += " \(read) = call i64 @fread(ptr \(base), i64 1, i64 65536, ptr \(handle))\n"
        let terminator = builder.freshTemp()
        bodyIR += builder.fmtGEPByteOffset(name: terminator, base: base, offset: read, offsetType: "i64") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: terminator) + "\n"
        let closed = builder.freshTemp()
        bodyIR += " \(closed) = call i32 @fclose(ptr \(handle))\n"
        // "i8*" (not "ptr"): that is the spelling emitScalarPrint treats as a
        // C string; a bare `ptr` falls into the %d default and prints the
        // address.
        return IRValue(llvmType: "i8*", ssaName: base)
    }

    /// `readLine()` (G17): a 256-byte stack buffer filled by `fgets` from the
    /// stdin stream, yielded as a String. Mirrors the legacy emitter
    /// instruction for instruction — including the fact that the newline is
    /// left in place when stdin has one (the interpreter strips it; the
    /// divergence is registered, and this grid preserves the legacy
    /// behaviour rather than changing the flip's observable output).
    private func emitReadLine() -> IRValue {
        usesReadLine = true
        let bufferSize = 256
        let buffer = freshSlot(for: "readline.buffer")
        bodyIR += builder.fmtAlloca(name: buffer, type: "[\(bufferSize) x i8]") + "\n"
        let base = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: base, aggregate: "[\(bufferSize) x i8]", base: buffer, indices: [0, 0]) + "\n"
        let stream = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: stream, type: "ptr", ptr: "@__stdinp") + "\n"
        let line = builder.freshTemp()
        bodyIR += " \(line) = call ptr @fgets(ptr \(base), i32 \(bufferSize), ptr \(stream))\n"
        // "i8*" for the same reason emitFileRead returns it: that is the
        // spelling emitScalarPrint routes to %s.
        return IRValue(llvmType: "i8*", ssaName: line)
    }

    /// `is_ascii_digit(s)` (G17): the first byte of the C string tested
    /// against [0x30, 0x39]. The empty string loads its NUL terminator and is
    /// false without a length check — the same shape the legacy emitter uses,
    /// and the same answer the interpreter's first-grapheme rule gives in the
    /// ASCII domain.
    private func emitIsAsciiDigit(_ argument: HIRExpr) -> IRValue {
        let subject = emitExpr(argument)
        let byte = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: byte, type: "i8", ptr: subject.ssaName) + "\n"
        let lowerBound = builder.freshTemp()
        bodyIR += " \(lowerBound) = icmp uge i8 \(byte), 48\n"
        let upperBound = builder.freshTemp()
        bodyIR += " \(upperBound) = icmp ule i8 \(byte), 57\n"
        let isDigit = builder.freshTemp()
        bodyIR += " \(isDigit) = and i1 \(lowerBound), \(upperBound)\n"
        return IRValue(llvmType: "i1", ssaName: isDigit)
    }

    /// `assert(cond, msg?)`: branch on the condition; the false edge
    /// prints the message (or a default) and calls the noreturn panic.
    /// Passing asserts fall through — a failing assert never appears in a
    /// parity baseline (test blocks are not executed by the harness).
    private func emitAssertCall(condition: HIRExpr, message: HIRExpr?) -> IRValue {
        let cond = emitExpr(condition)
        let passLabel = "assert.pass.\(builder.freshLabel())"
        let failLabel = "assert.fail.\(builder.freshLabel())"
        let endLabel = "assert.end.\(builder.freshLabel())"
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: passLabel, elseLabelName: failLabel) + "\n"
        bodyIR += "\(failLabel):\n"
        let msg = message ?? .stringConst(value: "assert failed")
        let rendered = emitExpr(msg)
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(rendered.ssaName))\n"
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        bodyIR += " call ptr @bk_panic(ptr null)\n"
        bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        bodyIR += "\(passLabel):\n"
        bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        bodyIR += "\(endLabel):\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    // MARK: - G14 FFI pointer primitives

    /// `load(p)`: typed load through the pointer, then widen to the
    /// unified int value the rest of the pipeline prints with (mirrors the
    /// interpreter's decodePointer — U8 sign-extends, U64 loads 8 bytes).
    private func emitPointerLoad(pointer: HIRExpr, element: HIRType) -> IRValue {
        let p = emitExpr(pointer)
        let loaded = builder.freshTemp()
        bodyIR += " \(loaded) = load \(element.llvmSpelling), ptr \(p.ssaName)\n"
        if element.llvmSpelling == "i8" {
            let widened = builder.freshTemp()
            bodyIR += " \(widened) = sext i8 \(loaded) to i64\n"
            return IRValue(llvmType: "i64", ssaName: widened)
        }
        return IRValue(llvmType: element.llvmSpelling, ssaName: loaded)
    }

    /// `store(p, v)`: truncating store for narrow elements (mirrors the
    /// interpreter's encode — Int8(truncatingIfNeeded:)). The value's own
    /// IR type drives the narrowing chain (a declared I32 into a *U8 slot
    /// truncates i32 -> i8); the element type is the ABI authority.
    private func emitPointerStore(pointer: HIRExpr, value: HIRExpr, element: HIRType) -> IRValue {
        let p = emitExpr(pointer)
        var v = emitExpr(value)
        let target = element.llvmSpelling
        if v.llvmType != target {
            if v.llvmType == "i64" {
                if target == "i32" {
                    let narrowed = builder.freshTemp()
                    bodyIR += " \(narrowed) = trunc i64 \(v.ssaName) to i32\n"
                    v = IRValue(llvmType: "i32", ssaName: narrowed)
                } else if target == "i8" {
                    let narrowed = builder.freshTemp()
                    bodyIR += " \(narrowed) = trunc i64 \(v.ssaName) to i8\n"
                    v = IRValue(llvmType: "i8", ssaName: narrowed)
                }
            } else if v.llvmType == "i32" && target == "i8" {
                let narrowed = builder.freshTemp()
                bodyIR += " \(narrowed) = trunc i32 \(v.ssaName) to i8\n"
                v = IRValue(llvmType: "i8", ssaName: narrowed)
            } else {
                fatalError("IREmitter: pointerStore cannot shrink \(v.llvmType) to \(target)")
            }
        }
        bodyIR += " store \(v.llvmType) \(v.ssaName), ptr \(p.ssaName)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// `&x`: the variable's alloca slot address (D-B true pointer
    /// semantics). Opaque ptr typed by the pointee for load/store use.
    private func emitAddressOfVar(name: String, type: HIRType) -> IRValue {
        guard let slot = lookupSlot(name) else {
            fatalError("IREmitter: addressOf of undeclared variable '\(name)' (HIRLowerer guarantees declarations)")
        }
        return IRValue(llvmType: "ptr", ssaName: slot)
    }

    /// `print(a, b, ...)`: per-argument value print separated by single
    /// spaces, one trailing newline (D-A=A1 — mirrors the interpreter's
    /// stringify-join byte stream). No newline after each argument, unlike
    /// the single-argument print path.
    ///
    /// This path renders through the scalar printer, which carries no case
    /// for aggregate or handle spellings: such an argument reaches its
    /// fallback and is handed to `printf` as an integer, so the statement
    /// prints the value's bits where its formatted value belongs — silently
    /// wrong output with no diagnostic. Aggregate arguments therefore trap
    /// at run time instead (`bk_panic` is noreturn), keeping the gap
    /// observable; the formatting that would render them is a later grid.
    /// The single-argument path already gates the same shapes, at lowering
    /// time.
    private func emitPrintMulti(arguments: [HIRExpr]) -> IRValue {
        if arguments.contains(where: { Self.hasNoScalarRendering(hirType(of: $0)) }) {
            let message = emitStringConstant(
                "Pini runtime error: printing an aggregate value is a later grid (value formatting)"
            )
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"
            // Resume on a fresh block so the statement stream keeps a
            // well-formed block structure. Control never reaches it: the
            // panic does not return.
            bodyIR += "print.multi.resume.\(builder.freshLabel()):\n"
            terminated = false
            return IRValue(llvmType: "void", ssaName: "")
        }
        for (index, argument) in arguments.enumerated() {
            if index > 0 {
                let space = emitStringConstant(" ")
                bodyIR += " call i32 (ptr, ...) @printf(ptr \(space.ssaName))\n"
            }
            let printed = emitExpr(argument)
            emitScalarPrint(printed)
        }
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// True for the types the scalar print path cannot render — it falls
    /// back to printing the value's spelling as an integer, so aggregates
    /// (`{ ... }` registers) and runtime handles (`%bk_*`) would come out as
    /// their bits. Scalars, strings and raw pointers keep the existing
    /// scalar spelling.
    private static func hasNoScalarRendering(_ type: HIRType) -> Bool {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .f64, .boolean, .string, .pointer:
            return false
        case .result, .array, .optional, .nominal, .enumeration, .dict,
             .lazyRef, .set, .tuple, .function:
            return true
        }
    }

    // MARK: - G13 batch 1 (LazyRef)

    /// `LazyRef<T>(closure)` (G13 batch 1): extract the initializer's fat
    /// pointer { code, env }, ensure the type-specialized boxing wrapper,
    /// and call `bk_lazyref_create(wrapper, code, env, bytes, tag)`. The
    /// handle is kept as an opaque `%bk_lazyref*` (legacy bitcast mirror).
    private func emitLazyRefConstruct(closure: HIRExpr, type: HIRType) -> IRValue {
        guard case .lazyRef(let element) = type else {
            fatalError("IREmitter: lazyRefConstruct type is not a lazyRef (HIRLowerer guarantees)")
        }
        let (elemSpelling, bytes, tag) = lazyRefElemABI(element)
        usesLazyRef = true
        let closureValue = emitExpr(closure)
        guard closureValue.llvmType == "{ ptr, ptr }" else {
            fatalError("IREmitter: LazyRef initializer is not a closure (HIRLowerer guarantees)")
        }
        let code = builder.freshTemp()
        bodyIR += " \(code) = extractvalue { ptr, ptr } \(closureValue.ssaName), 0\n"
        let env = builder.freshTemp()
        bodyIR += " \(env) = extractvalue { ptr, ptr } \(closureValue.ssaName), 1\n"
        let wrapperName = ensureLazyRefWrapper(element: element, elemSpelling: elemSpelling)
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = call ptr @bk_lazyref_create(ptr @\(wrapperName), ptr \(code), ptr \(env), i32 \(bytes), i32 \(tag))\n"
        let typed = builder.freshTemp()
        bodyIR += " \(typed) = bitcast ptr \(handle) to %bk_lazyref*\n"
        return IRValue(llvmType: "%bk_lazyref*", ssaName: typed)
    }

    /// `handle.value` (G13 batch 1): `bk_lazyref_value(handle)` yields the
    /// cached element box; the element value is loaded out of it.
    private func emitLazyRefValue(handle: HIRExpr, element: HIRType) -> IRValue {
        usesLazyRef = true
        let handleValue = emitExpr(handle)
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(handleValue.llvmType) \(handleValue.ssaName) to ptr\n"
        let box = builder.freshTemp()
        bodyIR += " \(box) = call ptr @bk_lazyref_value(ptr \(raw))\n"
        let spelling = element.llvmSpelling
        let value = builder.freshTemp()
        bodyIR += " \(value) = load \(spelling), ptr \(box)\n"
        return IRValue(llvmType: spelling, ssaName: value)
    }

    /// LazyRef element boxing ABI (bytes/tag): aligned with the legacy
    /// `lazyRefElemInfo` table — string uses the raw-ptr tag (4), NOT the
    /// array-family tag 3 (strings are immutable C bytes with no share
    /// count; boxing them as share-counted handles would corrupt cleanup).
    private func lazyRefElemABI(_ type: HIRType) -> (spelling: String, bytes: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 4)
        default:
            fatalError("IREmitter: no LazyRef element ABI for '\(type)' (HIRLowerer gates element types)")
        }
    }

    /// Buffer (deduplicated) the type-specialized boxing wrapper:
    /// `ptr @__lazyref_wrapper_<T>(ptr code, ptr env, ptr out)` — calls the
    /// initializer code, stores the element into the runtime-provided heap
    /// box, and returns it (uniform ptr ABI sidesteps per-type return
    /// register differences; the runtime owns the box allocation).
    private func ensureLazyRefWrapper(element: HIRType, elemSpelling: String) -> String {
        let suffix: String
        switch element {
        case .i32: suffix = "i32"
        case .f64: suffix = "f64"
        case .boolean: suffix = "i1"
        case .string: suffix = "ptr"
        default: suffix = elemSpelling.replacingOccurrences(of: " ", with: "_")
        }
        guard !lazyrefWrapperNames.contains(suffix) else { return "__lazyref_wrapper_\(suffix)" }
        lazyrefWrapperNames.insert(suffix)
        var def = "define ptr @__lazyref_wrapper_\(suffix)(ptr %code, ptr %env, ptr %out) {\n"
        def += " %val = call \(elemSpelling) %code(ptr %env)\n"
        def += " store \(elemSpelling) %val, ptr %out\n"
        def += " ret ptr %out\n"
        def += "}\n\n"
        lazyrefWrappers.append(def)
        return "__lazyref_wrapper_\(suffix)"
    }

    // MARK: - Nominal types (G3)

    /// Field layout resolution for a nominal base expression: aggregate
    /// spelling, the field's type, and its GEP index (objects offset past
    /// the refcount header at field 0).
    private func fieldLayout(of base: HIRExpr, field: String) -> (aggregate: String, fieldType: HIRType, index: Int) {
        let baseType = hirType(of: base)
        guard case .nominal(let name, let isObject) = baseType else {
            fatalError("IREmitter: field access on non-nominal base (HIRLowerer guarantees)")
        }
        guard let decl = moduleTypes.first(where: { $0.name == name }),
              let index = decl.fields.firstIndex(where: { $0.name == field }) else {
            fatalError("IREmitter: unknown nominal field '\(name).\(field)' (HIRLowerer guarantees)")
        }
        let aggregate = "%\(isObject ? "object" : "struct").\(IRName.mangle(name))"
        return (aggregate, decl.fields[index].type, index + (isObject ? 1 : 0))
    }

    private func emitConstruct(type: HIRType) -> IRValue {
        guard case .nominal(let name, let isObject) = type,
              let aggregate = type.nominalAggregateSpelling,
              let decl = moduleTypes.first(where: { $0.name == name }) else {
            fatalError("IREmitter: construct of unknown nominal type (HIRLowerer guarantees)")
        }
        let ptr = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: ptr, type: aggregate) + "\n"
        let zero = zeroConst(for:)
        if isObject {
            let refcountPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: refcountPtr, aggregate: aggregate, base: ptr, indices: [0, 0]) + "\n"
            bodyIR += builder.fmtStore(value: "1", type: "i32", ptr: refcountPtr) + "\n"
        }
        for (index, field) in decl.fields.enumerated() {
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: ptr, indices: [0, index + (isObject ? 1 : 0)]) + "\n"
            if let defaultValue = field.defaultValue {
                let value = emitExpr(defaultValue)
                bodyIR += builder.fmtStore(value: value.ssaName, type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
            } else {
                bodyIR += builder.fmtStore(value: zeroConst(for: field.type), type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
            }
        }
        return IRValue(llvmType: type.llvmSpelling, ssaName: ptr)
    }

    /// Zero constant per field spelling (legacy zeroConst mirror).
    private func zeroConst(for type: HIRType) -> String {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .boolean: return "0"
        case .f64: return "0.0"
        default: return "null"
        }
    }

    /// `container.slice(start, end)` (G2b). Bound semantics mirror the sunk
    /// stdlib slice: an `optionalConstruct(isSome: false)` bound takes its
    /// default (start → 0, end → len); an integer bound is tail-counted when
    /// negative; both bounds clamp to [0, len]; hi < lo yields the empty
    /// value. Arrays build a new handle with an inline copy loop (nested
    /// handle elements retain one share — the source array still holds its
    /// own); strings copy bytes into a fresh stack buffer with a NUL
    /// terminator (byte semantics — the documented ASCII limitation, same
    /// as the legacy len(string) gap).
    private func emitSliceCall(container: HIRExpr, start: HIRExpr, end: HIRExpr, type: HIRType) -> IRValue {
        let containerValue = emitExpr(container)

        switch type {
        case .array(let elementType):
            let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_array* \(containerValue.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
            let lo = resolveSliceBound(start, count: count, defaultValue: "0")
            let hi = resolveSliceBound(end, count: count, defaultValue: count)
            let length = builder.freshTemp()
            bodyIR += " \(length) = sub i32 \(hi), \(lo)\n"

            let create = builder.freshTemp()
            bodyIR += " \(create) = call ptr @bk_array_create(i32 \(length))\n"
            let handleSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: handleSlot, type: "%bk_array*") + "\n"
            let createHandle = builder.freshTemp()
            bodyIR += " \(createHandle) = bitcast ptr \(create) to %bk_array*\n"
            bodyIR += builder.fmtStore(value: createHandle, type: "%bk_array*", ptr: handleSlot) + "\n"

            let kSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: kSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: kSlot) + "\n"
            let id = builder.freshLabel()
            let condLabel = "slice.cond.\(id)"
            let bodyLabel = "slice.body.\(id)"
            let incLabel = "slice.inc.\(id)"
            let endLabel = "slice.end.\(id)"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
            bodyIR += "\(condLabel):\n"
            let k = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: kSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(k), \(length)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"

            bodyIR += "\(bodyLabel):\n"
            let current = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: current, type: "%bk_array*", ptr: handleSlot) + "\n"
            let currentRaw = builder.freshTemp()
            bodyIR += " \(currentRaw) = bitcast %bk_array* \(current) to ptr\n"
            let srcIndex = builder.freshTemp()
            bodyIR += " \(srcIndex) = add i32 \(lo), \(k)\n"
            let boxPtr = builder.freshTemp()
            bodyIR += " \(boxPtr) = call ptr @bk_array_get(ptr \(raw), i32 \(srcIndex))\n"
            if elementType.llvmSpelling == "%bk_array*" {
                // Nested handle element: the source array still holds its
                // share, so the copy retains one (ownership contract 3).
                let inner = builder.freshTemp()
                bodyIR += builder.fmtLoad(name: inner, type: "%bk_array*", ptr: boxPtr) + "\n"
                let innerRaw = builder.freshTemp()
                bodyIR += " \(innerRaw) = bitcast %bk_array* \(inner) to ptr\n"
                bodyIR += " call void @bk_handle_retain(ptr \(innerRaw))\n"
            }
            let newRaw = builder.freshTemp()
            bodyIR += " \(newRaw) = call ptr @bk_array_set(ptr \(currentRaw), i32 \(k), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
            let newHandle = builder.freshTemp()
            bodyIR += " \(newHandle) = bitcast ptr \(newRaw) to %bk_array*\n"
            bodyIR += builder.fmtStore(value: newHandle, type: "%bk_array*", ptr: handleSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"

            bodyIR += "\(incLabel):\n"
            let kValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: kSlot) + "\n"
            let kNext = builder.freshTemp()
            bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
            bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: kSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            let result = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: result, type: "%bk_array*", ptr: handleSlot) + "\n"
            return IRValue(llvmType: "%bk_array*", ssaName: result)

        case .string:
            // Length: inline byte scan (strlen semantics — ASCII parity with
            // the interpreter's character count holds for the corpus).
            let count = emitStringByteLength(containerValue)
            let lo = resolveSliceBound(start, count: count, defaultValue: "0")
            let hi = resolveSliceBound(end, count: count, defaultValue: count)
            let length = builder.freshTemp()
            bodyIR += " \(length) = sub i32 \(hi), \(lo)\n"
            let bufferBytes = builder.freshTemp()
            bodyIR += " \(bufferBytes) = add i32 \(length), 1\n"
            let buffer = builder.freshTemp()
            bodyIR += " \(buffer) = alloca i8, i32 \(bufferBytes)\n"
            let kSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: kSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: kSlot) + "\n"
            let id = builder.freshLabel()
            let condLabel = "strslice.cond.\(id)"
            let bodyLabel = "strslice.body.\(id)"
            let incLabel = "strslice.inc.\(id)"
            let endLabel = "strslice.end.\(id)"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
            bodyIR += "\(condLabel):\n"
            let k = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: kSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(k), \(length)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"

            bodyIR += "\(bodyLabel):\n"
            let srcIndex = builder.freshTemp()
            bodyIR += " \(srcIndex) = add i32 \(lo), \(k)\n"
            let srcByte = builder.freshTemp()
            bodyIR += " \(srcByte) = getelementptr i8, ptr \(containerValue.ssaName), i32 \(srcIndex)\n"
            let byte = builder.freshTemp()
            bodyIR += " \(byte) = load i8, ptr \(srcByte)\n"
            let dstByte = builder.freshTemp()
            bodyIR += " \(dstByte) = getelementptr i8, ptr \(buffer), i32 \(k)\n"
            bodyIR += builder.fmtStore(value: byte, type: "i8", ptr: dstByte) + "\n"
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"

            bodyIR += "\(incLabel):\n"
            let kValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: kSlot) + "\n"
            let kNext = builder.freshTemp()
            bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
            bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: kSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            let terminatorSlot = builder.freshTemp()
            bodyIR += " \(terminatorSlot) = getelementptr i8, ptr \(buffer), i32 \(length)\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: terminatorSlot) + "\n"
            return IRValue(llvmType: "i8*", ssaName: buffer)

        default:
            fatalError("IREmitter: slice on non-array/string type '\(type)' (HIRLowerer gates)")
        }
    }

    /// One slice bound: `none` (optionalConstruct isSome=false) takes the
    /// default (start → "0", end → the runtime count); an integer is
    /// tail-counted when negative, then clamped into [0, count] — all via
    /// select chains, no branches (sunk-stdlib parity).
    private func resolveSliceBound(_ bound: HIRExpr, count: String, defaultValue: String) -> String {
        if case .optionalConstruct(let isSome, _, _) = bound, !isSome {
            return defaultValue
        }
        let raw = emitExpr(bound)
        let isNegative = builder.freshTemp()
        bodyIR += " \(isNegative) = icmp slt i32 \(raw.ssaName), 0\n"
        let adjusted = builder.freshTemp()
        bodyIR += " \(adjusted) = add i32 \(count), \(raw.ssaName)\n"
        let tailCounted = builder.freshTemp()
        bodyIR += " \(tailCounted) = select i1 \(isNegative), i32 \(adjusted), i32 \(raw.ssaName)\n"
        let belowZero = builder.freshTemp()
        bodyIR += " \(belowZero) = icmp slt i32 \(tailCounted), 0\n"
        let floored = builder.freshTemp()
        bodyIR += " \(floored) = select i1 \(belowZero), i32 0, i32 \(tailCounted)\n"
        let aboveCount = builder.freshTemp()
        bodyIR += " \(aboveCount) = icmp sgt i32 \(floored), \(count)\n"
        let clamped = builder.freshTemp()
        bodyIR += " \(clamped) = select i1 \(aboveCount), i32 \(count), i32 \(floored)\n"
        return clamped
    }

    /// Inline byte-scan length for an `i8*` string value: counts bytes up to the
    /// NUL terminator. Used for slice arithmetic, which indexes bytes — see
    /// `emitStringCharCount` for the value `len` reports.
    private func emitStringByteLength(_ value: IRValue) -> String {
        let counterSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: counterSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: counterSlot) + "\n"
        let id = builder.freshLabel()
        let condLabel = "strlen.cond.\(id)"
        let bodyLabel = "strlen.body.\(id)"
        let incLabel = "strlen.inc.\(id)"
        let endLabel = "strlen.end.\(id)"
        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        bodyIR += "\(condLabel):\n"
        let k = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: counterSlot) + "\n"
        let bytePtr = builder.freshTemp()
        bodyIR += " \(bytePtr) = getelementptr i8, ptr \(value.ssaName), i32 \(k)\n"
        let byte = builder.freshTemp()
        bodyIR += " \(byte) = load i8, ptr \(bytePtr)\n"
        let notEnd = builder.freshTemp()
        bodyIR += " \(notEnd) = icmp ne i8 \(byte), 0\n"
        bodyIR += builder.fmtCondBr(cond: notEnd, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"
        bodyIR += "\(bodyLabel):\n"
        bodyIR += builder.fmtBr(labelName: incLabel) + "\n"
        bodyIR += "\(incLabel):\n"
        let kValue = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: counterSlot) + "\n"
        let kNext = builder.freshTemp()
        bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
        bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: counterSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
        bodyIR += "\(endLabel):\n"
        let result = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: result, type: "i32", ptr: counterSlot) + "\n"
        return result
    }

    /// Character count for an `i8*` string value: the number of Unicode
    /// scalars, obtained by counting every byte that is not a UTF-8
    /// continuation byte (`byte & 0xC0 == 0x80`). This is what `len` reports
    /// on a string, and mirrors the byte-skipping loop the retired emitter
    /// emitted — the interpreter counts grapheme clusters, which is the same
    /// number for CJK and ordinary text; ZWJ and skin-tone sequences are a
    /// known edge.
    private func emitStringCharCount(_ value: IRValue) -> String {
        let countSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: countSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: countSlot) + "\n"
        let cursorSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: cursorSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: cursorSlot) + "\n"
        let id = builder.freshLabel()
        let loopLabel = "strcount.loop.\(id)"
        let bodyLabel = "strcount.body.\(id)"
        let countLabel = "strcount.count.\(id)"
        let incLabel = "strcount.inc.\(id)"
        let endLabel = "strcount.end.\(id)"
        bodyIR += builder.fmtBr(labelName: loopLabel) + "\n"
        bodyIR += "\(loopLabel):\n"
        let cursor = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: cursor, type: "i32", ptr: cursorSlot) + "\n"
        let bytePtr = builder.freshTemp()
        bodyIR += " \(bytePtr) = getelementptr i8, ptr \(value.ssaName), i32 \(cursor)\n"
        let byte = builder.freshTemp()
        bodyIR += " \(byte) = load i8, ptr \(bytePtr)\n"
        let isEnd = builder.freshTemp()
        bodyIR += " \(isEnd) = icmp eq i8 \(byte), 0\n"
        bodyIR += builder.fmtCondBr(cond: isEnd, thenLabelName: endLabel, elseLabelName: bodyLabel) + "\n"
        bodyIR += "\(bodyLabel):\n"
        let leadBits = builder.freshTemp()
        bodyIR += " \(leadBits) = and i8 \(byte), 192\n"
        let isContinuation = builder.freshTemp()
        bodyIR += " \(isContinuation) = icmp eq i8 \(leadBits), 128\n"
        bodyIR += builder.fmtCondBr(cond: isContinuation, thenLabelName: incLabel, elseLabelName: countLabel) + "\n"
        bodyIR += "\(countLabel):\n"
        let current = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: current, type: "i32", ptr: countSlot) + "\n"
        let bumped = builder.freshTemp()
        bodyIR += " \(bumped) = add i32 \(current), 1\n"
        bodyIR += builder.fmtStore(value: bumped, type: "i32", ptr: countSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: incLabel) + "\n"
        bodyIR += "\(incLabel):\n"
        let cursorValue = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: cursorValue, type: "i32", ptr: cursorSlot) + "\n"
        let cursorNext = builder.freshTemp()
        bodyIR += " \(cursorNext) = add i32 \(cursorValue), 1\n"
        bodyIR += builder.fmtStore(value: cursorNext, type: "i32", ptr: cursorSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: loopLabel) + "\n"
        bodyIR += "\(endLabel):\n"
        let total = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: total, type: "i32", ptr: countSlot) + "\n"
        return total
    }

    /// `arr.get(i)` — tolerant read: tail-counted negative index, then a
    /// bounds check; some(payload) or none. Arrays go through the runtime
    /// handle; strings scan bytes inline (ASCII parity with the interpreter's
    /// character count) and wrap the byte in a fresh 2-byte buffer. The
    /// aggregate flows through a stack slot (alloca + store + load) so the
    /// branch join needs no phi node.
    private func emitOptionalGet(container: HIRExpr, index: HIRExpr, type: HIRType) -> IRValue {
        guard case .optional(let wrapped) = type else {
            fatalError("IREmitter: optionalGet type is not Optional (HIRLowerer guarantees)")
        }
        let aggregate = type.llvmSpelling
        let containerValue = emitExpr(container)
        let indexValue = emitExpr(index)

        let isStringReceiver = hirType(of: container) == .string
        let count: String
        var arrayRaw: String? = nil
        if isStringReceiver {
            count = emitStringByteLength(containerValue)
        } else {
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_array* \(containerValue.ssaName) to ptr\n"
            arrayRaw = raw
            count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
        }
        let effective = tailCountIndex(index: indexValue.ssaName, count: count)

        let slot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: slot, type: aggregate) + "\n"
        let id = builder.freshLabel()
        let someLabel = "get.some.\(id)"
        let noneLabel = "get.none.\(id)"
        let endLabel = "get.end.\(id)"
        let inBounds = builder.freshTemp()
        bodyIR += " \(inBounds) = icmp slt i32 \(effective), \(count)\n"
        let notNegative = builder.freshTemp()
        bodyIR += " \(notNegative) = icmp sge i32 \(effective), 0\n"
        let ok = builder.freshTemp()
        bodyIR += " \(ok) = and i1 \(inBounds), \(notNegative)\n"
        bodyIR += builder.fmtCondBr(cond: ok, thenLabelName: someLabel, elseLabelName: noneLabel) + "\n"

        bodyIR += "\(someLabel):\n"
        let value: String
        if isStringReceiver {
            let bytePtr = builder.freshTemp()
            bodyIR += " \(bytePtr) = getelementptr i8, ptr \(containerValue.ssaName), i32 \(effective)\n"
            let byte = builder.freshTemp()
            bodyIR += " \(byte) = load i8, ptr \(bytePtr)\n"
            let buffer = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: buffer, type: "[2 x i8]") + "\n"
            let byteSlot = builder.freshTemp()
            bodyIR += " \(byteSlot) = getelementptr [2 x i8], ptr \(buffer), i32 0, i32 0\n"
            bodyIR += builder.fmtStore(value: byte, type: "i8", ptr: byteSlot) + "\n"
            let zeroSlot = builder.freshTemp()
            bodyIR += " \(zeroSlot) = getelementptr [2 x i8], ptr \(buffer), i32 0, i32 1\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: zeroSlot) + "\n"
            value = buffer
        } else {
            let boxPtr = builder.freshTemp()
            bodyIR += " \(boxPtr) = call ptr @bk_array_get(ptr \(arrayRaw!), i32 \(effective))\n"
            let loaded = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: loaded, type: wrapped.llvmSpelling, ptr: boxPtr) + "\n"
            value = loaded
        }
        let some0 = builder.freshTemp()
        bodyIR += " \(some0) = insertvalue \(aggregate) undef, i64 0, 0\n"
        let some1 = builder.freshTemp()
        bodyIR += " \(some1) = insertvalue \(aggregate) \(some0), \(wrapped.llvmSpelling) \(value), 1\n"
        bodyIR += builder.fmtStore(value: some1, type: aggregate, ptr: slot) + "\n"
        bodyIR += builder.fmtBr(labelName: endLabel) + "\n"

        bodyIR += "\(noneLabel):\n"
        let none0 = builder.freshTemp()
        bodyIR += " \(none0) = insertvalue \(aggregate) undef, i64 1, 0\n"
        bodyIR += builder.fmtStore(value: none0, type: aggregate, ptr: slot) + "\n"
        bodyIR += builder.fmtBr(labelName: endLabel) + "\n"

        bodyIR += "\(endLabel):\n"
        let result = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: result, type: aggregate, ptr: slot) + "\n"
        return IRValue(llvmType: aggregate, ssaName: result)
    }

    /// Tail-counted index resolution (G48): `i < 0 ? count + i : i` as a
    /// select — the caller applies its own bounds policy afterwards.
    private func tailCountIndex(index: String, count: String) -> String {
        let isNegative = builder.freshTemp()
        bodyIR += " \(isNegative) = icmp slt i32 \(index), 0\n"
        let adjusted = builder.freshTemp()
        bodyIR += " \(adjusted) = add i32 \(count), \(index)\n"
        let effective = builder.freshTemp()
        bodyIR += " \(effective) = select i1 \(isNegative), i32 \(adjusted), i32 \(index)\n"
        return effective
    }

    // MARK: - Array family (G2)

    /// Element boxing ABI against the runtime `_BkTag` values: the tag lets
    /// the runtime distinguish raw scalars from nested container handles
    /// (release / COW semantics). Strings use the raw ptr tag (3), NOT the
    /// handle tag: they are immutable C strings with no share count — the
    /// handle tag makes dict cowCopy retain read-only constant bytes (a
    /// legacy bug that surfaces only on dict alias splits).
    private func arrayElementABI(_ type: HIRType) -> (spelling: String, width: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 3)
        case .array: return ("%bk_array*", 8, 4)
        case .dict: return ("%bk_dict*", 8, 4)
        case .set: return ("%bk_set*", 8, 4)
        default:
            fatalError("IREmitter: no array element ABI for '\(type)' (HIRLowerer gates element types)")
        }
    }

    /// Alias-point retain (ownership contract 3). Two node shapes mean the
    /// source still holds its share, so the copy retains one:
    /// - `.load` of a container-typed variable (variable alias);
    /// - `.subscriptGet` / nested read whose RESULT is a container handle —
    ///   the parent container's slot still references the inner handle, so
    ///   `var row = g[0]` shares with `g` and the next write must split
    ///   (the legacy emitter skipped this retain, which is one reason it
    ///   could not pass cow.pini). True temporaries (literals, scalars,
    ///   fresh constructions) transfer ownership and must NOT retain.
    private func emitRetainIfAliased(_ valueNode: HIRExpr, _ value: IRValue) {
        let containerSpellings = ["%bk_array*", "%bk_dict*", "%bk_set*"]
        guard containerSpellings.contains(value.llvmType) else { return }
        let aliased: Bool
        switch valueNode {
        case .load:
            aliased = true
        case .subscriptGet:
            aliased = true
        default:
            aliased = false
        }
        guard aliased else { return }
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr\n"
        bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
    }

    private func emitArrayLiteral(elements: [HIRExpr], type: HIRType) -> IRValue {
        guard case .array(let elementType) = type else {
            fatalError("IREmitter: arrayLiteral type is not an array (HIRLowerer guarantees)")
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        let createTemp = builder.freshTemp()
        bodyIR += " \(createTemp) = call ptr @bk_array_create(i32 \(elements.count))\n"
        // The construction handle is always unique (create starts at shares==1),
        // but the set calls are threaded anyway so construction and write-back
        // share one shape (legacy emitter contract).
        var curRaw = createTemp
        for (index, element) in elements.enumerated() {
            let value = emitExpr(element)
            let boxPtr = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
            bodyIR += builder.fmtStore(value: value.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
            emitRetainIfAliased(element, value)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_array_set(ptr \(curRaw), i32 \(index), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_array*\n"
        return IRValue(llvmType: "%bk_array*", ssaName: handle)
    }

    private func emitSubscriptGet(container: HIRExpr, index: HIRExpr, type: HIRType) -> IRValue {
        let containerValue = emitExpr(container)
        let indexValue = emitExpr(index)

        // Dictionary read (G5): the key is boxed by its own type; a missing
        // key panics inside bk_dict_get (G48 three-channel alignment).
        if case .dict(let keyType, let valueType) = hirType(of: container) {
            let (keySpelling, keyWidth, keyTag) = arrayElementABI(keyType)
            let keyBox = boxValue(indexValue, spelling: keySpelling)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(containerValue.ssaName) to ptr\n"
            let valueBox = builder.freshTemp()
            bodyIR += " \(valueBox) = call ptr @bk_dict_get(ptr \(raw), ptr \(keyBox), i32 \(keyWidth), i32 \(keyTag))\n"
            let value = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: value, type: valueType.llvmSpelling, ptr: valueBox) + "\n"
            return IRValue(llvmType: valueType.llvmSpelling, ssaName: value)
        }

        if hirType(of: container) == .string {
            // String subscript: tail-counted index, inline strlen, OOB panics
            // (safe-assert channel, E5-005 parity); returns a 1-char string.
            let count = emitStringByteLength(containerValue)
            let effective = tailCountIndex(index: indexValue.ssaName, count: count)
            let id = builder.freshLabel()
            let okLabel = "strsub.ok.\(id)"
            let failLabel = "strsub.fail.\(id)"
            let endLabel = "strsub.end.\(id)"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(effective), \(count)\n"
            let notNegative = builder.freshTemp()
            bodyIR += " \(notNegative) = icmp sge i32 \(effective), 0\n"
            let ok = builder.freshTemp()
            bodyIR += " \(ok) = and i1 \(inBounds), \(notNegative)\n"
            bodyIR += builder.fmtCondBr(cond: ok, thenLabelName: okLabel, elseLabelName: failLabel) + "\n"

            bodyIR += "\(okLabel):\n"
            let bytePtr = builder.freshTemp()
            bodyIR += " \(bytePtr) = getelementptr i8, ptr \(containerValue.ssaName), i32 \(effective)\n"
            let byte = builder.freshTemp()
            bodyIR += " \(byte) = load i8, ptr \(bytePtr)\n"
            let buffer = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: buffer, type: "[2 x i8]") + "\n"
            let byteSlot = builder.freshTemp()
            bodyIR += " \(byteSlot) = getelementptr [2 x i8], ptr \(buffer), i32 0, i32 0\n"
            bodyIR += builder.fmtStore(value: byte, type: "i8", ptr: byteSlot) + "\n"
            let zeroSlot = builder.freshTemp()
            bodyIR += " \(zeroSlot) = getelementptr [2 x i8], ptr \(buffer), i32 0, i32 1\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: zeroSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"

            bodyIR += "\(failLabel):\n"
            let message = emitStringConstant("Pini runtime error: string index out of range")
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"

            bodyIR += "\(endLabel):\n"
            return IRValue(llvmType: "i8*", ssaName: buffer)
        }

        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(containerValue.ssaName) to ptr\n"
        let count = builder.freshTemp()
        bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
        // Negative indices tail-count (G48); out-of-range still panics inside
        // bk_array_get — the safe-assert channel, matching E5-005.
        let effective = tailCountIndex(index: indexValue.ssaName, count: count)
        let boxPtr = builder.freshTemp()
        bodyIR += " \(boxPtr) = call ptr @bk_array_get(ptr \(raw), i32 \(effective))\n"
        let value = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: value, type: type.llvmSpelling, ptr: boxPtr) + "\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: value)
    }

    private func emitLen(_ argument: HIRExpr) -> IRValue {
        let value = emitExpr(argument)
        switch hirType(of: argument) {
        case .dict:
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_dict_len(ptr \(raw))\n"
            return IRValue(llvmType: "i32", ssaName: count)
        case .set:
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_set* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_set_len(ptr \(raw))\n"
            return IRValue(llvmType: "i32", ssaName: count)
        case .string:
            return IRValue(llvmType: "i32", ssaName: emitStringCharCount(value))
        default:
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_array* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
            return IRValue(llvmType: "i32", ssaName: count)
        }
    }

    /// Box a scalar/handle value into a runtime box (alloca + store), for
    /// dict keys/values and set elements (C ABI passes boxes by pointer).
    private func boxValue(_ value: IRValue, spelling: String) -> String {
        let boxPtr = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: boxPtr, type: spelling) + "\n"
        bodyIR += builder.fmtStore(value: value.ssaName, type: spelling, ptr: boxPtr) + "\n"
        return boxPtr
    }

    private func emitDictLiteral(entries: [HIRDictEntry], type: HIRType) -> IRValue {
        guard case .dict(let keyType, let valueType) = type else {
            fatalError("IREmitter: dictLiteral type is not a dict (HIRLowerer guarantees)")
        }
        let (keySpelling, keyWidth, keyTag) = arrayElementABI(keyType)
        let (valueSpelling, valueWidth, valueTag) = arrayElementABI(valueType)
        let create = builder.freshTemp()
        bodyIR += " \(create) = call ptr @bk_dict_create()\n"
        var curRaw = create
        for entry in entries {
            let keyNode = entry.key
            let valueNode = entry.value
            let keyValue = emitExpr(keyNode)
            let keyBox = boxValue(keyValue, spelling: keySpelling)
            emitRetainIfAliased(keyNode, keyValue)
            let dictValue = IRValue(llvmType: "%bk_dict*", ssaName: curRaw)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(dictValue.ssaName) to ptr\n"
            let value = emitExpr(valueNode)
            let valueBox = boxValue(value, spelling: valueSpelling)
            emitRetainIfAliased(valueNode, value)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_dict_set(ptr \(raw), ptr \(keyBox), i32 \(keyWidth), i32 \(keyTag), ptr \(valueBox), i32 \(valueWidth), i32 \(valueTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_dict*\n"
        return IRValue(llvmType: "%bk_dict*", ssaName: handle)
    }

    private func emitSetLiteral(elements: [HIRExpr], type: HIRType) -> IRValue {
        guard case .set(let elementType) = type else {
            fatalError("IREmitter: setLiteral type is not a set (HIRLowerer guarantees)")
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        let create = builder.freshTemp()
        bodyIR += " \(create) = call ptr @bk_set_create()\n"
        var curRaw = create
        for element in elements {
            let value = emitExpr(element)
            let box = boxValue(value, spelling: elemSpelling)
            emitRetainIfAliased(element, value)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_set_add(ptr \(curRaw), ptr \(box), i32 \(width), i32 \(elemTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_set*\n"
        return IRValue(llvmType: "%bk_set*", ssaName: handle)
    }

    /// Widen any scalar payload to the type-erased error word (i64): sign /
    /// zero extension, pointer-to-int, or bitcast for doubles.
    private func widenToWord(_ value: IRValue) -> IRValue {
        switch value.llvmType {
        case "i64":
            return value
        case "i32":
            let t = builder.freshTemp()
            bodyIR += " \(t) = sext i32 \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "i1":
            let t = builder.freshTemp()
            bodyIR += " \(t) = zext i1 \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "i8*":
            let t = builder.freshTemp()
            bodyIR += " \(t) = ptrtoint ptr \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "double":
            let t = builder.freshTemp()
            bodyIR += " \(t) = bitcast double \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        default:
            fatalError("IREmitter: no word widening for '\(value.llvmType)' (HIRLowerer gates non-scalar payloads)")
        }
    }

    private func emitBinary(op: HIRBinaryOp, lhs: HIRExpr, rhs: HIRExpr, type: HIRType) -> IRValue {
        let lhsValue = emitExpr(lhs)
        let rhsValue = emitExpr(rhs)
        let temp = builder.freshTemp()

        if op.isComparison {
            let predicate = comparePredicate(op: op, operandType: lhsValue.llvmType, temp: temp,
                                             lhs: lhsValue, rhs: rhsValue)
            bodyIR += " \(temp) = \(predicate)\n"
            return IRValue(llvmType: "i1", ssaName: temp)
        }

        // min/max intrinsics (G9): I32 select forms.
        if op == .minOf || op == .maxOf {
            let cond = builder.freshTemp()
            bodyIR += " \(cond) = icmp \(op == .minOf ? "slt" : "sgt") i32 \(lhsValue.ssaName), \(rhsValue.ssaName)\n"
            let sel = builder.freshTemp()
            bodyIR += " \(sel) = select i1 \(cond), i32 \(lhsValue.ssaName), i32 \(rhsValue.ssaName)\n"
            return IRValue(llvmType: "i32", ssaName: sel)
        }

        let instruction: String
        if lhsValue.llvmType == "double" {
            switch op {
            case .add: instruction = "fadd"
            case .subtract: instruction = "fsub"
            case .multiply: instruction = "fmul"
            case .divide: instruction = "fdiv"
            case .modulo: instruction = "frem"
            default: instruction = "add"
            }
        } else {
            switch op {
            case .add: instruction = "add"
            case .subtract: instruction = "sub"
            case .multiply: instruction = "mul"
            case .divide: instruction = "sdiv"
            case .modulo: instruction = "srem"
            // Bitwise family (G15): LLVM integer instructions, 1:1 with the
            // interpreter's int×int eval table (bitwiseAnd/Or/Xor/leftShift/
            // rightShift). Shifts are arithmetic (ashr) matching Swift's `>>`
            // on signed ints; `shl`/`shr` keep the operand type.
            case .bitwiseAnd: instruction = "and"
            case .bitwiseOr: instruction = "or"
            case .bitwiseXor: instruction = "xor"
            case .leftShift: instruction = "shl"
            case .rightShift: instruction = "ashr"
            default: instruction = "add"
            }
        }
        bodyIR += " \(temp) = \(instruction) \(lhsValue.llvmType) \(lhsValue.ssaName), \(rhsValue.ssaName)\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: temp)
    }

    /// Comparison line body for the operand kind. Strings compare via strcmp
    /// against zero; floats use ordered fcmp; integers/bools use icmp.
    private func comparePredicate(op: HIRBinaryOp, operandType: String, temp: String,
                                  lhs: IRValue, rhs: IRValue) -> String {
        if operandType == "i8*" {
            usesStrCmp = true
            let cmpTemp = builder.freshTemp()
            bodyIR += " \(cmpTemp) = call i32 @strcmp(ptr \(lhs.ssaName), ptr \(rhs.ssaName))\n"
            let intPredicate: String
            switch op {
            case .equal: intPredicate = "eq"
            case .notEqual: intPredicate = "ne"
            case .lessThan: intPredicate = "slt"
            case .lessThanOrEqual: intPredicate = "sle"
            case .greaterThan: intPredicate = "sgt"
            case .greaterThanOrEqual: intPredicate = "sge"
            default: intPredicate = "eq"
            }
            return "icmp \(intPredicate) i32 \(cmpTemp), 0"
        }
        let predicate: String
        if operandType == "double" {
            switch op {
            case .equal: predicate = "oeq"
            case .notEqual: predicate = "one"
            case .lessThan: predicate = "olt"
            case .lessThanOrEqual: predicate = "ole"
            case .greaterThan: predicate = "ogt"
            case .greaterThanOrEqual: predicate = "oge"
            default: predicate = "oeq"
            }
            return "fcmp \(predicate) \(operandType) \(lhs.ssaName), \(rhs.ssaName)"
        }
        switch op {
        case .equal: predicate = "eq"
        case .notEqual: predicate = "ne"
        case .lessThan: predicate = "slt"
        case .lessThanOrEqual: predicate = "sle"
        case .greaterThan: predicate = "sgt"
        case .greaterThanOrEqual: predicate = "sge"
        default: predicate = "eq"
        }
        return "icmp \(predicate) \(operandType) \(lhs.ssaName), \(rhs.ssaName)"
    }

    /// Intrinsic print: value + newline (interpreter print semantics).
    /// Aggregates (arrays / optionals) print recursively with the
    /// interpreter's rendering: `[e1, e2]` with raw string elements,
    /// `some(payload)` / `none`. F64 goes through the runtime's
    /// bk_double_to_string (shortest round-trip, spec "value display
    /// semantics" note, LR-8); the malloc'd C string is freed right after
    /// printf consumes it.
    private func emitPrint(_ argument: HIRExpr) -> IRValue {
        let type = hirType(of: argument)
        let value = emitExpr(argument)
        emitValuePrint(value: value, type: type)
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// Resolved HIR type of a lowered expression node (every case carries
    /// its type — the typed-tree contract).
    private func hirType(of expr: HIRExpr) -> HIRType {
        switch expr {
        case .intConst(_, let type): return type
        case .floatConst: return .f64
        case .boolConst: return .boolean
        case .stringConst: return .string
        case .load(_, let type): return type
        case .binary(_, _, _, let type): return type
        case .unary(_, _, let type): return type
        case .call(_, _, let returnType): return returnType ?? .i32
        case .printCall: return .i32
        case .resultConstruct(_, _, let type): return type
        case .arrayLiteral(_, let type): return type
        case .subscriptGet(_, _, let type): return type
        case .lenCall: return .i32
        case .optionalGet(_, _, let type): return type
        case .optionalConstruct(_, _, let type): return type
        case .sliceCall(_, _, _, let type): return type
        case .construct(let type): return type
        case .fieldGet(_, _, let type): return type
        case .enumConstruct(_, _, _, _, _, let type): return type
        case .dictLiteral(_, let type): return type
        case .setLiteral(_, let type): return type
        case .tupleConstruct(_, _, let type): return type
        case .tupleIndexGet(_, _, let type): return type
        case .stringCase: return .string
        case .stringContains: return .boolean
        case .stringSubstring: return .string
        case .stringSplit(_, _, let type): return type
        case .arrayJoin: return .string
        case .stringConcat: return .string
        case .interpString: return .string
        case .closureLiteral(_, _, _, _, _, _, let type): return type
        case .functionValue(_, let type): return type
        case .indirectCall(_, _, let returnType): return returnType ?? .i32
        case .lazyRefConstruct(_, let type): return type
        case .lazyRefValue(_, let type): return type
        case .pointerLoad(_, let type): return type
        case .pointerStore: return .i32
        case .addressOfVar(_, let type): return .pointer(element: type)
        case .printMulti: return .i32
        case .assertCall: return .i32
        case .fileWrite: return .i32
        case .fileRead: return .string
        case .readLine: return .string
        case .isAsciiDigit: return .boolean
        }
    }

    /// Print one scalar value by its IR spelling (no newline).
    private func emitScalarPrint(_ value: IRValue) {
        switch value.llvmType {
        case "i1":
            let sel = builder.freshTemp()
            bodyIR += " \(sel) = select i1 \(value.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(sel))\n"
        case "i8":
            // Narrow integers widen to i32 for %d — varargs demand it, and
            // the interpreter models every integer as one signed value (the
            // same sign-extending read emitPointerLoad uses for U8).
            let extended = builder.freshTemp()
            bodyIR += " \(extended) = sext i8 \(value.ssaName) to i32\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, i32 \(extended))\n"
        case "i64":
            // Narrow to i32 for %d; `sext i64 -> i32` is an invalid cast (the
            // legacy emitter has this same bug — registered separately).
            let narrow = builder.freshTemp()
            bodyIR += " \(narrow) = trunc i64 \(value.ssaName) to i32\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, i32 \(narrow))\n"
        case "double":
            let rendered = builder.freshTemp()
            bodyIR += " \(rendered) = call ptr @bk_double_to_string(double \(value.ssaName))\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(rendered))\n"
            bodyIR += " call ptr @free(ptr \(rendered))\n"
        case "i8*":
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(value.ssaName))\n"
        default:
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, \(value.llvmType) \(value.ssaName))\n"
        }
    }

    /// Print a value of any slice type (no newline). Arrays iterate the
    /// runtime handle (bk_array_len/get loop, induction via a stack slot —
    /// no phi); optionals branch on the tag. Literal formatting pieces come
    /// from emitStringConstant (deduped module constants).
    private func emitValuePrint(value: IRValue, type: HIRType) {
        switch type {
        case .array(let elementType):
            let open = emitStringConstant("[")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_array* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
            let kSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: kSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: kSlot) + "\n"
            let id = builder.freshLabel()
            let condLabel = "fmt.cond.\(id)"
            let bodyLabel = "fmt.body.\(id)"
            let sepLabel = "fmt.sep.\(id)"
            let elemLabel = "fmt.elem.\(id)"
            let incLabel = "fmt.inc.\(id)"
            let endLabel = "fmt.end.\(id)"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
            bodyIR += "\(condLabel):\n"
            let k = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: kSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(k), \(count)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"

            bodyIR += "\(bodyLabel):\n"
            let isFirst = builder.freshTemp()
            bodyIR += " \(isFirst) = icmp eq i32 \(k), 0\n"
            bodyIR += builder.fmtCondBr(cond: isFirst, thenLabelName: elemLabel, elseLabelName: sepLabel) + "\n"

            bodyIR += "\(sepLabel):\n"
            let separator = emitStringConstant(", ")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: elemLabel) + "\n"

            bodyIR += "\(elemLabel):\n"
            let boxPtr = builder.freshTemp()
            bodyIR += " \(boxPtr) = call ptr @bk_array_get(ptr \(raw), i32 \(k))\n"
            let element = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: element, type: elementType.llvmSpelling, ptr: boxPtr) + "\n"
            emitValuePrint(
                value: IRValue(llvmType: elementType.llvmSpelling, ssaName: element),
                type: elementType
            )
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"

            bodyIR += "\(incLabel):\n"
            let kValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: kSlot) + "\n"
            let kNext = builder.freshTemp()
            bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
            bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: kSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            let close = emitStringConstant("]")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(close.ssaName))\n"

        case .optional(let wrapped):
            let aggregate = type.llvmSpelling
            let tag = builder.freshTemp()
            bodyIR += " \(tag) = extractvalue \(aggregate) \(value.ssaName), 0\n"
            let isSome = builder.freshTemp()
            bodyIR += " \(isSome) = icmp eq i64 \(tag), 0\n"
            let id = builder.freshLabel()
            let someLabel = "fmt.some.\(id)"
            let noneLabel = "fmt.none.\(id)"
            let endLabel = "fmt.opt.end.\(id)"
            bodyIR += builder.fmtCondBr(cond: isSome, thenLabelName: someLabel, elseLabelName: noneLabel) + "\n"

            bodyIR += "\(someLabel):\n"
            let someText = emitStringConstant("some(")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(someText.ssaName))\n"
            let payload = builder.freshTemp()
            bodyIR += " \(payload) = extractvalue \(aggregate) \(value.ssaName), 1\n"
            emitValuePrint(
                value: IRValue(llvmType: wrapped.llvmSpelling, ssaName: payload),
                type: wrapped
            )
            let closeParen = emitStringConstant(")")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(closeParen.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"

            bodyIR += "\(noneLabel):\n"
            let noneText = emitStringConstant("none")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(noneText.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            terminated = false

        case .tuple(let labels, let fieldTypes):
            // `[v1, v2]`, labeled fields as `label: v` — interpreter
            // stringify parity (probe-verified). Register aggregate:
            // payloads come out via extractvalue, recursion per field type.
            let open = emitStringConstant("[")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            for (index, fieldType) in fieldTypes.enumerated() {
                if index > 0 {
                    let separator = emitStringConstant(", ")
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
                }
                if let label = labels[index] {
                    let labelText = emitStringConstant("\(label): ")
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(labelText.ssaName))\n"
                }
                let field = builder.freshTemp()
                bodyIR += " \(field) = extractvalue \(type.llvmSpelling) \(value.ssaName), \(index)\n"
                emitValuePrint(
                    value: IRValue(llvmType: fieldType.llvmSpelling, ssaName: field),
                    type: fieldType
                )
            }
            let close = emitStringConstant("]")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(close.ssaName))\n"

        case .nominal:
            // Gated by the lowerer (printing struct/object values is a later
            // grid); kept here only to make the switch total.
            fatalError("IREmitter: printing a nominal value is gated (HIRLowerer)")

        case .enumeration(let name):
            // Enum value rendering (interpreter stringify parity):
            // `caseName(p1, p2)` — runtime tag dispatch, payloads printed
            // recursively by their declared types.
            guard let enumDecl = moduleEnums.first(where: { $0.name == name }),
                  let aggregate = type.nominalAggregateSpelling else {
                fatalError("IREmitter: printing unregistered enum (HIRLowerer guarantees)")
            }
            let tagPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: value.ssaName, indices: [0, 0]) + "\n"
            let tag = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: tag, type: "i32", ptr: tagPtr) + "\n"
            let id = builder.freshLabel()
            let endLabel = "fmt.enum.end.\(id)"
            for (caseIndex, enumCase) in enumDecl.cases.enumerated() {
                let matchesTag = builder.freshTemp()
                bodyIR += " \(matchesTag) = icmp eq i32 \(tag), \(enumCase.tag)\n"
                let armLabel = "fmt.enum.arm.\(id).\(caseIndex)"
                let nextLabel = caseIndex + 1 < enumDecl.cases.count
                    ? "fmt.enum.next.\(id).\(caseIndex)"
                    : "fmt.enum.fail.\(id)"
                bodyIR += builder.fmtCondBr(cond: matchesTag, thenLabelName: armLabel, elseLabelName: nextLabel) + "\n"

                bodyIR += "\(armLabel):\n"
                if enumCase.payloadTypes.isEmpty {
                    let caseText = emitStringConstant(enumCase.name)
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(caseText.ssaName))\n"
                } else {
                    let openText = emitStringConstant("\(enumCase.name)(")
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(openText.ssaName))\n"
                    for (slot, payloadType) in enumCase.payloadTypes.enumerated() {
                        if slot > 0 {
                            let separator = emitStringConstant(", ")
                            bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
                        }
                        let fieldPtr = builder.freshTemp()
                        bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: value.ssaName, indices: [0, slot + 1]) + "\n"
                        let element = builder.freshTemp()
                        bodyIR += builder.fmtLoad(name: element, type: payloadType.llvmSpelling, ptr: fieldPtr) + "\n"
                        emitValuePrint(
                            value: IRValue(llvmType: payloadType.llvmSpelling, ssaName: element),
                            type: payloadType
                        )
                    }
                    let closeText = emitStringConstant(")")
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(closeText.ssaName))\n"
                }
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
                if caseIndex + 1 < enumDecl.cases.count {
                    bodyIR += "fmt.enum.next.\(id).\(caseIndex):\n"
                }
            }
            bodyIR += "fmt.enum.fail.\(id):\n"
            let failText = emitStringConstant("Pini runtime error: enum value has unknown tag")
            bodyIR += " call void @bk_panic(ptr \(failText.ssaName))\n"
            bodyIR += " unreachable\n"
            bodyIR += "\(endLabel):\n"
            terminated = false

        case .dict(let keyType, let valueType):
            // Dict rendering (interpreter stringify parity): `{k: v, ...}`
            // via the index accessors, keys/values printed by their types.
            let open = emitStringConstant("{")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_dict_len(ptr \(raw))\n"
            let kSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: kSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: kSlot) + "\n"
            let id = builder.freshLabel()
            let condLabel = "fmtd.cond.\(id)"
            let bodyLabel = "fmtd.body.\(id)"
            let sepLabel = "fmtd.sep.\(id)"
            let elemLabel = "fmtd.elem.\(id)"
            let incLabel = "fmtd.inc.\(id)"
            let endLabel = "fmtd.end.\(id)"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
            bodyIR += "\(condLabel):\n"
            let k = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: kSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(k), \(count)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"

            bodyIR += "\(bodyLabel):\n"
            let isFirst = builder.freshTemp()
            bodyIR += " \(isFirst) = icmp eq i32 \(k), 0\n"
            bodyIR += builder.fmtCondBr(cond: isFirst, thenLabelName: elemLabel, elseLabelName: sepLabel) + "\n"

            bodyIR += "\(sepLabel):\n"
            let separator = emitStringConstant(", ")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: elemLabel) + "\n"

            bodyIR += "\(elemLabel):\n"
            let keyBox = builder.freshTemp()
            bodyIR += " \(keyBox) = call ptr @bk_dict_key_at(ptr \(raw), i32 \(k))\n"
            let keyValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: keyValue, type: keyType.llvmSpelling, ptr: keyBox) + "\n"
            emitValuePrint(
                value: IRValue(llvmType: keyType.llvmSpelling, ssaName: keyValue),
                type: keyType
            )
            let colon = emitStringConstant(": ")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(colon.ssaName))\n"
            let valueBox = builder.freshTemp()
            bodyIR += " \(valueBox) = call ptr @bk_dict_val_at(ptr \(raw), i32 \(k))\n"
            let dictValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: dictValue, type: valueType.llvmSpelling, ptr: valueBox) + "\n"
            emitValuePrint(
                value: IRValue(llvmType: valueType.llvmSpelling, ssaName: dictValue),
                type: valueType
            )
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"

            bodyIR += "\(incLabel):\n"
            let kValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: kSlot) + "\n"
            let kNext = builder.freshTemp()
            bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
            bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: kSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            let close = emitStringConstant("}")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(close.ssaName))\n"

        case .set(let elementType):
            // Set rendering: `{e1, e2, ...}` via bk_set_at index accessors.
            let open = emitStringConstant("{")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_set* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_set_len(ptr \(raw))\n"
            let kSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: kSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: kSlot) + "\n"
            let id = builder.freshLabel()
            let condLabel = "fmts.cond.\(id)"
            let bodyLabel = "fmts.body.\(id)"
            let sepLabel = "fmts.sep.\(id)"
            let elemLabel = "fmts.elem.\(id)"
            let incLabel = "fmts.inc.\(id)"
            let endLabel = "fmts.end.\(id)"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"
            bodyIR += "\(condLabel):\n"
            let k = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: k, type: "i32", ptr: kSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(k), \(count)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: bodyLabel, elseLabelName: endLabel) + "\n"

            bodyIR += "\(bodyLabel):\n"
            let isFirst = builder.freshTemp()
            bodyIR += " \(isFirst) = icmp eq i32 \(k), 0\n"
            bodyIR += builder.fmtCondBr(cond: isFirst, thenLabelName: elemLabel, elseLabelName: sepLabel) + "\n"

            bodyIR += "\(sepLabel):\n"
            let separator = emitStringConstant(", ")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: elemLabel) + "\n"

            bodyIR += "\(elemLabel):\n"
            let boxPtr = builder.freshTemp()
            bodyIR += " \(boxPtr) = call ptr @bk_set_at(ptr \(raw), i32 \(k))\n"
            let element = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: element, type: elementType.llvmSpelling, ptr: boxPtr) + "\n"
            emitValuePrint(
                value: IRValue(llvmType: elementType.llvmSpelling, ssaName: element),
                type: elementType
            )
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"

            bodyIR += "\(incLabel):\n"
            let kValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: kValue, type: "i32", ptr: kSlot) + "\n"
            let kNext = builder.freshTemp()
            bodyIR += " \(kNext) = add i32 \(kValue), 1\n"
            bodyIR += builder.fmtStore(value: kNext, type: "i32", ptr: kSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: condLabel) + "\n"

            bodyIR += "\(endLabel):\n"
            let close = emitStringConstant("}")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(close.ssaName))\n"

        default:
            emitScalarPrint(value)
        }
    }

    private func emitStringConstant(_ value: String) -> IRValue {
        let entry: (name: String, length: Int)
        if let existing = stringConstants[value] {
            entry = existing
        } else {
            let id = stringConstantDefs.count
            let name = "@.str\(id)"
            let bytes = Array(value.utf8)
            let length = bytes.count + 1
            var hex = ""
            for byte in bytes {
                hex += String(format: "\\%02X", byte)
            }
            stringConstantDefs.append("\(name) = private constant [\(length) x i8] c\"\(hex)\\00\"")
            entry = (name, length)
            stringConstants[value] = entry
        }
        let temp = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: temp, aggregate: "[\(entry.length) x i8]", base: entry.name, indices: [0, 0]) + "\n"
        return IRValue(llvmType: "i8*", ssaName: temp)
    }

    // MARK: - Slots & literals

    private func freshSlot(for name: String) -> String {
        let base = Self.mangle(name) + "_slot"
        let count = slotCounters[base] ?? 0
        slotCounters[base] = count + 1
        return count == 0 ? "%\(base)" : "%\(base)_\(count)"
    }

    private func lookupSlot(_ name: String) -> String? {
        for scope in scopes.reversed() {
            if let slot = scope[name] { return slot }
        }
        return nil
    }

    /// LLVM double literal: decimal form when it round-trips unambiguously,
    /// hex bit-pattern form otherwise (exponent notation, inf/nan, -0.0).
    private func doubleLiteral(_ value: Double) -> String {
        if value.isNaN || value.isInfinite || value == 0 {
            return "0x" + String(format: "%016llX", value.bitPattern)
        }
        let text = String(value)
        if text.contains("e") || text.contains("E") {
            return "0x" + String(format: "%016llX", value.bitPattern)
        }
        return text.contains(".") ? text : text + ".0"
    }

    /// Hex-encode non-ASCII identifiers into LLVM-safe names (`点` -> `_u70B9`).
    /// Delegates to the shared `IRName.mangle` (single implementation source
    /// for both pipelines since G3; HIRType spellings mangle through it too).
    static func mangle(_ name: String) -> String {
        IRName.mangle(name)
    }

    // MARK: - G6 closures / higher-order functions

    /// Closure value construction at the creation point: malloc the env, fill
    /// each field with a pointer to the captured variable's storage slot
    /// (reference capture — later writes to the outer variable are visible),
    /// and build the `{ code, env }` fat pointer. The closure's `define` body
    /// is buffered and appended at module end (legacy contract).
    ///
    /// Emission order note: this runs while emitting the enclosing function,
    /// so the buffered closure body must not disturb the current body state —
    /// emitClosureBody swaps the per-function state out and back.
    private func emitClosureLiteral(
        id: Int,
        paramNames: [String],
        paramTypes: [HIRType],
        returnType: HIRType?,
        captures: [HIRCapture],
        body: [HIRStmt],
        type: HIRType
    ) -> IRValue {
        let mangled = "@__closure_\(id)"
        let envPtr: String
        if captures.isEmpty {
            envPtr = "null"
        } else {
            let envTypeName = "%__closure_env_\(id)"
            closureEnvTypeDecls.append("\(envTypeName) = type { " +
                captures.map { _ in "ptr" }.joined(separator: ", ") + " }")
            let mallocTemp = builder.freshTemp()
            bodyIR += " \(mallocTemp) = call ptr @malloc(i64 \(captures.count * 8))\n"
            for (index, capture) in captures.enumerated() {
                guard let slot = lookupSlot(capture.name) ?? captureSlots[capture.name] else {
                    fatalError("IREmitter: capture '\(capture.name)' has no visible slot (HIRLowerer guarantees)")
                }
                let gepTemp = builder.freshTemp()
                bodyIR += builder.fmtGEP(name: gepTemp, aggregate: envTypeName, base: mallocTemp, indices: [0, index]) + "\n"
                bodyIR += builder.fmtStore(value: slot, type: "ptr", ptr: gepTemp) + "\n"
            }
            envPtr = mallocTemp
        }

        let codeTemp = builder.freshTemp()
        bodyIR += " \(codeTemp) = insertvalue { ptr, ptr } { ptr \(mangled), ptr null }, ptr \(mangled), 0\n"
        let closureTemp = builder.freshTemp()
        bodyIR += " \(closureTemp) = insertvalue { ptr, ptr } \(codeTemp), ptr \(envPtr), 1\n"

        emitClosureDefine(
            id: id, mangled: mangled, paramNames: paramNames, paramTypes: paramTypes,
            returnType: returnType, captures: captures, body: body
        )
        return IRValue(llvmType: "{ ptr, ptr }", ssaName: closureTemp)
    }

    /// A named top-level function used as a value: an env-ignoring adapter
    /// fat pointer. Indirect calls always use the closure ABI
    /// `code(ptr env, args...)`; a bare function's ABI lacks the env slot,
    /// so passing its code pointer directly would shift arguments (the #8
    /// higher-order bug: `加倍(null, 5)` -> 0). The adapter bridges the two.
    private func emitFunctionValue(functionName: String) -> IRValue {
        let mangled = Self.mangle(functionName)
        emitAdapter(mangled: mangled)
        let codeTemp = builder.freshTemp()
        bodyIR += " \(codeTemp) = insertvalue { ptr, ptr } { ptr @__adapter_\(mangled), ptr null }, ptr @__adapter_\(mangled), 0\n"
        let closureTemp = builder.freshTemp()
        bodyIR += " \(closureTemp) = insertvalue { ptr, ptr } \(codeTemp), ptr null, 1\n"
        return IRValue(llvmType: "{ ptr, ptr }", ssaName: closureTemp)
    }

    /// Indirect call through a function value: extractvalue code + env, then
    /// `call ret code(ptr env, args...)` (uniform closure ABI).
    private func emitIndirectCall(
        callee: HIRExpr,
        arguments: [HIRExpr],
        returnType: HIRType?
    ) -> IRValue {
        let closure = emitExpr(callee)
        let code = builder.freshTemp()
        bodyIR += " \(code) = extractvalue { ptr, ptr } \(closure.ssaName), 0\n"
        let env = builder.freshTemp()
        bodyIR += " \(env) = extractvalue { ptr, ptr } \(closure.ssaName), 1\n"
        var argList = ["ptr \(env)"]
        for argument in arguments {
            let value = emitExpr(argument)
            argList.append("\(value.llvmType) \(value.ssaName)")
        }
        if let returnType = returnType {
            let retTemp = builder.freshTemp()
            bodyIR += " \(retTemp) = call \(returnType.llvmSpelling) \(code)(\(argList.joined(separator: ", ")))\n"
            return IRValue(llvmType: returnType.llvmSpelling, ssaName: retTemp)
        }
        bodyIR += " call void \(code)(\(argList.joined(separator: ", ")))\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// Buffer (deduplicated) the env-ignoring adapter for a named function:
    /// slot each formparam, reload, tail-call the original with plain ABI.
    private func emitAdapter(mangled: String) {
        guard !adapterNames.contains(mangled) else { return }
        adapterNames.insert(mangled)
        // The adapter's signature comes from the original function define,
        // which lives in bodyIR; parse its param types out of the recorded
        // function signatures at emit time is complex — instead the adapter
        // is generated lazily against the module function registry passed
        // through moduleFunctions (set during emit(module:)).
        guard let function = moduleFunctions[mangled] else {
            fatalError("IREmitter: adapter for unknown function '\(mangled)' (HIRLowerer guarantees)")
        }
        var body = ""
        var callArgs: [String] = []
        for (index, param) in function.params.enumerated() {
            let spelling = param.type.llvmSpelling
            let argName = "%arg\(index)"
            let slotName = "%arg\(index)_slot"
            body += " \(slotName) = alloca \(spelling)\n"
            body += " store \(spelling) \(argName), ptr \(slotName)\n"
            let loadName = "%v\(index)"
            body += " \(loadName) = load \(spelling), ptr \(slotName)\n"
            callArgs.append("\(spelling) \(loadName)")
        }
        let returnType = function.returnType?.llvmSpelling ?? "void"
        var paramsIR = ["ptr %env"]
        for (index, param) in function.params.enumerated() {
            paramsIR.append("\(param.type.llvmSpelling) %arg\(index)")
        }
        var def = "define \(returnType) @__adapter_\(mangled)(\(paramsIR.joined(separator: ", "))) {\n"
        def += body
        if function.returnType == nil {
            def += " call void @\(mangled)(\(callArgs.joined(separator: ", ")))\n"
            def += " ret void\n"
        } else {
            def += " %r = call \(returnType) @\(mangled)(\(callArgs.joined(separator: ", ")))\n"
            def += " ret \(returnType) %r\n"
        }
        def += "}\n\n"
        adapterDefs.append(def)
    }

    /// Swap in a clean per-function state, emit the closure body into a
    /// private buffer, and record the buffered `define` for module-end
    /// assembly. Captures enter as slot pointers (reference capture: loads
    /// and stores go through the same slot the outer variable uses).
    private func emitClosureDefine(
        id: Int,
        mangled: String,
        paramNames: [String],
        paramTypes: [HIRType],
        returnType: HIRType?,
        captures: [HIRCapture],
        body: [HIRStmt]
    ) {
        let savedScopes = scopes
        let savedSlotCounters = slotCounters
        let savedTerminated = terminated
        let savedLoopStack = loopStack
        let savedDeferScopeBase = deferScopeBase
        let savedReturnType = currentReturnType
        let savedIsMain = currentIsMain
        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedCaptureSlots = captureSlots

        scopes = [[:]]
        slotCounters = [:]
        terminated = false
        loopStack = []
        // A return inside the closure must not run the enclosing function's
        // defers: defer frames opened by the closure live above this base.
        deferScopeBase = pendingDefers.count
        currentReturnType = returnType
        currentIsMain = false
        builder = IRBuilder()
        bodyIR = ""
        captureSlots = [:]

        let envTypeName = "%__closure_env_\(id)"
        for (index, capture) in captures.enumerated() {
            // The env field holds the outer variable's slot pointer; load it
            // into a local register and register it as the capture's slot so
            // every body access reads/writes the outer storage.
            let gepTemp = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: gepTemp, aggregate: envTypeName, base: "%env", indices: [0, index]) + "\n"
            let slotTemp = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: slotTemp, type: "ptr", ptr: gepTemp) + "\n"
            scopes[scopes.count - 1][capture.name] = slotTemp
            captureSlots[capture.name] = slotTemp
        }
        for (index, paramType) in paramTypes.enumerated() {
            let spelling = paramType.llvmSpelling
            let slot = "%arg\(index)_slot"
            bodyIR += builder.fmtAlloca(name: slot, type: spelling) + "\n"
            bodyIR += builder.fmtStore(value: "%arg\(index)", type: spelling, ptr: slot) + "\n"
            // Body statements reference params by source name; decl order
            // parallels paramTypes (HIRLowerer contract).
            let name = index < paramNames.count ? paramNames[index] : "param\(index)"
            scopes[scopes.count - 1][name] = slot
        }

        emitBlock(body)

        if !terminated {
            bodyIR += builder.fmtBr(labelName: "exit_block") + "\n"
            bodyIR += "exit_block:\n"
            if let returnType = returnType {
                bodyIR += " ret \(returnType.llvmSpelling) undef\n"
            } else {
                bodyIR += " ret void\n"
            }
        }

        var paramsIR = ["ptr %env"]
        for (index, paramType) in paramTypes.enumerated() {
            paramsIR.append("\(paramType.llvmSpelling) %arg\(index)")
        }
        let returnSpelling = returnType?.llvmSpelling ?? "void"
        closureDefs.append("define \(returnSpelling) \(mangled)(\(paramsIR.joined(separator: ", "))) {\n")
        closureDefs.append(bodyIR)
        closureDefs.append("}\n\n")

        scopes = savedScopes
        slotCounters = savedSlotCounters
        terminated = savedTerminated
        loopStack = savedLoopStack
        deferScopeBase = savedDeferScopeBase
        currentReturnType = savedReturnType
        currentIsMain = savedIsMain
        bodyIR = savedBodyIR
        builder = savedBuilder
        captureSlots = savedCaptureSlots
    }

    // MARK: - G9 string deepening

    /// `s.upper()` / `s.lower()`: memcpy the receiver, toupper/tolower loop.
    private func emitStringCase(isUpper: Bool, source: String) -> IRValue {
        let funcName = isUpper ? "toupper" : "tolower"
        let clen = builder.freshTemp()
        bodyIR += " \(clen) = call i64 @strlen(ptr \(source))\n"
        let sz1 = builder.freshTemp()
        bodyIR += " \(sz1) = add i64 \(clen), 1\n"
        let copyBuf = builder.freshTemp()
        bodyIR += " \(copyBuf) = alloca i8, i64 \(sz1)\n"
        bodyIR += " call ptr @memcpy(ptr \(copyBuf), ptr \(source), i64 \(sz1))\n"
        let slot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: slot, type: "ptr") + "\n"
        bodyIR += builder.fmtStore(value: copyBuf, type: "ptr", ptr: slot) + "\n"
        let id = builder.freshLabel()
        let header = "strcase.hdr.\(id)"
        let bodyLabel = "strcase.body.\(id)"
        let endLabel = "strcase.end.\(id)"
        bodyIR += builder.fmtBr(labelName: header) + "\n"
        bodyIR += "\(header):\n"
        let curPtr = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: curPtr, type: "ptr", ptr: slot) + "\n"
        let ch = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: ch, type: "i8", ptr: curPtr) + "\n"
        let done = builder.freshTemp()
        bodyIR += " \(done) = icmp eq i8 \(ch), 0\n"
        bodyIR += builder.fmtCondBr(cond: done, thenLabelName: endLabel, elseLabelName: bodyLabel) + "\n"
        bodyIR += "\(bodyLabel):\n"
        let wide = builder.freshTemp()
        bodyIR += " \(wide) = sext i8 \(ch) to i32\n"
        let conv = builder.freshTemp()
        bodyIR += " \(conv) = call i32 @\(funcName)(i32 \(wide))\n"
        let narrow = builder.freshTemp()
        bodyIR += " \(narrow) = trunc i32 \(conv) to i8\n"
        bodyIR += builder.fmtStore(value: narrow, type: "i8", ptr: curPtr) + "\n"
        let next = builder.freshTemp()
        bodyIR += " \(next) = getelementptr i8, ptr \(curPtr), i64 1\n"
        bodyIR += builder.fmtStore(value: next, type: "ptr", ptr: slot) + "\n"
        bodyIR += builder.fmtBr(labelName: header) + "\n"
        bodyIR += "\(endLabel):\n"
        return IRValue(llvmType: "i8*", ssaName: copyBuf)
    }

    /// `s.split(delim)` — a real `Array<String>`: two strtok passes over
    /// copies of the source (pass 1 counts tokens so bk_array_create gets
    /// the exact length; pass 2 fills), each token strdup'd into the array
    /// via bk_array_set (raw-ptr tag 3). strtok skips empty tokens —
    /// corpus-identical with the interpreter's sunk split.
    private func emitStringSplit(source: String, delim: String, type: HIRType) -> IRValue {
        let slen = builder.freshTemp()
        bodyIR += " \(slen) = call i64 @strlen(ptr \(source))\n"

        func copySource(_ buf: String) {
            bodyIR += " call ptr @memcpy(ptr \(buf), ptr \(source), i64 \(slen))\n"
            let nl = builder.freshTemp()
            bodyIR += " \(nl) = getelementptr i8, ptr \(buf), i64 \(slen)\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: nl) + "\n"
        }

        // Pass 1: count tokens.
        let countBuf = builder.freshTemp()
        bodyIR += " \(countBuf) = alloca i8, i64 1024\n"
        copySource(countBuf)
        let counterSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: counterSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: counterSlot) + "\n"
        let t1 = builder.freshTemp()
        bodyIR += " \(t1) = call ptr @strtok(ptr \(countBuf), ptr \(delim))\n"
        let tokSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: tokSlot, type: "ptr") + "\n"
        bodyIR += builder.fmtStore(value: t1, type: "ptr", ptr: tokSlot) + "\n"
        let id = builder.freshLabel()
        let countHdr = "splitc.hdr.\(id)"
        let countBody = "splitc.body.\(id)"
        let countEnd = "splitc.end.\(id)"
        bodyIR += builder.fmtBr(labelName: countHdr) + "\n"
        bodyIR += "\(countHdr):\n"
        let curTok = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: curTok, type: "ptr", ptr: tokSlot) + "\n"
        let done = builder.freshTemp()
        bodyIR += " \(done) = icmp eq ptr \(curTok), null\n"
        bodyIR += builder.fmtCondBr(cond: done, thenLabelName: countEnd, elseLabelName: countBody) + "\n"
        bodyIR += "\(countBody):\n"
        let curCount = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: curCount, type: "i32", ptr: counterSlot) + "\n"
        let nextCount = builder.freshTemp()
        bodyIR += " \(nextCount) = add i32 \(curCount), 1\n"
        bodyIR += builder.fmtStore(value: nextCount, type: "i32", ptr: counterSlot) + "\n"
        let nextTok = builder.freshTemp()
        bodyIR += " \(nextTok) = call ptr @strtok(ptr null, ptr \(delim))\n"
        bodyIR += builder.fmtStore(value: nextTok, type: "ptr", ptr: tokSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: countHdr) + "\n"
        bodyIR += "\(countEnd):\n"

        let tokenCount = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: tokenCount, type: "i32", ptr: counterSlot) + "\n"
        let create = builder.freshTemp()
        bodyIR += " \(create) = call ptr @bk_array_create(i32 \(tokenCount))\n"
        let handleSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: handleSlot, type: "%bk_array*") + "\n"
        let createHandle = builder.freshTemp()
        bodyIR += " \(createHandle) = bitcast ptr \(create) to %bk_array*\n"
        bodyIR += builder.fmtStore(value: createHandle, type: "%bk_array*", ptr: handleSlot) + "\n"

        // Pass 2: fill.
        let fillBuf = builder.freshTemp()
        bodyIR += " \(fillBuf) = alloca i8, i64 1024\n"
        copySource(fillBuf)
        let f1 = builder.freshTemp()
        bodyIR += " \(f1) = call ptr @strtok(ptr \(fillBuf), ptr \(delim))\n"
        let fillTokSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: fillTokSlot, type: "ptr") + "\n"
        bodyIR += builder.fmtStore(value: f1, type: "ptr", ptr: fillTokSlot) + "\n"
        let idxSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: idxSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: idxSlot) + "\n"

        let fid = builder.freshLabel()
        let fillHdr = "splitf.hdr.\(fid)"
        let fillBody = "splitf.body.\(fid)"
        let fillEnd = "splitf.end.\(fid)"
        bodyIR += builder.fmtBr(labelName: fillHdr) + "\n"
        bodyIR += "\(fillHdr):\n"
        let fillTok = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: fillTok, type: "ptr", ptr: fillTokSlot) + "\n"
        let fillDone = builder.freshTemp()
        bodyIR += " \(fillDone) = icmp eq ptr \(fillTok), null\n"
        bodyIR += builder.fmtCondBr(cond: fillDone, thenLabelName: fillEnd, elseLabelName: fillBody) + "\n"
        bodyIR += "\(fillBody):\n"
        let dupLen = builder.freshTemp()
        bodyIR += " \(dupLen) = call i64 @strlen(ptr \(fillTok))\n"
        let dupBuf = builder.freshTemp()
        bodyIR += " \(dupBuf) = call ptr @malloc(i64 \(dupLen))\n"
        bodyIR += " call ptr @strcpy(ptr \(dupBuf), ptr \(fillTok))\n"
        let idx = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: idx, type: "i32", ptr: idxSlot) + "\n"
        let handle = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: handle, type: "%bk_array*", ptr: handleSlot) + "\n"
        let handleRaw = builder.freshTemp()
        bodyIR += " \(handleRaw) = bitcast %bk_array* \(handle) to ptr\n"
        let box = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: box, type: "i8*") + "\n"
        bodyIR += builder.fmtStore(value: dupBuf, type: "i8*", ptr: box) + "\n"
        let newRaw = builder.freshTemp()
        bodyIR += " \(newRaw) = call ptr @bk_array_set(ptr \(handleRaw), i32 \(idx), ptr \(box), i32 8, i32 3)\n"
        let newHandle = builder.freshTemp()
        bodyIR += " \(newHandle) = bitcast ptr \(newRaw) to %bk_array*\n"
        bodyIR += builder.fmtStore(value: newHandle, type: "%bk_array*", ptr: handleSlot) + "\n"
        let idxNext = builder.freshTemp()
        bodyIR += " \(idxNext) = add i32 \(idx), 1\n"
        bodyIR += builder.fmtStore(value: idxNext, type: "i32", ptr: idxSlot) + "\n"
        let nextFillTok = builder.freshTemp()
        bodyIR += " \(nextFillTok) = call ptr @strtok(ptr null, ptr \(delim))\n"
        bodyIR += builder.fmtStore(value: nextFillTok, type: "ptr", ptr: fillTokSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: fillHdr) + "\n"
        bodyIR += "\(fillEnd):\n"
        let finalHandle = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: finalHandle, type: "%bk_array*", ptr: handleSlot) + "\n"
        return IRValue(llvmType: "%bk_array*", ssaName: finalHandle)
    }

    /// `arr.join(sep)`: string-array elements strcat'd with sep into a
    /// stack buffer (legacy mirror; element strings are raw C ptrs).
    private func emitArrayJoin(array: IRValue, sep: String) -> IRValue {
        let buf = builder.freshTemp()
        bodyIR += " \(buf) = alloca i8, i64 4096\n"
        bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: buf) + "\n"
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(array.ssaName) to ptr\n"
        let count = builder.freshTemp()
        bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
        let idxSlot = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: idxSlot, type: "i32") + "\n"
        bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: idxSlot) + "\n"
        let id = builder.freshLabel()
        let header = "join.hdr.\(id)"
        let firstLabel = "join.first.\(id)"
        let sepLabel = "join.sep.\(id)"
        let elemLabel = "join.elem.\(id)"
        let incLabel = "join.inc.\(id)"
        let endLabel = "join.end.\(id)"
        bodyIR += builder.fmtBr(labelName: header) + "\n"
        bodyIR += "\(header):\n"
        let idx = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: idx, type: "i32", ptr: idxSlot) + "\n"
        let inBounds = builder.freshTemp()
        bodyIR += " \(inBounds) = icmp slt i32 \(idx), \(count)\n"
        bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: firstLabel, elseLabelName: endLabel) + "\n"
        bodyIR += "\(firstLabel):\n"
        let isFirst = builder.freshTemp()
        bodyIR += " \(isFirst) = icmp eq i32 \(idx), 0\n"
        bodyIR += builder.fmtCondBr(cond: isFirst, thenLabelName: elemLabel, elseLabelName: sepLabel) + "\n"
        bodyIR += "\(sepLabel):\n"
        bodyIR += " call ptr @strcat(ptr \(buf), ptr \(sep))\n"
        bodyIR += builder.fmtBr(labelName: elemLabel) + "\n"
        bodyIR += "\(elemLabel):\n"
        let box = builder.freshTemp()
        bodyIR += " \(box) = call ptr @bk_array_get(ptr \(raw), i32 \(idx))\n"
        let element = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: element, type: "i8*", ptr: box) + "\n"
        bodyIR += " call ptr @strcat(ptr \(buf), ptr \(element))\n"
        bodyIR += builder.fmtBr(labelName: incLabel) + "\n"
        bodyIR += "\(incLabel):\n"
        let idxNext = builder.freshTemp()
        bodyIR += " \(idxNext) = add i32 \(idx), 1\n"
        bodyIR += builder.fmtStore(value: idxNext, type: "i32", ptr: idxSlot) + "\n"
        bodyIR += builder.fmtBr(labelName: header) + "\n"
        bodyIR += "\(endLabel):\n"
        return IRValue(llvmType: "i8*", ssaName: buf)
    }

    /// String interpolation: pieces converted to C strings, strcat'd into a
    /// stack buffer. Uses stringifyValue (same display pipeline as print).
    private func emitInterpString(parts: [HIRExpr]) -> IRValue {
        let buf = builder.freshTemp()
        bodyIR += " \(buf) = alloca i8, i64 4096\n"
        bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: buf) + "\n"
        for part in parts {
            let piece = emitStringPiece(part)
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(piece.ssaName))\n"
        }
        return IRValue(llvmType: "i8*", ssaName: buf)
    }

    /// One interpolation piece as a C string pointer. Buffers for scalars
    /// are stack allocas; container pieces recurse through stringifyValue.
    private func emitStringPiece(_ part: HIRExpr) -> IRValue {
        let type = hirType(of: part)
        switch type {
        case .string:
            return emitExpr(part)
        default:
            let value = emitExpr(part)
            return stringifyValue(value: value, type: type)
        }
    }

    /// Value display into a string (G9): the string-building mirror of
    /// emitValuePrint. Supports the scalar/container set the corpus
    /// interpolates (i32/F64/bool/string/array); optionals/enums/tuples
    /// render through the same buffer-concat shape as their print paths.
    private func stringifyValue(value: IRValue, type: HIRType) -> IRValue {
        switch type {
        case .i32:
            let buf = builder.freshTemp()
            bodyIR += " \(buf) = alloca i8, i64 32\n"
            bodyIR += " call i32 (ptr, i64, ptr, ...) @snprintf(ptr \(buf), i64 31, ptr @fmt_int, i32 \(value.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: buf)
        case .f64:
            let rendered = builder.freshTemp()
            bodyIR += " \(rendered) = call ptr @bk_double_to_string(double \(value.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: rendered)
        case .boolean:
            let sel = builder.freshTemp()
            bodyIR += " \(sel) = select i1 \(value.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false\n"
            return IRValue(llvmType: "i8*", ssaName: sel)
        case .string:
            return value
        case .array(let elementType):
            let buf = builder.freshTemp()
            bodyIR += " \(buf) = alloca i8, i64 4096\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: buf) + "\n"
            let open = emitStringConstant("[")
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(open.ssaName))\n"
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_array* \(value.ssaName) to ptr\n"
            let count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_array_len(ptr \(raw))\n"
            let idxSlot = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: idxSlot, type: "i32") + "\n"
            bodyIR += builder.fmtStore(value: "0", type: "i32", ptr: idxSlot) + "\n"
            let id = builder.freshLabel()
            let header = "sarr.hdr.\(id)"
            let firstLabel = "sarr.first.\(id)"
            let sepLabel = "sarr.sep.\(id)"
            let elemLabel = "sarr.elem.\(id)"
            let incLabel = "sarr.inc.\(id)"
            let endLabel = "sarr.end.\(id)"
            bodyIR += builder.fmtBr(labelName: header) + "\n"
            bodyIR += "\(header):\n"
            let idx = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: idx, type: "i32", ptr: idxSlot) + "\n"
            let inBounds = builder.freshTemp()
            bodyIR += " \(inBounds) = icmp slt i32 \(idx), \(count)\n"
            bodyIR += builder.fmtCondBr(cond: inBounds, thenLabelName: firstLabel, elseLabelName: endLabel) + "\n"
            bodyIR += "\(firstLabel):\n"
            let isFirst = builder.freshTemp()
            bodyIR += " \(isFirst) = icmp eq i32 \(idx), 0\n"
            bodyIR += builder.fmtCondBr(cond: isFirst, thenLabelName: elemLabel, elseLabelName: sepLabel) + "\n"
            bodyIR += "\(sepLabel):\n"
            let separator = emitStringConstant(", ")
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(separator.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: elemLabel) + "\n"
            bodyIR += "\(elemLabel):\n"
            let box = builder.freshTemp()
            bodyIR += " \(box) = call ptr @bk_array_get(ptr \(raw), i32 \(idx))\n"
            let element = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: element, type: elementType.llvmSpelling, ptr: box) + "\n"
            let piece = stringifyValue(
                value: IRValue(llvmType: elementType.llvmSpelling, ssaName: element),
                type: elementType
            )
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(piece.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: incLabel) + "\n"
            bodyIR += "\(incLabel):\n"
            let idxNext = builder.freshTemp()
            bodyIR += " \(idxNext) = add i32 \(idx), 1\n"
            bodyIR += builder.fmtStore(value: idxNext, type: "i32", ptr: idxSlot) + "\n"
            bodyIR += builder.fmtBr(labelName: header) + "\n"
            bodyIR += "\(endLabel):\n"
            let close = emitStringConstant("]")
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(close.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: buf)
        default:
            fatalError("IREmitter: stringify of '\(type)' outside the G9 grid (HIRLowerer gates interpolation parts)")
        }
    }
}
