import Foundation

/// 当前函数（或闭包）**有没有可恢复帧**（`DE-6b`）。
///
/// ⚠️ 它只管一件事：**这个体的局部槽能不能活过「让出」这一次返回**。没有帧的体（同步函数、
/// 闭包）保持 `DE-6b` 之前的发射形状**一字不改** —— 让出只发生在异步体里，把其余函数也改成
/// 帧式只会让「本批改了什么」变模糊。
private enum FunctionFrameMode {
    /// 普通体：局部槽落栈（今天的形状）。
    case none
    /// 可恢复体：局部槽落帧，允许在顶层语句处让出。
    case resumable
}

/// IR -> LLVM IR text emitter for the M4 vertical slice (LR-2/LR-3).
///
/// The emitter is a mechanical translation: every type decision was already
/// made by `IRLowerer` (the single capability gate), so this file contains no
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
    /// Mirrors the IR tree nesting so shadowing declarations resolve
    /// innermost-first at emit time.
    private var scopes: [[String: String]] = []

    /// Per-function slot-name counters so shadowing declarations get fresh
    /// allocas instead of colliding with the outer slot.
    private var slotCounters: [String: Int] = [:]

    /// Current block terminated by `ret`; later statements in the block are
    /// unreachable and must not be emitted (instructions after a terminator
    /// are invalid IR).
    private var terminated = false

    /// Enclosing interruptible frames, innermost last. `break` targets `exit`;
    /// `continue` targets `continueTarget` (the step entry when the loop has
    /// a step block, else the header) — labeled forms (depth > 1, 标签语法反转)
    /// target the depth-th frame's `header`. With an empty stack both lower
    /// to a runtime panic (interpreter parity: a bare break/continue
    /// escaping to the top level errors).
    ///
    /// 标签 break 定向范围 widened this from "loop frames" to "interruptible frames": a
    /// labeled `if` block is a frame too, so `break 标签` may leave it. The
    /// two resume labels are meaningless for such a frame (`continue` resolves
    /// to loop frames only) and are set to its merge block, which is also its
    /// `exit` — leaving a labeled `if` resumes right after it.
    private struct ControlFrame {
        let exit: String
        let header: String
        let continueTarget: String
        /// `false` for a labeled `if` block: a frame `break` may leave but
        /// `continue` may not target.
        let isLoop: Bool
        /// Index of the frame's BODY's defer frame in `pendingDefers` (the
        /// frame pushed after this frame was pushed). A break/continue
        /// out of this frame flushes defer frames from the innermost one down
        /// to this index, both included — leaving the body block runs
        /// its defers (interpreter: the signal unwinds through
        /// executeBlock's own popDeferScope).
        let deferBase: Int
        /// Index of the frame's BODY's release frame in `pendingReleases`, the
        /// counterpart of `deferBase`: a break/continue out of this frame
        /// releases the collection handles registered in every frame from the
        /// innermost one down to this index, both included. Leaving the body
        /// block abandons those handles, and the runtime has no other holder.
        let releaseBase: Int
    }

    private var controlStack: [ControlFrame] = []

    /// Merge blocks that a `break` jumped to. `emitIf` decides whether to emit
    /// its merge label from whether both branches were terminated by their own
    /// terminators — but a `break` that leaves the `if` *is* a terminator and
    /// still lands on that label, so the label has to be emitted (标签 break 定向范围).
    /// Only non-loop frames record here: a loop's exit label is emitted
    /// unconditionally.
    private var breakMergeLabels: Set<String> = []

    /// Index in `pendingDefers` where the current function's (or closure's)
    /// defer frames begin. A `return` flushes defer frames down to this
    /// base and no further — a return inside a closure must not run the
    /// enclosing function's defers.
    private var deferScopeBase = 0

    private var currentIsMain = false
    private var currentReturnType: IRType? = nil

    private var builder = IRBuilder()
    private var bodyIR = ""

    /// Nominal type declarations of the module being emitted (G3) — field
    /// layouts for constructor / field-access GEPs.
    private var moduleTypes: [IRTypeDecl] = []

    /// Enum declarations of the module being emitted (G4) — case tags and
    /// payload types for construction and match dispatch.
    private var moduleEnums: [IREnumDecl] = []

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
    private var moduleFunctions: [String: IRFunction] = [:]
    /// G13 batch 1: `%bk_lazyref` handle type + `bk_lazyref_*` C ABI used —
    /// the header declares are appended conditionally (legacy
    /// `usesLazyRef` contract, golden-IR stability for modules that
    /// never touch LazyRef).
    private var usesLazyRef = false
    /// G15: `writeFile`/`readFile` pull in the stdio declares and the
    /// mode-string constants. Conditional for the same golden-IR reason
    /// as the other optional headers.
    private var usesFileWrite = false
    /// G15: `readFile` reads the whole file through the runtime shim
    /// (`bk_read_file`) rather than emitted stdio. A whole file does not fit a
    /// fixed stack buffer, and under LLI's JIT the size is not knowable before
    /// the read (`fseek` / `ftell` / `fstat` are unreliable there). Conditional
    /// for the same golden-IR reason as the other optional headers.
    private var usesFileRead = false
    /// G17: `readLine` pulls in the `fgets` declare and the stdin stream
    /// global. Conditional for the same golden-IR reason as the other
    /// optional headers.
    private var usesReadLine = false
    /// G13 batch 1: type-specialized `@__lazyref_wrapper_<T>` define buffer,
    /// deduplicated by element IR spelling; appended after the adapter defs.
    private var lazyrefWrappers: [String] = []
    private var lazyrefWrapperNames: Set<String> = []

    /// 本模块是否发射过并发面（派发 / 等待 / 剪枝）。三个 `bk_task_*` 的 declare 随之
    /// 条件出现 —— 与 LazyRef / 文件 IO / readLine 同一条契约：**不碰并发面的程序 IR 不变**。
    private var usesTaskRuntime = false
    /// 是否发射过容器形参的**份额**保留 —— 只有真要还回时才声明对应的运行时符号。
    private var usesTaskArgRelease = false
    /// 是否调用过 `sleep` —— 它在原语层（按片睡、每片查取消），故落点是运行时符号
    /// 而不是 libc 的睡眠，声明也随之条件出现。
    private var usesSleepShim = false
    /// 是否调用过字符内建（`chars` / `chr` / `ord` / `is_letter` / `is_number`）——
    /// 它们的运行时段在 `PiniRuntime`（`bk_<名字>`），declare 随之条件出现。
    private var usesCharacterShims = false
    /// 是否调用过宿主环境查询内建（`argv` / `listDir`）—— 同上，落点是 `bk_argv` / `bk_list_dir`。
    private var usesProcessShims = false
    /// 是否发射过**字符串字素簇通道**的调用 —— 落点是运行时段那一族（`bk_substring` /
    /// `bk_string_count` / `bk_string_char_at` / `bk_string_slice` / `bk_string_upper` /
    /// `bk_string_lower` / `bk_string_contains`）。
    ///
    /// ⭐ 为什么整族都在运行时段：契约 `字符模型 = Grapheme Cluster`，而字素簇边界是
    /// Unicode 分段算法，**发射器发不出**（发得出来的只有字节循环，那正是契约 §2.9
    /// 第 22/23/36/37 条登记的在案偏离）。运行时段用的是 `String` / `Character` ——
    /// 与解释器同一个模型。⚠️ 语义一律对着解释器那一路写，⛔ 不在这里各造一套。
    private var usesStringShims = false
    /// 是否发射过**名义箱的分配**（`bk_nominal_alloc`）—— 只有真构造过名义值的模块才带它的 declare。
    ///
    /// ⭐ 2026-10-01「名义箱上堆」：结构体 / 对象 / 枚举的箱从栈 `alloca` 搬到运行时段堆分配
    /// （三族首格统一为引用计数头）。与 LazyRef / 文件 IO / 字符族同规 —— 条件 declare，
    /// 不碰名义值的程序 IR 除类型定义外逐字节不变。
    private var usesNominalBoxes = false

    /// 本函数（或闭包体）里**被闭包捕获**的变量名集合（2026-10-01 · 片 D）。
    ///
    /// ⭐ 为什么要在进体之前先算出来：捕获的槽必须**在分配它的那一刻**就知道
    /// 「这个变量将来会被闭包带走」—— 声明点（`allocVar`）总在闭包字面量之前，
    /// 事后补不了（栈 `alloca` 已经发出去了）。
    private var capturedNamesInFunction: Set<String> = []

    /// 是否发射过**捕获槽的堆分配**（`bk_slot_alloc`）—— 条件 declare。
    private var usesCapturedSlots = false

    /// 逐类型合成的**释放胶水**（`__release_*`）缓冲与去重名集 —— 照 `givenInitializerDefs` 那套。
    private var releaseFunctionDefs: [String] = []
    private var releaseFunctionNames: Set<String> = []

    /// 逐类型合成的**值语义拷贝胶水**（`__copy_struct_*`，只为结构体存在）—— 同上。
    private var copyFunctionDefs: [String] = []
    private var copyFunctionNames: Set<String> = []

    /// 任务体 wrapper 的 `define` 缓冲与去重名集（照 `@__adapter_` 那套）。
    private var taskBodyDefs: [String] = []
    private var taskBodyNames: Set<String> = []

    // MARK: 可恢复帧（`DE-6b`）

    /// 当前正在发射的函数/闭包**有没有可恢复帧**。
    ///
    /// ⛔ 它是一个**闸**，不是优化开关：`DE-6b` 之前它永远缺席，而那时只有「发射层还没有让出
    /// 路径」这一个事实；现在它同时决定三件事 —— 局部槽落栈还是落帧 · 让出点能不能发射 ·
    /// 没有帧时的那条路是否响亮拒绝。闭包体一律 `.none`（闭包不是任务，没有帧可依）。
    private var frameMode: FunctionFrameMode = .none

    /// 块嵌套深度。**函数体那一层是 1** —— `DE-6b` 的让出点只允许出现在那一层。
    ///
    /// ⛔ 为什么要限层：续跑靠入口的 `switch` **直接跳回**让出点所在的那一块。嵌套在 `if` /
    /// `match` / 循环里的让出点，其所在块依赖于外层块先算出的值（条件、被匹配的主题），而那条
    /// 路径在续跑时被整段跳过 ⇒ 那些值**不支配**续跑块。限在顶层就没有这个问题：顶层语句之间
    /// 只经**帧**传值，而帧地址在入口块里取得、支配一切。
    private var blockDepth = 0

    /// 本函数帧里要取的槽，**按声明顺序**。顺序即重放顺序 —— `bk_task_slot` 的游标按同一顺序
    /// 命中上次发过的那一块（见 `declareLocalSlot`）。
    private var frameSlotDecls: [(name: String, spelling: String)] = []

    /// 已发射的让出点个数（`de6b.resume.<k>` 的 `k` 从 1 数起；入口的 `switch` 按它生成）。
    private var yieldPointCount = 0

    /// 是否发射过帧的取用 —— `bk_task_frame` / `bk_task_slot` 的 declare 随之条件出现。
    private var usesTaskFrame = false

    /// 是否把**调度器绑定**交给过运行时（`Q-4` 乙段）。
    ///
    /// ⚠️ 它是「派发点会取用默认调度实例」这件事的**唯一征兆**：本符号的 declare 随它条件出现，
    /// 与让出族那几行同规（只有真发过的模块才带）。
    private var usesSchedBinding = false

    /// ADR-001 `P2b`：默认实例的**存放位**（程序级槽位，每个给定块类型一个）。
    ///
    /// 定义处 = 声明所在文件（发射层按类型名发一次），同包内其它文件经**同一个** IR 模块
    /// 引用它 ⇒ 不需要 `external`：实测整包降载为**一个** `IRModule`、发射为**一个** IR 模块
    /// （计划件原写的「跨文件 `external`」在实测下不成立，已订正）。
    private var givenSlotDefs: [String] = []
    private var givenSlotNames: Set<String> = []
    /// ADR-001 `P2b`：合成的**初始化函数** `ptr @__given_init_<T>(ptr %out)` —— 把该类型的
    /// 字段初值写进运行时给的缓冲。与 LazyRef 那条 wrapper 同理：一次合成、按类型去重。
    private var givenInitializerDefs: [String] = []
    private var givenInitializerNames: Set<String> = []

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
    /// This sits in the emitter rather than in the IR tree on purpose: it is
    /// a code-generation environment input, not a language-semantics
    /// decision, and the IR tree stays a pure lowering of the source.
    public var programBase: String?

    public init() {}

    // MARK: - Module

    public func emit(module: IRModule) -> String {
        var header = "; Pini LLVM IR\n"
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
        header += "declare ptr @bk_array_append(ptr, ptr, i32, i32)\n"
        header += "declare void @bk_handle_retain(ptr)\n"
        header += "declare ptr @bk_handle_ensure_unique(ptr)\n"
        header += "declare ptr @bk_array_ensure_unique_at(ptr, i32)\n"
        header += "declare void @bk_panic(ptr) noreturn\n"
        // ADR-001 `P2b`：默认实例取用（`slot` = 存放位地址，`init_fn` = 合成初始化函数，
        // `bytes` = 聚合体大小）。与 `bk_array_*` 同规：无条件声明，未用到时是无害的前向声明。
        header += "declare ptr @bk_given_get(ptr, ptr, i64)\n"
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
        // Collection release: the runtime owns the share count, so a destroy
        // on a handle that is still aliased only drops this holder's share.
        header += "declare void @bk_array_destroy(ptr)\n"
        header += "declare void @bk_dict_destroy(ptr)\n"
        header += "declare void @bk_set_destroy(ptr)\n"
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
        usesFileWrite = false
        usesFileRead = false
        usesReadLine = false
        usesTaskRuntime = false
        usesTaskArgRelease = false
        usesSleepShim = false
        usesCharacterShims = false
        usesProcessShims = false
        usesStringShims = false
        usesTaskFrame = false
        usesSchedBinding = false
        frameMode = .none
        blockDepth = 0
        frameSlotDecls = []
        yieldPointCount = 0
        usesNominalBoxes = false
        usesCapturedSlots = false
        capturedNamesInFunction = []
        releaseFunctionDefs = []
        releaseFunctionNames = []
        copyFunctionDefs = []
        copyFunctionNames = []
        taskBodyDefs = []
        taskBodyNames = []
        lazyrefWrappers = []
        lazyrefWrapperNames = []
        givenSlotDefs = []
        givenSlotNames = []
        givenInitializerDefs = []
        givenInitializerNames = []
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
        // ⭐ 2026-10-01（名义箱上堆）：**三族名义箱的第 0 格一律是 `i32` 引用计数** ——
        // `%struct` 与 `%object` 由此同形，`%enum` 的用例标签顺延到第 1 格。
        // 头固定在 0 格是刻意的：分配 / retain / release / 释放胶水都只认这一个偏移。
        // ⚠️ 箱的分配点见 `emitNominalAllocation`（⛔ 不再是栈 `alloca`）。
        for typeDecl in module.types {
            let aggregate = "%\(typeDecl.isObject ? "object" : "struct").\(IRName.mangle(typeDecl.name))"
            var fieldTypes = ["i32"]
            fieldTypes.append(contentsOf: typeDecl.fields.map { $0.type.llvmSpelling })
            bodyIR += "\(aggregate) = type { \(fieldTypes.joined(separator: ", ")) }\n"
        }
        for enumDecl in module.enums {
            let aggregate = "%enum.\(IRName.mangle(enumDecl.name))"
            // 第 0 格 = 引用计数头，第 1 格 = 用例标签（2026-10-01 · 名义箱上堆）。
            var fieldTypes = ["i32", "i32"]
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
        // G15: `writeFile`'s declares + mode-string constant, appended only for
        // modules that actually write. ⚠️ `readFile` is **not** here any more
        // (2026-10-01): it reads through the runtime shim, so neither `fread`
        // nor the `"r"` mode string has an emitter-side user left.
        if usesFileWrite {
            tail += "declare ptr @fopen(ptr, ptr)\n"
            tail += "declare i64 @fwrite(ptr, i64, i64, ptr)\n"
            tail += "declare i32 @fclose(ptr)\n"
            tail += "@.fopen_w = private constant [2 x i8] c\"w\\00\"\n"
        }
        if usesFileRead {
            tail += "declare ptr @bk_read_file(ptr)\n"
        }
        // G17: `readLine` pulls in the libc line reader and the stdin stream
        // global (macOS `__stdinp`, the legacy module header's spelling).
        if usesReadLine {
            tail += "declare ptr @fgets(ptr, i32, ptr)\n"
            tail += "@__stdinp = external global ptr\n"
        }
        // 并发面（`DE-3c`）：任务族的 C ABI。与前几处同规 —— 只有真发过派发 / 等待 / 剪枝的
        // 模块才带它们。本段只接三个符号（派发 · 阻塞等待 · 剪枝）；`join_within` / `join_all` /
        // `cancel` / `is_cancelled` / `capabilities` 的调用点尚未接线，故这里也不声明它们。
        if usesTaskRuntime {
            tail += "declare ptr @bk_task_spawn(ptr, ptr, ptr, i32, i32)\n"
            tail += "declare i32 @bk_task_join(ptr, ptr)\n"
            tail += "declare void @bk_task_detach(ptr)\n"
            if usesTaskArgRelease {
                tail += "declare void @bk_handle_release(ptr)\n"
            }
        }
        // 让出族（`DE-6b`）：帧的取用、帧内取槽、可让出的等待。与上面同规 —— 只有真发过的模块才带。
        if usesTaskFrame {
            tail += "declare ptr @bk_task_frame(i64)\n"
            tail += "declare ptr @bk_task_slot(i64)\n"
            tail += "declare i32 @bk_task_await(ptr, ptr)\n"
        }
        if usesSleepShim {
            tail += "declare void @bk_sleep(i32)\n"
        }
        // 字符内建（G-3a）与宿主环境查询（P4-1b / M8）的**运行时段落地**。
        // ⚠️ 与上面同规：只有真调用过才带这几个 declare ⇒ 不碰它们的程序 IR 逐字节不变。
        // ⛔ 谓词与 `ord` 一律 `i32` 返回（收敛到 i1 由调用点做，见 `.call` 那条注释）。
        if usesCharacterShims {
            tail += "declare ptr @bk_chars(ptr)\n"
            tail += "declare ptr @bk_chr(i32)\n"
            tail += "declare i32 @bk_ord(ptr)\n"
            tail += "declare i32 @bk_is_letter(ptr)\n"
            tail += "declare i32 @bk_is_number(ptr)\n"
        }
        if usesProcessShims {
            tail += "declare ptr @bk_argv()\n"
            tail += "declare ptr @bk_list_dir(ptr)\n"
        }
        if usesCapturedSlots {
            tail += "declare ptr @bk_slot_alloc(i64)\n"
        }
        if usesNominalBoxes {
            tail += "declare ptr @bk_nominal_alloc(i64)\n"
            tail += "declare void @bk_nominal_retain(ptr)\n"
            tail += "declare i32 @bk_nominal_release(ptr)\n"
        }
        if usesStringShims {
            tail += "declare ptr @bk_substring(ptr, i32, i32)\n"
            tail += "declare i32 @bk_string_count(ptr)\n"
            tail += "declare ptr @bk_string_char_at(ptr, i32)\n"
            tail += "declare ptr @bk_string_slice(ptr, i32, i32, i32, i32)\n"
            tail += "declare ptr @bk_string_upper(ptr)\n"
            tail += "declare ptr @bk_string_lower(ptr)\n"
            tail += "declare i32 @bk_string_contains(ptr, ptr)\n"
        }
        // 调度驱动面（`Q-4` 乙段）：派发点把调度器绑定交给运行时。与上面同规 ——
        // 只有真发过派发的模块才带。⚠️ 观测符号 `bk_task_state` **不在这里** ——
        // 它没有调用点（发射层从不发射它），它是给宿主与判据用的 C ABI 观测面。
        if usesSchedBinding {
            tail += "declare i32 @bk_task_bind_sched(ptr, ptr)\n"
        }
        // ADR-001 `P2b`：默认实例的存放位。模块级全局、初值 null ⇒ 首调由运行时建盒。
        for def in givenSlotDefs {
            tail += def
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
        for def in givenInitializerDefs {
            closureTail += def
        }
        // 名义箱的释放胶水（2026-10-01）：按类型合成、只在真用到时才有内容。
        for def in releaseFunctionDefs {
            closureTail += def
        }
        // 值语义的拷贝胶水（片 C）：同上，只为结构体合成。
        for def in copyFunctionDefs {
            closureTail += def
        }
        for def in taskBodyDefs {
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

    private func emitFunction(_ function: IRFunction) {
        builder.reset()
        scopes = [[:]]
        slotCounters = [:]
        controlStack = []
        breakMergeLabels = []
        deferScopeBase = 0
        pendingDefers.removeAll()
        // Frame 0 of this function is its body block, pushed by the
        // `emitBlock` call below; `emitBlock` leaves that frame to the exit
        // paths here (see `emitReleases` in the fall-through tail).
        pendingReleases.removeAll()
        terminated = false
        currentIsMain = function.name == "main"
        currentReturnType = function.returnType
        blockDepth = 0
        frameSlotDecls = []
        yieldPointCount = 0
        // `DE-6b`：**只有「会被派发的异步体」**走帧式 —— 判据与 `emitTaskSpawn` 的进入条件
        // **逐字同源**（`isAsync` 且返回 `Result`）。⛔ 为什么要同源而不是「凡是异步就帧式」：
        // `=> ()` 的异步函数今天在发射层走的是**直呼**那条路（已登记的静默降级缺陷），
        // 而帧式要求「进入体时必然有一个当前任务」⇒ 若把它也帧式，那条路会从「静默同步执行」
        // 变成「响亮拒绝」，等于顺手改了本批 scope 之外的一件事。
        frameMode = (function.isAsync && isResultReturning(function)) ? .resumable : .none
        // 片 D：本函数里被闭包捕获的名字 —— 捕获槽由此改走堆分配（`declareValueSlot`）。
        // ⚠️ 收集范围是整个函数体（含嵌套闭包）⇒ **宁可宽**：同名局部会多上一次堆，
        // 无害；漏收才会让某个槽留在栈上，而那正是跨帧才炸的那一类。
        capturedNamesInFunction = capturedNames(in: function.body)

        // main is the process entry: emitted with i32 return regardless of
        // the Pini-level void signature (bare returns become `ret i32 0`).
        let returnSpelling =
            currentIsMain
            ? "i32"
            : (function.returnType?.llvmSpelling ?? "void")
        // ⛔ 形参 SSA 名**不能**直接用源码名（规则与理由见 `parameterSSANames`）：
        // 发射器自有的局部名有两族 —— `%t<数字>`（临时值）与 `%<名字>_slot[_<k>]`（Pini 级
        // 局部槽）—— 源码里的形参名若恰好落进这两族，同一个函数里就会出现两个同名局部值，
        // 而 clang 的处置是**拒绝整段模块**（`multiple definition of local value named 'X'`），
        // 同时 `emit` 自身 **rc=0**（静默产出不可用 IR）。
        let paramNames = parameterSSANames(function.params.map { $0.name })
        let params = zip(function.params, paramNames).map { "\($0.0.type.llvmSpelling) %\($0.1)" }
        let header = "define \(returnSpelling) @\(Self.mangle(function.name))(\(params.joined(separator: ", "))) {\n"

        // 体先写进 `bodyIR`（此时它被清空），收尾时再与 `header` / 帧序拼起来。
        // ⚠️ 两个顺序都不能颠倒：① 帧序里那串 `bk_task_slot` 的**顺序**由体走出来的声明顺序决定，
        // 所以序只能**在体之后**生成，却要**排在体之前**；② `bodyIR` 是**模块级累积缓冲**
        // （每个函数都往里加），故本函数那一段必须单独攒、最后接回原缓冲 —— 直接清空会把前面
        // 已发射的函数整段抹掉，而那种损坏在 IR 文本里只是「少了一个 define」，不报错。
        let emittedFunctions = bodyIR
        bodyIR = ""

        for (index, param) in function.params.enumerated() {
            let spelling = param.type.llvmSpelling
            // ⚠️★ 形参槽走 `freshSlot` 的**同一计数器**，⛔ 不再手工拼 `%<名字>_slot`：
            // 形参与体内同名局部（自举 `common.pini` 的 `var span = span`）各声明一个槽，
            // 手工命名会让两条路都取到 `%span_slot` —— 同一个函数里两个同名局部值。
            // 计数器把「第二个同名者」推到 `%span_slot_1`；⚠️ 不相撞时计数为 0 ⇒ **原样**，
            // 既有 golden IR 逐字节不变。
            // 片 D：形参同样可能被闭包捕获（E 探针那类形态的入口）。
            let slot = declareValueSlot(
                named: freshSlot(for: param.name), spelling: spelling,
                captured: capturedNamesInFunction.contains(param.name))
            bodyIR += builder.fmtStore(value: "%\(paramNames[index])", type: spelling, ptr: slot) + "\n"
            scopes[scopes.count - 1][param.name] = slot
        }

        emitBlock(function.body)

        if !terminated {
            bodyIR += builder.fmtBr(labelName: "exit_block") + "\n"
            bodyIR += "exit_block:\n"
            // H1-B: the top-level scope's handles are released here, on the
            // fall-through edge. A `return` emits its own copy before its
            // `ret`, so the two paths never both run.
            emitReleases(downTo: 0)
            if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else if let returnType = function.returnType {
                bodyIR += " ret \(returnType.llvmSpelling) undef\n"
            } else {
                bodyIR += " ret void\n"
            }
        }

        let statements = bodyIR
        if frameMode == .resumable {
            bodyIR = emittedFunctions + header + emitFramePrologue() + "de6b.body:\n" + statements + "}\n\n"
        } else {
            bodyIR = emittedFunctions + header + statements + "}\n\n"
        }
        frameMode = .none
    }

    /// 该函数会不会被 `emitTaskSpawn` 接住（`isAsync` 且返回 `Result`）。
    ///
    /// ⭐ 抽成一个函数而不是在两处各写一遍：帧式的启用条件必须与派发点的进入条件**逐字同源**，
    /// 否则会出现「派发了但没有帧」或「有帧却从未被派发」这两种都很难查的错配。
    private func isResultReturning(_ function: IRFunction) -> Bool {
        guard let returnType = function.returnType else { return false }
        if case .result = returnType { return true }
        return false
    }

    /// 声明一个 **Pini 级局部槽**，返回它的地址名。
    ///
    /// - 普通体（`.none`）：`alloca`，即 `DE-6b` 之前的形状，**一字未改**。
    /// - 可恢复体（`.resumable`）：落在**帧**里 —— 因为体让出等于**从栈返回**，栈上的槽活不过
    ///   那一次返回，而续跑要读的正是这些槽。
    ///
    /// ⭐ 地址名是**确定性**的（由槽名派生），不是 `freshTemp()`：帧槽的**取得代码**与**引用它的
    /// 体代码**分处两个 buffer（体在前、帧序在后），用匿名临时名会让体引用一个还没生成的名字。
    private func declareLocalSlot(named slot: String, spelling: String) -> String {
        guard frameMode == .resumable else {
            bodyIR += builder.fmtAlloca(name: slot, type: spelling) + "\n"
            return slot
        }
        let address = "%de6b." + slot.dropFirst()
        frameSlotDecls.append((name: address, spelling: spelling))
        return address
    }

    /// 声明一个**值变量**的槽：被闭包捕获的那一族走**堆槽**，其余照旧（栈 `alloca` / 帧槽）。
    ///
    /// ⭐ 为什么捕获的那一族必须上堆（2026-10-01 片 D）：闭包 env 里存的就是**这个槽的
    /// 地址**，而闭包可能比创建帧活得久 —— 栈上的槽随帧作废（E 探针：原生 `E2 -255950759`，
    /// 解释器 `101`）。上堆之后，帧与闭包读写的是同一个盒。
    /// ⚠️ 堆槽**不登记释放**：寿命归闭包（本批如实登记这条边界 —— 见报告）。
    /// ⚠️ 可恢复体（`.resumable`）仍走帧槽：帧本身由运行时持有，与捕获槽同一份存储。
    private func declareValueSlot(named slot: String, spelling: String, captured: Bool) -> String {
        guard captured, frameMode != .resumable else {
            return declareLocalSlot(named: slot, spelling: spelling)
        }
        usesCapturedSlots = true
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: spelling, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = call ptr @bk_slot_alloc(i64 \(sizeTemp))\n"
        let typed = builder.freshTemp()
        bodyIR += " \(typed) = bitcast ptr \(raw) to \(spelling)*\n"
        return typed
    }

    /// 帧序（`DE-6b`）：取帧 → 读续跑点并清零 → **按声明顺序**取槽 → 按续跑点分派。
    ///
    /// - Returns: 一段**完整**的 IR 文本（自带终结指令），由调用方排在函数体之前。
    private func emitFramePrologue() -> String {
        usesTaskFrame = true
        var ir = ""
        let frame = "%de6b.frame"
        ir += " \(frame) = call ptr @bk_task_frame(i64 0)\n"
        // ⛔ 没有当前任务就没有帧可依 —— 而**没有帧的体连一块局部变量都放不下**。
        // 故这条路**响亮拒绝**，不静默降级：`.result` 异步体只该经派发进入（`emitTaskSpawn`），
        // 走到这里说明有人绕过了派发（函数值 adapter）。⚠️ 与 `.none` 那条路的分界：
        // `=> ()` 的直呼**不在**帧式之内（见 `frameMode` 的赋值处），它的既有行为不受影响。
        ir += " \(frame)_is_null = icmp eq ptr \(frame), null\n"
        ir += " br i1 \(frame)_is_null, label %de6b.frameless, label %de6b.alloc\n"
        ir += "de6b.frameless:\n"
        // ⚠️ 这里**不能**用 `emitStringConstant`：它把取串的 GEP 写进 `bodyIR`，而帧序排在体之前
        // ⇒ 那个 GEP 会落在**不支配**帧序块的另一个块里，IR 非法。故只登记常量、自己发 GEP。
        let message = registerStringConstant(
            "Pini runtime error: an async body was entered without a task — dispatch it instead of calling it")
        ir +=
            " "
            + builder.fmtGEP(
                name: "%de6b.panic.msg", aggregate: "[\(message.length) x i8]", base: message.name,
                indices: [0, 0]) + "\n"
        ir += " call void @bk_panic(ptr %de6b.panic.msg)\n"
        ir += " unreachable\n"
        ir += "de6b.alloc:\n"
        let resumePoint = "%de6b.resume.point"
        ir += " \(resumePoint) = load i64, ptr \(frame)\n"
        // 读完即清零 ⇒ 体在本次进入之后要么写下新的续跑点（再让出），要么让它保持 0（真跑完）。
        // wrapper 正是靠「跑完之后这个字是不是 0」区分两态 —— 不必再加一个标志字。
        ir += builder.fmtStore(value: "0", type: "i64", ptr: frame) + "\n"
        for decl in frameSlotDecls {
            ir += " \(decl.name) = call ptr @bk_task_slot(i64 \(slotSizeExpression(decl.spelling)))\n"
        }
        let resumed = "%de6b.resumed"
        ir += " \(resumed) = icmp ne i64 \(resumePoint), 0\n"
        ir += " br i1 \(resumed), label %de6b.dispatch, label %de6b.body\n"
        ir += "de6b.dispatch:\n"
        if yieldPointCount == 0 {
            ir += " br label %de6b.body\n"
        } else {
            let cases = (1...yieldPointCount).map { "i64 \($0), label %de6b.resume.\($0)" }
            ir += " switch i64 \(resumePoint), label %de6b.body [ \(cases.joined(separator: " ")) ]\n"
        }
        return ir
    }

    /// 某个 LLVM 类型的**字节数**，写成 IR 常量表达式。
    ///
    /// ⭐ 为什么在 IR 里算而不是在 Swift 侧查表：本仓**没有**「类型 → 字节数」的通用能力
    /// （容器元素那两张表都只枚举有限类型、聚合一律拒绝），而帧要放任意类型的局部槽。在 Swift 侧
    /// 另算一套布局就成了「同一件事两处各算一次」—— 一旦与 LLVM 自己的规则不一致，帧里就是
    /// **错位的槽**：不崩溃，只是值从错误的地址进出。⚠️ `ptrtoint (getelementptr (T, null, 1))`
    /// 让 LLVM 自己回答尺寸，两处因而不存在不一致的可能。
    private func slotSizeExpression(_ spelling: String) -> String {
        "ptrtoint (ptr getelementptr (\(spelling), ptr null, i64 1) to i64)"
    }

    // MARK: - Statements

    ///
    /// `seedingReleases` prepopulates the block's release frame with handles
    /// whose declaration code was emitted *before* the block opened — the
    /// `for … in` element bindings are alloca'd ahead of their body, so they
    /// belong to the body block's frame even though they are not statements
    /// inside it.
    private func emitBlock(_ block: IRBlock, seedingReleases seed: [ReleasedHandle] = []) {
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
        let releaseBase = pendingReleases.count
        pendingReleases.append(seed)
        blockDepth += 1
        defer { blockDepth -= 1 }
        for statement in block {
            if terminated { break }
            emitStatement(statement)
        }
        if terminated {
            // A panic never runs defers — drop the frame. A return/break/
            // continue already flushed copies of the frames it unwound
            // through before its jump, and the block tail is unreachable.
            // The root frame (releaseBase == 0) outlives its block: it
            // represents the function's top-level scope and is owned by the
            // function's exit paths, not by this call.
            if releaseBase > 0 {
                _ = pendingReleases.removeLast()
            }
            _ = pendingDefers.removeLast()
        } else {
            flushDefers(downTo: frameBase)
            // H1-B: a block's own handles drop their shares as control falls
            // out of it, before the caller emits its jump (a loop body runs
            // this every iteration). The function body's own frame is the one
            // exception — its handles belong to the top-level scope and are
            // released at the function exit, so `exit_block` (or the `return`
            // path) is where they are cleaned up, not the body's last
            // statement.
            if releaseBase > 0 {
                emitReleases(downTo: releaseBase)
                _ = pendingReleases.removeLast()
            }
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
    private var pendingDefers: [[IRBlock]] = []

    /// A local holding one share of a refcounted collection handle, whose
    /// share this block must drop when it exits (H1-B, `pendingDefers`'
    /// sibling). `slot` and `typeSpelling` are snapshotted at registration so
    /// a later same-name redeclaration cannot release through the wrong slot.
    private struct ReleasedHandle {
        let slot: String
        let typeSpelling: String
        let destroySymbol: String
    }

    /// Collection handles to release per open block scope, in declaration
    /// order (release runs in reverse). Frames are pushed by `emitBlock`, so
    /// the frame stack tracks block scopes exactly; the function body's own
    /// frame is left to the function exit, matching the legacy emitter's
    /// top-level scope handling.
    private var pendingReleases: [[ReleasedHandle]] = []

    /// The `bk_*_destroy` symbol that drops one share of an opaque collection
    /// handle, or nil when the spelling is not one of the three refcounted
    /// families. Other handle-like types (lazyref pointers, foreign pointers)
    /// have no share count and are not tracked here.
    private static func collectionDestroySymbol(for typeSpelling: String) -> String? {
        switch typeSpelling {
        case "%bk_array*": return "bk_array_destroy"
        case "%bk_dict*": return "bk_dict_destroy"
        case "%bk_set*": return "bk_set_destroy"
        default: return nil
        }
    }

    /// Register a freshly declared local so its block exit drops its share of
    /// the handle. Same-slot duplicates within one frame are skipped: a
    /// shadowing redeclaration reuses the name, and releasing twice would drop
    /// two shares for one holder (over-release → use-after-free).
    private func registerReleasedHandle(slot: String, type: IRType) {
        guard let symbol = releaseSymbol(for: type) else { return }
        guard !pendingReleases.isEmpty else { return }
        let frame = pendingReleases.count - 1
        guard !pendingReleases[frame].contains(where: { $0.slot == slot }) else { return }
        pendingReleases[frame].append(
            ReleasedHandle(slot: slot, typeSpelling: type.llvmSpelling, destroySymbol: symbol)
        )
    }

    /// 一个「持有者槽」在退出 / 被覆盖时要调的释放符号；nil = 该类型不在计数族里。
    ///
    /// ⭐ 两族共用**同一条登记通道**（2026-10-01 · 名义箱上堆）：容器句柄用 `bk_*_destroy`，
    /// 名义箱用合成胶水 `__release_*` —— 下游（`emitReleases` / `emitReassignRelease`）
    /// 只认符号名，不关心是哪一族。⛔ 也正因如此，**改族别不会漏掉释放点**：
    /// 释放点只问「这个类型要不要释放」，不问「它是谁」。
    private func releaseSymbol(for type: IRType) -> String? {
        if nominalKindSpelling(type) != nil { return ensureReleaseFunction(for: type) }
        return Self.collectionDestroySymbol(for: type.llvmSpelling)
    }

    /// Emit one `bk_*_destroy` per registered handle in frames `base...`
    /// (innermost frame first, and within a frame the reverse of declaration
    /// order), WITHOUT popping the frames. A terminator and a block tail are
    /// separate runtime paths over the same statically emitted code, so each
    /// emits its own copy — the same contract `flushDefers` follows.
    private func emitReleases(downTo base: Int) {
        guard base < pendingReleases.count else { return }
        for frame in pendingReleases[base...].reversed() {
            for handle in frame.reversed() {
                let loaded = builder.freshTemp()
                bodyIR +=
                    builder.fmtLoad(
                        name: loaded, type: handle.typeSpelling, ptr: handle.slot
                    ) + "\n"
                bodyIR += " call void @\(handle.destroySymbol)(ptr \(loaded))\n"
            }
        }
    }

    /// Drop the share held by `slot` before it is overwritten by a new value
    /// (reassignment is a release point, not just a store). Only slots that
    /// were registered for release are eligible, so a variable of a non-handle
    /// type is never touched.
    private func emitReassignRelease(slot: String) {
        guard
            pendingReleases.contains(where: { frame in
                frame.contains(where: { $0.slot == slot })
            })
        else { return }
        guard
            let registered =
                pendingReleases
                .flatMap({ $0 })
                .first(where: { $0.slot == slot })
        else { return }
        let loaded = builder.freshTemp()
        bodyIR +=
            builder.fmtLoad(
                name: loaded, type: registered.typeSpelling, ptr: slot
            ) + "\n"
        bodyIR += " call void @\(registered.destroySymbol)(ptr \(loaded))\n"
    }

    /// 字段被覆盖前释放旧值 —— `emitReassignRelease` 的**字段版**。
    ///
    /// ⚠️ 与槽那版的一处结构差异：槽的释放符号在登记时就固定了（写进 `ReleasedHandle`），
    /// 字段这里**当场问类型**（`releaseCallee`）—— 字段的布局来自静态声明，
    /// 对同一字段的两次写一定是同一个类型。
    /// ⚠️ 旧值可能是 null（无默认值字段刚构造出来）：容器那一族因此走判空分支
    /// （由 `emitReleaseCall` 发），名义一族不必 —— 见 `releaseCallee`。
    private func emitFieldReassignRelease(fieldPtr: String, type: IRType) {
        guard let callee = releaseCallee(for: type) else { return }
        let old = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: old, type: type.llvmSpelling, ptr: fieldPtr) + "\n"
        emitReleaseCall(
            callee: callee, valueName: old, spelling: type.llvmSpelling, tag: "w\(builder.freshLabel())")
    }

    private func emitStatement(_ statement: IRStmt) {
        switch statement {
        case .allocVar(let name, let type, _, let initializer):
            let slot = freshSlot(for: name)
            // 片 D：被闭包捕获的变量走**堆槽**（闭包与帧共享同一个盒）。
            let address = declareValueSlot(
                named: slot, spelling: type.llvmSpelling,
                captured: capturedNamesInFunction.contains(name))
            // ⚠️★ 绑定的**登记**排在初始化式求值**之后**（槽名与 `alloca` 仍在原处，
            // 故不相撞的程序 IR 逐字节不变）。理由：`var x = <expr>` 里的 `<expr>` 在
            // **旧**作用域里求值 —— 这是解释器的语义。旧形状先登记后求值 ⇒
            // `var span = span`（自举 `common.pini`，与形参同名）生成
            // 「`load` **自己刚分配、还没写过**的槽 → 存回自己」⇒ 后续 `span.startLine`
            // 解引用未初始化指针。实证：`render` 空指针崩溃（`KERN_INVALID_ADDRESS at 0x0`）。
            // ⭐ 与形参槽那处（`freshSlot` 计数器）、与 `stringSubstring` 那处同属一族：
            // **遮蔽名字时的「谁先谁后」**——三处都是顺序错，不是算错。
            if let initializer = initializer {
                if frameMode == .resumable, blockDepth == 1, case .join(let awaited, _, .awaits) = initializer {
                    scopes[scopes.count - 1][name] = address
                    emitYieldPoint(awaited: awaited, type: type, produce: .frameSlot(address))
                } else {
                    let value = emitExpr(initializer)
                    scopes[scopes.count - 1][name] = address
                    // 值语义（片 C）：结构体别名 ⇒ 拷出新箱；对象 / 枚举 / 容器别名 ⇒ retain；
                    // 临时值 ⇒ 直接接管。⛔ 这一步必须在 store **之前** —— 它是「站住」那一步。
                    let stored = emitValueForStorage(initializer, value, type: type)
                    bodyIR += builder.fmtStore(value: stored.ssaName, type: type.llvmSpelling, ptr: address) + "\n"
                }
            } else {
                scopes[scopes.count - 1][name] = address
                // ⚠️★ 没有初始化式的变量槽**必须清零**（2026-10-01 · 片 B 的配套）：
                // 这种槽会被下面的 `registerReleasedHandle` 登记，退出 / 被覆盖时
                // 按计数释放 —— 而栈 `alloca` 里是**垃圾**。实测（自举 `ast` 层）：
                // 退出时 `bk_nominal_release` 写在代码段上，SIGBUS / KERN_PROTECTION_FAILURE。
                // 零 = `null` =「还没有箱」：释放路径对它是无操作（`bk_nominal_release(null)`
                // 返回 0；容器那一族走判空分支）。
                // ⚠️ 只对**参与计数**的类型发这条 store：不变量类型（标量 / 字符串 / 外呼指针）
                // 的 IR 与改动前逐字节相同。
                if releaseSymbol(for: type) != nil {
                    bodyIR += builder.fmtStore(value: zeroConst(for: type), type: type.llvmSpelling, ptr: address) + "\n"
                }
            }
            // H1-B: the fresh local holds one share of its handle; drop it
            // when the declaring block exits.
            registerReleasedHandle(slot: address, type: type)

        case .storeVar(let name, let type, let value):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: store to undeclared variable '\(name)' (IRLowerer guarantees declarations)")
            }
            let lowered = emitExpr(value)
            // ⚠️★ 三行的顺序就是语义（2026-10-01 片 C）：**先**让新值站住（结构体 ⇒ 拷出
            // 新箱；对象/枚举/容器别名 ⇒ retain），**再**释放旧值，最后才写槽。
            // 旧形状把 `emitRetainIfAliased` 排在释放**之后** ⇒ `a = a` 这类自赋值会
            // 先把新值要读的那个箱回收掉（读已释放内存）。⭐ 与既有的三处同族：**顺序错**。
            let stored = emitValueForStorage(value, lowered, type: type)
            // H1-B: overwriting a handle-typed local drops the share it held
            // before the store replaces it. The runtime only decrements, so an
            // alias still holding the old handle keeps it alive.
            emitReassignRelease(slot: slot)
            bodyIR += builder.fmtStore(value: stored.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            emitIf(label: label, condition: condition, thenBody: thenBody, elseBody: elseBody)

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
            // ⚠️★ 下面三行的**顺序就是语义**，⛔ 不是风格（H1-B 之后的第二处修正）：
            //   「求值 → 若与局部**别名**则留一份 → 再释放 → ret」。
            // 旧形状把释放排在求值**之前**（`emitReleases` 紧跟 `flushDefers`），于是
            // `return <局部容器>` 交出的是**已被回收**的悬垂句柄 —— 实证：自举
            // `splitLines` 的 `return lines` 生成 `call void @bk_array_destroy(...)`
            // 紧接 `ret %bk_array*`，调用方第一次 `len()` 就撞进已释放的 box
            // （`KERN_INVALID_ADDRESS`，帧落 `bk_array_len`）。
            // ⭐ 判据不是「释放对不对」（它本来就该释放局部）而是**顺序**：所有权契约里
            // 返回值是**转移**出去的那一份，先把它扣住，局部释放才不会把它一起带走。
            // ⚠️★ 这个 `var` 不是风格：值语义那一步会**换掉**交出去的那个值
            // （结构体别名 ⇒ 拷贝出的新箱）。上一版把它写成 `let` + `_ =`，于是
            // 拷贝做了、`ret` 交出去的却还是**原件** —— 而原件紧接着就被 `emitReleases`
            // 释放掉 ⇒ 调用方拿到悬垂箱（读数：`RETURN 0`，解释器 `7`）。
            var returnedValue: IRValue? = value.map { emitExpr($0) }
            if let returnedNode = value, let current = returnedValue {
                // 值语义（片 C）：结构体别名 ⇒ 拷出新箱交出去；对象 / 枚举 / 容器 ⇒ retain 一份。
                // ⚠️ 没有返回类型（`main`）时退化为原来的别名点 retain —— 那条路不交值。
                if let returnType = currentReturnType {
                    returnedValue = emitValueForStorage(returnedNode, current, type: returnType)
                } else {
                    emitRetainIfAliased(returnedNode, current)
                }
            }
            // H1-B: returning leaves the function outright, abandoning every
            // open scope; the fall-through `exit_block` cleanup is only
            // reached when control does NOT return, so the two never both run.
            emitReleases(downTo: 0)
            if let returnedValue {
                bodyIR += " ret \(returnedValue.llvmType) \(returnedValue.ssaName)\n"
            } else if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else {
                bodyIR += " ret void\n"
            }
            terminated = true

        case .exprStmt(let expr):
            // ⭐ `S1`（`DE-6c`）：`await f()` 独占一行 —— 让出，结果按语言语义**丢弃**。
            // ⛔ 不加这一支的话，这条路会落到 `emitJoin` 的 `.awaits` 拒绝上 —— 一个本该让出的
            // 位置被当成「写错了」，而它其实是降载层明文承诺合法的四个位置之一。
            if frameMode == .resumable, blockDepth == 1, case .join(let awaited, let type, .awaits) = expr {
                emitYieldPoint(awaited: awaited, type: type, produce: .discard)
            } else {
                _ = emitExpr(expr)
            }

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
            let (aggregate, _, fieldIndex) = fieldLayout(of: base, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName, indices: [0, fieldIndex]) + "\n"
            // ⚠️ 顺序同 `storeVar`：新值先站住（拷贝 / retain），**再**释放字段旧值，最后写。
            let stored = emitValueForStorage(value, loweredValue, type: fieldType)
            // 字段是**持有者**：被覆盖前先释放旧值（与 `emitReassignRelease` 同规，落点是字段）。
            emitFieldReassignRelease(fieldPtr: fieldPtr, type: fieldType)
            bodyIR += builder.fmtStore(value: stored.ssaName, type: fieldType.llvmSpelling, ptr: fieldPtr) + "\n"

        case .captureMarker:
            // Marker only — captures are materialized by the closure literal
            // emission (env slot pointers), nothing to emit here.
            break

        case .detachStmt(let inner):
            // `DE-3c`：`detach` 是**剪枝** —— 从父 scope 摘掉、主动退出所有权
            // （fire-and-forget 的唯一合法出口）。它与等待不同：**不消费结果**，
            // 于是没有 `out` 缓冲，也不解构任何东西。
            //
            // 这一段此前写着「按构造不可达、到了这里就是坏了不说缺功能」。那句话在写下时
            // 是准的（那时的降载与执行面都还没接通），但 `detach` 早经另一条路径可达
            // （下位机已有 `.detachStmt` 的降载与执行支），于是它同时是**过时的**。
            usesTaskRuntime = true
            let handle = emitExpr(inner)
            guard handle.llvmType == "ptr" else {
                fatalError("IREmitter: detach operand is not a task handle (IRLowerer gates the operand)")
            }
            bodyIR += " call void @bk_task_detach(ptr \(handle.ssaName))\n"
        }
    }

    /// `break`: the depth-th enclosing frame's exit (1 = innermost); without
    /// enough enclosing frames, a runtime panic — the interpreter errors when
    /// a break escapes to the top level (probe-verified), so this is
    /// fail-loud parity, not a silent skip. Leaving the frame also leaves its
    /// body block, so the defer frames down to that body's own frame run
    /// before the jump.
    ///
    /// The frame this leaves may be a labeled `if` rather than a loop
    /// (标签 break 定向范围). Its exit is an `if.end.N` merge label, which `emitIf` would
    /// otherwise skip when both branches end in their own terminators — so the
    /// label is recorded as targeted. A loop's exit label needs no such note:
    /// `emitWhile`/`emitForIn` emit it unconditionally.
    private func emitBreak(depth: Int) {
        if controlStack.count >= depth {
            let frame = controlStack[controlStack.count - depth]
            flushDefers(downTo: frame.deferBase)
            // H1-B: breaking abandons the body scope (and every scope
            // nested inside it) before the jump, so their handles are released
            // here. Iterations that end normally release the same handles at
            // the body block's tail — separate runtime paths, separate copies
            // of the same release code.
            emitReleases(downTo: frame.releaseBase)
            if !frame.isLoop { breakMergeLabels.insert(frame.exit) }
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
    /// form (depth > 1) jumps to the depth-th frame's header. The checker
    /// rejects a continue outside any loop, so the panic here is fail-loud
    /// parity. Ending the iteration leaves the loop's body block, so the defer
    /// frames down to that block's frame run before the jump.
    ///
    /// ⚠️ The `depth > 1` target is **not** interpreter parity, despite what
    /// this comment used to claim. The interpreter runs the target loop's step
    /// on a matching `continue`, while `header` is that loop's *condition*: for
    /// a `while` with a step this skips the step, and for a `for` it skips the
    /// increment and re-enters the bounds check with the index unchanged. That
    /// is a defect of its own, older than and independent of 标签 break 定向范围 (which
    /// only widened the frame stack to include `if` blocks), and it is filed
    /// separately rather than fixed here.
    private func emitContinue(depth: Int) {
        if controlStack.count >= depth {
            let frame = controlStack[controlStack.count - depth]
            flushDefers(downTo: frame.deferBase)
            // H1-B: ending the iteration early abandons the scopes it held;
            // release them before the jump (same contract as emitBreak).
            emitReleases(downTo: frame.releaseBase)
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
    /// 判别式的求值 —— `S3`（`DE-6c`）的落点。
    ///
    /// 一般情形就是 `emitExpr(scrutinee)`；⭐ 但当判别式位是一处**可让出的 `await`**（且满足让出点
    /// 那两条前置：可恢复体 · 顶层语句）时，它必须走**让出序列**，并把结果落进**帧槽**再由这里读回。
    ///
    /// ⛔ **为什么不直接用让出序列产出的那个 SSA 值**：体让出等于**从栈返回**，而续跑是从函数入口的
    /// `switch` 跳进 `de6b.resume.k` 的 —— 让出点所在块里的 SSA 值**不支配**续跑块。
    /// 帧槽是两条路径唯一都够得着的地方（这与 `S2` 存变量槽是同一个理由，不是新机制）。
    ///
    /// ⚠️ 让出序列只在这两条前置都成立时才接得住；不成立时**落到 `emitExpr`**，由 `emitJoin`
    /// 按位置响亮拒绝 —— 那条路不是静默降级。
    private func emitMatchSubject(_ scrutinee: IRExpr, type: IRType) -> IRValue {
        guard frameMode == .resumable, blockDepth == 1,
            case .join(let awaited, _, .awaits) = scrutinee
        else {
            return emitExpr(scrutinee)
        }
        let slot = declareLocalSlot(
            named: "%yield_scrutinee_\(yieldPointCount + 1)", spelling: type.llvmSpelling)
        emitYieldPoint(awaited: awaited, type: type, produce: .frameSlot(slot))
        let loaded = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: loaded, type: type.llvmSpelling, ptr: slot) + "\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: loaded)
    }

    private func emitMatch(scrutinee: IRExpr, cases: [IRMatchCase], scrutineeType: IRType) {
        // ⭐ 判别式**只在这里求值一次** —— `S3`（`DE-6c`）的落点就在这一步（见 `emitMatchSubject`）。
        // 四个分派分支因此拿的都是同一个已物化的值，不存在「某条分支漏走让出」的缝。
        let subject = emitMatchSubject(scrutinee, type: scrutineeType)
        switch scrutineeType {
        case .optional(let wrapped):
            let aggregate = scrutineeType.llvmSpelling
            emitTaggedMatch(
                scrutineeValue: subject, cases: cases, aggregate: aggregate, tagType: "i64",
                tagFor: { $0.caseName == "some" ? "0" : "1" },
                payloadSpelling: { _, _ in wrapped.llvmSpelling },
                loadTag: { [self] base in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), 0\n"
                    return IRValue(llvmType: "i64", ssaName: value)
                },
                loadPayload: { [self] _, base, slot, spelling in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), \(slot + 1)\n"
                    return IRValue(llvmType: spelling, ssaName: value)
                }
            )
        case .enumeration(let enumName):
            guard let aggregate = scrutineeType.nominalAggregateSpelling,
                let enumDecl = moduleEnums.first(where: { $0.name == enumName })
            else {
                fatalError("IREmitter: match on unregistered enum (IRLowerer guarantees)")
            }
            emitTaggedMatch(
                scrutineeValue: subject, cases: cases, aggregate: aggregate, tagType: "i32",
                tagFor: { arm in
                    guard let enumCase = enumDecl.cases.first(where: { $0.name == arm.caseName }) else {
                        fatalError("IREmitter: match case '\(arm.caseName)' not in enum decl (IRLowerer guarantees)")
                    }
                    return String(enumCase.tag)
                },
                payloadSpelling: { (arm, slot) in
                    guard let enumCase = enumDecl.cases.first(where: { $0.name == arm.caseName }) else {
                        fatalError("IREmitter: match case '\(arm.caseName)' not in enum decl (IRLowerer guarantees)")
                    }
                    return enumCase.payloadTypes[slot].llvmSpelling
                },
                loadTag: { [self] base in
                    // 标签在第 1 格（第 0 格是引用计数头，2026-10-01）。
                    let tagPtr = builder.freshTemp()
                    bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: base, indices: [0, 1]) + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: "i32", ptr: tagPtr) + "\n"
                    return IRValue(llvmType: "i32", ssaName: value)
                },
                loadPayload: { [self] _, base, slot, spelling in
                    let fieldPtr = builder.freshTemp()
                    bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: base, indices: [0, slot + 2]) + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: spelling, ptr: fieldPtr) + "\n"
                    return IRValue(llvmType: spelling, ssaName: value)
                }
            )
        case .result(let okType):
            // Result scrutinee (`G72`): tag 0 = ok, 1 = err. The ok payload
            // rides in field 1 and the err payload in field 2 — the erased
            // error word (LR-12), which is why the two sides cannot share one
            // slot formula the way Optional's single payload can.
            //
            // Reaching this case at all is new: before it, a Result scrutinee
            // fell to the `default` arm below, which for a family with no
            // literal patterns emits the scrutinee and drops every arm — so
            // the program ran to completion having executed none of them.
            // Silent, and rc=0. This arm is what makes the tag actually
            // dispatch.
            let aggregate = scrutineeType.llvmSpelling
            emitTaggedMatch(
                scrutineeValue: subject, cases: cases, aggregate: aggregate, tagType: "i64",
                tagFor: { $0.caseName == "ok" ? "0" : "1" },
                payloadSpelling: { arm, _ in arm.caseName == "ok" ? okType.llvmSpelling : "i64" },
                loadTag: { [self] base in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), 0\n"
                    return IRValue(llvmType: "i64", ssaName: value)
                },
                loadPayload: { [self] arm, base, _, spelling in
                    let value = builder.freshTemp()
                    bodyIR += " \(value) = extractvalue \(aggregate) \(base), \(arm.caseName == "ok" ? 1 : 2)\n"
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
                emitScalarMatch(scrutineeValue: subject, cases: cases)
            }
            // 无字面量手臂时**什么都不发**：判别式的求值（含它可能的副作用与让出）已经在
            // `emitMatchSubject` 里做过了。⛔ 不许在这里再求一次 —— 判别式若是 `await`，
            // 再求一次就是**多派发一个任务**（而且那个任务的句柄没人接）。
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
    private func emitScalarMatch(scrutineeValue: IRValue, cases: [IRMatchCase]) {
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
            let nextLabel =
                position + 1 < literalArms.count
                ? checkLabel(literalArms[position + 1].offset)
                : defaultLabel
            bodyIR += "\(checkLabel(index)):\n"
            guard let literal = matchCase.literal,
                let comparison = emitLiteralComparison(literal, scrutinee: scrutineeValue)
            else {
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
    private func emitLiteralComparison(_ literal: IRMatchLiteral, scrutinee: IRValue) -> String? {
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
        scrutineeValue: IRValue,
        cases: [IRMatchCase],
        aggregate: String,
        tagType: String,
        tagFor: (IRMatchCase) -> String,
        payloadSpelling: (IRMatchCase, Int) -> String,
        loadTag: (String) -> IRValue,
        loadPayload: (IRMatchCase, String, Int, String) -> IRValue
    ) {
        let tag = loadTag(scrutineeValue.ssaName)
        let id = builder.freshLabel()
        let endLabel = "match.end.\(id)"
        let panicLabel = "match.fail.\(id)"
        for (caseIndex, matchCase) in cases.enumerated() {
            let armLabel = "match.arm.\(id).\(caseIndex)"
            let fallthroughLabel =
                caseIndex + 1 < cases.count
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
                let value = loadPayload(matchCase, scrutineeValue.ssaName, slot, spelling)
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
    private func emitSubscriptStore(container: IRExpr, index: IRExpr, value: IRExpr, elementType: IRType) {
        // Dictionary store (G5): keys/values boxed by their own types; the
        // returned handle is written back to the owning slot (COW parity).
        if case .dict(let keyType, let valueType) = irType(of: container) {
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
                    fatalError("IREmitter: dict store to undeclared container '\(name)' (IRLowerer guarantees)")
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
                fatalError("IREmitter: subscript store to undeclared container '\(name)' (IRLowerer guarantees declarations)")
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
    private func emitUniqueContainerHandle(_ container: IRExpr) -> IRValue {
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
                let (keySpelling, keyWidth, keyTag) = arrayElementABI(irType(of: index))
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
    /// `try` 操作数的求值 —— `S4`（`DE-6c`）的落点。
    ///
    /// 与 `emitMatchSubject` **同一条理由、同一种做法**（判别式位与 `try` 位在发射层是同一件事：
    /// 都是「一条语句的根部有一个先求值、后分派的操作数」）。⛔ 不合并成一个通用函数是有意的：
    /// 两处的**分派**形态不同（tagged match vs tag→ok/err 两支），能共用的只是这一段求值。
    private func emitTryOperand(_ operand: IRExpr, type: IRType) -> IRValue {
        guard frameMode == .resumable, blockDepth == 1,
            case .join(let awaited, _, .awaits) = operand
        else {
            return emitExpr(operand)
        }
        let slot = declareLocalSlot(
            named: "%yield_operand_\(yieldPointCount + 1)", spelling: type.llvmSpelling)
        emitYieldPoint(awaited: awaited, type: type, produce: .frameSlot(slot))
        let loaded = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: loaded, type: type.llvmSpelling, ptr: slot) + "\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: loaded)
    }

    private func emitTry(operand: IRExpr, errorVar: String, handler: IRBlock, okTarget: String?, type: IRType) {
        // ⚠️ 错误变量的槽在让出点**之前**声明 —— 若它落在栈上，续跑路径（入口 `switch` →
        // `de6b.resume.k`）**不支配**它，续跑之后读到的就是一块悬垂地址。故与其余局部槽同规：
        // 走 `declareLocalSlot`（可恢复体里 = 帧槽；普通体里 = `alloca`，形状一字未改）。
        let errSlot = declareLocalSlot(named: freshSlot(for: errorVar), spelling: "i64")
        scopes[scopes.count - 1][errorVar] = errSlot

        // ⭐ `S4`（`DE-6c`）：`try` 位若是可让出的 `await` ⇒ 走让出序列，结果落帧槽再读回。
        let resultValue = emitTryOperand(operand, type: type)
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
                fatalError("IREmitter: try ok target '\(okTarget)' undeclared (IRLowerer guarantees the allocation)")
            }
            guard case .result(let okType) = type else {
                fatalError("IREmitter: tryStmt type is not a Result (IRLowerer guarantees)")
            }
            terminated = false
            let payload = builder.freshTemp()
            bodyIR += " \(payload) = extractvalue \(aggregate) \(resultValue.ssaName), 1\n"
            bodyIR += builder.fmtStore(value: payload, type: okType.llvmSpelling, ptr: okSlot) + "\n"
        } else {
            terminated = false
        }
    }

    private func emitIf(label: String?, condition: IRExpr, thenBody: IRBlock, elseBody: IRBlock?) {
        let cond = emitExpr(condition)
        let id = builder.freshLabel()
        let thenLabel = "if.then.\(id)"
        let endLabel = "if.end.\(id)"
        let elseLabel = elseBody != nil ? "if.else.\(id)" : endLabel
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: thenLabel, elseLabelName: elseLabel) + "\n"

        // 标签 break 定向范围: a labeled `if` is an interruptible frame, so a `break 标签`
        // inside either branch jumps to `endLabel`. It is not a `continue`
        // target, so its two resume labels are never read; they point at the
        // merge block, which is what "leaving the `if`" resumes at. Each branch
        // gets its own push so the frame's `deferBase`/`releaseBase` name that
        // branch's body frame — the same trick `emitWhile` uses for body/step.
        let isFrame = label != nil

        bodyIR += "\(thenLabel):\n"
        if isFrame {
            controlStack.append(
                ControlFrame(
                    exit: endLabel, header: endLabel, continueTarget: endLabel, isLoop: false,
                    deferBase: pendingDefers.count, releaseBase: pendingReleases.count
                ))
        }
        scopes.append([:])
        terminated = false
        emitBlock(thenBody)
        let thenTerminated = terminated
        if isFrame { controlStack.removeLast() }
        if !thenTerminated {
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        }
        scopes.removeLast()

        var elseTerminated = false
        if let elseBody = elseBody {
            bodyIR += "\(elseLabel):\n"
            if isFrame {
                controlStack.append(
                    ControlFrame(
                        exit: endLabel, header: endLabel, continueTarget: endLabel, isLoop: false,
                        deferBase: pendingDefers.count, releaseBase: pendingReleases.count
                    ))
            }
            scopes.append([:])
            terminated = false
            emitBlock(elseBody)
            elseTerminated = terminated
            if isFrame { controlStack.removeLast() }
            if !elseTerminated {
                bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
            }
            scopes.removeLast()
        }

        // The merge block is skippable only when both branches are covered by
        // an else and both returned — and, since 标签 break 定向范围, only when no `break`
        // jumped to it: such a jump is itself a terminator, so without this the
        // label would be branched to but never defined.
        let endTargeted = breakMergeLabels.contains(endLabel)
        if elseBody != nil && thenTerminated && elseTerminated && !endTargeted {
            terminated = true
        } else {
            bodyIR += "\(endLabel):\n"
            terminated = false
        }
    }

    /// `while cond: body [step: block]` (step: G15, 标签语法反转).
    ///
    /// Layout — the step block sits between body and the back edge, so an
    /// unlabeled `continue` inside the body lands on the **step entry**
    /// (interpreter parity: `shouldRunStep = true` on continue), while a
    /// `continue` inside the step lands on the step's end. `break` targets
    /// the loop exit from either block and skips the step.
    private func emitWhile(condition: IRExpr, loopBody: IRBlock, step: IRBlock?) {
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
        controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, isLoop: true, deferBase: pendingDefers.count, releaseBase: pendingReleases.count))
        scopes.append([:])
        terminated = false
        emitBlock(loopBody)
        controlStack.removeLast()
        if !terminated {
            bodyIR += builder.fmtBr(labelName: step != nil ? stepLabel : condLabel) + "\n"
        }
        scopes.removeLast()

        if let step = step {
            bodyIR += "\(stepLabel):\n"
            // Inside the step, an unlabeled continue goes to its own end
            // (interpreter: continue in the step block → next iteration).
            controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, isLoop: true, deferBase: pendingDefers.count, releaseBase: pendingReleases.count))
            scopes.append([:])
            terminated = false
            emitBlock(step)
            controlStack.removeLast()
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
        elementTypes: [IRType],
        kind: IRForIterableKind,
        iterable: IRExpr,
        body: IRBlock,
        step: IRBlock?
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
        controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, isLoop: true, deferBase: pendingDefers.count, releaseBase: pendingReleases.count))
        scopes.append([:])
        terminated = false
        // Pattern bindings: a fresh slot per iteration (the loop scope makes
        // the previous iteration's binding unreachable, matching the
        // interpreter's per-iteration Environment).
        let indexForBind = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: indexForBind, type: "i32", ptr: indexSlot) + "\n"
        // H1-B: element bindings that are collection handles hold one share
        // for the iteration; collect them for the body block's release frame.
        var patternReleases: [ReleasedHandle] = []
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
            if let symbol = Self.collectionDestroySymbol(for: spelling) {
                patternReleases.append(
                    ReleasedHandle(slot: slot, typeSpelling: spelling, destroySymbol: symbol)
                )
            }
        }
        // The step block shares the loop environment in the interpreter
        // (executeFor runs it with currentEnv = loopEnv), so the pattern
        // variables stay visible there — a bare `v` in `step:` resolves to
        // the body's slot. Hand the same bindings to the step scope.
        let patternBindings = scopes[scopes.count - 1]
        emitBlock(body, seedingReleases: patternReleases)
        controlStack.removeLast()
        if !terminated {
            bodyIR += builder.fmtBr(labelName: step != nil ? stepLabel : incLabel) + "\n"
        }
        scopes.removeLast()

        if let step = step {
            bodyIR += "\(stepLabel):\n"
            controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, isLoop: true, deferBase: pendingDefers.count, releaseBase: pendingReleases.count))
            scopes.append(patternBindings)
            terminated = false
            emitBlock(step)
            controlStack.removeLast()
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

    private func emitExpr(_ expr: IRExpr) -> IRValue {
        switch expr {
        case .intConst(let value, let type):
            // ⚠️ 指针类型上不能写整数字面量：`ret ptr 0` 会让**整个模块**被 lli 拒
            // （integer constant must have integer type）⇒ 指针位的零要写成 `null`。
            // 那个零的**含义**就是空指针 —— 「这个句柄没有指向任何东西」。
            if case .pointer = type, value == 0 {
                return IRValue(llvmType: type.llvmSpelling, ssaName: "null")
            }
            return IRValue(llvmType: type.llvmSpelling, ssaName: String(value))

        case .floatConst(let value):
            return IRValue(llvmType: "double", ssaName: doubleLiteral(value))

        case .boolConst(let value):
            return IRValue(llvmType: "i1", ssaName: value ? "true" : "false")

        case .stringConst(let value):
            return emitStringConstant(value)

        case .load(let name, let type):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: load of undeclared variable '\(name)' (IRLowerer guarantees declarations)")
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
            case .bitwiseNot:
                // `~v` is `v ^ -1`; the operand is I32 (the lowerer gates it).
                bodyIR += " \(temp) = xor \(lowered.llvmType) \(lowered.ssaName), -1\n"
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
            // `DE-3c`：异步被调者的**调用点就是派发点** —— 糖读法（提案件「调度面」的裁定 37）
            // 说的「调用即派发」，在发射层就是这一行。
            //
            // 判据取**被调者自己的** `isAsync`，不取类型：调用节点上带的是**体协议**
            // （`Result`，即被调用方真的返回什么），句柄类型只活在签名表里。这个分叉是
            // `DE-3a` 刻意留的（节点协议 ≠ 表达式类型），于是「这次调用是不是派发」
            // 只有函数自己的事实能回答。
            if let callee = moduleFunctions[Self.mangle(function)], callee.isAsync,
                let bodyReturn = callee.returnType, case .result = bodyReturn
            {
                return emitTaskSpawn(callee: callee, mangled: Self.mangle(function), args: args)
            }
            // G-2R: `F64(x)` is an instruction, not a symbol. Falling through to
            // the generic `call @F64` below would emit IR that references an
            // undefined value while the command still exits zero -- the silent
            // shape the LLVM runtime-surface ticket records, and the reason this
            // case is handled here instead of in the declare pass. A double is
            // already there; anything integral widens with sitofp.
            if function == "F64", args.count == 1 {
                let operand = args[0]
                if operand.llvmType == "double" { return operand }
                let temp = builder.freshTemp()
                bodyIR += " \(temp) = sitofp \(operand.llvmType) \(operand.ssaName) to double\n"
                return IRValue(llvmType: "double", ssaName: temp)
            }

            // 语言层的内建数组方法 `append` 在降载层是**命名调用**（不展开成专门节点），
            // 解释器后端由运行时回答它，而 LLVM 后端此前没有任何符号来回答 ⇒ IR 里引用了未定义值。
            // ⚠️ 它住在**对每个程序无条件生效**的预置声明里 ⇒ 拒绝面是**整个模块**，不是个别程序。
            // 这里把它接到数组族的符号上；元素 ABI 与 `bk_array_set` 取同一张表。
            if function == "Array.append" {
                guard args.count == 2, case .array(let elementType)? = returnType else {
                    fatalError(
                        "IREmitter: the builtin array append needs a receiver plus one element and an array result (IRLowerer guarantees)"
                    )
                }
                return emitArrayAppend(
                    receiver: args[0], elementNode: arguments[1], elementValue: args[1],
                    elementType: elementType)
            }

            let argList = args.map { "\($0.llvmType) \($0.ssaName)" }.joined(separator: ", ")
            // G-3a 的字符内建：解释器侧由 `RuntimeOps.characterBuiltins` 按名回答，而 LLVM 侧
            // 此前**没有任何符号**回答它们 —— 降载照常产出 `call @chars(...)`（rc=0、静默），
            // 由 clang 以 `use of undefined value` 拒绝（与 `argv` / `listDir` 同形）。
            // 这里把它们接到 `bk_<名字>` 运行时段上。⚠️ 表即白名单（与降载侧同一条规矩）
            // ⇒ 不存在「降下来了却没人答」的名字。
            //
            // ⛔ 谓词**不**用 C 的 `_Bool` 返回：那在 C ABI 里是零扩展的 i8，而本层语言的 Bool
            // 是 i1 —— 两处对不上就是「看起来能跑、高位语义没人定义」。故运行时段一律回 `i32`，
            // 收敛到 `i1` 这一步在**这里**显式做掉。
            if RuntimeOps.characterBuiltins[function] != nil {
                usesCharacterShims = true
                let symbol = "bk_\(function)"
                switch function {
                case "chars":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call ptr @\(symbol)(\(argList))\n"
                    return IRValue(llvmType: "%bk_array*", ssaName: temp)
                case "chr":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call ptr @\(symbol)(\(argList))\n"
                    return IRValue(llvmType: "i8*", ssaName: temp)
                case "ord":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call i32 @\(symbol)(\(argList))\n"
                    return IRValue(llvmType: "i32", ssaName: temp)
                default:
                    let raw = builder.freshTemp()
                    bodyIR += " \(raw) = call i32 @\(symbol)(\(argList))\n"
                    let flag = builder.freshTemp()
                    bodyIR += " \(flag) = icmp ne i32 \(raw), 0\n"
                    return IRValue(llvmType: "i1", ssaName: flag)
                }
            }
            // G14: runtime-shimmed foreign symbols call their bk_ name
            // (the declare pass emits the matching bk_ symbol).
            let symbolName: String
            if function == "cstr" {
                symbolName = "bk_cstr"
            } else if function == "sleep" {
                // `sleep` 是并发内建里**唯一**被降载成一条普通调用、却又必须由后端实现的：
                // 它按片睡、每片查一次取消 ⇒ 落点是原语层的运行时符号，不是 libc 的睡眠
                // （理由见 `PiniRuntime` 里 `bk_sleep` 的注释）。
                usesSleepShim = true
                symbolName = "bk_sleep"
            } else if function == "argv" {
                // P4-1b 的宿主环境查询内建：降载侧早已按名降成既有 `call` 节点，
                // 解释器侧由执行器按名回答；**缺的一直只是 LLVM 侧的符号**。
                // 接 `bk_argv`（无参、回字符串数组 = `%bk_array*`）。
                usesProcessShims = true
                symbolName = "bk_argv"
            } else if function == "listDir" {
                // 自举仓 M8 前置的目录枚举。同上：降载已在册，LLVM 侧此前无符号。
                // 接 `bk_list_dir`（一参 String、回**条目名字**数组，排序与错误语义镜像解释器）。
                usesProcessShims = true
                symbolName = "bk_list_dir"
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
                fatalError("IREmitter: resultConstruct type is not a Result (IRLowerer guarantees)")
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
                fatalError("IREmitter: optionalConstruct type is not Optional (IRLowerer guarantees)")
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
                fatalError("IREmitter: enumConstruct on non-enum type (IRLowerer guarantees)")
            }
            // 名义箱上堆（2026-10-01）：分配器写第 0 格（引用计数 = 1）；
            // 标签落第 1 格、载荷从第 2 格起 —— 与 `emitMatch` 的 enum 分支同一套偏移。
            let ptr = emitNominalAllocation(aggregate: aggregate)
            let tagPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: ptr, indices: [0, 1]) + "\n"
            bodyIR += builder.fmtStore(value: String(tag), type: "i32", ptr: tagPtr) + "\n"
            for (index, payload) in payloads.enumerated() {
                let value = emitExpr(payload)
                let fieldPtr = builder.freshTemp()
                bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: ptr, indices: [0, index + 2]) + "\n"
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
            // 契约 §2.9 第 37 条：**字素级**判定。⛔ 旧形状的 `strstr` 是字节查找 ——
            // 分解式 Unicode 下与字素判定分歧（`"café"` 分解式 vs 预组合）。语义在运行时段，
            // 与解释器的 `.stringContains` 同源。
            let receiverValue = emitExpr(receiver)
            let needleValue = emitExpr(needle)
            usesStringShims = true
            let hit = builder.freshTemp()
            bodyIR +=
                " \(hit) = call i32 @bk_string_contains(ptr \(receiverValue.ssaName), "
                + "ptr \(needleValue.ssaName))\n"
            let found = builder.freshTemp()
            bodyIR += " \(found) = icmp ne i32 \(hit), 0\n"
            return IRValue(llvmType: "i1", ssaName: found)

        case .stringSubstring(let receiver, let start, let end):
            // ⚠️⭐ 本节点此前是**在案 B 组缺陷**（契约 §2.9 第 38 条原文：「注册表与测试已裁
            // `(start, end)`；LLVM 侧现为 `(start, length)`，**偏离**」）。契约与解释器都按
            // **end（绝对下标）**钉，只有发射器按 length 读 —— 自举代码处处写
            // `s.substring(i, i + 1)`，于是每取一个字符都多拷 `i` 个字节。
            // ⛔ 更贵的是它同时是个**栈炸弹**：旧形状在**调用点**发 `alloca i8, len+1`，而循环里
            // 的 `alloca` 不到函数返回不回收 ⇒ 循环 N 次即吃 N²/2 字节栈。自举 `splitLines`
            // 实测正是这样撞上栈保护页（`KERN_PROTECTION_FAILURE`，帧落 `_platform_memmove`）。
            // ⇒ 语义（字素 · 负值尾计数 · 双端夹取 · hi≤lo 得空串）与分配一起交给运行时段，
            // 与解释器的 `IRExecutor.stringSubstring` **同源**，⛔ 不再各写一份。
            let receiverValue = emitExpr(receiver)
            let startValue = emitExpr(start)
            let endValue = emitExpr(end)
            usesStringShims = true
            let substringResult = builder.freshTemp()
            bodyIR +=
                " \(substringResult) = call ptr @bk_substring(ptr \(receiverValue.ssaName), "
                + "i32 \(startValue.ssaName), i32 \(endValue.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: substringResult)

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

        case .join(let future, let type, let form):
            return emitJoin(future: future, type: type, form: form)

        case .givenInstance(let type):
            // ADR-001 `P2b`：物化面已落 —— 存放位 + 合成初始化函数 + 运行时取用。
            return emitGivenInstance(type: type)
        }
    }

    /// Bake a path *literal* against the program base (see `programBase`).
    /// Non-literals and paths that the rule exempts come back untouched, so
    /// every caller can route its path argument through this unconditionally.
    private func bakedIOPath(_ path: IRExpr) -> IRExpr {
        guard let base = programBase,
            case .stringConst(let value) = path,
            !value.hasPrefix("/"),
            !value.hasPrefix("./"),
            !value.hasPrefix("../")
        else {
            return path
        }
        return .stringConst(value: base + "/" + value)
    }

    /// A libc call or a runtime shim that answers NULL on failure is turned into
    /// a panic here rather than handed on: the legacy emitter passes the NULL
    /// through, and the trap then happens inside libc with no message at all.
    /// Failing loud through the same panic channel as the other runtime guards
    /// names the builtin instead of surfacing as an opaque crash. The path is
    /// deliberately not interpolated: a non-literal argument cannot be folded
    /// into a constant here, and a message that only covers some call shapes
    /// would be worse than one that covers none. `message` is a caller-supplied
    /// constant for the same reason -- `readFile` can now fail at the **read**
    /// and not only at the open, and a message that still said "could not open"
    /// would be wrong about half the failures it can no longer tell apart.
    private func emitNullGuard(handle: String, message: String) {
        let failed = builder.freshTemp()
        bodyIR += " \(failed) = icmp eq ptr \(handle), null\n"
        let id = builder.freshLabel()
        let failLabel = "io.fail.\(id)"
        let openLabel = "io.open.\(id)"
        bodyIR += builder.fmtCondBr(cond: failed, thenLabelName: failLabel, elseLabelName: openLabel) + "\n"
        bodyIR += "\(failLabel):\n"
        let text = emitStringConstant(message)
        bodyIR += " call void @bk_panic(ptr \(text.ssaName))\n"
        bodyIR += " unreachable\n"
        bodyIR += "\(openLabel):\n"
    }

    /// `writeFile(path, content)` (G15): fopen(path, "w") / strlen /
    /// fwrite / fclose. Mirrors the legacy emitter byte for byte — no
    /// trailing newline is appended, matching the interpreter's
    /// `String.write(toFile:)`. Yields the fclose i32 as the value. The one
    /// deliberate divergence is the NULL guard: the legacy emitter has none.
    private func emitFileWrite(path: IRExpr, content: IRExpr) -> IRValue {
        usesFileWrite = true
        let pathValue = emitExpr(bakedIOPath(path))
        let contentValue = emitExpr(content)
        let mode = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: mode, aggregate: "[2 x i8]", base: "@.fopen_w", indices: [0, 0]) + "\n"
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = call ptr @fopen(ptr \(pathValue.ssaName), ptr \(mode))\n"
        emitNullGuard(handle: handle, message: "Pini runtime error: writeFile could not open the file")
        let length = builder.freshTemp()
        bodyIR += " \(length) = call i64 @strlen(ptr \(contentValue.ssaName))\n"
        let written = builder.freshTemp()
        bodyIR += " \(written) = call i64 @fwrite(ptr \(contentValue.ssaName), i64 1, i64 \(length), ptr \(handle))\n"
        let closed = builder.freshTemp()
        bodyIR += " \(closed) = call i32 @fclose(ptr \(handle))\n"
        return IRValue(llvmType: "i32", ssaName: closed)
    }

    /// `readFile(path)` (G15): the runtime shim reads the whole file and hands
    /// back a NUL-terminated, malloc-allocated C string (UTF-8), or NULL when
    /// the file cannot be read. Yields that pointer as a String.
    ///
    /// ⚠️⭐ This used to `fread` into a **fixed 64 KiB stack buffer** and drop
    /// the rest -- silently, on both channels. The buffer could not be sized
    /// from the file, because LLI's JIT makes `fseek` / `ftell` / `fstat`
    /// unreliable, so "read the whole file" was not expressible in **emitted
    /// IR** at all. It is expressible in the runtime, which is where it lives
    /// now; the cap's removal is documented in `IOLimits`.
    ///
    /// The NULL guard stays, and now covers the read as well as the open: a
    /// missing file is reachable from ordinary source, unlike the write path's.
    private func emitFileRead(path: IRExpr) -> IRValue {
        usesFileRead = true
        let pathValue = emitExpr(bakedIOPath(path))
        let content = builder.freshTemp()
        bodyIR += " \(content) = call ptr @bk_read_file(ptr \(pathValue.ssaName))\n"
        emitNullGuard(handle: content, message: "Pini runtime error: readFile could not read the file")
        // "i8*" (not "ptr"): that is the spelling emitScalarPrint treats as a
        // C string; a bare `ptr` falls into the %d default and prints the
        // address.
        return IRValue(llvmType: "i8*", ssaName: content)
    }

    /// `readLine()` (G17): a fixed-size stack buffer filled by `fgets` from the
    /// stdin stream, yielded as a String.
    ///
    /// The cap and the retained line terminator are the interpreter's answer
    /// too — the A-group ruling kept both, and the interpreter was moved onto
    /// that behaviour rather than the other way round. The buffer size comes
    /// from the shared limit so neither side can drift.
    ///
    /// The end-of-input guard is this emitter's own addition: `fgets` yields
    /// NULL when the stream is exhausted, and the print path's `%s`
    /// conversion is then handed a pointer that is not a string — undefined
    /// behaviour instead of the language's answer. Substituting the empty
    /// string gives both channels the answer the interpreter already has at
    /// end of input.
    private func emitReadLine() -> IRValue {
        usesReadLine = true
        let bufferSize = IOLimits.lineBufferSize
        let buffer = freshSlot(for: "readline.buffer")
        bodyIR += builder.fmtAlloca(name: buffer, type: "[\(bufferSize) x i8]") + "\n"
        let base = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: base, aggregate: "[\(bufferSize) x i8]", base: buffer, indices: [0, 0]) + "\n"
        let stream = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: stream, type: "ptr", ptr: "@__stdinp") + "\n"
        let line = builder.freshTemp()
        bodyIR += " \(line) = call ptr @fgets(ptr \(base), i32 \(bufferSize), ptr \(stream))\n"
        let exhausted = builder.freshTemp()
        bodyIR += " \(exhausted) = icmp eq ptr \(line), null\n"
        let empty = emitStringConstant("")
        let text = builder.freshTemp()
        bodyIR += " \(text) = select i1 \(exhausted), ptr \(empty.ssaName), ptr \(line)\n"
        // "i8*" for the same reason emitFileRead returns it: that is the
        // spelling emitScalarPrint routes to %s.
        return IRValue(llvmType: "i8*", ssaName: text)
    }

    /// `is_ascii_digit(s)` (G17): the first byte of the C string tested
    /// against [0x30, 0x39]. The empty string loads its NUL terminator and is
    /// false without a length check — the same shape the legacy emitter uses,
    /// and the same answer the interpreter's first-grapheme rule gives in the
    /// ASCII domain.
    private func emitIsAsciiDigit(_ argument: IRExpr) -> IRValue {
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
    private func emitAssertCall(condition: IRExpr, message: IRExpr?) -> IRValue {
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
    private func emitPointerLoad(pointer: IRExpr, element: IRType) -> IRValue {
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
    private func emitPointerStore(pointer: IRExpr, value: IRExpr, element: IRType) -> IRValue {
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
    private func emitAddressOfVar(name: String, type: IRType) -> IRValue {
        guard let slot = lookupSlot(name) else {
            fatalError("IREmitter: addressOf of undeclared variable '\(name)' (IRLowerer guarantees declarations)")
        }
        return IRValue(llvmType: "ptr", ssaName: slot)
    }

    /// `print(a, b, ...)`: per-argument value print separated by single
    /// spaces, one trailing newline (D-A=A1 — mirrors the interpreter's
    /// stringify-join byte stream). No newline after each argument, unlike
    /// the single-argument print path.
    ///
    /// Every argument renders through the shared recursive printer, which
    /// covers the slice shapes and falls back to the scalar path, so a mixed
    /// call matches the single-argument form byte for byte. Types that still
    /// have no rendering at all trap at run time instead (`bk_panic` is
    /// noreturn), keeping the remaining gap observable rather than letting
    /// the scalar fallback print a handle's bits.
    private func emitPrintMulti(arguments: [IRExpr]) -> IRValue {
        if arguments.contains(where: { Self.hasNoScalarRendering(irType(of: $0)) }) {
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
            emitValuePrint(value: printed, type: irType(of: argument))
        }
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// True for the types neither print path can render — the scalar path
    /// falls back to printing the value's spelling as an integer, so
    /// aggregates (`{ ... }` registers) and runtime handles (`%bk_*`) would
    /// come out as their bits. Scalars, strings and raw pointers keep the
    /// existing scalar spelling. Nominal values are no longer in this set:
    /// they render through the shared recursive printer.
    ///
    /// A `Future` sits with the handles rather than with the pointers even
    /// though both are spelled `ptr`: what groups a type here is whether
    /// printing one produces an answer, and a running process has no scalar
    /// rendering to fall back on. It belongs to the same family as the other
    /// opaque handles, and it degrades the same way they do.
    private static func hasNoScalarRendering(_ type: IRType) -> Bool {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .f64, .boolean, .string, .char, .pointer,
            .nominal:
            return false
        case .result, .future, .array, .optional, .enumeration, .dict,
            .lazyRef, .set, .tuple, .function:
            return true
        }
    }

    // MARK: - G13 batch 1 (LazyRef)

    /// `LazyRef<T>(closure)` (G13 batch 1): extract the initializer's fat
    /// pointer { code, env }, ensure the type-specialized boxing wrapper,
    /// and call `bk_lazyref_create(wrapper, code, env, bytes, tag)`. The
    /// handle is kept as an opaque `%bk_lazyref*` (legacy bitcast mirror).
    private func emitLazyRefConstruct(closure: IRExpr, type: IRType) -> IRValue {
        guard case .lazyRef(let element) = type else {
            fatalError("IREmitter: lazyRefConstruct type is not a lazyRef (IRLowerer guarantees)")
        }
        let (elemSpelling, bytes, tag) = lazyRefElemABI(element)
        usesLazyRef = true
        let closureValue = emitExpr(closure)
        guard closureValue.llvmType == "{ ptr, ptr }" else {
            fatalError("IREmitter: LazyRef initializer is not a closure (IRLowerer guarantees)")
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
    private func emitLazyRefValue(handle: IRExpr, element: IRType) -> IRValue {
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
    private func lazyRefElemABI(_ type: IRType) -> (spelling: String, bytes: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 4)
        /// `Char` (P0d), declared rather than left to the default: it rides on
        /// `string` here because the representation is the same, so the same
        /// raw-ptr tag applies for the reason in the note above — a grapheme
        /// is immutable C bytes with no share count.
        case .char: return ("i8*", 8, 4)
        default:
            fatalError("IREmitter: no LazyRef element ABI for '\(type)' (IRLowerer gates element types)")
        }
    }

    /// Buffer (deduplicated) the type-specialized boxing wrapper:
    /// `ptr @__lazyref_wrapper_<T>(ptr code, ptr env, ptr out)` — calls the
    /// initializer code, stores the element into the runtime-provided heap
    /// box, and returns it (uniform ptr ABI sidesteps per-type return
    /// register differences; the runtime owns the box allocation).
    private func ensureLazyRefWrapper(element: IRType, elemSpelling: String) -> String {
        let suffix: String
        switch element {
        case .i32: suffix = "i32"
        case .f64: suffix = "f64"
        case .boolean: suffix = "i1"
        case .string: suffix = "ptr"
        /// Same spelling as `string` on purpose — identical ABI means one
        /// wrapper, and the dedup guard below then shares it.
        case .char: suffix = "ptr"
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
    private func fieldLayout(of base: IRExpr, field: String) -> (aggregate: String, fieldType: IRType, index: Int) {
        let baseType = irType(of: base)
        guard case .nominal(let name, let isObject) = baseType else {
            fatalError("IREmitter: field access on non-nominal base (IRLowerer guarantees)")
        }
        guard let decl = moduleTypes.first(where: { $0.name == name }),
            let index = decl.fields.firstIndex(where: { $0.name == field })
        else {
            fatalError("IREmitter: unknown nominal field '\(name).\(field)' (IRLowerer guarantees)")
        }
        let aggregate = "%\(isObject ? "object" : "struct").\(IRName.mangle(name))"
        // 三族名义箱的第 0 格都是引用计数头（2026-10-01）⇒ 字段索引一律 +1。
        // ⚠️ `isObject` 仍决定聚合名拼写（`%object` / `%struct` 是两个不同的类型名），
        // 只是**不再影响字段偏移** —— 头两边都有。
        return (aggregate, decl.fields[index].type, index + 1)
    }

    /// ADR-001 `P2b`：默认实例的取用点。
    ///
    /// 形状 = `bk_given_get(槽位, 初始化函数, 字节数)` → 盒指针，**再 `memcpy` 一份到本地**。
    ///
    /// WHY 拷贝（用户 2026-09-19 裁定）：`using` 取的是**实参的副本**，与函数传参一致。
    /// 盒是程序级唯一的，但交给调用点的是**值** ⇒ 写实例自身字段等于改参数（不留痕），
    /// 只有经它持有的**引用字段**往下写才对所有取用点可见。解释器那一臂天然同形
    /// （那边 `Value` 本就是值类型），故两臂语义一致 —— 这是本批刻意维持的对等。
    ///
    /// 字节数取「**过尾指针的整数形式**」：本仓无 `sizeof` 先例，而这个式子只依赖聚合体定义，
    /// 是 LLVM 取类型大小的标准写法（不引入新声明、不依赖目标数据布局查询）。
    ///
    /// ⚠️ 同一个式子有**两种位置**，而**位置决定它合法与否**：当**操作数**用（调用实参之类）合法；
    /// 写在**赋值位**不合法 —— 那里它被当作一条 cast **指令**解析，于是要求 `<类型> <值>`，
    /// 而它看到的是一个 `(`，报 `expected type`。⇒ 此处发**两条真指令**（先取过尾指针、再转成整数），
    /// 而不是把这个式子绑到一个名字上。
    /// ⛔ 别处把它当**调用实参**用是**合法**的 —— 这里改了**不等于**那边也该改。
    private func emitGivenInstance(type: IRType) -> IRValue {
        guard case .nominal(let name, _) = type,
            let aggregate = type.nominalAggregateSpelling,
            moduleTypes.contains(where: { $0.name == name })
        else {
            fatalError("IREmitter: givenInstance of unknown nominal type (IRLowerer guarantees)")
        }
        let slot = ensureGivenSlot(type: type)
        let initializer = ensureGivenInitializer(type: type)
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: aggregate, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let boxed = builder.freshTemp()
        bodyIR += " \(boxed) = call ptr @bk_given_get(ptr @\(slot), ptr @\(initializer), i64 \(sizeTemp))\n"
        // ⭐ 副本也住堆（2026-10-01）：它是取用方**自己的一份**（`using` 的副本语义），
        // 但那份副本会随帧外逃 ⇒ 不能再落在栈上。`memcpy` 连头一起搬，随后把头**重写成 1**
        // —— 副本与源从此各是一次独立持有，不依赖源头当时的值。
        let local = emitNominalAllocation(aggregate: aggregate)
        bodyIR += " call ptr @memcpy(ptr \(local), ptr \(boxed), i64 \(sizeTemp))\n"
        let rcFix = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: rcFix, aggregate: aggregate, base: local, indices: [0, 0]) + "\n"
        bodyIR += builder.fmtStore(value: "1", type: "i32", ptr: rcFix) + "\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: local)
    }

    /// 默认实例的**盒指针** —— ⛔ 不是它的值。
    ///
    /// 与 `emitGivenInstance` 只差一处：**不做那份本地拷贝**。
    ///
    /// ⚠️ 为什么本处必须**不**拷贝：策略层的方法会**写它自己的字段**（入队 / 出队），
    /// 队列状态因而必须活过派发点那一帧。把调用方栈上那份副本的地址交给运行时，
    /// 等于把队列放进一个**随帧消失**的对象里 —— 挑选循环随后拿到的是**悬垂指针**，
    /// 而它的症状是随机错乱、不是立即崩溃。
    /// ⇒ 取用点要副本（「实参的副本」是那条路的语义），驱动面要**本体**，两者不可互推。
    private func emitGivenBoxPointer(type: IRType) -> IRValue {
        guard case .nominal(let name, _) = type,
            let aggregate = type.nominalAggregateSpelling,
            moduleTypes.contains(where: { $0.name == name })
        else {
            fatalError("IREmitter: given box pointer of unknown nominal type (caller gates this)")
        }
        let slot = ensureGivenSlot(type: type)
        let initializer = ensureGivenInitializer(type: type)
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: aggregate, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let boxed = builder.freshTemp()
        bodyIR += " \(boxed) = call ptr @bk_given_get(ptr @\(slot), ptr @\(initializer), i64 \(sizeTemp))\n"
        return IRValue(llvmType: "ptr", ssaName: boxed)
    }

    /// 把一个**已派发**的任务与调度器绑定起来（`Q-4` 乙段）。
    ///
    /// ⭐ 为什么由发射层交出「怎么调」：策略是 Pini 值、它的方法体是**编译产物**，
    /// 而运行时那一层是纯 C ABI、**拿不到方法表** ⇒ 那层不可能自己去调策略。
    /// 三个机器字 —— 策略实例 · 「收下」的入口 · 「选择下一个任务」的入口 —— 就是那次交接
    /// （裁定 **57** 取甲：运行时持挑选循环，发射层交出可调用的入口）。
    ///
    /// ⚠️ 策略实例取的是**盒指针**而不是它的一份副本，理由见 `emitGivenBoxPointer`。
    /// ⚠️ 两个入口直接取方法函数的地址：调用约定能对上的理由是**两边都是裸指针形态**
    /// （第一实参是策略实例，参数 / 返回是任务句柄）。
    /// ⛔ 方法不存在时这里**不做检查** —— 发射层照发那个符号，由 `lli` 报未定义符号。
    /// 如实登记：解释器后端的对应形态是运行期抛「策略没有这个方法」，各后端的**拒绝形态不同**，
    /// 收敛它须另行点名（⛔ 不在本段）。
    private func emitSchedulerBinding(handle: String) {
        // 调度器类型不在本模块 ⇒ 没有策略可绑。⛔ 此时不绑：运行时的处置是
        // 「没有绑定 ⇒ 该任务按取消归约」，而那条路只有在**真有人 await** 时才有对象。
        guard moduleTypes.contains(where: { $0.name == PredefinedDecls.schedulerTypeName }) else {
            return
        }
        usesSchedBinding = true
        let schedulerType = IRType.nominal(
            name: PredefinedDecls.schedulerTypeName, isObject: false)
        let sched = emitGivenBoxPointer(type: schedulerType)
        let typeName = IRName.mangle(PredefinedDecls.schedulerTypeName)
        let accept = "@\(IRName.mangle(PredefinedDecls.acceptMethodName))__\(typeName)"
        let pick = "@\(IRName.mangle(PredefinedDecls.pickMethodName))__\(typeName)"
        let binding = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: binding, type: "[3 x ptr]") + "\n"
        for (index, value) in [sched.ssaName, accept, pick].enumerated() {
            let field = builder.freshTemp()
            bodyIR += builder.fmtGEPByteOffset(name: field, base: binding, offset: "\(index * 8)") + "\n"
            bodyIR += builder.fmtStore(value: value, type: "ptr", ptr: field) + "\n"
        }
        let ignored = builder.freshTemp()
        bodyIR += " \(ignored) = call i32 @bk_task_bind_sched(ptr \(handle), ptr \(binding))\n"
    }

    /// 取（并在首次需要时定义）某类型的存放位符号。
    private func ensureGivenSlot(type: IRType) -> String {
        guard case .nominal(let name, _) = type else {
            fatalError("IREmitter: given slot for non-nominal type (IRLowerer guarantees)")
        }
        let symbol = "__given_slot_\(IRName.mangle(name))"
        if givenSlotNames.insert(symbol).inserted {
            givenSlotDefs.append("@\(symbol) = internal global ptr null\n")
        }
        return symbol
    }

    /// 合成（并按类型去重）该类型的初始化函数：`define ptr @__given_init_<T>(ptr %out)`。
    ///
    /// 字段初值在这里当**普通表达式**降载 —— 与 `emitConstruct` 同一套算法，只差落点：
    /// 那边写进一个新 `alloca`，这边写进运行时给的 `%out`。故本函数保存/恢复发射上下文，
    /// 在一个干净的子上下文里发射函数体（姿势照抄闭包发射，那边也是「另起一个 define」）。
    ///
    /// ⚠️ **可重入**：某个字段初值自己可能取用**另一个**给定块 ⇒ 这里会递归回到
    /// `emitGivenInstance`。上下文是保存/恢复的、两个符号集合各自去重，故递归安全
    /// （运行时那一侧的死锁由 `bk_given_get` 的两级锁挡住，见其实现注释）。
    private func ensureGivenInitializer(type: IRType) -> String {
        guard case .nominal(let name, _) = type,
            let aggregate = type.nominalAggregateSpelling,
            let decl = moduleTypes.first(where: { $0.name == name })
        else {
            fatalError("IREmitter: given initializer for unknown nominal type (IRLowerer guarantees)")
        }
        let symbol = "__given_init_\(IRName.mangle(name))"
        guard givenInitializerNames.insert(symbol).inserted else { return symbol }

        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedScopes = scopes
        let savedSlotCounters = slotCounters
        let savedTerminated = terminated
        let savedControlStack = controlStack
        let savedBreakMergeLabels = breakMergeLabels
        let savedDeferScopeBase = deferScopeBase
        let savedReturnType = currentReturnType
        let savedIsMain = currentIsMain
        let savedCaptureSlots = captureSlots
        let savedPendingReleases = pendingReleases

        builder = IRBuilder()
        bodyIR = ""
        scopes = [[:]]
        slotCounters = [:]
        terminated = false
        controlStack = []
        breakMergeLabels = []
        deferScopeBase = 0
        currentReturnType = nil
        currentIsMain = false
        captureSlots = [:]
        pendingReleases = []

        // 引用计数头（第 0 格）：`%out` 是运行时给的**程序级单例盒**，头格写 1；
        // ⚠️ 它**不参与计数释放**（`bk_given_get` 持有到进程结束），写 1 只是形态一致。
        let rcPtr = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: rcPtr, aggregate: aggregate, base: "%out", indices: [0, 0]) + "\n"
        bodyIR += builder.fmtStore(value: "1", type: "i32", ptr: rcPtr) + "\n"
        for (index, field) in decl.fields.enumerated() {
            let fieldPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: "%out", indices: [0, index + 1]) + "\n"
            if let defaultValue = field.defaultValue {
                let value = emitExpr(defaultValue)
                bodyIR +=
                    builder.fmtStore(value: value.ssaName, type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
            } else {
                bodyIR +=
                    builder.fmtStore(value: zeroConst(for: field.type), type: field.type.llvmSpelling, ptr: fieldPtr)
                    + "\n"
            }
        }
        bodyIR += " ret ptr %out\n"
        givenInitializerDefs.append("define ptr @\(symbol)(ptr %out) {\n" + bodyIR + "}\n\n")

        bodyIR = savedBodyIR
        builder = savedBuilder
        scopes = savedScopes
        slotCounters = savedSlotCounters
        terminated = savedTerminated
        controlStack = savedControlStack
        breakMergeLabels = savedBreakMergeLabels
        deferScopeBase = savedDeferScopeBase
        currentReturnType = savedReturnType
        currentIsMain = savedIsMain
        captureSlots = savedCaptureSlots
        pendingReleases = savedPendingReleases
        return symbol
    }

    /// 名义箱的**分配**（2026-10-01 · 名义箱上堆）。
    ///
    /// 把一个聚合体大小的块要进**运行时段**（`bk_nominal_alloc`），由它写第 0 格
    /// 引用计数 = 1。⛔ 不再用栈 `alloca`：栈上的箱活不过创建帧，而名义值今天会随
    /// 返回值 / 字段 / 闭包捕获跨帧（实测五条外逃全红的那一族）。
    ///
    /// 大小用「**过尾指针的整数形式**」（`getelementptr <agg>, ptr null, i32 1` → `ptrtoint`）——
    /// 与 `emitGivenInstance` 同一式子，只依赖聚合体定义，不引入 `sizeof` 先例。
    ///
    /// ⚠️ 与 `bk_given_get` 的单例盒**不是**同一条通道：那边由运行时持有到进程结束、
    /// 从不释放，因此不参与计数（见 `ensureGivenInitializer`）。
    private func emitNominalAllocation(aggregate: String) -> String {
        usesNominalBoxes = true
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: aggregate, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let ptr = builder.freshTemp()
        bodyIR += " \(ptr) = call ptr @bk_nominal_alloc(i64 \(sizeTemp))\n"
        return ptr
    }

    // MARK: - 释放胶水（2026-10-01 · 名义箱的寿命）

    /// 收集一棵 IR 子树里**所有闭包字面量捕获的变量名**（含嵌套闭包自己再捕获的）。
    ///
    /// ⚠️ 用 `Mirror` 反射而不是手写 `switch`：IR 有几十个节点种类，手写遍历漏掉一个
    /// 新节点时的症状是「某个捕获槽还留在栈上」—— 只在跨帧时才炸，正是本片要修的那一类。
    /// 反射在这里**宁可宽**：多收几个名字只会让那个槽上堆（多一次分配），漏收才出错。
    private func capturedNames(in value: Any) -> Set<String> {
        var names: Set<String> = []
        collectCaptures(value, into: &names)
        return names
    }

    private func collectCaptures(_ value: Any, into names: inout Set<String>) {
        if let expr = value as? IRExpr,
            case .closureLiteral(_, _, _, _, let captures, let body, _) = expr
        {
            for capture in captures { names.insert(capture.name) }
            collectCaptures(body, into: &names)
            return
        }
        for child in Mirror(reflecting: value).children {
            collectCaptures(child.value, into: &names)
        }
    }

    /// 名义类型的「胶水专用」拼写：`struct.<mangled>` / `object.<mangled>` / `enum.<mangled>`。
    ///
    /// ⭐ 抽出来的理由不是好看：`__release_*` / `__copy_*`（片 C）两族合成函数都按它去重，
    /// 而**同名的 struct 与 enum** 若共用一族的符号就会撞在一起。
    private func nominalKindSpelling(_ type: IRType) -> String? {
        switch type {
        case .nominal(let name, let isObject):
            return "\(isObject ? "object" : "struct").\(IRName.mangle(name))"
        case .enumeration(let name):
            return "enum.\(IRName.mangle(name))"
        default:
            return nil
        }
    }

    /// 释放胶水对某个**字段类型**要做的动作。
    /// - 名义字段（struct / object / enum）：递归调它自己的释放胶水 —— **不判空**
    ///   （`bk_nominal_release(null)` 返回 0 ⇒ 递归进去什么也不做）。
    /// - 容器字段（array / dict / set）：`bk_*_destroy` —— **必须判空**
    ///   （运行时的 destroy 对 null 是 `bk_panic`）。
    /// - 其余（标量 / 字符串 / 指针）：无动作。
    private func releaseCallee(for type: IRType) -> (symbol: String, needsNullGuard: Bool)? {
        if nominalKindSpelling(type) != nil {
            return (ensureReleaseFunction(for: type), false)
        }
        if let destroy = Self.collectionDestroySymbol(for: type.llvmSpelling) {
            return (destroy, true)
        }
        return nil
    }

    /// 某个类型在释放胶水里**有没有动作**。
    ///
    /// ⚠️ 与 `releaseCallee` 的分工：那个会**递归合成**子类型的胶水（有副作用），
    /// 这个只回答「要不要」—— 胶水里的**分派结构**（哪些 case 值得生成一个 arm）
    /// 必须在合成之前就能算出来，否则会为「只有标量载荷的 case」生成空 arm。
    private func needsReleaseAction(for type: IRType) -> Bool {
        if nominalKindSpelling(type) != nil { return true }
        return Self.collectionDestroySymbol(for: type.llvmSpelling) != nil
    }

    /// 在胶水体里发一次「释放这个值」的调用；需要判空的那一族先生成分支。
    private func emitReleaseCall(
        callee: (symbol: String, needsNullGuard: Bool), valueName: String, spelling: String, tag: String
    ) {
        guard callee.needsNullGuard else {
            // 名义递归：直接传（null 进去返回 0，不做任何事）
            bodyIR += " call void @\(callee.symbol)(ptr \(valueName))\n"
            return
        }
        let nonNull = builder.freshTemp()
        bodyIR += " \(nonNull) = icmp ne \(spelling) \(valueName), null\n"
        bodyIR +=
            builder.fmtCondBr(cond: nonNull, thenLabelName: "rel.\(tag)", elseLabelName: "cont.\(tag)") + "\n"
        bodyIR += "rel.\(tag):\n"
        bodyIR += " call void @\(callee.symbol)(ptr \(valueName))\n"
        bodyIR += builder.fmtBr(labelName: "cont.\(tag)") + "\n"
        bodyIR += "cont.\(tag):\n"
    }

    /// 逐类型合成的**值语义拷贝胶水**：`define ptr @__copy_struct_<mangled>(ptr %src)`。
    ///
    /// 规则**逐条对齐**解释器的 `RuntimeOps.copyIfStruct`（那边是权威；它的注释原文写着
    /// 「Both engines owe this rule at every binding and store site」）：
    /// - **结构体字段** ⇒ 递归拷贝（新箱）；
    /// - **对象 / 枚举字段** ⇒ **原样共享**（引用语义，`copyIfStruct` 对它们原样返回）+ retain；
    /// - **容器字段** ⇒ 共享 + retain（写时复制由容器在运行时那一层管）；
    /// - **标量 / 字符串 / 指针** ⇒ 直接复制（字符串是不可变 C 串，没有主）。
    ///
    /// ⚠️ `null` 入参返回 `null`（无默认值字段还没写过）—— 调用点因此不必判空。
    /// ⚠️ 只为**结构体**合成：对象与枚举本身是引用语义，拷贝即共享 ⇒ 那条路走 retain。
    private func ensureCopyFunction(for type: IRType) -> String? {
        guard case .nominal(let name, let isObject) = type, !isObject else { return nil }
        guard let decl = moduleTypes.first(where: { $0.name == name }),
            let aggregate = type.nominalAggregateSpelling
        else {
            fatalError("IREmitter: copy glue for unregistered struct (IRLowerer guarantees)")
        }
        let symbol = "__copy_struct_\(IRName.mangle(name))"
        guard copyFunctionNames.insert(symbol).inserted else { return symbol }

        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedUsesNominalBoxes = usesNominalBoxes
        builder = IRBuilder()
        bodyIR = ""
        usesNominalBoxes = true

        let isNull = builder.freshTemp()
        bodyIR += " \(isNull) = icmp eq ptr %src, null\n"
        bodyIR += builder.fmtCondBr(cond: isNull, thenLabelName: "null.src", elseLabelName: "copy") + "\n"
        bodyIR += "null.src:\n"
        bodyIR += " ret ptr null\n"
        bodyIR += "copy:\n"
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: aggregate, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let dst = builder.freshTemp()
        bodyIR += " \(dst) = call ptr @bk_nominal_alloc(i64 \(sizeTemp))\n"
        for (index, field) in decl.fields.enumerated() {
            let srcPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: srcPtr, aggregate: aggregate, base: "%src", indices: [0, index + 1]) + "\n"
            let value = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: value, type: field.type.llvmSpelling, ptr: srcPtr) + "\n"
            let stored: String
            switch boxFamily(ofValueSpelling: field.type.llvmSpelling) {
            case .container:
                // 容器：共享 + 留一份份额（COW 的分裂逻辑在运行时那一层）
                let raw = builder.freshTemp()
                bodyIR += " \(raw) = bitcast \(field.type.llvmSpelling) \(value) to ptr\n"
                bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
                stored = value
            case .nominal:
                if case .nominal(_, false) = field.type, let sub = ensureCopyFunction(for: field.type) {
                    // 结构体字段：值语义的一部分 ⇒ 递归拷贝
                    let copied = builder.freshTemp()
                    bodyIR += " \(copied) = call ptr @\(sub)(ptr \(value))\n"
                    let typed = builder.freshTemp()
                    bodyIR += " \(typed) = bitcast ptr \(copied) to \(field.type.llvmSpelling)\n"
                    stored = typed
                } else {
                    // 对象 / 枚举字段：引用语义 ⇒ 共享 + retain
                    let raw = builder.freshTemp()
                    bodyIR += " \(raw) = bitcast \(field.type.llvmSpelling) \(value) to ptr\n"
                    bodyIR += " call void @bk_nominal_retain(ptr \(raw))\n"
                    stored = value
                }
            case nil:
                stored = value  // 标量 / 字符串 / 指针：直接复制
            }
            let dstPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: dstPtr, aggregate: aggregate, base: dst, indices: [0, index + 1]) + "\n"
            bodyIR += builder.fmtStore(value: stored, type: field.type.llvmSpelling, ptr: dstPtr) + "\n"
        }
        bodyIR += " ret ptr \(dst)\n"
        copyFunctionDefs.append("define ptr @\(symbol)(ptr %src) {\nentry:\n" + bodyIR + "}\n\n")

        bodyIR = savedBodyIR
        builder = savedBuilder
        usesNominalBoxes = savedUsesNominalBoxes
        return symbol
    }

    /// 该表达式节点给的是**已有箱的别名**（要按值语义拷贝 / 按引用语义 retain），
    /// 还是**一个新箱的所有权**（直接接管，什么都不做）。
    ///
    /// ⚠️ `.fieldGet` 在列：读字段给的是**指向父箱字段的指针**（别名），不是一份自己的
    /// 存储 —— `var g = h.p` 因此必须拷贝。而 `h.p.x = 9` 里的那个 `h.p` 是 fieldStore 的
    /// **base**，走的是发射 base 的分支、⛔ 不经过这里。
    private func yieldsAlias(_ node: IRExpr) -> Bool {
        switch node {
        case .load, .subscriptGet, .fieldGet, .optionalGet:
            return true
        default:
            return false
        }
    }

    /// 把「求值出来的值」按**值语义**落到一个持有位置（变量槽 / 字段 / 返回值）。
    ///
    /// - 结构体**别名** ⇒ 拷贝出新箱（`__copy_struct_*`，规则见它的注释）；
    /// - 对象 / 枚举 / 容器别名 ⇒ retain 一份（引用语义 / 写时复制）；
    /// - **临时值**（构造、调用返回值 …）⇒ 直接接管，零额外动作。
    ///
    /// - Returns: 应当被存下去（或被交出去）的那个值。
    @discardableResult
    private func emitValueForStorage(_ node: IRExpr, _ value: IRValue, type: IRType) -> IRValue {
        guard yieldsAlias(node) else { return value }
        if case .nominal(_, false) = type, let symbol = ensureCopyFunction(for: type) {
            let copied = builder.freshTemp()
            bodyIR += " \(copied) = call ptr @\(symbol)(ptr \(value.ssaName))\n"
            let typed = builder.freshTemp()
            bodyIR += " \(typed) = bitcast ptr \(copied) to \(type.llvmSpelling)\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: typed)
        }
        emitRetainIfAliased(node, value)
        return value
    }

    /// 逐类型合成的**释放胶水**：`define void @__release_<kind>_<mangled>(ptr %box)`。
    ///
    /// 形状（与容器那套「份额」语义对齐）：
    /// ① `bk_nominal_release(box)` —— 头格减一，返回 1 表示**归零**；
    /// ② **只有归零**才进 `sweep`：逐字段释放，最后 `free(box)`。
    ///
    /// ⚠️ 自引用类型（链表节点等）靠「**名字先占位**」防合成期无限递归；运行期沿指针走，
    /// 与解释器同假设（值类型语义下不存在环）。
    /// ⚠️ 枚举按 **tag 分派**：只有被选中 case 的载荷槽里有活值，其余槽**不碰**
    /// （未选中的槽里是分配器的原样字节）。
    /// ⚠️ 合成期间会递归回到自己（字段是名义类型时）—— 上下文保存/恢复照
    /// `ensureGivenInitializer` 的姿势，可重入。
    private func ensureReleaseFunction(for type: IRType) -> String {
        guard let kind = nominalKindSpelling(type) else {
            fatalError("IREmitter: release glue for non-nominal type (caller gates this)")
        }
        let symbol = "__release_\(kind)"
        guard releaseFunctionNames.insert(symbol).inserted else { return symbol }

        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedUsesNominalBoxes = usesNominalBoxes
        builder = IRBuilder()
        bodyIR = ""
        usesNominalBoxes = true  // 胶水体自己要用 bk_nominal_release

        let dead = builder.freshTemp()
        bodyIR += " \(dead) = call i32 @bk_nominal_release(ptr %box)\n"
        let isZero = builder.freshTemp()
        bodyIR += " \(isZero) = icmp ne i32 \(dead), 0\n"
        bodyIR += builder.fmtCondBr(cond: isZero, thenLabelName: "sweep", elseLabelName: "done") + "\n"
        bodyIR += "sweep:\n"

        switch type {
        case .nominal(let name, _):
            guard let decl = moduleTypes.first(where: { $0.name == name }),
                let aggregate = type.nominalAggregateSpelling
            else {
                fatalError("IREmitter: release glue for unregistered nominal (IRLowerer guarantees)")
            }
            for (index, field) in decl.fields.enumerated() {
                guard let callee = releaseCallee(for: field.type) else { continue }
                let fieldPtr = builder.freshTemp()
                bodyIR +=
                    builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: "%box", indices: [0, index + 1])
                    + "\n"
                let value = builder.freshTemp()
                bodyIR += builder.fmtLoad(name: value, type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
                emitReleaseCall(
                    callee: callee, valueName: value, spelling: field.type.llvmSpelling, tag: "f\(index)")
            }
        case .enumeration(let name):
            guard let enumDecl = moduleEnums.first(where: { $0.name == name }),
                let aggregate = type.nominalAggregateSpelling
            else {
                fatalError("IREmitter: release glue for unregistered enum (IRLowerer guarantees)")
            }
            let tagPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: "%box", indices: [0, 1]) + "\n"
            let tagValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: tagValue, type: "i32", ptr: tagPtr) + "\n"
            // ⚠️★ 判据必须用 **case 自己的 `payloadTypes`**，⛔ 不能用 `slotTypes`（那一版
            // 把自举的 `ast` 层跑崩了，实测栈：`__release_enum.TypeAnnotation` →
            // `__release_enum.TypeAnnotationList(box=0x1000b06a5)`，而那个地址落在
            // `__TEXT.__const`）。理由：**同一个槽在不同 case 里可以是不同类型** ——
            // `TypeAnnotation` 的槽 0，`simple` 放 `String`、`tupleType` 放 `TypeAnnotationList`。
            // 按 `slotTypes` 统一判断 ⇒ 会给「槽里其实是字符串常量」的 case 也生成释放。
            //
            // ⚠️ 另一半判据：只挑**真的有释放动作**的 case —— 只有标量载荷的 case 生成出来的
            // arm 里一条释放也没有，而 `after` 标签前若没有终结指令，clang 同样拒绝
            // （`expected instruction opcode`）。
            let payloadCases = enumDecl.cases.enumerated().filter { entry in
                entry.element.payloadTypes.contains { needsReleaseAction(for: $0) }
            }
            let afterLabel = "rel.cases.after"
            for (position, entry) in payloadCases.enumerated() {
                let (caseIndex, enumCase) = (entry.offset, entry.element)
                let matches = builder.freshTemp()
                bodyIR += " \(matches) = icmp eq i32 \(tagValue), \(enumCase.tag)\n"
                let armLabel = "rel.case.\(caseIndex)"
                let nextLabel =
                    position + 1 < payloadCases.count ? "rel.next.\(caseIndex)" : afterLabel
                bodyIR +=
                    builder.fmtCondBr(cond: matches, thenLabelName: armLabel, elseLabelName: nextLabel) + "\n"
                bodyIR += "\(armLabel):\n"
                for (slot, payloadType) in enumCase.payloadTypes.enumerated() {
                    guard let callee = releaseCallee(for: payloadType) else { continue }
                    // 拼写跟着**这个 case 的实际载荷类型**走 —— 与构造点的 `store` 同一套拼写。
                    let slotSpelling = payloadType.llvmSpelling
                    let fieldPtr = builder.freshTemp()
                    bodyIR +=
                        builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: "%box", indices: [0, slot + 2])
                        + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: slotSpelling, ptr: fieldPtr) + "\n"
                    emitReleaseCall(
                        callee: callee, valueName: value, spelling: slotSpelling,
                        tag: "c\(caseIndex)s\(slot)")
                }
                bodyIR += builder.fmtBr(labelName: afterLabel) + "\n"
                if position + 1 < payloadCases.count {
                    bodyIR += "rel.next.\(caseIndex):\n"
                }
            }
            if !payloadCases.isEmpty {
                bodyIR += "\(afterLabel):\n"
            }
        default:
            break
        }

        bodyIR += " call void @free(ptr %box)\n"
        bodyIR += builder.fmtBr(labelName: "done") + "\n"
        bodyIR += "done:\n"
        bodyIR += " ret void\n"
        releaseFunctionDefs.append("define void @\(symbol)(ptr %box) {\nentry:\n" + bodyIR + "}\n\n")

        bodyIR = savedBodyIR
        builder = savedBuilder
        usesNominalBoxes = savedUsesNominalBoxes
        return symbol
    }

    private func emitConstruct(type: IRType) -> IRValue {
        guard case .nominal(let name, _) = type,
            let aggregate = type.nominalAggregateSpelling,
            let decl = moduleTypes.first(where: { $0.name == name })
        else {
            fatalError("IREmitter: construct of unknown nominal type (IRLowerer guarantees)")
        }
        // 名义箱上堆（2026-10-01）：分配器写第 0 格（引用计数 = 1），字段从第 1 格起。
        // ⚠️ `isObject` 只影响聚合名拼写 —— 头两边都有，字段偏移不再分类讨论。
        let ptr = emitNominalAllocation(aggregate: aggregate)
        let zero = zeroConst(for:)
        for (index, field) in decl.fields.enumerated() {
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: ptr, indices: [0, index + 1]) + "\n"
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
    private func zeroConst(for type: IRType) -> String {
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
    private func emitSliceCall(container: IRExpr, start: IRExpr, end: IRExpr, type: IRType) -> IRValue {
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
            // 契约 §2.9 第 23 条：String 切片按**字素簇**。⛔ 旧形状按字节切（内联数字节 +
            // 逐字节 copy + 调用点变长 `alloca`）—— 非 ASCII 文本上切点落进多字节序列内部，
            // 自举 `splitLines` 正是由此切错行。语义与分配一起交给运行时段，
            // 与 `IRExecutor.sliceValue` 的 `.string` 分支同源。
            //
            // ⚠️ 开界传**标志位**，⛔ 不传哨兵：`s[-1...]` 是合法写法，拿 `-1` 当「开」
            // 会与真实下标撞车。开界时也⛔ 不求值那个界（旧形状同此）。
            let startOpen = sliceBoundIsOpen(start)
            let endOpen = sliceBoundIsOpen(end)
            let startOperand = startOpen ? "0" : emitExpr(start).ssaName
            let endOperand = endOpen ? "0" : emitExpr(end).ssaName
            usesStringShims = true
            let sliced = builder.freshTemp()
            bodyIR +=
                " \(sliced) = call ptr @bk_string_slice(ptr \(containerValue.ssaName), "
                + "i32 \(startOpen ? "0" : "1"), i32 \(startOperand), "
                + "i32 \(endOpen ? "0" : "1"), i32 \(endOperand))\n"
            return IRValue(llvmType: "i8*", ssaName: sliced)

        default:
            fatalError("IREmitter: slice on non-array/string type '\(type)' (IRLowerer gates)")
        }
    }

    /// Append one element, yielding a **new** array handle (the input handle and
    /// its contents are left alone — the same functional shape `slice` produces).
    ///
    /// The element ABI (width + tag) comes from the table the subscript store
    /// uses, and so does the alias rule: a value the source still owns is
    /// retained before the move, while a fresh temporary transfers ownership.
    /// The byte copy itself belongs to the runtime, which is also where the
    /// tag's nested-handle accounting lives.
    private func emitArrayAppend(
        receiver: IRValue, elementNode: IRExpr, elementValue: IRValue, elementType: IRType
    ) -> IRValue {
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        emitRetainIfAliased(elementNode, elementValue)
        let boxPtr = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
        bodyIR += builder.fmtStore(value: elementValue.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast %bk_array* \(receiver.ssaName) to ptr\n"
        let appended = builder.freshTemp()
        bodyIR += " \(appended) = call ptr @bk_array_append(ptr \(raw), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
        let typed = builder.freshTemp()
        bodyIR += " \(typed) = bitcast ptr \(appended) to %bk_array*\n"
        return IRValue(llvmType: "%bk_array*", ssaName: typed)
    }

    /// 切片的界是否是**开界**（`s[lo...]` / `s[...hi]` / `s[...]`）。
    ///
    /// 判据是**语法节点**（`optionalConstruct` 的 `isSome == false`）而不是值 ⇒ 发射期即可
    /// 定死，运行时段只收一个标志位（C ABI 面没有 Optional 这个类型）。
    private func sliceBoundIsOpen(_ bound: IRExpr) -> Bool {
        if case .optionalConstruct(let isSome, _, _) = bound, !isSome { return true }
        return false
    }

    /// One **Array** slice bound: `none` (optionalConstruct isSome=false) takes the
    /// default (start → "0", end → the runtime count); an integer is
    /// tail-counted when negative, then clamped into [0, count] — all via
    /// select chains, no branches (sunk-stdlib parity).
    ///
    /// ⚠️ String 切片**不走这里**：它的界、尾计数与夹取都在运行时段（`bk_string_slice`），
    /// 因为 String 的「字符」是字素簇 —— 拿字节或标量做算术都会偏离（契约第 23 条）。
    private func resolveSliceBound(_ bound: IRExpr, count: String, defaultValue: String) -> String {
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


    /// `arr.get(i)` — tolerant read: tail-counted negative index, then a
    /// bounds check; some(payload) or none. Arrays go through the runtime
    /// handle; strings take the **grapheme** count and the character itself from
    /// the runtime too (contract row 22/23 — the character model is grapheme
    /// clusters, which byte arithmetic cannot express). The aggregate flows
    /// through a stack slot (alloca + store + load) so the branch join needs no
    /// phi node.
    ///
    /// ⚠️ Tolerant channel: out-of-range yields `none`, so the bounds test stays
    /// here and the runtime character fetch is only ever reached in range.
    private func emitOptionalGet(container: IRExpr, index: IRExpr, type: IRType) -> IRValue {
        guard case .optional(let wrapped) = type else {
            fatalError("IREmitter: optionalGet type is not Optional (IRLowerer guarantees)")
        }
        let aggregate = type.llvmSpelling
        let containerValue = emitExpr(container)
        let indexValue = emitExpr(index)

        let isStringReceiver = irType(of: container) == .string
        let count: String
        var arrayRaw: String? = nil
        if isStringReceiver {
            // 契约 §2.9 第 22 条：String 的「字符」= **字素簇**（与 `len` 同一定义）。
            usesStringShims = true
            count = builder.freshTemp()
            bodyIR += " \(count) = call i32 @bk_string_count(ptr \(containerValue.ssaName))\n"
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
            // 到此 `effective` 必在 `[0, count)` ⇒ 运行时段不会 panic（容错通道）。
            let charAt = builder.freshTemp()
            bodyIR +=
                " \(charAt) = call ptr @bk_string_char_at(ptr \(containerValue.ssaName), "
                + "i32 \(effective))\n"
            value = charAt
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
    private func arrayElementABI(_ type: IRType) -> (spelling: String, width: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 3)
        case .char: return ("i8*", 8, 3)
        case .array: return ("%bk_array*", 8, 4)
        case .dict: return ("%bk_dict*", 8, 4)
        case .set: return ("%bk_set*", 8, 4)
        // ⭐ `*T` 原始指针走**裸指针 tag**（与 String / Char 同格），不是容器句柄那一格：
        // 它不参与引用计数，而运行时那两条钩子（retain / release）只在 handle tag 上动手。
        // ⚠️ 装箱搬的是**指针值本身** —— 它指向什么，不归本层管（它是不透明句柄）。
        case .pointer: return ("i8*", 8, 3)
        case .future:
            // 句柄数组（`joinAll` 的实参形态）需要一条把句柄搬进运行时容器的通道，
            // 而聚合 join 尚未接线 ⇒ 这里给一个点名的拒绝，而不是笼统的「没有这条 ABI」。
            fatalError(
                "IREmitter: an array of task handles has no element ABI yet — the aggregate join is not wired (this batch covers dispatch, blocking wait and pruning)")
        default:
            fatalError("IREmitter: no array element ABI for '\(type)' (IRLowerer gates element types)")
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
    private func emitRetainIfAliased(_ valueNode: IRExpr, _ value: IRValue) {
        guard let family = boxFamily(ofValueSpelling: value.llvmType) else { return }
        guard yieldsAlias(valueNode) else { return }
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr\n"
        switch family {
        case .container:
            bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
        case .nominal:
            usesNominalBoxes = true
            bodyIR += " call void @bk_nominal_retain(ptr \(raw))\n"
        }
    }

    /// 值在发射层的**计数族**（2026-10-01 · 名义箱上堆）：容器句柄与名义箱走两套 C ABI
    /// （`bk_handle_*` / `bk_nominal_*`），但**所有权规则同一套**
    /// （别名点 retain · 作用域退出 release · 写前 release 旧值）。
    ///
    /// 返回 nil = 该类型不参与计数（标量 / 字符串 / 外呼指针 / 任务句柄 …）。
    private enum BoxFamily { case container, nominal }

    private func boxFamily(ofValueSpelling spelling: String) -> BoxFamily? {
        if ["%bk_array*", "%bk_dict*", "%bk_set*"].contains(spelling) { return .container }
        if spelling.hasPrefix("%struct.") || spelling.hasPrefix("%object.")
            || spelling.hasPrefix("%enum.")
        {
            return .nominal
        }
        return nil
    }

    private func emitArrayLiteral(elements: [IRExpr], type: IRType) -> IRValue {
        guard case .array(let elementType) = type else {
            fatalError("IREmitter: arrayLiteral type is not an array (IRLowerer guarantees)")
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

    private func emitSubscriptGet(container: IRExpr, index: IRExpr, type: IRType) -> IRValue {
        let containerValue = emitExpr(container)
        let indexValue = emitExpr(index)

        // Dictionary read (G5): the key is boxed by its own type; a missing
        // key panics inside bk_dict_get (G48 three-channel alignment).
        if case .dict(let keyType, let valueType) = irType(of: container) {
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

        if irType(of: container) == .string {
            // 契约 §2.9 第 23 条：String 下标按**字素簇**，负值尾计数，越界走安全断言通道
            // （E5-005 parity）。⛔ 旧形状按**字节**取一个字节 —— 非 ASCII 上取出的不是合法
            // UTF-8，且与 `len` 的计数模型互相矛盾（两者叠在一起正是自举切错的机理）。
            // 语义（含越界 panic 与单字符结果）都在运行时段，与 `SubscriptReadStrategy`
            // 的 `.string` 策略同源。
            usesStringShims = true
            let charAt = builder.freshTemp()
            bodyIR +=
                " \(charAt) = call ptr @bk_string_char_at(ptr \(containerValue.ssaName), "
                + "i32 \(indexValue.ssaName))\n"
            return IRValue(llvmType: "i8*", ssaName: charAt)
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

    private func emitLen(_ argument: IRExpr) -> IRValue {
        let value = emitExpr(argument)
        switch irType(of: argument) {
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
            // 契约 §2.9 第 22 条：**字素簇**计数，与解释器的 `text.count` 同一定义。
            // ⛔ 旧形状数的是「非续字节」（= Unicode 标量）：纯 ASCII 与 CJK 上同值，
            // 只在组合序列上分歧 —— 但正是它与下标的字节寻址**叠在一起**，把自举切错。
            usesStringShims = true
            let charCount = builder.freshTemp()
            bodyIR += " \(charCount) = call i32 @bk_string_count(ptr \(value.ssaName))\n"
            return IRValue(llvmType: "i32", ssaName: charCount)
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

    private func emitDictLiteral(entries: [IRDictEntry], type: IRType) -> IRValue {
        guard case .dict(let keyType, let valueType) = type else {
            fatalError("IREmitter: dictLiteral type is not a dict (IRLowerer guarantees)")
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

    private func emitSetLiteral(elements: [IRExpr], type: IRType) -> IRValue {
        guard case .set(let elementType) = type else {
            fatalError("IREmitter: setLiteral type is not a set (IRLowerer guarantees)")
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
        case "i8":
            let t = builder.freshTemp()
            bodyIR += " \(t) = sext i8 \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        case "ptr":
            let t = builder.freshTemp()
            bodyIR += " \(t) = ptrtoint ptr \(value.ssaName) to i64\n"
            return IRValue(llvmType: "i64", ssaName: t)
        default:
            // 具名指针（`%bk_array*` / `%struct.X*` / `%enum.X*` …）：与 `ptr` 同一条路。
            if value.llvmType.hasSuffix("*") {
                let t = builder.freshTemp()
                bodyIR += " \(t) = ptrtoint \(value.llvmType) \(value.ssaName) to i64\n"
                return IRValue(llvmType: "i64", ssaName: t)
            }
            fatalError("IREmitter: no word widening for '\(value.llvmType)' (IRLowerer gates non-scalar payloads)")
        }
    }

    private func emitBinary(op: IRBinaryOp, lhs: IRExpr, rhs: IRExpr, type: IRType) -> IRValue {
        let lhsValue = emitExpr(lhs)
        let rhsValue = emitExpr(rhs)
        let temp = builder.freshTemp()

        if op.isComparison {
            let predicate = comparePredicate(
                op: op, operandType: lhsValue.llvmType, temp: temp,
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
    private func comparePredicate(
        op: IRBinaryOp, operandType: String, temp: String,
        lhs: IRValue, rhs: IRValue
    ) -> String {
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
    private func emitPrint(_ argument: IRExpr) -> IRValue {
        let type = irType(of: argument)
        let value = emitExpr(argument)
        emitValuePrint(value: value, type: type)
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// Resolved IR type of a lowered expression node (every case carries
    /// its type — the typed-tree contract).
    private func irType(of expr: IRExpr) -> IRType {
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
        case .join(_, let type, _): return type
        case .givenInstance(let type): return type
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
    private func emitValuePrint(value: IRValue, type: IRType) {
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

        case .nominal(let name, _):
            // Struct / object value rendering (interpreter stringify parity):
            // `Name{field: value, ...}` with the fields ordered by name.
            //
            // The display order is resolved here, not at run time: the
            // aggregate's field positions are static, so an ordered view over
            // the declared fields can still read each field's original slot.
            // Objects carry a refcount word ahead of the first field, which
            // shifts every field index by one — the same offset the
            // constructor applies.
            guard let decl = moduleTypes.first(where: { $0.name == name }),
                let aggregate = type.nominalAggregateSpelling
            else {
                fatalError("IREmitter: printing unregistered nominal (IRLowerer guarantees)")
            }
            let open = emitStringConstant("\(name){")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            // 引用计数头占第 0 格（2026-10-01）⇒ 字段基准一律 1。
            let fieldBase = 1
            let orderedFields = decl.fields.enumerated().sorted {
                $0.element.name < $1.element.name
            }
            for (position, entry) in orderedFields.enumerated() {
                if position > 0 {
                    let separator = emitStringConstant(", ")
                    bodyIR += " call i32 (ptr, ...) @printf(ptr \(separator.ssaName))\n"
                }
                let label = emitStringConstant("\(entry.element.name): ")
                bodyIR += " call i32 (ptr, ...) @printf(ptr \(label.ssaName))\n"
                let fieldPtr = builder.freshTemp()
                bodyIR +=
                    builder.fmtGEP(
                        name: fieldPtr, aggregate: aggregate, base: value.ssaName,
                        indices: [0, fieldBase + entry.offset]
                    ) + "\n"
                let fieldValue = builder.freshTemp()
                bodyIR +=
                    builder.fmtLoad(
                        name: fieldValue, type: entry.element.type.llvmSpelling, ptr: fieldPtr
                    ) + "\n"
                emitValuePrint(
                    value: IRValue(
                        llvmType: entry.element.type.llvmSpelling, ssaName: fieldValue
                    ),
                    type: entry.element.type
                )
            }
            let close = emitStringConstant("}")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(close.ssaName))\n"

        case .enumeration(let name):
            // Enum value rendering (interpreter stringify parity):
            // `caseName(p1, p2)` — runtime tag dispatch, payloads printed
            // recursively by their declared types.
            guard let enumDecl = moduleEnums.first(where: { $0.name == name }),
                let aggregate = type.nominalAggregateSpelling
            else {
                fatalError("IREmitter: printing unregistered enum (IRLowerer guarantees)")
            }
            let tagPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: tagPtr, aggregate: aggregate, base: value.ssaName, indices: [0, 1]) + "\n"
            let tag = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: tag, type: "i32", ptr: tagPtr) + "\n"
            let id = builder.freshLabel()
            let endLabel = "fmt.enum.end.\(id)"
            for (caseIndex, enumCase) in enumDecl.cases.enumerated() {
                let matchesTag = builder.freshTemp()
                bodyIR += " \(matchesTag) = icmp eq i32 \(tag), \(enumCase.tag)\n"
                let armLabel = "fmt.enum.arm.\(id).\(caseIndex)"
                let nextLabel =
                    caseIndex + 1 < enumDecl.cases.count
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
                        bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: value.ssaName, indices: [0, slot + 2]) + "\n"
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

    /// 登记一个字符串常量（去重），返回它的全局名与字节长度。
    ///
    /// ⭐ 与 `emitStringConstant` 分家的理由只有一个：**取串的 GEP 由谁发**。
    /// 那个函数把 GEP 写进 `bodyIR`（当前插入点），而帧序要的是一条能排在任何块之前的取串指令 ——
    /// 由调用方自己发。⛔ 两处**不各算一次**：常量的登记与去重仍然只有这一份实现。
    private func registerStringConstant(_ value: String) -> (name: String, length: Int) {
        if let existing = stringConstants[value] { return existing }
        let id = stringConstantDefs.count
        let name = "@.str\(id)"
        let bytes = Array(value.utf8)
        let length = bytes.count + 1
        var hex = ""
        for byte in bytes {
            hex += String(format: "\\%02X", byte)
        }
        stringConstantDefs.append("\(name) = private constant [\(length) x i8] c\"\(hex)\\00\"")
        let entry = (name: name, length: length)
        stringConstants[value] = entry
        return entry
    }

    private func emitStringConstant(_ value: String) -> IRValue {
        let entry = registerStringConstant(value)
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

    /// 这个名字是否与发射器**自己生成**的局部名同形。
    ///
    /// 生成名只有四族：`freshTemp` 的 `%t<数字>` · `freshSlot` 的 `%<mangled>_slot` 与
    /// `%<mangled>_slot_<k>` · 帧式体的 `%de6b.*` · 闭包形参的 `%arg<数字>_slot`。
    /// 源码标识符落进其中任何一族，生成的 IR 里就是**两个同名局部值**。
    static func isEmitterLocalShape(_ name: String) -> Bool {
        if name.hasPrefix("de6b.") { return true }
        if name.count > 1, name.hasPrefix("t"), name.dropFirst().allSatisfy({ $0.isNumber }) {
            return true
        }
        if name.hasSuffix("_slot") { return true }
        if let r = name.range(of: "_slot_", options: .backwards) {
            let tail = name[r.upperBound...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber }) { return true }
        }
        return false
    }

    /// 形参的 SSA 名，与 `params` **按位置一一对应**。
    ///
    /// ⭐ 规则：**只在必要时改名** —— 名字落进发射器自有命名族（`isEmitterLocalShape`），
    /// 或与前面某个形参重名。其余一律**原样**，故不相撞的程序其 IR **逐字节不变**
    /// （既有 golden / 字节级门禁不受影响）。
    ///
    /// 改名形如 `<原名>.p<序号>`：`.p` 同时避开两族（族成员要么是 `t<数字>`、要么以
    /// `_slot` 结尾），且 `.` 不在语言的标识符字符集里 ⇒ 源码名**不可能**先占这个形状。
    /// ⚠️ 与 `%<名字>_slot` 同级的另一处是**槽名**，它由 `freshSlot` 的计数器保证唯一
    /// —— 两处各自收敛，才不会有「一处唯一、另一处不唯一」的漏网。
    private func parameterSSANames(_ names: [String]) -> [String] {
        var taken = Set<String>()
        var out: [String] = []
        for (index, name) in names.enumerated() {
            let raw = Self.mangle(name)
            var candidate = raw
            if Self.isEmitterLocalShape(raw) || taken.contains(raw) {
                candidate = "\(raw).p\(index)"
                var bump = 0
                while taken.contains(candidate) || Self.isEmitterLocalShape(candidate) {
                    bump += 1
                    candidate = "\(raw).p\(index).\(bump)"
                }
            }
            taken.insert(candidate)
            out.append(candidate)
        }
        return out
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
    /// for both pipelines since G3; IRType spellings mangle through it too).
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
        paramTypes: [IRType],
        returnType: IRType?,
        captures: [IRCapture],
        body: IRBlock,
        type: IRType
    ) -> IRValue {
        let mangled = "@__closure_\(id)"
        let envPtr: String
        if captures.isEmpty {
            envPtr = "null"
        } else {
            let envTypeName = "%__closure_env_\(id)"
            closureEnvTypeDecls.append("\(envTypeName) = type { " + captures.map { _ in "ptr" }.joined(separator: ", ") + " }")
            let mallocTemp = builder.freshTemp()
            bodyIR += " \(mallocTemp) = call ptr @malloc(i64 \(captures.count * 8))\n"
            for (index, capture) in captures.enumerated() {
                guard let slot = lookupSlot(capture.name) ?? captureSlots[capture.name] else {
                    fatalError("IREmitter: capture '\(capture.name)' has no visible slot (IRLowerer guarantees)")
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
        callee: IRExpr,
        arguments: [IRExpr],
        returnType: IRType?
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
            fatalError("IREmitter: adapter for unknown function '\(mangled)' (IRLowerer guarantees)")
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

    // MARK: - 并发接线（`DE-3c`；让出路径 `DE-6b`）

    /// 让出点的**产出档位**（`DE-6c`）：这一处让出要不要把结果交给后续代码。
    ///
    /// ⭐ 抽成档位而不是两份发射函数：四个让出位置**只差这一点**，其余发射（求值 · 可让出的等待 ·
    /// 续跑点 · 让出块 · 续跑块）逐字共用。分成两份函数会让「同一个约定两处解释」的老毛病回来 ——
    /// 那条约定（三槽的装配、续跑块由入口 `switch` 跳入）本段只该有一处解释。
    private enum YieldProduce {
        /// 结果**丢弃** —— `S1`（`await f()` 独占一行）。⚠️ 丢弃的是**结果**，不是**等待**。
        case discard
        /// 结果**存进给定的帧槽** —— `S2` / `S3` / `S4` 都是这一档，只是槽的用途不同
        /// （分别是变量本身 · 判别式 · `try` 的操作数）。
        /// ⛔ 必须是**帧槽**：续跑块由入口 `switch` 跳入，让出点所在块里的 SSA 值**不支配**它。
        case frameSlot(String)
    }

    /// 一个**让出点**（`DE-6b` 立 · `DE-6c` 扩到四形态）：顶层语句根部的 `await`。
    ///
    /// 四处调用点，形态即位置：`S1` 裸语句 `await f()` · `S2` `var x = await f(...)` ·
    /// `S3` `match await f():` 的判别式 · `S4` `try await f() else …` 的 `try` 位。
    /// ⭐ 这四个正是降载层已经**明文承诺合法**的位置（它那条位置报文的原话），本函数是把发射层
    /// 补齐到与那条承诺一致。
    ///
    /// 发射的形状（`DE-1` §3.2.1 / §3.2.2 的落地）：
    ///
    /// ```text
    ///   %hand = <派发 f(...)>
    ///   store ptr %hand, ptr <句柄帧槽>          ; 让出后它会丢，必须留在帧里
    ///   %st = call i32 @bk_task_await(%hand, %out0)
    ///   %isy = icmp eq i32 %st, 2
    ///   br i1 %isy, label %yield.k, label %de6b.resume.k
    /// de6b.resume.k:                             ; ← 也是「没让出」那条路的落点
    ///   %h = load ptr, ptr <句柄帧槽>            ; 不从 %hand 读：续跑是从入口 switch 跳进来的
    ///   %out = alloca {i64,i64,i64}
    ///   call i32 @bk_task_await(%h, %out)        ; 此时它已决 ⇒ 直线取值，不再让出
    ///   <三槽 → Result> → store 到 x 的帧槽
    /// yield.k:
    ///   store i64 k, ptr %frame                  ; 续跑点
    ///   ret <返回类型> undef                     ; 把控制流交还驱动器
    /// ```
    ///
    /// ⭐ **两个入口共用同一条取值路径**（`de6b.resume.k`）：没让出时也跳到这里，于是「构造 Result」
    /// 只有一份 —— 少一处两套口径的可能。代价是那条路上多一次 `bk_task_await` 调用，而它面对的
    /// 是一个**已决**对象（运行时在那条路上的动作是「查一下已决就直通」）。
    ///
    /// ⭐ **为什么续跑块不从 `%hand` 读句柄**：它由入口的 `switch` 直接跳进来，而 `%hand` 定义在
    /// 让出点那一块里 —— 那一块**不支配**续跑块。帧槽才是两侧都够得着的地方。
    ///
    /// ⛔ **限层**：只允许出现在函数体那一层（`blockDepth == 1`）。嵌套在 `if` / `match` / 循环
    /// 里的让出点，其所在块依赖外层块先算出的值（条件、被匹配的主题），而续跑的跳转会整段跳过
    /// 那些计算 ⇒ 那些值**不支配**续跑块。限在顶层就没有这个问题：顶层语句之间只经**帧**传值。
    private func emitYieldPoint(awaited: IRExpr, type: IRType, produce: YieldProduce) {
        guard blockDepth == 1 else {
            fatalError(
                "IREmitter: a resumable `await` must sit at the top level of an async body"
                    + " (nested control flow has no resume entry yet)")
        }
        guard case .result(let okType) = type else {
            fatalError("IREmitter: await site type is not a Result (IRLowerer guarantees)")
        }
        // ⭐ 载荷宽度只在**真搬运**时才成为约束：`S1` 把结果丢弃 ⇒ 没有搬运通道要过，
        // 于是聚合载荷的 `await` 在那条路上是合法的。⛔ 不许把这个检查提到前面 ——
        // 那会让「丢弃」凭空多出一条与它无关的限制。
        if case .frameSlot = produce {
            guard isSingleWordPayload(okType) else {
                fatalError(
                    "IREmitter: task ok payload '\(okType.llvmSpelling)' is an aggregate — the three-slot task ABI carries one word")
            }
        }
        let handle = emitExpr(awaited)
        guard handle.llvmType == "ptr" else {
            fatalError("IREmitter: await operand is not a task handle (IRLowerer guarantees)")
        }
        yieldPointCount += 1
        let index = yieldPointCount
        // 句柄槽也走 `declareLocalSlot`：**同一个**声明序列 ⇒ 帧序里那串 `bk_task_slot` 的顺序与
        // 体走出来的顺序逐项一致，重放才命中同一批块。（名字给的是裸名，`%de6b.` 前缀由该函数加。）
        let handleSlot = declareLocalSlot(named: "%pending_handle_\(index)", spelling: "ptr")
        bodyIR += builder.fmtStore(value: handle.ssaName, type: "ptr", ptr: handleSlot) + "\n"

        let preOut = builder.freshTemp()
        bodyIR += " \(preOut) = alloca { i64, i64, i64 }, align 8\n"
        let status = builder.freshTemp()
        bodyIR += " \(status) = call i32 @bk_task_await(ptr \(handle.ssaName), ptr \(preOut))\n"
        let yields = builder.freshTemp()
        bodyIR += " \(yields) = icmp eq i32 \(status), 2\n"
        bodyIR += builder.fmtCondBr(cond: yields, thenLabelName: "de6b.yield.\(index)", elseLabelName: "de6b.resume.\(index)") + "\n"

        bodyIR += "de6b.yield.\(index):\n"
        bodyIR += builder.fmtStore(value: "\(index)", type: "i64", ptr: "%de6b.frame") + "\n"
        // 让出 = **从栈返回**。⛔ 这里**不**跑 defer、**不**释放句柄：体还没结束。
        let returnSpelling = currentReturnType?.llvmSpelling ?? "void"
        bodyIR += " ret \(returnSpelling) undef\n"

        bodyIR += "de6b.resume.\(index):\n"
        let handleReloaded = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: handleReloaded, type: "ptr", ptr: handleSlot) + "\n"
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        // 返回值**刻意丢弃**：与 `emitJoin` 同一条口径 —— 三槽已由运行时归一化，状态位不必再判。
        bodyIR += " call i32 @bk_task_await(ptr \(handleReloaded), ptr \(out))\n"
        // ⭐ 产出档位在这里分岔 —— 这是本段唯一的形态差异，其余发射**逐字共用**。
        switch produce {
        case .discard:
            // `S1`（`await f()` 独占一行）：结果按语言语义**丢弃** ⇒ 续跑块到此为止。
            // ⚠️ 仍然保留上面那次 `bk_task_await`：丢弃的是**结果**，不是**等待**。
            // 语义上 `await f()` 承诺「等它跑完」，而那条承诺的兑现点就是这次调用
            // （已决 ⇒ 运行时直通）；省掉它会让「丢弃结果」顺带丢掉「等待」。
            break
        case .frameSlot(let slot):
            let filled = collectResult(from: out, type: type, okType: okType)
            bodyIR += builder.fmtStore(value: filled.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"
        }
    }

    /// 三槽 → `Result` 聚合（与 `emitJoin` 的装配**同形**；`DE-1` §3.1 的三槽约定只有一处解释）。
    private func collectResult(
        from out: String, type: IRType, okType: IRType
    ) -> IRValue {
        let tag = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: tag, type: "i64", ptr: out) + "\n"
        let okSlot = builder.freshTemp()
        bodyIR += builder.fmtGEPByteOffset(name: okSlot, base: out, offset: "8") + "\n"
        let okValue = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: okValue, type: okType.llvmSpelling, ptr: okSlot) + "\n"
        let errSlot = builder.freshTemp()
        bodyIR += builder.fmtGEPByteOffset(name: errSlot, base: out, offset: "16") + "\n"
        let errValue = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: errValue, type: "i64", ptr: errSlot) + "\n"
        let resultType = type.llvmSpelling
        let withTag = builder.freshTemp()
        bodyIR += " \(withTag) = insertvalue \(resultType) undef, i64 \(tag), 0\n"
        let withOk = builder.freshTemp()
        bodyIR += " \(withOk) = insertvalue \(resultType) \(withTag), \(okType.llvmSpelling) \(okValue), 1\n"
        let filled = builder.freshTemp()
        bodyIR += " \(filled) = insertvalue \(resultType) \(withOk), i64 \(errValue), 2\n"
        return IRValue(llvmType: resultType, ssaName: filled)
    }

    /// 一次异步调用在发射层的落点 = 一次**派发**。
    ///
    /// 「急切派发」在这里是可测的：建盒、认父、起线程三件做完**才**返回，
    /// 于是调用方拿到句柄的那一刻，体已经在自己推进。
    ///
    /// 实参经一段**堆上的缓冲**交给体，而不是放在调用方的栈上：体跑在另一条线程上，
    /// `detach` 之后调用方的帧可能已经不在 —— 栈上的实参会变成悬垂引用。
    /// 每个槽先**加宽成一个字**再写（`widenToWord`），取回时成对收窄（`narrowWord`），
    /// 故任何位型都逐位往返。
    ///
    /// ⭐ `DE-6b`：那块缓冲**升格为「体的持久帧」**（`DE-1` §3.2.2）—— 由运行时分配
    /// （`bk_task_frame`，**已清零**，故帧头那个「续跑点 = 0」不必再发一条 store）、由运行时交还，
    /// 而**不再**由体 wrapper 释放。布局：`[0..8)` = 续跑点 · `[8 + 8i ..)` = 第 i 个形参（加宽后的字）。
    private func emitTaskSpawn(callee: IRFunction, mangled: String, args: [IRValue]) -> IRValue {
        usesTaskRuntime = true
        emitTaskBodyWrapper(callee: callee, mangled: mangled)
        let envRaw = builder.freshTemp()
        usesTaskFrame = true
        bodyIR += " \(envRaw) = call ptr @bk_task_frame(i64 \(8 + args.count * 8))\n"
        for (index, arg) in args.enumerated() {
            let slot = builder.freshTemp()
            bodyIR += builder.fmtGEPByteOffset(name: slot, base: envRaw, offset: "\(8 + index * 8)") + "\n"
            let word = widenToWord(arg)
            bodyIR += builder.fmtStore(value: word.ssaName, type: "i64", ptr: slot) + "\n"
            // 容器形参必须**留一份自己的份额**：体可能晚于调用方起跑，而 `detach` 之后
            // 调用方的帧已经不在了。份额由 wrapper 在体**真跑完**时还回（配对点见该函数；
            // 让出时**不**还 —— 体还在用它们）。
            retainIfOwningContainer(arg, type: callee.params[index].type)
        }
        // `code` 按空指针传：体的入口是**每函数一个**的 wrapper，调用点不需要再指定一份。
        // 末尾两个实参是 ok 载荷描述（`DE-1` §3.1 的 `elemBytes` / `elemTag`）——
        // ⛔ 此处**刻意留 0**：本段接线的两个符号都不读它们（消费者是尚未接线的聚合 join）。
        let handle = builder.freshTemp()
        bodyIR +=
            " \(handle) = call ptr @bk_task_spawn(ptr @__task_body_\(mangled), ptr null, ptr \(envRaw), i32 0, i32 0)\n"
        // `Q-4` 乙段：把调度器绑定交给运行时。⭐ 派发点是「这个任务属于哪个调度器」的
        // **唯一知情处** —— 设计里「派发点把调度器写进盒子」那句话的落点就在这一行。
        emitSchedulerBinding(handle: handle)
        return IRValue(llvmType: "ptr", ssaName: handle)
    }

    /// 每个异步函数一份的**体 wrapper**（`DE-1` §3.1 的 `i32 (code, env, out)` 形态）。
    ///
    /// 为什么需要它：运行时要的是「一个 C 函数指针 + 一段实参缓冲」，而被调用方的 IR 签名是
    /// 它自己的形参表 —— 两者之间必须有人把缓冲拆成形参、再把体的返回摊进三槽。这份 wrapper
    /// 就是那个人，每个函数一份、按 IR 名去重（照 `@__adapter_` 的同一套）。
    ///
    /// ⭐ `DE-6b`：它同时负责**把两态报告给运行时**。判据不是别的，就是**帧头那个字**：
    /// 体在让出前会把续跑点写进去，而入口每次进入都会把它清零 ⇒ 「跑完之后它是不是 0」精确地
    /// 区分了两态，不必再加一个标志字。
    ///
    /// - Returns: `0` = 体跑到底、三槽已写。⭐ `2` = 体已让出 —— `out` **一个字节都不写**，
    ///   容器形参的份额也**不**还（体还在用它们；那是续跑方的责任）。
    private func emitTaskBodyWrapper(callee: IRFunction, mangled: String) {
        let name = "__task_body_\(mangled)"
        guard !taskBodyNames.contains(name) else { return }
        guard case .result(let okType)? = callee.returnType else {
            fatalError("IREmitter: task body wrapper needs a Result-returning body (emitTaskSpawn gates this)")
        }
        let okSpelling = okType.llvmSpelling
        let resultType = IRType.result(ok: okType).llvmSpelling
        taskBodyNames.insert(name)
        var body = ""
        var callArgs: [String] = []
        var containerArgs: [(spelling: String, name: String)] = []
        for (index, param) in callee.params.enumerated() {
            let spelling = param.type.llvmSpelling
            let slot = builder.freshTemp()
            // 形参区自 **8** 起：帧头那 8 字节是续跑点（`DE-6b`）。
            body += builder.fmtGEPByteOffset(name: slot, base: "%env", offset: "\(8 + index * 8)") + "\n"
            let word = builder.freshTemp()
            body += builder.fmtLoad(name: word, type: "i64", ptr: slot) + "\n"
            let (instruction, value) = narrowWord(word, to: spelling)
            body += instruction
            callArgs.append("\(spelling) \(value)")
            if isOwningContainer(param.type) {
                containerArgs.append((spelling, value))
            }
        }
        // ⛔ `DE-6b` 起帧**不在这里释放**（旧形状在这里 `free(%env)`）：帧跨让出存活，只在体
        // **真跑完**时才该交还，而「真跑完」是下面那个分支才知道的事；何况所有权已归运行时
        // （由它分配、由它交还），这里是第二条释放路径的话就是 double free。
        let result = builder.freshTemp()
        body += " \(result) = call \(resultType) @\(mangled)(\(callArgs.joined(separator: ", ")))\n"
        let resumePoint = builder.freshTemp()
        body += builder.fmtLoad(name: resumePoint, type: "i64", ptr: "%env") + "\n"
        let yielded = builder.freshTemp()
        body += " \(yielded) = icmp ne i64 \(resumePoint), 0\n"
        body += builder.fmtCondBr(cond: yielded, thenLabelName: "yielded", elseLabelName: "finished") + "\n"
        body += "yielded:\n"
        body += " ret i32 2\n"
        body += "finished:\n"
        // 与派发侧的 retain 配对：容器形参的份额在体**真跑完**之后还回。
        for container in containerArgs {
            let raw = builder.freshTemp()
            body += " \(raw) = bitcast \(container.spelling) \(container.name) to ptr\n"
            body += " call void @bk_handle_release(ptr \(raw))\n"
        }
        // 三槽：槽 0 = tag · 槽 1 = ok 载荷 · 槽 2 = err 载荷，一律**擦除为 i64 宽度**
        // （`DE-1` §3.1）；这与 `_bkTaskRunBody` 读回三槽的方式是同一条约定。
        let tagField = builder.freshTemp()
        body += " \(tagField) = extractvalue \(resultType) \(result), 0\n"
        let okField = builder.freshTemp()
        body += " \(okField) = extractvalue \(resultType) \(result), 1\n"
        let errField = builder.freshTemp()
        body += " \(errField) = extractvalue \(resultType) \(result), 2\n"
        let (okInstruction, okWord) = wordOf(okField, spelling: okSpelling)
        body += okInstruction
        body += builder.fmtStore(value: tagField, type: "i64", ptr: "%out") + "\n"
        let okSlot = builder.freshTemp()
        body += builder.fmtGEPByteOffset(name: okSlot, base: "%out", offset: "8") + "\n"
        body += builder.fmtStore(value: okWord, type: "i64", ptr: okSlot) + "\n"
        let errSlot = builder.freshTemp()
        body += builder.fmtGEPByteOffset(name: errSlot, base: "%out", offset: "16") + "\n"
        body += builder.fmtStore(value: errField, type: "i64", ptr: errSlot) + "\n"
        body += " ret i32 0\n"
        taskBodyDefs.append("define i32 @\(name)(ptr %code, ptr %env, ptr %out) {\n" + body + "}\n\n")
    }

    /// `await` / `wait` 的落点（`DE-1` §3.1 的 `bk_task_join`）。
    ///
    /// ⭐ `DE-6b` 起**两形分岔**：`await` 在**可恢复体的顶层语句**处走让出路径（那条路不走本函数，
    /// 见 `emitYieldPoint`），而**到达本函数的 `await`** 本段**响亮拒绝**。
    ///
    /// ⚠️ **谁还会到达这里**（2026-09-24 订正）：原先这里列的是「`match` / `try` 的操作数、表达式
    /// 内部、闭包体」—— 那份清单里**位置**那一半已经不成立了：同一天起，**嵌套位置与表达式内部
    /// 位置在降载层就被拒**（`E6-010`），根本到不了发射层。⇒ 今天仍会到达本函数的只剩**一种**：
    /// **拿不到可恢复帧的体**里的顶层 `await` —— 即**无声明返回类型的异步体**（它不返回 `Result`，
    /// 因而没有承载续跑点的帧）以及闭包体（闭包不是任务，一律无帧）。
    /// ⚠️ 这一格**未收口**，仍以本处断言拒绝；它与上面那批不是一个量级的事（那批是**位置**，
    /// 这一格是**体没有帧**），故分开记。
    ///
    /// ⛔ 为什么拒绝而不是照旧发射一条阻塞 join：`await` 的语义承诺是「把任务让出去」。在本函数
    /// 面对的这种体里若静默地按占用处理，就是**把承诺打折而不出声** —— 而本仓
    /// 反复吃亏的正是这种形态。
    ///
    /// `wait`（`.waits`）与 `joinWithin` 一类的聚合等待**不受影响**：它们的承诺就是阻塞。
    ///
    /// 状态位**不由本段判断**：`status` 非 0 时运行时已经把三槽写成「非 ok」，
    /// 所以这里无条件读三槽即得正确的 `Result` —— 少一个分支，也少一处可能与运行时
    /// 不同的口径。
    private func emitJoin(future: IRExpr, type: IRType, form: JoinForm) -> IRValue {
        if form == .awaits {
            fatalError(
                "IREmitter: a resumable `await` needs a frame — this body has none"
                    + " (an async body with no declared Result return, or a closure body)."
                    + " Nested and in-expression positions are refused earlier, in lowering")
        }
        usesTaskRuntime = true
        guard case .result(let okType) = type else {
            fatalError("IREmitter: join site type is not a Result (IRLowerer guarantees)")
        }
        // 载荷宽度：三槽把载荷**擦除为 i64**（`DE-1` §3.1）⇒ 只有单字载荷能原样往返。
        // 聚合载荷（元组 / optional / 嵌套 Result 的值形态）今天没有搬运通道，故在这里
        // 响亮拒绝，而不是搬一个错的值回来。
        guard isSingleWordPayload(okType) else {
            fatalError(
                "IREmitter: task ok payload '\(okType.llvmSpelling)' is an aggregate — the three-slot task ABI carries one word")
        }
        let handle = emitExpr(future)
        guard handle.llvmType == "ptr" else {
            fatalError("IREmitter: join operand is not a task handle (IRLowerer guarantees)")
        }
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        bodyIR += " call i32 @bk_task_join(ptr \(handle.ssaName), ptr \(out))\n"
        // 三槽 → `Result` 的装配与让出路径**共用一份**实现：这条约定（`DE-1` §3.1）只该有一处解释。
        return collectResult(from: out, type: type, okType: okType)
    }

    /// 需要**份额**的句柄类型（容器）：它们的生命周期由运行时的份额计数管，
    /// 跨线程借用必须自己留一份。字符串是裸 C 串、标量是值，都不在此列
    /// （与 `emitRetainIfAliased` 认定的集合一致）。
    private func isOwningContainer(_ type: IRType) -> Bool {
        ["%bk_array*", "%bk_dict*", "%bk_set*"].contains(type.llvmSpelling)
    }

    private func retainIfOwningContainer(_ value: IRValue, type: IRType) {
        guard isOwningContainer(type) else { return }
        usesTaskArgRelease = true
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr\n"
        bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
    }

    /// ok 载荷能否住进**一个字**（三槽 ABI 的宽度）。聚合值（元组 / optional / 嵌套 Result）
    /// 需要多于一个字，本后端没有搬运通道。
    private func isSingleWordPayload(_ type: IRType) -> Bool {
        switch type {
        case .tuple, .optional, .result: return false
        default: return true
        }
    }

    /// 把 env 槽里的一个字**收窄**回形参的 IR 拼写 —— `widenToWord` 的逆。
    /// 返回的指令文本为空表示该拼写本身就是字宽（`i64`），直接沿用那个名字。
    private func narrowWord(_ word: String, to spelling: String) -> (instruction: String, name: String) {
        let name = builder.freshTemp()
        switch spelling {
        case "i64":
            return ("", word)
        case "i32":
            return (" \(name) = trunc i64 \(word) to i32\n", name)
        case "i8":
            return (" \(name) = trunc i64 \(word) to i8\n", name)
        case "i1":
            return (" \(name) = trunc i64 \(word) to i1\n", name)
        case "double":
            return (" \(name) = bitcast i64 \(word) to double\n", name)
        default:
            // 指针一族（`ptr` / `i8*` / `%bk_array*` / 具名聚合指针）按不透明指针还原。
            return (" \(name) = inttoptr i64 \(word) to \(spelling)\n", name)
        }
    }

    /// 把一个具名值**加宽成一个字**，返回指令文本。
    ///
    /// 与 `widenToWord` 的分工：那个往调用方的 `bodyIR` 里写，这个只**返回文本** ——
    /// 任务体 wrapper 要写进自己的缓冲，不能碰调用方的 `bodyIR`。
    private func wordOf(_ name: String, spelling: String) -> (instruction: String, name: String) {
        let temp = builder.freshTemp()
        switch spelling {
        case "i64":
            return ("", name)
        case "i32":
            return (" \(temp) = sext i32 \(name) to i64\n", temp)
        case "i8":
            return (" \(temp) = sext i8 \(name) to i64\n", temp)
        case "i1":
            return (" \(temp) = zext i1 \(name) to i64\n", temp)
        case "double":
            return (" \(temp) = bitcast double \(name) to i64\n", temp)
        default:
            return (" \(temp) = ptrtoint \(spelling) \(name) to i64\n", temp)
        }
    }

    /// Swap in a clean per-function state, emit the closure body into a
    /// private buffer, and record the buffered `define` for module-end
    /// assembly. Captures enter as slot pointers (reference capture: loads
    /// and stores go through the same slot the outer variable uses).
    private func emitClosureDefine(
        id: Int,
        mangled: String,
        paramNames: [String],
        paramTypes: [IRType],
        returnType: IRType?,
        captures: [IRCapture],
        body: IRBlock
    ) {
        let savedScopes = scopes
        let savedSlotCounters = slotCounters
        let savedTerminated = terminated
        let savedControlStack = controlStack
        let savedBreakMergeLabels = breakMergeLabels
        let savedDeferScopeBase = deferScopeBase
        let savedReturnType = currentReturnType
        let savedIsMain = currentIsMain
        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedCaptureSlots = captureSlots
        let savedCapturedNames = capturedNamesInFunction
        // A closure is its own release scope: its body block is frame 0 of a
        // fresh stack, exactly like a function body. Without this the closure
        // would inherit the enclosing function's frames, and a `return` inside
        // it (which releases down to frame 0) would drop the enclosing
        // function's top-level handles — an over-release.
        let savedPendingReleases = pendingReleases
        // `DE-6b`：闭包体是**自己的函数**，而它不是任务 ⇒ 没有帧可依。⛔ 不继承外层体的帧式：
        // 外层的帧槽是外层的，闭包体内的局部槽若发成「帧槽」，取的会是**外层那一块**（或者根本没有）。
        // 深度的重置同理 —— 闭包的函数体那一层也应该是 1。
        let savedFrameMode = frameMode
        let savedBlockDepth = blockDepth

        scopes = [[:]]
        slotCounters = [:]
        frameMode = .none
        blockDepth = 0
        terminated = false
        controlStack = []
        breakMergeLabels = []
        // A return inside the closure must not run the enclosing function's
        // defers: defer frames opened by the closure live above this base.
        deferScopeBase = pendingDefers.count
        currentReturnType = returnType
        currentIsMain = false
        builder = IRBuilder()
        bodyIR = ""
        captureSlots = [:]
        pendingReleases = []
        // 片 D：闭包体是**自己的**函数上下文 —— 它自己的嵌套闭包捕获的名字要在进体前算好
        // （同 `emitFunction` 的理由：声明点在捕获点之前）。
        capturedNamesInFunction = capturedNames(in: body)

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
            // parallels paramTypes (IRLowerer contract).
            let name = index < paramNames.count ? paramNames[index] : "param\(index)"
            scopes[scopes.count - 1][name] = slot
        }

        emitBlock(body)

        if !terminated {
            bodyIR += builder.fmtBr(labelName: "exit_block") + "\n"
            bodyIR += "exit_block:\n"
            // H1-B: drop the closure's own top-level handles on the
            // fall-through edge (a `return` emits its own copy before its ret).
            emitReleases(downTo: 0)
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
        controlStack = savedControlStack
        breakMergeLabels = savedBreakMergeLabels
        deferScopeBase = savedDeferScopeBase
        currentReturnType = savedReturnType
        currentIsMain = savedIsMain
        bodyIR = savedBodyIR
        builder = savedBuilder
        captureSlots = savedCaptureSlots
        pendingReleases = savedPendingReleases
        capturedNamesInFunction = savedCapturedNames
        frameMode = savedFrameMode
        blockDepth = savedBlockDepth
    }

    // MARK: - G9 string deepening

    /// `s.upper()` / `s.lower()` —— 契约 §2.9 第 36 条：**Unicode 感知**，接收者不变。
    ///
    /// ⛔ 旧形状是「memcpy 接收者 + 逐字节 `toupper`/`tolower`」：ASCII-only（实测
    /// `"café".upper()` 得 `CAFé`），而且那个 `memcpy` 落在**调用点的变长 `alloca`** 上
    /// —— 与 `substring` 同一个栈炸弹形状。语义与分配一起交给运行时段，
    /// 与解释器的 `.stringCase` 分支同源。
    private func emitStringCase(isUpper: Bool, source: String) -> IRValue {
        usesStringShims = true
        let symbol = isUpper ? "bk_string_upper" : "bk_string_lower"
        let converted = builder.freshTemp()
        bodyIR += " \(converted) = call ptr @\(symbol)(ptr \(source))\n"
        return IRValue(llvmType: "i8*", ssaName: converted)
    }

    /// `s.split(delim)` — a real `Array<String>`: two strtok passes over
    /// copies of the source (pass 1 counts tokens so bk_array_create gets
    /// the exact length; pass 2 fills), each token strdup'd into the array
    /// via bk_array_set (raw-ptr tag 3). strtok skips empty tokens —
    /// corpus-identical with the interpreter's sunk split.
    private func emitStringSplit(source: String, delim: String, type: IRType) -> IRValue {
        let slen = builder.freshTemp()
        bodyIR += " \(slen) = call i64 @strlen(ptr \(source))\n"
        // Room for the NUL copySource writes at index slen. Sized from the
        // source, not from a constant: the caller is routinely a whole file's
        // text (the selfhost scanner splits file content on newline), and a
        // fixed buffer overruns on it -- measured, ASan reports the copy as a
        // SEGV on a wild address.
        let slenRoom = builder.freshTemp()
        bodyIR += " \(slenRoom) = add i64 \(slen), 1\n"

        func copySource(_ buf: String) {
            bodyIR += " call ptr @memcpy(ptr \(buf), ptr \(source), i64 \(slen))\n"
            let nl = builder.freshTemp()
            bodyIR += " \(nl) = getelementptr i8, ptr \(buf), i64 \(slen)\n"
            bodyIR += builder.fmtStore(value: "0", type: "i8", ptr: nl) + "\n"
        }

        // Pass 1: count tokens.
        let countBuf = builder.freshTemp()
        bodyIR += " \(countBuf) = call ptr @malloc(i64 \(slenRoom))\n"
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
        bodyIR += " \(fillBuf) = call ptr @malloc(i64 \(slenRoom))\n"
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
        // +1 for the NUL strcpy writes: allocating strlen alone leaves the
        // terminator one byte past the region. Measured, not reasoned about —
        // ASan reports "WRITE of size 85 -> 84-byte region" in makeScanner.
        let dupRoom = builder.freshTemp()
        bodyIR += " \(dupRoom) = add i64 \(dupLen), 1\n"
        let dupBuf = builder.freshTemp()
        bodyIR += " \(dupBuf) = call ptr @malloc(i64 \(dupRoom))\n"
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
        // Both scratch copies are dead by here (strtok rewrote them in place).
        // The token strings themselves are strdup'd and belong to the array.
        bodyIR += " call ptr @free(ptr \(countBuf))\n"
        bodyIR += " call ptr @free(ptr \(fillBuf))\n"
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
    private func emitInterpString(parts: [IRExpr]) -> IRValue {
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
    private func emitStringPiece(_ part: IRExpr) -> IRValue {
        let type = irType(of: part)
        switch type {
        case .string, .char:
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
    private func stringifyValue(value: IRValue, type: IRType) -> IRValue {
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
        case .string, .char:
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
            fatalError("IREmitter: stringify of '\(type)' outside the G9 grid (IRLowerer gates interpolation parts)")
        }
    }
}
