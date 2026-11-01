import Foundation
import PiniBackendKit
import PiniSyntax
import PiniSemantics
import PiniIR

/// 当前函数（或闭包）有没有可恢复帧：决定局部槽落栈还是落帧、让出点能否发射。
/// 无帧的体（同步函数、闭包）保持原发射形状；让出只发生在异步体里。
private enum FunctionFrameMode {
    /// 普通体：局部槽落栈（今天的形状）。
    case none
    /// 可恢复体：局部槽落帧，允许在顶层语句处让出。
    case resumable
}

/// 把已定型的 IR 翻译成 LLVM IR 文本：类型决策全由 `IRLowerer` 做完，此处不做推断、
/// 不维护影子类型表、无未支持分支，每次发射新建一个实例。输出可直接由 `lli`/`clang` 执行，
/// stdout 语义与解释器一致（print 带换行、布尔为 true/false、double 走 %f）。
public final class IREmitter {

    // MARK: - 名义箱头布局

    /// 头四格的 LLVM 拼写，顺序同 `PiniHeader`：强计数 · 弱计数 · 类型标识 · 弱引用旁表指针。
    private static let nominalHeaderSpellings = ["i32", "i32", "i32", "ptr"]
    /// 当前模块的布局事实，`emit` 入口处取自 `module.layout`；槽位一律问它，发射器不再自己推。
    private var layout: IRLayout = .standard

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

    /// 可中断帧栈，最内层在末尾。`break` 指向 `exit`，`continue` 指向 `continueTarget`
    /// （有 step 块时为 step 入口，否则为 header）；带标签的形式指向第 depth 帧的 `header`。
    /// 带标签的 `if` 也是帧，其两个续跑标签都设为 merge 块（同时也是 `exit`）。
    private struct ControlFrame {
        let exit: String
        let header: String
        let continueTarget: String
        /// `false` for a labeled `if` block: a frame `break` may leave but
        /// `continue` may not target.
        let isLoop: Bool
        /// 本帧在清理栈中的起始下标。跳出时由内向外执行到该下标（含两端），
        /// 与解释器沿 `executeBlock` 弹出作用域等价。
        let cleanupBase: Int
    }

    private var controlStack: [ControlFrame] = []

    /// 被 `break` 跳到的 merge 块。`emitIf` 按两支是否各自终止决定是否发射 merge 标签，
    /// 而离开 `if` 的 `break` 本身是终止指令却仍落该标签，故必须发射。只有非循环帧记录。
    private var breakMergeLabels: Set<String> = []

    /// 当前函数（或闭包）在清理栈中的起点。`return` 只冲刷到此处，
    /// 故闭包内的 return 不执行外层函数的清理。
    private var cleanupScopeBase = 0

    private var currentIsMain = false
    private var currentReturnType: IRType? = nil

    /// 当前函数是 `|test` 且本模块正按测试驱动器发射——「此刻是否按测试口径发射」，
    /// 两个条件缺一不可；「是不是测试函数」这一事实在 `IRFunction.isTest` 上。
    private var currentIsTest = false

    /// 本函数的测试出口标签：测试模式下失败断言跳到它。解释器里失败断言是 panic 信号，
    /// 中止本测试剩余语句后在调用边界收成一条失败结果；陷阱做不到「交回控制权」，故设此落点。
    private var currentTestExitLabel: String? = nil

    private var builder = IRBuilder()
    private var bodyIR = ""

    /// Nominal type declarations of the module being emitted (G3) — field
    /// layouts for constructor / field-access GEPs.
    private var moduleTypes: [IRTypeDecl] = []

    /// Enum declarations of the module being emitted (G4) — case tags and
    /// payload types for construction and match dispatch.
    private var moduleEnums: [IREnumDecl] = []

    // MARK: - Module-level collected pieces

    /// 名义类型 → 模块内类型标识。0 保留给「未知」，故编号从 1 起；结构体与枚举共用一段连续编号。
    private var structTypeIDs: [String: Int32] = [:]
    private var enumTypeIDs: [String: Int32] = [:]

    private var stringConstantDefs: [String] = []
    private var stringConstants: [String: (name: String, length: Int)] = [:]
    /// 匿名常量（`@.str<序号>`）已发出几个 —— 具名常量不计入，故不影响它们的编号。
    private var anonymousStringConstantCount = 0
    private var usesStrCmp = false

    // MARK: G6 closure / higher-order state

    /// 延迟发射的闭包 `define` 体：发射函数时先缓冲，模块末尾统一追加，
    /// 好让主函数体的 SSA 命名空间保持干净。
    private var closureDefs: [String] = []
    /// Deferred env struct type declarations, referenced by creation-point
    /// GEPs before the closure bodies are appended (forward refs legal).
    private var closureEnvTypeDecls: [String] = []
    /// Env-ignoring adapter definitions for named functions used as values
    /// (`@__adapter_<mangled>`), deduplicated by mangled name.
    private var adapterDefs: [String] = []
    private var adapterNames: Set<String> = []
    /// 正在发射的闭包体内活跃的捕获槽指针：捕获名 → 持有该变量槽指针的寄存器。
    /// 与作用域槽同表登记，故体内的 `load`/`storeVar` 一律走槽（引用捕获）。
    private var captureSlots: [String: String] = [:]
    /// Module function registry by mangled IR name (G6): adapter generation
    /// reads the original ABI (params/return) from here.
    private var moduleFunctions: [String: IRFunction] = [:]
    /// 是否用到 `%bk_lazyref` 句柄类型与 `bk_lazyref_*` 这组 C ABI：头声明按需追加，
    /// 从不触碰 LazyRef 的模块其 IR 保持逐字节不变。
    private var usesLazyRef = false
    /// `writeFile`/`readFile` pull in the stdio declares and the
    /// mode-string constants. Conditional for the same golden-IR reason
    /// as the other optional headers.
    private var usesFileWrite = false
    /// `appendFile` pulls in the append shim's declare. Kept separate from
    /// `usesFileWrite` on the same conditional-declare contract: a module that
    /// never appends must not grow a declare line (golden IR stays put).
    private var usesFileAppend = false
    /// 是否用到 `readFile`：整文件读取走运行时 `bk_read_file` 而非发射的 stdio——
    /// 固定栈缓冲装不下整文件，且 LLI 的 JIT 下读取前无法得知大小。头声明同样按需追加。
    private var usesFileRead = false
    /// 可接住的 IO：`tryReadFile` / `tryWriteFile` / `tryAppendFile` 各拉一条 declare。
    /// 三个分开而不是一个 flag —— 同一份「从不接错误的模块不得多出 declare 行」的
    /// 金样契约（与上面三条同规）。
    private var usesFileTryRead = false
    private var usesFileTryWrite = false
    private var usesFileTryAppend = false
    /// `readLine` pulls in the `fgets` declare and the stdin stream
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
    /// 是否调用过 `moduleRoot` —— 落点是 `bk_module_root`。
    ///  行不通  不并入 `usesProcessShims`：那一族的声明是整批固定输出的，共用的代价是只调 `argv`
    /// 或 `listDir` 的程序凭空多出本符号的声明，而它们的产物必须逐字节不变。
    private var usesModuleRootShim = false
    /// 是否在进程入口注入了程序基准（`bk_set_program_base`）—— declare 随之条件出现。
    ///  行不通  它**不**复用 `usesProcessShims`：注入发生在入口，而入口可能早于任何 IO 调用点发射。
    private var usesProgramBase = false
    /// 是否发射过错误载荷族调用（`bk_error_create` / `bk_cancel_error_create` /
    /// `bk_error_is_cancel` / `bk_error_message`）。四者同开关：构造与读取成对出现，
    /// 拆成四个布尔只会同时翻转；未被调用的声明不改变产物语义。
    private var usesErrorShims = false
    /// 是否发射过字符串字素簇族调用（`bk_substring` / `bk_string_count` / `bk_string_char_at` /
    /// `bk_string_slice` / `bk_string_upper` / `bk_string_lower` / `bk_string_contains`）。
    /// 字素簇边界是 Unicode 分段算法，发射器发不出，故整族落在运行时段，与解释器同一模型。
    private var usesStringShims = false

    /// 是否发射过名义箱分配（`bk_nominal_alloc`）：结构体/对象/枚举的箱走运行时堆分配，
    /// 三族统一带引用计数头。只有真正构造名义值的模块才带这条 declare。
    private var usesNominalBoxes = false

    /// 是否发射过字符串引用计数调用（`bk_str_retain` / `bk_str_release`）。累积形态
    /// `self.buf = self.buf + line` 每次丢弃旧串，没人回收的话峰值等于各次结果长度之和；
    /// 本条即为此而开。不涉计数字符串的模块 IR 逐字节不变。
    private var usesStringRefcount = false

    /// 本层当前持有 +1 引用的字符串 SSA 名（发射器侧账本）。入账：本层分配的堆串；
    /// 出账：交出份额（存槽/return/存元素/存字段）或就地消费（打印/运算/传内建）。
    /// 中间串既不落槽也非最终值，没有这本账就无人释放，正是二次方项的来源。
    private var heldStrings: Set<String> = []

    /// `heldStrings` 需要跨函数隔离：函数体发射前保存、发射后恢复。
    private var heldStringsStack: [Set<String>] = []

    /// 本层新分配、尚无持有者的名义箱 / 容器句柄：SSA 名 → 类型。与 `heldStrings` 同一本账的另一半
    /// （字符串族固定走 `bk_str_release`，故那边只记名字）。入账：构造点；出账：被持有位置接管，或就地还。
    /// 未出账的条目最多是泄漏（现状）， 行不通  不会被二次释放 —— 键是双端唯一的 SSA 名。
    private var heldBoxes: [String: IRType] = [:]

    /// 与 `heldStringsStack` 同规：函数体 / 闭包体 / 给定初始化器各持一份，`IRBuilder` 重新编号 ⇒ 不能串。
    private var heldBoxesStack: [[String: IRType]] = []

    /// 本函数（或闭包体）中被闭包捕获的变量名。必须在进体前算出：捕获槽要在分配那一刻
    /// 就知道会被带走，而 `allocVar` 总在闭包字面量之前，事后补不了。
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

    // MARK: - 可恢复帧

    /// 当前正在发射的函数/闭包有没有可恢复帧。它是闸而非优化开关：同时决定局部槽落栈
    /// 还是落帧、让出点能否发射、无帧时是否响亮拒绝。闭包体一律 `.none`。
    private var frameMode: FunctionFrameMode = .none

    /// 块嵌套深度：函数体那一层是 1，顶层语句的让出点只允许出现在这一层。
    /// 续跑靠入口 `switch` 直接跳回让出点所在块；嵌套在 `if` / `match` / 循环里的让出点，
    /// 其块依赖外层先算出的条件或被匹配主题，而那条路径续跑时被跳过 ⇒ 不支配续跑块。
    private var blockDepth = 0

    /// 本函数帧里要取的槽，**按声明顺序**。顺序即重放顺序 —— `bk_task_slot` 的游标按同一顺序
    /// 命中上次发过的那一块（见 `declareLocalSlot`）。
    private var frameSlotDecls: [(name: String, spelling: String)] = []

    /// 已发射的让出点个数（`de6b.resume.<k>` 的 `k` 从 1 数起；入口的 `switch` 按它生成）。
    private var yieldPointCount = 0

    /// 是否发射过帧的取用 —— `bk_task_frame` / `bk_task_slot` 的 declare 随之条件出现。
    private var usesTaskFrame = false

    /// 是否发射过 `cancel` —— 落点是运行时的取消入口，声明与派发族分开：不取消的模块不多一行。
    private var usesTaskCancel = false

    /// 是否发射过 `joinWithin` —— 三槽装配与 `join` 同形，只是多一个时限参数，声明也分开。
    private var usesTaskJoinWithin = false

    /// 是否发射过 `joinAll` —— 聚合 join 另走一条入口，声明同样只在用时出现。
    private var usesTaskJoinAll = false

    /// 是否发射过变量数组形态的 `joinAll` —— 它让运行时逐槽取句柄，符号与上一条不同。
    private var usesTaskJoinAllBox = false

    /// 是否调用过 `cstr` —— 外部 C 串转换走 `bk_cstr`，声明随它条件出现。
    private var usesCStrShim = false

    /// 是否把调度器绑定交给过运行时；declare 随它条件出现，只有真发过的模块才带。
    /// 它是「派发点会取用默认调度实例」的唯一征兆，与让出族那几个开关同规。
    private var usesSchedBinding = false

    /// 默认实例的存放位（程序级槽位，每个给定块类型一个）与已发过的类型名集合。
    /// 定义处即声明所在文件，发射层按类型名只发一次；整包降载为单个 `IRModule`，
    /// 同包其它文件引用同一个定义，故不需要 `external`。
    private var givenSlotDefs: [String] = []
    private var givenSlotNames: Set<String> = []
    /// 合成的**初始化函数** `ptr @__given_init_<T>(ptr %out)` —— 把该类型的字段初值
    /// 写进运行时给的缓冲。与 LazyRef 那条 wrapper 同理：一次合成、按类型去重。
    private var givenInitializerDefs: [String] = []
    private var givenInitializerNames: Set<String> = []

    /// Program base handed to the runtime at entry: the emitted entry calls `bk_set_program_base`
    /// once, and every IO path — literal or not — is resolved there, so no path is baked here.
    /// Nil (default) emits no setter and leaves relative paths to the CWD: a codegen knob, not IR data.
    public var programBase: String?

    /// 测试模式：非 nil 时本模块按测试驱动器发射，该值即报告首行正文；默认 nil，关闭时产物逐字节不变。
    /// 打开后跳过程序入口、`|test` 内的失败断言改记标志并跳到本函数测试出口、合成驱动器与入口，
    /// 报告由驱动器自己写完 —— 解释器那条路也是「程序输出在前、报告收尾」，两腿 stdout 才逐字节同序。
    public var testReportHeader: String?

    /// 测试模式下要跑的测试（按名的有序清单）；nil = 模块里全部 `|test`。
    /// 「按路径收窄」由此兑现：驱动器只调用选中的那些，模块本身仍带全部函数 ——
    /// 收窄的是跑哪些、不是能看到什么。清单与降载结果同源，两条通道的顺序不会各自漂移。
    public var testSelection: [String]?

    private var testMode: Bool { testReportHeader != nil }

    /// 失败标志与断言消息的模块级插槽名。
    /// 刻意不用 `bk_*` 运行时段符号：驱动器与断言同在本模块，故运行时段不必改动，
    /// 也不新增跨 ABI 面（运行时段符号的增删另有纪律）。
    static let testFailedGlobal = "__pini_test_failed"
    static let testMsgGlobal = "__pini_test_msg"

    public init() {}

    // MARK: - Module

    public func emit(module: IRModule) throws -> String {
        refusals.removeAll()
        var header = "; Pini LLVM IR\n"
        header += "declare i32 @printf(ptr, ...)\n"
        header += Builtins.declaration(for: "bk_double_to_string")
        header += "declare void @free(ptr)\n"
        header += "declare double @sqrt(double)\n"
        header += "@fmt_int = private constant [3 x i8] c\"%d\\00\"\n"
        header += "@fmt_bool_true = private constant [6 x i8] c\"true\\00\\00\"\n"
        header += "@fmt_bool_false = private constant [7 x i8] c\"false\\00\\00\"\n"
        header += "@fmt_string = private constant [3 x i8] c\"%s\\00\"\n"
        header += "@fmt_newline = private constant [2 x i8] c\"\\0A\\00\"\n"
        /// 数组族：不透明句柄类型 + 运行时 C ABI 声明。LLVM IR 模块允许前向引用，
        /// 故 declare 一律无条件发射，未用到时只是无害的前向声明。
        header += "%bk_array = type { ptr }\n"
        header += Builtins.declaration(for: "bk_array_create")
        header += Builtins.declaration(for: "bk_array_len")
        header += Builtins.declaration(for: "bk_array_get")
        header += Builtins.declaration(for: "bk_array_set")
        header += Builtins.declaration(for: "bk_array_append")
        header += Builtins.declaration(for: "bk_handle_retain")
        header += Builtins.declaration(for: "bk_handle_ensure_unique")
        header += Builtins.declaration(for: "bk_array_ensure_unique_at")
        header += Builtins.declaration(for: "bk_panic")
        /// 默认实例取用（`slot` = 存放位地址，`init_fn` = 合成初始化函数，`bytes` = 聚合体大小）。
        /// 与 `bk_array_*` 同规：无条件声明，未用到时是无害的前向声明。
        header += Builtins.declaration(for: "bk_given_get")
        // Dict / set family (G5): opaque handles + runtime C ABI declares.
        header += "%bk_dict = type { ptr }\n"
        header += "%bk_set = type { ptr }\n"
        header += Builtins.declaration(for: "bk_dict_create")
        header += Builtins.declaration(for: "bk_dict_len")
        header += Builtins.declaration(for: "bk_dict_get")
        header += Builtins.declaration(for: "bk_dict_set")
        header += Builtins.declaration(for: "bk_dict_ensure_unique_at")
        header += Builtins.declaration(for: "bk_dict_key_at")
        header += Builtins.declaration(for: "bk_dict_val_at")
        header += Builtins.declaration(for: "bk_set_create")
        header += Builtins.declaration(for: "bk_set_len")
        header += Builtins.declaration(for: "bk_set_add")
        header += Builtins.declaration(for: "bk_set_at")
        // Collection release: the runtime owns the share count, so a destroy
        // on a handle that is still aliased only drops this holder's share.
        header += Builtins.declaration(for: "bk_array_destroy")
        header += Builtins.declaration(for: "bk_dict_destroy")
        header += Builtins.declaration(for: "bk_set_destroy")
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
        /// Foreign blocks declare their external signatures; symbols resolve at JIT link time (libc via
        /// the process image, dlopened libraries via `--dlopen`). Symbols declared elsewhere are skipped:
        /// libc ones by the fixed header above, runtime shims by the conditional tail below.
        let predeclared: Set<String> = ["printf", "malloc", "free", "strlen", "memcpy"]
        let runtimeShims: Set<String> = ["cstr"]
        for foreignBlock in module.foreigns {
            for func_ in foreignBlock.funcs
            where !predeclared.contains(func_.name) && !runtimeShims.contains(func_.name) {
                let symbol = IRName.mangle(func_.name)
                let params = func_.paramTypes.map { $0.llvmSpelling }.joined(separator: ", ")
                let ret = func_.returnType?.llvmSpelling ?? "void"
                header += "declare \(ret) @\(symbol)(\(params))\n"
            }
        }
        header += "\n"

        bodyIR = ""
        stringConstantDefs = []
        stringConstants = [:]
        anonymousStringConstantCount = 0
        usesStrCmp = false
        usesLazyRef = false
        usesFileWrite = false
        usesFileAppend = false
        usesFileRead = false
        usesFileTryRead = false
        usesFileTryWrite = false
        usesFileTryAppend = false
        usesReadLine = false
        usesTaskRuntime = false
        usesTaskArgRelease = false
        usesSleepShim = false
        usesCharacterShims = false
        usesProcessShims = false
        usesModuleRootShim = false
        usesProgramBase = false
        usesErrorShims = false
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
        // 测试模式的两个**每模一次**的状态：模块级重置（ 行不通  不放在 `emitFunction` 里 ——
        // 一个发射器的实例可以连发多个模块，留在上一个模块的值会让下一个模块的第一个函数
        // 误判自己是不是测试）。
        currentIsTest = false
        currentTestExitLabel = nil
        moduleTypes = module.types
        moduleEnums = module.enums
        layout = module.layout
        precondition(
            Self.nominalHeaderSpellings.count == layout.headerSlotCount,
            "头槽数与头拼写不符：布局说 \(layout.headerSlotCount) 槽，拼写给了 \(Self.nominalHeaderSpellings.count) 个")
        // Record every top-level function's ABI by mangled IR name so
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
        /// 名义类型定义（`%struct.X` / `%object.X` / 标签联合 `%enum.X`）先于其取值点发射，
        /// 故字段 GEP 面对的是完整类型。头四格由 `nominalHeaderSpellings` 统一给出，
        /// 分配 / retain / release / 释放胶水都只认它 ⇒ 三族偏移不会各自漂移。
        structTypeIDs = [:]
        for (index, typeDecl) in module.types.enumerated() {
            let aggregate = "%\(typeDecl.isObject ? "object" : "struct").\(IRName.mangle(typeDecl.name))"
            structTypeIDs[typeDecl.name] = Int32(index + 1)
            var fieldTypes = Self.nominalHeaderSpellings
            fieldTypes.append(contentsOf: typeDecl.fields.map { $0.type.llvmSpelling })
            bodyIR += "\(aggregate) = type { \(fieldTypes.joined(separator: ", ")) }\n"
        }
        enumTypeIDs = [:]
        for (index, enumDecl) in module.enums.enumerated() {
            let aggregate = "%enum.\(IRName.mangle(enumDecl.name))"
            /// 头四格之后是第 4 格的用例标签，载荷从第 5 格起 —— 与 `emitMatch` 的 enum 分支同一基准。
            enumTypeIDs[enumDecl.name] = Int32(module.types.count + index + 1)
            var fieldTypes = Self.nominalHeaderSpellings
            fieldTypes.append("i32")
            fieldTypes.append(contentsOf: enumDecl.slotTypes.map { $0.llvmSpelling })
            bodyIR += "\(aggregate) = type { \(fieldTypes.joined(separator: ", ")) }\n"
        }
        if !module.types.isEmpty || !module.enums.isEmpty {
            bodyIR += "\n"
        }
        for function in module.functions {
            /// 测试模式不发射程序入口，兑现「`pini test` 不执行 main」。
            /// 判据须与 `emitFunction` 里 `currentIsMain` 逐字同源：那边把测试模式下的 `|test main` 判成
            /// 非入口，这边也只跳过角色是入口的那一个，否则会出现跳过了却被驱动器调用的错配。
            if testMode, function.name == "main", !function.isTest { continue }
            emitFunction(function)
        }
        for typeDecl in module.types {
            for method in typeDecl.methods {
                emitFunction(method)
            }
        }

        //  重要  测试模式：合成驱动器与入口。位置**必须在下面组 `tail` 之前** ——
        // 驱动器与报告片段都经 `registerStringConstant` 登记常量，而 `tail` 正是把已登记的
        // 常量刷出去的那一刻 ⇒ 排在它之后就一个常量都刷不出来（产物里只剩裸 `@.strN` 引用）。
        if testMode {
            bodyIR += emitTestDriver(module: module)
        }

        var tail = ""
        // 测试模式的两个模块级插槽（ 行不通  不是运行时段符号，见 `testFailedGlobal` 那条注释）。
        // `internal` 而非 `private`：驱动器与各测试函数都在本模块内，两者都要读写它们。
        if testMode {
            tail += "@\(Self.testFailedGlobal) = internal global i32 0\n"
            tail += "@\(Self.testMsgGlobal) = internal global ptr null\n"
        }
        for def in stringConstantDefs {
            tail += def + "\n"
        }
        if usesStrCmp {
            tail += "declare i32 @strcmp(ptr, ptr)\n"
        }
        /// LazyRef 句柄类型 + C ABI 声明：只在模块真的创建 / 读取惰性引用时才追加。
        if usesLazyRef {
            tail += "%bk_lazyref = type { ptr }\n"
            tail += Builtins.declaration(for: "bk_lazyref_create")
            tail += Builtins.declaration(for: "bk_lazyref_value")
            tail += Builtins.declaration(for: "bk_lazyref_destroy")
        }
        // `writeFile` 的 declare，只在实际写入的模块里出现。
        // 落点是运行时 shim 的一次调用 —— 路径解析与写语义都在那一侧，此处不发 libc 写调用。
        if usesFileWrite {
            tail += Builtins.declaration(for: "bk_write_file")
        }
        if usesFileAppend {
            tail += Builtins.declaration(for: "bk_append_file")
        }
        if usesFileRead {
            tail += Builtins.declaration(for: "bk_read_file")
        }
        // 可接住的 IO：读的成功值走返回值、错误走 out 参数；写与追加没有成功值，
        // 错误直接是返回值（`0` = 成功）。三者都**不引线程局部隐状态** —— 那个形状
        // 在嵌套调用下会互相覆盖，而正确性不该靠发射顺序维持。
        if usesFileTryRead {
            tail += Builtins.declaration(for: "bk_try_read_file")
        }
        if usesFileTryWrite {
            tail += Builtins.declaration(for: "bk_try_write_file")
        }
        if usesFileTryAppend {
            tail += Builtins.declaration(for: "bk_try_append_file")
        }
        /// `readLine` 会拉进 libc 行读取器与 stdin 流全局（macOS 上拼作 `__stdinp`）。
        if usesReadLine {
            tail += "declare ptr @fgets(ptr, i32, ptr)\n"
            tail += "@__stdinp = external global ptr\n"
        }
        /// 任务族的 C ABI。只有真发过派发 / 等待 / 剪枝的模块才带它们。本段接派发、阻塞等待、
        /// 剪枝三个符号；`join_all` / `capabilities` 的调用点尚未接线，故这里也不声明它们。
        if usesTaskRuntime {
            tail += Builtins.declaration(for: "bk_task_spawn")
            tail += Builtins.declaration(for: "bk_task_join")
            tail += Builtins.declaration(for: "bk_task_detach")
            if usesTaskArgRelease {
                tail += Builtins.declaration(for: "bk_handle_release")
            }
        }
        if usesTaskJoinWithin {
            tail += Builtins.declaration(for: "bk_task_join_within")
        }
        if usesTaskJoinAll {
            tail += Builtins.declaration(for: "bk_task_join_all")
        }
        if usesTaskJoinAllBox {
            tail += Builtins.declaration(for: "bk_task_join_all_box")
        }
        /// 让出族：帧的取用、帧内取槽、可让出的等待。与上面同规 —— 只有真发过的模块才带。
        if usesTaskCancel {
            tail += Builtins.declaration(for: "bk_task_cancel")
        }
        if usesTaskFrame {
            tail += Builtins.declaration(for: "bk_task_frame")
            tail += Builtins.declaration(for: "bk_task_slot")
            tail += Builtins.declaration(for: "bk_task_await")
        }
        if usesSleepShim {
            tail += Builtins.declaration(for: "bk_sleep")
        }
        /// 字符内建与宿主环境查询的**运行时段落地**。
        ///  注意  与上面同规：只有真调用过才带这几个 declare ⇒ 不碰它们的程序 IR 逐字节不变。
        ///  行不通  谓词与 `ord` 一律 `i32` 返回（收敛到 i1 由调用点做，见 `.call` 那条注释）。
        if usesCharacterShims {
            tail += Builtins.declaration(for: "bk_chars")
            tail += Builtins.declaration(for: "bk_chr")
            tail += Builtins.declaration(for: "bk_ord")
            tail += Builtins.declaration(for: "bk_is_letter")
            tail += Builtins.declaration(for: "bk_is_number")
        }
        if usesProcessShims {
            tail += Builtins.declaration(for: "bk_argv")
            tail += Builtins.declaration(for: "bk_list_dir")
            // 探测类：`i32` 返回（0/1），收敛到 `i1` 由调用点做 —— 同谓词那条。
            tail += Builtins.declaration(for: "bk_exists")
            tail += Builtins.declaration(for: "bk_is_dir")
        }
        if usesModuleRootShim {
            tail += Builtins.declaration(for: "bk_module_root")
        }
        if usesErrorShims {
            // err 槽的字：构造侧两个（业务错误 / 取消错误，只差标志位），读侧两个
            // （判定取消 / 取消息）。 注意  三个 `i64` 参数都是**句柄位型**， 行不通  不是指针。
            tail += Builtins.declaration(for: "bk_error_create")
            tail += Builtins.declaration(for: "bk_cancel_error_create")
            tail += Builtins.declaration(for: "bk_error_is_cancel")
            tail += Builtins.declaration(for: "bk_error_message")
        }
        if usesProgramBase {
            tail += Builtins.declaration(for: "bk_set_program_base")
        }
        if usesCStrShim {
            tail += Builtins.declaration(for: "bk_cstr")
        }
        if usesCapturedSlots {
            tail += Builtins.declaration(for: "bk_slot_alloc")
        }
        if usesNominalBoxes {
            tail += Builtins.declaration(for: "bk_nominal_alloc")
            tail += Builtins.declaration(for: "bk_nominal_retain")
            tail += Builtins.declaration(for: "bk_nominal_release")
        }
        // N76：字符串的引用计数。与上一条同规 —— 只有真发过 retain / release 的模块才带，
        // 故「不碰计数字符串」的程序 IR 逐字节不变。
        if usesStringRefcount {
            tail += Builtins.declaration(for: "bk_str_alloc")
            tail += Builtins.declaration(for: "bk_str_dup")
            tail += Builtins.declaration(for: "bk_str_retain")
            tail += Builtins.declaration(for: "bk_str_release")
        }
        if usesStringShims {
            tail += Builtins.declaration(for: "bk_substring")
            tail += Builtins.declaration(for: "bk_string_count")
            tail += Builtins.declaration(for: "bk_string_char_at")
            tail += Builtins.declaration(for: "bk_string_slice")
            tail += Builtins.declaration(for: "bk_string_upper")
            tail += Builtins.declaration(for: "bk_string_lower")
            tail += Builtins.declaration(for: "bk_string_contains")
            tail += Builtins.declaration(for: "bk_string_split")
            tail += Builtins.declaration(for: "bk_string_trim_left")
            tail += Builtins.declaration(for: "bk_string_trim_right")
            tail += Builtins.declaration(for: "bk_string_index_of")
        }
        // 调度驱动面（`Q-4` 乙段）：派发点把调度器绑定交给运行时。与上面同规 ——
        // 只有真发过派发的模块才带。 注意  观测符号 `bk_task_state` **不在这里** ——
        // 它没有调用点（发射层从不发射它），它是给宿主与判据用的 C ABI 观测面。
        if usesSchedBinding {
            tail += Builtins.declaration(for: "bk_task_bind_sched")
        }
        /// 默认实例的存放位：模块级全局、初值 null ⇒ 首调由运行时建盒。
        for def in givenSlotDefs {
            tail += def
        }
        /// Env struct type declarations precede their uses: creation-point GEPs live in the function
        /// bodies and lli needs a sized base element at the GEP. Closure/adapter defines trail the module.
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
        /// 名义箱的释放胶水：按类型合成、按名去重，只在真用到时才有内容。
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
        /// 本通道搬不动的地方在发射期只记账：产物反正要丢，收尾一次抛出即可 ——
        /// 比先走一趟预检少一棵树的遍历，判定表仍只有一份。
        if let refusal = refusals.first { throw refusal }
        return header + envHeader + tail + "\n" + bodyIR + closureTail
    }

    /// 本通道搬不动的地方。`BackendError` 是能力声明的执行面：族取契约小节，reason 说缺哪种能力。
    private var refusals: [BackendError] = []

    private func refuse(node: String, family: BackendCapabilities.Family, reason: String) {
        refusals.append(BackendError(node: node, family: family, reason: reason))
    }

    // MARK: - Functions

    private func emitFunction(_ function: IRFunction) {
        builder.reset()
        scopes = [[:]]
        slotCounters = [:]
        controlStack = []
        breakMergeLabels = []
        cleanupScopeBase = 0
        /// 字符串账本每函数一份：进体前压栈、换上空账本，函数发射结束时还原。
        /// 少了这一步账本会跨函数累积 —— 上个函数未出账的 SSA 名留在本函数账上却无人释放，
        /// 症状只是编译期集合变大。压栈是为了让「账本 = 本函数的持有量」这句话成立。
        heldStringsStack.append(heldStrings)
        heldStrings = []
        heldBoxesStack.append(heldBoxes)
        heldBoxes = [:]
        // Frame 0 of this function is its body block, pushed by the `emitBlock` call below;
        // that block runs its own cleanup at the tail, so nothing is left for `exit_block`.
        pendingCleanup.removeAll()
        terminated = false
        /// 测试模式下「是不是入口」按角色判，不只看名字：恰好叫 `main` 的 `|test` 函数是测试。
        /// 只看名字会让它拿到入口的 i32 返回口径，而驱动器仍按它声明的返回类型调用 ⇒ 签名对不上。
        currentIsMain = function.name == "main" && !(testMode && function.isTest)
        currentIsTest = testMode && function.isTest
        currentTestExitLabel = currentIsTest ? "test.exit.\(builder.freshLabel())" : nil
        currentReturnType = function.returnType
        blockDepth = 0
        frameSlotDecls = []
        yieldPointCount = 0
        /// 只有会被派发的异步体走帧式：判据 `isAsync` 且返回 `Result`，与 `emitTaskSpawn` 的进入条件同源。
        /// 若不同源，`=> ()` 的异步函数会被一起帧式，而帧式要求进体时必有当前任务 ——
        /// 那条路就从静默同步执行变成响亮拒绝。
        frameMode = (function.isAsync && isResultReturning(function)) ? .resumable : .none
        // 片 D：本函数里被闭包捕获的名字 —— 捕获槽由此改走堆分配（`declareValueSlot`）。
        //  注意  收集范围是整个函数体（含嵌套闭包）⇒ **宁可宽**：同名局部会多上一次堆，
        // 无害；漏收才会让某个槽留在栈上，而那正是跨帧才炸的那一类。
        capturedNamesInFunction = capturedNames(in: function.body)

        // main is the process entry: emitted with i32 return regardless of
        // the Pini-level void signature (bare returns become `ret i32 0`).
        let returnSpelling =
            currentIsMain
            ? "i32"
            : (function.returnType?.llvmSpelling ?? "void")
        /// 形参 SSA 名不能直接用源码名（规则见 `parameterSSANames`）：发射器自有的 `%t<数字>` 与
        /// `%<名字>_slot[_<k>]` 两族若与形参名相撞，同一函数里出现两个同名局部值，clang 拒绝整段模块，
        /// 而 `emit` 自身 rc=0，静默产出不可用 IR。
        let paramNames = parameterSSANames(function.params.map { $0.name })
        let params = zip(function.params, paramNames).map { "\($0.0.type.llvmSpelling) %\($0.1)" }
        let header = "define \(returnSpelling) @\(Self.mangle(function.name))(\(params.joined(separator: ", "))) {\n"

        /// 体先写进 `bodyIR`（此时清空），收尾时再与 `header`、帧序拼起来。
        /// 两个顺序都不能颠倒：帧序的槽顺序由体走出的声明顺序决定，只能在体之后生成却要排在体之前；
        /// `bodyIR` 是模块级累积缓冲，本函数那段必须单独攒再接回，直接清空会抹掉先前已发射的函数。
        let emittedFunctions = bodyIR
        bodyIR = ""

        // 程序基准的注入点：入口函数体最前，早于任何 Pini 语句。
        //  注意  判据只看 `programBase`， 行不通  不看 `usesProcessShims` —— 入口可能先于 IO 调用点发射，
        // 那时该标志尚未置位，据此决定就会漏插（症状是静默回落到进程 CWD）。
        if currentIsMain {
            bodyIR += programBaseSetterIR()
        }

        for (index, param) in function.params.enumerated() {
            let spelling = param.type.llvmSpelling
            /// 形参槽走 `freshSlot` 的同一计数器，不手工拼 `%<名字>_slot`：形参与体内同名局部
            /// （如 `var span = span`）各要一个槽，手工命名会让两者都取到 `%span_slot`。
            /// 计数器把第二个推到 `%span_slot_1`；形参也可能被闭包捕获，故与局部同走 `declareValueSlot`。
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
            // 根帧的清理已在块尾执行完；`return` 也在自己的 `ret` 前发过一份副本，
            // 两条路径不会都跑。此标签只剩返回。
            if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else if let returnType = function.returnType {
                bodyIR += " ret \(returnType.llvmSpelling) undef\n"
            } else {
                bodyIR += " ret void\n"
            }
        }

        /// 测试出口：失败断言的假边跳到这里，放弃本函数剩余语句，但把控制交回驱动器。
        /// 它与 `exit_block` 不能合并：那条走正常落空路径并带句柄释放，而本块从体内半途跳来，
        /// 归还台账停在分支点状态，故只返回一个不用的值；失败测试的局部容器因此不在本函数释放。
        if currentIsTest, let exitLabel = currentTestExitLabel {
            bodyIR += "\(exitLabel):\n"
            if let returnType = function.returnType {
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
        // N76：还原上一个函数的字符串账本（与函数头的压栈配对）。
        heldStrings = heldStringsStack.popLast() ?? []
        heldBoxes = heldBoxesStack.popLast() ?? [:]
    }

    /// 该函数会不会被 `emitTaskSpawn` 接住（`isAsync` 且返回 `Result`）。
    /// 抽成一个函数而非两处各写一遍：帧式的启用条件必须与派发点的进入条件逐字同源，
    /// 否则会出现「派发了但没有帧」或「有帧却从未被派发」这两种都很难查的错配。
    private func isResultReturning(_ function: IRFunction) -> Bool {
        guard let returnType = function.returnType else { return false }
        if case .result = returnType { return true }
        return false
    }

    /// 合成的测试驱动器与入口的符号名（`__` 前缀与 `__given_init_*` 同族：
    /// 它们不是 Pini 级名字，故不经 `mangle`，也 行不通  不进任何用户可见的名字域）。
    static let testDriverName = "__pini_test_driver"

    /// 「把程序基准交给运行时」那条调用；`programBase == nil` 时返空串 ⇒ 产物逐字节不变。
    ///  注意  常量用固定名、地址直取全局（ 行不通  不取临时名）：注入点排在所有 Pini 语句之前，
    /// 一占名字就会把同一程序其余的名字全体推后一位，注入的差异便淹没在改名里。
    private func programBaseSetterIR() -> String {
        guard let base = programBase else { return "" }
        usesProgramBase = true
        let entry = registerStringConstant(base, named: "@.pini_program_base")
        return " call void @bk_set_program_base(ptr \(entry.name))\n"
    }

    /// 合成测试驱动器与进程入口。
    /// 驱动器逐个调用 `|test`（实参按类型注入零值）、累计失败、自己把报告写完并返回失败条数，
    /// 入口把它归一成 0/1 退出码；报告与退出码都由运行中的程序产生，两腿输出才逐字节同序。
    private func emitTestDriver(module: IRModule) -> String {
        // 选中面：给了清单就按清单（**保持清单给的顺序**），否则取模块里全部 `|test`
        // （即模块声明序 —— 与解释器那边 `module.functions` 的过滤同序）。
        let tests: [IRFunction]
        if let selection = testSelection {
            var byName: [String: IRFunction] = [:]
            for function in module.functions where function.isTest {
                byName[function.name] = function
            }
            //  注意  清单里有、模块里没有的名字**静默跳过**而不是崩：清单是从同一个降载结果算的，
            // 对不上只可能是发射器被单独驱动（测试直接构造发射器）。那种情况下少跑一条，
            // 比让整段发射崩掉更容易定位。
            tests = selection.compactMap { byName[$0] }
        } else {
            tests = module.functions.filter { $0.isTest }
        }
        var d = ""

        /// 把一个字符串登记为常量并就地取址（`ptr`），返回该 `ptr` 的 SSA 名。
        /// 这里不写 `bodyIR`：驱动器单独成段收口（在所有函数之后、常量组之前），
        /// 取址指令进本函数的局部缓冲，由调用方按顺序拼进驱动器体。
        func strPtr(_ value: String) -> String {
            let entry = registerStringConstant(value)
            let temp = builder.freshTemp()
            d += " " + builder.fmtGEP(
                name: temp, aggregate: "[\(entry.length) x i8]", base: entry.name,
                indices: [0, 0]) + "\n"
            return temp
        }

        func printString(_ ptr: String) {
            d += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(ptr))\n"
        }
        func printNewline() {
            d += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        }

        // 计数器用 `alloca` 而 行不通  不用全局：驱动器是单次调用，槽只活在本帧内，
        // 于是「跨测试的状态」仅剩那两个插槽，可被逐条读清。
        let failsSlot = builder.freshTemp()
        d += "define i32 @\(Self.testDriverName)() {\n"
        d += " \(failsSlot) = alloca i32\n"
        d += " store i32 0, ptr \(failsSlot)\n"

        /// 报告首行、各片段与每条测试名字的取址全排在第一个标签之前（入口块里），故支配其后每个块。
        /// 挪到分支之后就成「用未支配的值」。首行正文由调用方给：它是「测试文件: <路径>」与
        /// 「测试目标: 模块 …」两形之一，只有命令行知道该用哪一形，发射器不猜。
        let headerPtr = testReportHeader.map { strPtr($0) }
        let passPrefix = strPtr(" \u{2713} ")
        let failPrefix = strPtr(" \u{2717} ")
        let colon = strPtr(": ")
        let summaryFormat = strPtr("结果: %d 通过, %d 失败")
        let namePtrs = tests.map { strPtr($0.name) }

        /// 结果收集槽：每条测试一份「判定」与一份「消息」，用本帧 `alloca` 而非模块级数组 ——
        /// 驱动器单次调用，于是跨测试的共享状态只剩那两个插槽，可被逐条读清。
        /// 先收后写：测试体里的 `print` 边跑边出，报告全部跑完才打，报告行才不会插进输出中间。
        let outcomeSlots = tests.map { _ in builder.freshTemp() }
        let messageSlots = tests.map { _ in builder.freshTemp() }
        for index in tests.indices {
            d += " \(outcomeSlots[index]) = alloca i32\n"
            d += " \(messageSlots[index]) = alloca ptr\n"
        }

        // ── 阶段 1：逐个跑，只收集（ 行不通  本阶段一条输出都不产生）────────────────
        for (index, test) in tests.enumerated() {
            // 每条测试前把两个插槽归零。 行不通  不归零的话上一条的失败会**污染**下一条 ——
            // 驱动器问的是「本条跑完之后标志是不是 1」，不是「有没有人为它置过 1」。
            d += " store i32 0, ptr @\(Self.testFailedGlobal)\n"
            d += " store ptr null, ptr @\(Self.testMsgGlobal)\n"

            // 实参：按声明类型注入零值（与解释器 `zeroValue(forTestParam:)` 同规）。
            var args: [String] = []
            for param in test.params {
                let value = testZeroArgument(for: param.type, output: &d)
                args.append("\(param.type.llvmSpelling) \(value)")
            }
            let retSpelling = test.returnType?.llvmSpelling ?? "void"
            d += " call \(retSpelling) @\(Self.mangle(test.name))(\(args.joined(separator: ", ")))\n"

            let flag = builder.freshTemp()
            let bad = builder.freshTemp()
            let asInt = builder.freshTemp()
            let prev = builder.freshTemp()
            let next = builder.freshTemp()
            let message = builder.freshTemp()
            d += " \(flag) = load i32, ptr @\(Self.testFailedGlobal)\n"
            d += " \(bad) = icmp ne i32 \(flag), 0\n"
            d += " \(asInt) = zext i1 \(bad) to i32\n"
            d += " \(prev) = load i32, ptr \(failsSlot)\n"
            d += " \(next) = add i32 \(prev), \(asInt)\n"
            d += " store i32 \(next), ptr \(failsSlot)\n"
            d += " store i32 \(asInt), ptr \(outcomeSlots[index])\n"
            d += " \(message) = load ptr, ptr @\(Self.testMsgGlobal)\n"
            d += " store ptr \(message), ptr \(messageSlots[index])\n"
        }

        // ── 阶段 2：写报告（首行 → 每条 → 收尾）────────────────────────────
        if let headerPtr {
            printString(headerPtr)
            printNewline()
        }
        if tests.isEmpty {
            printString(strPtr(" （未找到 |test 测试函数）"))
            printNewline()
        }

        for (index, _) in tests.enumerated() {
            let value = builder.freshTemp()
            let isBad = builder.freshTemp()
            /// 标签名一律加前缀，不能直接用 `freshLabel()` 的裸数值：那个数只是「本函数第几个标签」，
            /// 而 LLVM 里裸数字标签是无名值的编号（`5:` 定义第 5 个无名值，`br label %5` 于是成了
            /// 前向引用的 label，clang 拒绝整段模块）。本类一律写成 `<族名>.<数>`。
            let passLabel = "test.pass.\(builder.freshLabel())"
            let failLabel = "test.fail.\(builder.freshLabel())"
            let endLabel = "test.end.\(builder.freshLabel())"
            d += " \(value) = load i32, ptr \(outcomeSlots[index])\n"
            d += " \(isBad) = icmp ne i32 \(value), 0\n"
            d += " br i1 \(isBad), label %\(failLabel), label %\(passLabel)\n"
            d += "\(passLabel):\n"
            printString(passPrefix)
            printString(namePtrs[index])
            printNewline()
            d += " br label %\(endLabel)\n"
            d += "\(failLabel):\n"
            printString(failPrefix)
            printString(namePtrs[index])
            printString(colon)
            // 消息是断言点存下的那个串 —— 与解释器报告里那一格**同一个字符串**
            // （源里的消息字面量），故两腿这一格逐字节相同。
            let message = builder.freshTemp()
            d += " \(message) = load ptr, ptr \(messageSlots[index])\n"
            printString(message)
            printNewline()
            d += " br label %\(endLabel)\n"
            d += "\(endLabel):\n"
        }

        // 收尾行：通过数 = 总数 − 失败数。 注意  这里 行不通  不能用 `printString`（那会把格式当普通串打出来）。
        let totalFails = builder.freshTemp()
        let totalPass = builder.freshTemp()
        d += " \(totalFails) = load i32, ptr \(failsSlot)\n"
        d += " \(totalPass) = sub i32 \(tests.count), \(totalFails)\n"
        d += " call i32 (ptr, ...) @printf(ptr \(summaryFormat), i32 \(totalPass), i32 \(totalFails))\n"
        d += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        d += " ret i32 \(totalFails)\n"
        d += "}\n\n"

        // 进程入口：把「失败条数」归一成 0/1。解释器那条路的退出码约定 =
        // 「全通过 0 · 存在失败测试 1 · 文件/解析/框架错误 2」，末一条由命令行侧处理。
        let driverResult = builder.freshTemp()
        let nonZero = builder.freshTemp()
        let code = builder.freshTemp()
        d += "define i32 @main() {\n"
        // 测试模式的进程入口同样是注入点：各 `|test` 函数里的 `moduleRoot` 读的是这里交出去的值。
        d += programBaseSetterIR()
        d += " \(driverResult) = call i32 @\(Self.testDriverName)()\n"
        d += " \(nonZero) = icmp ne i32 \(driverResult), 0\n"
        d += " \(code) = select i1 \(nonZero), i32 1, i32 0\n"
        d += " ret i32 \(code)\n"
        d += "}\n\n"
        return d
    }

    /// 某类型在测试参数注入下的零值文本（LLVM 常量或已取好的 SSA 名）。
    /// 与解释器 `ProgramRunner.zeroValue(forTestParam:)` 逐条同规：整数→0 · 浮点→0.0 · 布尔→false ·
    /// 字符串→空串（不是空指针）· 其它→`null`，`Char` 亦落「其它」：语言里没有空字符，两侧同规矩。
    private func testZeroArgument(for type: IRType, output: inout String) -> String {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .boolean:
            return "0"
        case .f64:
            return "0.000000e+00"
        case .string:
            let entry = registerStringConstant("")
            let temp = builder.freshTemp()
            output += " " + builder.fmtGEP(
                name: temp, aggregate: "[\(entry.length) x i8]", base: entry.name,
                indices: [0, 0]) + "\n"
            return temp
        default:
            let spelling = type.llvmSpelling
            return (spelling == "ptr" || spelling.hasSuffix("*")) ? "null" : "zeroinitializer"
        }
    }

    /// 声明一个 Pini 级局部槽，返回它的地址名：普通体（`.none`）发 `alloca`，
    /// 可恢复体（`.resumable`）落帧 —— 体让出等于从栈返回，栈上的槽活不过那次返回。
    /// 地址名由槽名派生而非 `freshTemp()`：取槽代码与引用它的体代码分处两个 buffer，匿名名会前向引用。
    private func declareLocalSlot(named slot: String, spelling: String) -> String {
        guard frameMode == .resumable else {
            bodyIR += builder.fmtAlloca(name: slot, type: spelling) + "\n"
            return slot
        }
        let address = "%de6b." + slot.dropFirst()
        frameSlotDecls.append((name: address, spelling: spelling))
        return address
    }

    /// 声明一个值变量的槽：被闭包捕获的那一族走堆槽，其余照旧（栈 alloca / 帧槽）。
    /// 捕获必须上堆，因为闭包 env 存的就是这个槽的地址，而闭包可能比创建帧活得久 ——
    /// 栈上的槽随帧作废。上堆后帧与闭包读写同一个盒；堆槽不登记释放，寿命归闭包。
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

    /// 帧序：取帧 → 读续跑点并清零 → **按声明顺序**取槽 → 按续跑点分派。
    /// - Returns: 一段**完整**的 IR 文本（自带终结指令），由调用方排在函数体之前。
    private func emitFramePrologue() -> String {
        usesTaskFrame = true
        var ir = ""
        let frame = "%de6b.frame"
        ir += " \(frame) = call ptr @bk_task_frame(i64 0)\n"
        /// 没有当前任务就没有帧可依，而没帧的体连一块局部变量都放不下 ⇒ 响亮拒绝，不静默降级。
        /// `.result` 异步体只该经派发进入（`emitTaskSpawn`），走到这里说明有人绕过了派发；
        /// `=> ()` 的直呼不在帧式之内（见 `frameMode` 的赋值处），其既有行为不受影响。
        ir += " \(frame)_is_null = icmp eq ptr \(frame), null\n"
        ir += " br i1 \(frame)_is_null, label %de6b.frameless, label %de6b.alloc\n"
        ir += "de6b.frameless:\n"
        //  注意  这里**不能**用 `emitStringConstant`：它把取串的 GEP 写进 `bodyIR`，而帧序排在体之前
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

    /// 某个 LLVM 类型的字节数，写成 IR 常量表达式。
    /// 本仓没有「类型 → 字节数」的通用能力（容器元素表只枚举有限类型、聚合一律拒绝），
    /// 在 Swift 侧另算布局一旦与 LLVM 不一致，帧里就是错位的槽：不崩溃，只是值进出错误地址。
    private func slotSizeExpression(_ spelling: String) -> String {
        "ptrtoint (ptr getelementptr (\(spelling), ptr null, i64 1) to i64)"
    }

    // MARK: - Statements

    /// 进入一个块作用域：压一层清理帧，跑完语句后按登记顺序逆序执行。
    /// `seed` 预置那些声明代码早于本块发射的条目：`for … in` 的元素绑定先于体 alloca，
    /// 故它们属于体块的帧，尽管并不是块内的语句。
    private func emitBlock(_ block: IRBlock, seeding seed: [CleanupEntry] = []) {
        let frameBase = pendingCleanup.count
        pendingCleanup.append(seed)
        blockDepth += 1
        defer { blockDepth -= 1 }
        for statement in block {
            if terminated { break }
            emitStatement(statement)
        }
        /// 终止路径（panic · return · break · continue）已在跳转前发过自己那一份副本，块尾不可达
        /// ⇒ 弃帧。根帧（`frameBase == 0`）属于函数顶层作用域，不弹；它的清理已在这里执行完。
        if terminated {
            if frameBase > 0 { _ = pendingCleanup.removeLast() }
        } else {
            emitCleanup(downTo: frameBase)
            if frameBase > 0 { _ = pendingCleanup.removeLast() }
        }
    }

    /// 由内向外、每帧逆序执行到 `base`（含两端），不弹栈：终止路径与块尾是两条运行路径，
    /// 各发一份。`defer` 体与局部释放共用这一条栈 —— 登记顺序即源码顺序，逆序即退出次序。
    private func emitCleanup(downTo base: Int) {
        guard base < pendingCleanup.count else { return }
        let wasTerminated = terminated
        terminated = false
        for frame in pendingCleanup[base...].reversed() {
            for entry in frame.reversed() {
                if terminated { break }
                switch entry {
                case .release(let handle):
                    let loaded = builder.freshTemp()
                    bodyIR +=
                        builder.fmtLoad(
                            name: loaded, type: handle.typeSpelling, ptr: handle.slot
                        ) + "\n"
                    bodyIR += " call void @\(handle.destroySymbol)(ptr \(loaded))\n"
                case .deferBody(let body):
                    for statement in body {
                        if terminated { break }
                        emitStatement(statement)
                    }
                }
            }
        }
        terminated = wasTerminated
    }

    /// 一条退出时要执行的动作：还一份份额，或跑一段 `defer` 体。
    private enum CleanupEntry {
        case release(ReleasedHandle)
        case deferBody(IRBlock)
    }

    /// 每个打开的块一层，元素按登记顺序。根帧（函数体那一层）由块尾自己执行。
    private var pendingCleanup: [[CleanupEntry]] = []

    /// A local holding one share of a refcounted handle, dropped when its block exits.
    /// `slot` and the spelling are snapshotted at registration so a later same-name
    /// redeclaration cannot release through the wrong slot.
    private struct ReleasedHandle {
        let slot: String
        let typeSpelling: String
        let destroySymbol: String
    }

    /// 把一个新声明的本地推进当前清理帧：退出时还掉它那一份。
    ///  注意  这是翻译，不是决策 —— 「这个槽持有份额」由 `allocVar` 的类型与 `IRType.shareClass` 给出。
    /// 同帧同槽只登记一次：遮蔽后的重声明会让名字重复，双释放会多扣一份（use-after-free）。
    private func ownSlot(_ slot: String, type: IRType) {
        guard let symbol = releaseSymbol(for: type) else { return }
        guard !pendingCleanup.isEmpty else { return }
        let frame = pendingCleanup.count - 1
        guard !pendingCleanup[frame].contains(where: { entry in
            if case .release(let handle) = entry { return handle.slot == slot }
            return false
        }) else { return }
        pendingCleanup[frame].append(
            .release(ReleasedHandle(slot: slot, typeSpelling: type.llvmSpelling, destroySymbol: symbol))
        )
    }

    /// 该类型在退出 / 被覆盖时要调的销毁符号，nil = 本层不释放它。判定来自 `IRType.shareClass`：
    /// 拼写是后端的表示，换表示就会变，而变了的形态是「某族不再释放」。
    ///  注意  `LazyRef` 归在计数族，但其销毁符号尚未登记 —— 契约第 4 节记的缺口，不是它不用释放。
    private static func collectionDestroySymbol(for type: IRType) -> String? {
        switch type.shareClass {
        case .retained(.array): return "bk_array_destroy"
        case .retained(.dict): return "bk_dict_destroy"
        case .retained(.set): return "bk_set_destroy"
        case .retained(.lazyRef): return "bk_lazyref_destroy"
        case .retained(.string), .retained(.object), .retained(.enumeration),
            .valueBox, .aggregate, .inert:
            return nil
        }
    }

    /// 一个持有者槽在退出 / 被覆盖时要调的释放符号；nil = 该类型不在计数族里。
    /// 容器句柄用 `bk_*_destroy`，名义箱用合成胶水 `__release_*`，两族共用同一条登记通道。
    /// 下游只认符号名，故释放点只问「这个类型要不要释放」，改族别不会漏掉释放点。
    private func releaseSymbol(for type: IRType) -> String? {
        if nominalKindSpelling(type) != nil { return ensureReleaseFunction(for: type) }
        if isRefcountedString(type) {
            usesStringRefcount = true
            return "bk_str_release"
        }
        return Self.collectionDestroySymbol(for: type)
    }

    /// 该类型在发射层是否按字符串参与引用计数：判据是 IR 类型为 `string` 或 `char`。
    /// `Char` 与 `String` 同构（运行时段都是带计数头的 C 串，元素 tag 都钉在 3）⇒ 同一条释放通道。
    /// `*T` 指针不算：它是外部内存，与计数头无关；本条按 `IRType` 判，`.pointer` 天然排除。
    private func isRefcountedString(_ type: IRType) -> Bool {
        switch type {
        case .string, .char: return true
        default: return false
        }
    }

    private func emitStatement(_ statement: IRStmt) {
        switch statement {
        case .allocVar(let name, let type, _, let initializer, let adopt):
            let slot = freshSlot(for: name)
            // 片 D：被闭包捕获的变量走**堆槽**（闭包与帧共享同一个盒）。
            let address = declareValueSlot(
                named: slot, spelling: type.llvmSpelling,
                captured: capturedNamesInFunction.contains(name))
            /// 绑定的登记排在初始化式求值之后（槽名与 `alloca` 仍在原处，故不相撞的程序 IR 逐字节不变）。
            /// `var x = <expr>` 里的 `<expr>` 在旧作用域求值，先登记后求值会让 `var span = span` 读到
            /// 自己刚分配、还没写过的槽，后续解引用未初始化指针。同族错误都是遮蔽名字时的「谁先谁后」。
            if let initializer = initializer {
                if frameMode == .resumable, blockDepth == 1, case .join(let awaited, _, .awaits) = initializer {
                    scopes[scopes.count - 1][name] = address
                    emitYieldPoint(awaited: awaited, type: type, produce: .frameSlot(address))
                } else {
                    let value = emitExpr(initializer)
                    scopes[scopes.count - 1][name] = address
                    // 接收动作由中端填（`IRType.adoption(of:)`），这里只翻译：移交 / 拷贝 / 保留，
                    // 顺序必须是「先让新值站住」再 store。
                    let stored = applyAdopt(adopt, value, type: type)
                    bodyIR += builder.fmtStore(value: stored.ssaName, type: type.llvmSpelling, ptr: address) + "\n"
                }
            } else {
                scopes[scopes.count - 1][name] = address
                /// 没有初始化式的变量槽必须清零：这种槽会被登记为持有者，退出 / 被覆盖时按计数释放，
                /// 而栈 `alloca` 里是垃圾 —— 释放伪指针会在代码段上写，SIGBUS。
                /// 零 = `null` =「还没有箱」，释放路径对它是无操作；只对参与计数的类型发这条 store。
                if releaseSymbol(for: type) != nil {
                    bodyIR += builder.fmtStore(value: zeroConst(for: type), type: type.llvmSpelling, ptr: address) + "\n"
                }
            }
            // 新本地握着一份份额：登记进本块清理帧，退出时还掉。
            ownSlot(address, type: type)

        case .storeVar(let name, let type, let value, let adopt, let releaseOld):
            guard let slot = lookupSlot(name) else {
                fatalError("IREmitter: store to undeclared variable '\(name)' (IRLowerer guarantees declarations)")
            }
            let lowered = emitExpr(value)
            /// 三行的顺序就是语义：先让新值站住（注解说的移交 / 拷贝 / 保留），
            /// 再释放旧值，最后才写槽。顺序颠倒则 `a = a` 这类自赋值先回收掉新值要读的箱，读已释放内存。
            let stored = applyAdopt(adopt, lowered, type: type)
            /// 覆盖点：旧值先还掉。要不要还由中端填的 `releaseOld` 说（借来的槽不会被标成持有者）。
            if releaseOld, let symbol = releaseSymbol(for: type) {
                let old = builder.freshTemp()
                bodyIR += builder.fmtLoad(name: old, type: type.llvmSpelling, ptr: slot) + "\n"
                bodyIR += " call void @\(symbol)(ptr \(old))\n"
            }
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

        case .returnStmt(let value, let adopt):
            /// 清理排在返回值站住之后：先求值、留一份，再按登记逆序执行到函数基址。
            /// 释放排在求值之前时，`return <局部容器>` 交出的就是已回收的悬垂句柄。
            /// `var` 亦非风格：值语义会换掉交出去的值，写成 `let` 则拷贝做了、`ret` 交的仍是原件。
            var returnedValue: IRValue? = value.map { emitExpr($0) }
            if let returnedNode = value, let current = returnedValue {
                /// 接收动作来自中端注解；没有声明返回类型时只剩别名点保留 —— 那条路不交值。
                if let returnType = currentReturnType {
                    returnedValue = applyAdopt(adopt, current, type: returnType)
                } else {
                    _ = applyAdopt(
                        irType(of: returnedNode).adoption(of: returnedNode),
                        current, type: irType(of: returnedNode))
                }
            }
            // Returning abandons every open scope; the fall-through cleanup already ran at the block
            // tail, and only one of the two paths is reachable, so they never both run.
            emitCleanup(downTo: cleanupScopeBase)
            if let returnedValue {
                bodyIR += " ret \(returnedValue.llvmType) \(returnedValue.ssaName)\n"
            } else if currentIsMain {
                bodyIR += " ret i32 0\n"
            } else {
                bodyIR += " ret void\n"
            }
            terminated = true

        case .exprStmt(let expr):
            ///  重要  `await f()` 独占一行 —— 让出，结果按语言语义**丢弃**。
            ///  行不通  少这一支的话，这条路会落到 `emitJoin` 的 `.awaits` 拒绝上 —— 一个本该让出的
            /// 位置被当成「写错了」，而它是降载层明文承诺合法的四个位置之一。
            if frameMode == .resumable, blockDepth == 1, case .join(let awaited, let type, .awaits) = expr {
                emitYieldPoint(awaited: awaited, type: type, produce: .discard)
            } else {
                _ = emitExpr(expr)
            }

        case .deferStmt(let body):
            pendingCleanup[pendingCleanup.count - 1].append(.deferBody(body))

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, let type):
            emitTry(operand: operand, errorVar: errorVar, handler: handler, okTarget: okTarget, type: type)

        case .subscriptStore(let container, let index, let value, let elementType, let adopt):
            emitSubscriptStore(
                container: container, index: index, value: value, elementType: elementType,
                adopt: adopt)

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

        case .fieldStore(let base, let field, let value, let fieldType, let adopt, let releaseOld):
            let baseValue = emitExpr(base)
            let loweredValue = emitExpr(value)
            let (aggregate, _, fieldIndex) = nominalField(of: base, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName, indices: [0, fieldIndex]) + "\n"
            //  注意  顺序同 `storeVar`：新值先站住（注解给的接收动作），**再**释放字段旧值，最后写。
            let stored = applyAdopt(adopt, loweredValue, type: fieldType)
            /// 字段是持有者：被覆盖前先还旧值；要不要还由 `releaseOld` 说。
            /// 旧值可能是 null（无默认值字段刚构造出来）⇒ 容器一族走判空分支，名义一族不必。
            if releaseOld, let callee = releaseCallee(for: fieldType) {
                let old = builder.freshTemp()
                bodyIR += builder.fmtLoad(name: old, type: fieldType.llvmSpelling, ptr: fieldPtr) + "\n"
                emitReleaseCall(
                    callee: callee, valueName: old, spelling: fieldType.llvmSpelling,
                    tag: "w\(builder.freshLabel())")
            }
            bodyIR += builder.fmtStore(value: stored.ssaName, type: fieldType.llvmSpelling, ptr: fieldPtr) + "\n"

        case .captureMarker:
            // Marker only — captures are materialized by the closure literal
            // emission (env slot pointers), nothing to emit here.
            break

        case .detachStmt(let inner):
            /// `detach` 是剪枝：从父 scope 摘掉、不再由父任务收回，是 fire-and-forget 的唯一合法出口。
            /// 它与等待不同 —— 不消费结果，于是没有 `out` 缓冲，也不解构任何东西。
            usesTaskRuntime = true
            let handle = emitExpr(inner)
            guard handle.llvmType == "ptr" else {
                fatalError("IREmitter: detach operand is not a task handle (IRLowerer gates the operand)")
            }
            bodyIR += " call void @bk_task_detach(ptr \(handle.ssaName))\n"
        }
    }

    /// `break`: jump to the depth-th enclosing frame's exit (1 = innermost); too few frames panics at
    /// runtime, matching the interpreter's top-level break error — fail-loud, not a silent skip. The
    /// body block's defers run first; a labeled `if` exit is recorded as targeted so its label exists.
    private func emitBreak(depth: Int) {
        if controlStack.count >= depth {
            let frame = controlStack[controlStack.count - depth]
            /// Breaking abandons the body scope (and every scope nested in it): its `defer` bodies run and
            /// its handles are released here, in the one registered order. Normal iterations do the same at
            /// the body block's tail — separate runtime paths, separate copies of the same cleanup code.
            emitCleanup(downTo: frame.cleanupBase)
            if !frame.isLoop { breakMergeLabels.insert(frame.exit) }
            bodyIR += builder.fmtBr(labelName: frame.exit) + "\n"
        } else {
            let message = emitStringConstant("Pini runtime error: break outside loop")
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"
        }
        terminated = true
    }

    /// `continue`: unlabeled jumps to the innermost continue-target (step entry if present, else the
    /// header); labeled (depth > 1) goes to the depth-th header; outside any loop it panics. The body
    /// block's defers run first.  注意  `depth > 1` skips the target loop's step, which the interpreter runs.
    private func emitContinue(depth: Int) {
        if controlStack.count >= depth {
            let frame = controlStack[controlStack.count - depth]
            // Ending the iteration early abandons the scopes it held; clean them before the jump
            // (same contract as emitBreak).
            emitCleanup(downTo: frame.cleanupBase)
            let target = depth == 1 ? frame.continueTarget : frame.header
            bodyIR += builder.fmtBr(labelName: target) + "\n"
        } else {
            let message = emitStringConstant("Pini runtime error: continue outside loop")
            bodyIR += " call void @bk_panic(ptr \(message.ssaName))\n"
            bodyIR += " unreachable\n"
        }
        terminated = true
    }

    /// 判别式的求值：一般情形就是 `emitExpr(scrutinee)`。
    /// 判别式位是一处可让出的 `await`（可恢复体 · 顶层语句）时，走让出序列并把结果落进帧槽再读回。
    /// 不能用让出序列产出的 SSA 值：体让出等于从栈返回，续跑块由入口 switch 跳入，那个值不支配它。
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
        ///  重要  判别式**只在这里求值一次**（见 `emitMatchSubject`）：四个分派分支拿的都是
        /// 同一个已物化的值，不存在「某条分支漏走让出」的缝。
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
                    /// 标签槽与载荷槽都问布局：标签紧随四格头，载荷从标签之后起。
                    let tagPtr = builder.freshTemp()
                    bodyIR +=
                        builder.fmtGEP(
                            name: tagPtr, aggregate: aggregate, base: base, indices: [0, layout.enumTagSlot])
                        + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: "i32", ptr: tagPtr) + "\n"
                    return IRValue(llvmType: "i32", ssaName: value)
                },
                loadPayload: { [self] _, base, slot, spelling in
                    let fieldPtr = builder.freshTemp()
                    bodyIR +=
                        builder.fmtGEP(
                            name: fieldPtr, aggregate: aggregate, base: base,
                            indices: [0, layout.enumPayloadSlot(of: slot)])
                        + "\n"
                    let value = builder.freshTemp()
                    bodyIR += builder.fmtLoad(name: value, type: spelling, ptr: fieldPtr) + "\n"
                    return IRValue(llvmType: spelling, ssaName: value)
                }
            )
        case .result(let okType):
            /// Result scrutinee: tag 0 = ok, 1 = err. The ok payload rides in field 1 and the err payload in
            /// field 2 — the type-erased error word — which is why the two sides cannot share one slot formula
            /// the way Optional's single payload can. Without this arm the tag never dispatches and no arm runs.
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
            /// Bare scrutinee: literal arms compare by value; a wildcard arm is live even with no literal arm,
            /// so the trigger is "literal arm or wildcard arm". Neither ⇒ dead match: emit for side effects,
            /// skip the arms.  行不通  Never re-evaluate the scrutinee — an `await` one would dispatch an unjoined task.
            if cases.contains(where: { $0.literal != nil }) || cases.contains(where: { $0.caseName == "_" }) {
                emitScalarMatch(scrutineeValue: subject, cases: cases)
            }
        }
    }

    /// Bare-scrutinee match: source-ordered value comparisons, first match wins (strcmp / fcmp / icmp);
    /// enum-case arms cannot match a bare value and are skipped, and falling off without a wildcard is
    /// a silent no-op. `literalArms` may be empty: a `case _:`-only match goes straight to default.
    private func emitScalarMatch(scrutineeValue: IRValue, cases: [IRMatchCase]) {
        let id = builder.freshLabel()
        let endLabel = "match.end.\(id)"
        let defaultLabel = "match.default.\(id)"
        func checkLabel(_ index: Int) -> String { "match.check.\(id).\(index)" }

        let literalArms = cases.enumerated().filter { $0.element.literal != nil }
        let wildcardArm = cases.first { $0.caseName == "_" }

        let entryLabel = literalArms.isEmpty ? defaultLabel : checkLabel(literalArms[0].offset)
        bodyIR += builder.fmtBr(labelName: entryLabel) + "\n"

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

    /// One literal arm's comparison against the bare scrutinee value. Returns the i1 temp, or nil when
    /// the operand does not fit the scrutinee's value type — the caller skips such an arm, since the
    /// interpreter never matches it either and inventing an operand would emit invalid IR.
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

    /// 下标写的容器求值 + 写回目标（`c[i] = v` 里的 `c`），三种形态各对应一条回写义务。
    /// `.subscriptGet` 走自上而下的独占化链，回写已在链内完成；`.fieldGet` 返回字段指针作写回目标，
    /// 不回写则 COW 分裂出的新句柄没人接住、那次写静默丢失；其余原样 `emitExpr`。`base` 只求值一次。
    private func emitSubscriptContainer(_ container: IRExpr) -> (value: IRValue, writeBack: (ptr: String, spelling: String)?) {
        if case .subscriptGet = container {
            return (emitUniqueContainerHandle(container), nil)
        }
        if case .fieldGet(let baseExpr, let field, let fieldType) = container {
            let baseValue = emitExpr(baseExpr)
            let (aggregate, _, fieldIndex) = nominalField(of: baseExpr, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(
                name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName,
                indices: [0, fieldIndex]
            ) + "\n"
            let loaded = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: loaded, type: fieldType.llvmSpelling, ptr: fieldPtr) + "\n"
            return (IRValue(llvmType: fieldType.llvmSpelling, ssaName: loaded), (fieldPtr, fieldType.llvmSpelling))
        }
        return (emitExpr(container), nil)
    }

    /// `bk_*_set` 之后把**新句柄写回字段**（`obj.field[i] = v` 那条链的收尾）。
    ///  行不通  它是那半条链的判据所在：不写回 ⇒ COW 分裂出的新句柄没人接住 ⇒ 那次写静默丢失。
    private func emitSubscriptFieldWriteBack(_ wb: (ptr: String, spelling: String)?, newRaw: String) {
        guard let wb = wb else { return }
        let typed = builder.freshTemp()
        bodyIR += " \(typed) = bitcast ptr \(newRaw) to \(wb.spelling)\n"
        bodyIR += builder.fmtStore(value: typed, type: wb.spelling, ptr: wb.ptr) + "\n"
    }

    /// 下标写入 `container[index] = value`（COW 契约）：先自上而下拆开嵌套容器
    /// （父独占在前、子在后）；`.load` 值在搬箱前 retain 一份；`bk_*_set` 回的分裂句柄
    /// 必须写回，否则这次写入会静默丢失。
    private func emitSubscriptStore(
        container: IRExpr, index: IRExpr, value: IRExpr, elementType: IRType, adopt: IRAdopt
    ) {
        // Dictionary store (G5): keys/values boxed by their own types; the
        // returned handle is written back to the owning slot (COW parity).
        if case .dict(let keyType, let valueType) = irType(of: container) {
            /// A nested dict target (`a["k"]["j"] = v`) joins the same top-down chain as the array branch: a
            /// bare `emitExpr` handle would write through a shared box and silently mutate every alias.
            let (containerValue, fieldWriteBack) = emitSubscriptContainer(container)
            let indexValue = emitExpr(index)
            let loweredValue = emitExpr(value)
            let storedValue = applyAdopt(adopt, loweredValue, type: valueType)
            let (keySpelling, keyWidth, keyTag) = arrayElementABI(keyType)
            let (valueSpelling, valueWidth, valueTag) = arrayElementABI(valueType)
            let keyBox = boxValue(indexValue, spelling: keySpelling)
            let valueBox = boxValue(storedValue, spelling: valueSpelling)
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
            //  重要  字段容器的回写（`obj.d["k"] = v`）：同一字段指针，时序在 `bk_dict_set` 之后。
            emitSubscriptFieldWriteBack(fieldWriteBack, newRaw: newRaw)
            /// 键被 `bk_dict_set` 拷进自己的箱：临时的键串读到这里就用完了。
            releaseOperand(index, indexValue)
            return
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        //  重要  容器求值走统一的 helper —— 它同时交出**字段容器**的写回钩子（`obj.field[i] = v`）。
        let (containerValue, fieldWriteBack) = emitSubscriptContainer(container)
        let indexValue = emitExpr(index)
        let loweredValue = emitExpr(value)
        let storedValue = applyAdopt(adopt, loweredValue, type: elementType)
        let boxPtr = builder.freshTemp()
        bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
        bodyIR += builder.fmtStore(value: storedValue.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
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
        //  重要  字段容器的回写（`obj.field[i] = v`）：**同一个**字段指针，时序在 `bk_array_set` 之后。
        //     行不通  不回写 ⇒ 分裂出的新句柄没人接住 ⇒ 那次写静默丢失（与上面变量槽那条同理）。
        emitSubscriptFieldWriteBack(fieldWriteBack, newRaw: newRaw)
    }

    /// Top-down COW split for nested container writes (`m[0][1] = v`), returning the exclusive
    /// innermost handle: the root's split goes back to its slot, inner levels are rewritten in place
    /// by `bk_*_ensure_unique_at`, and each level is typed by family (the dict split also boxes the key).
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

    /// `try` 操作数的求值 —— 与 `emitMatchSubject` 同一条理由、同一种做法：语句根部先求值、后分派。
    /// 可让出的操作数走让出序列，结果落帧槽再读回，因为让出点所在块的 SSA 值不支配续跑块。
    ///  行不通  不与判别式合成通用函数：两处分派形态不同（tagged match vs tag→ok/err），能共用的只有求值。
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
        //  注意  错误变量的槽在让出点**之前**声明 —— 若它落在栈上，续跑路径（入口 `switch` →
        // `de6b.resume.k`）**不支配**它，续跑之后读到的就是一块悬垂地址。故与其余局部槽同规：
        // 走 `declareLocalSlot`（可恢复体里 = 帧槽；普通体里 = `alloca`，形状一字未改）。
        let errSlot = declareLocalSlot(named: freshSlot(for: errorVar), spelling: "i64")
        scopes[scopes.count - 1][errorVar] = errSlot

        ///  重要  `try` 位若是可让出的 `await` ⇒ 走让出序列，结果落帧槽再读回。
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

        /// A labeled `if` is an interruptible frame, so `break 标签` inside either branch jumps to
        /// `endLabel`. It is not a `continue` target, so its resume labels are never read and point at the
        /// merge block. Each branch pushes its own frame so `cleanupBase` names that branch.
        let isFrame = label != nil

        bodyIR += "\(thenLabel):\n"
        if isFrame {
            controlStack.append(
                ControlFrame(
                    exit: endLabel, header: endLabel, continueTarget: endLabel, isLoop: false,
                    cleanupBase: pendingCleanup.count
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
                        cleanupBase: pendingCleanup.count
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

        /// The merge block is skippable only when both branches are covered by an else and both returned,
        /// and only when no `break` jumped to it: such a jump is itself a terminator, so without this the
        /// label would be branched to but never defined.
        let endTargeted = breakMergeLabels.contains(endLabel)
        if elseBody != nil && thenTerminated && elseTerminated && !endTargeted {
            terminated = true
        } else {
            bodyIR += "\(endLabel):\n"
            terminated = false
        }
    }

    /// `while cond: body [step: block]`. The step block sits between body and the back edge, so an
    /// unlabeled `continue` inside the body lands on the step entry (interpreter sets
    /// `shouldRunStep = true`), while `break` from either block targets the exit and skips the step.
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
        controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, isLoop: true, cleanupBase: pendingCleanup.count))
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
            controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, isLoop: true, cleanupBase: pendingCleanup.count))
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

    /// `for (pattern,) in iterable: body [step: block]`: the iterable is evaluated once, its length
    /// read via the kind's accessor, and a hidden i32 index walks it. Each iteration re-reads the
    /// element and re-binds the pattern in a fresh loop scope; step/break/continue per the whileStmt.
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
        controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: continueTarget, isLoop: true, cleanupBase: pendingCleanup.count))
        scopes.append([:])
        terminated = false
        // Pattern bindings: a fresh slot per iteration (the loop scope makes
        // the previous iteration's binding unreachable, matching the
        // interpreter's per-iteration Environment).
        let indexForBind = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: indexForBind, type: "i32", ptr: indexSlot) + "\n"
        // Element bindings that are collection handles hold one share
        // for the iteration; collect them for the body block's release frame.
        var patternReleases: [CleanupEntry] = []
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
            if let symbol = Self.collectionDestroySymbol(for: elementType) {
                patternReleases.append(
                    .release(ReleasedHandle(slot: slot, typeSpelling: spelling, destroySymbol: symbol))
                )
            }
        }
        /// The step block shares the loop environment in the interpreter (`executeFor` runs it with
        /// `currentEnv = loopEnv`), so pattern variables stay visible there — a bare `v` in `step:`
        /// resolves to the body's slot. Hand the same bindings to the step scope.
        let patternBindings = scopes[scopes.count - 1]
        emitBlock(body, seeding: patternReleases)
        controlStack.removeLast()
        if !terminated {
            bodyIR += builder.fmtBr(labelName: step != nil ? stepLabel : incLabel) + "\n"
        }
        scopes.removeLast()

        if let step = step {
            bodyIR += "\(stepLabel):\n"
            controlStack.append(ControlFrame(exit: exitLabel, header: condLabel, continueTarget: stepEndLabel, isLoop: true, cleanupBase: pendingCleanup.count))
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

    /// 求值的唯一出口：先求值，再按中端的表给新份额入账。入账在这里做而不是在各构造点 ——
    /// 构造点有七处，出口只有一个，而漏一处的后果是每次求值都漏一份。
    private func emitExpr(_ expr: IRExpr) -> IRValue {
        let value = emitExprValue(expr)
        if expr.shareEffect == .fresh, irType(of: expr).holdsAShare {
            adoptFreshShare(value, type: irType(of: expr))
        }
        return value
    }

    /// 记下一个刚造出来、还没有持有者的份额。它的去路只有两条：存储位接管（`applyAdopt`），
    /// 或消费位用完归还（`releaseHeldTemporary`）。两条都不走，就是漏一份。
    private func adoptFreshShare(_ value: IRValue, type: IRType) {
        switch type.shareClass {
        case .retained(.string): holdString(value.ssaName)
        case .valueBox, .retained: holdBox(name: value.ssaName, type: type)
        case .inert, .aggregate: break
        }
    }

    private func emitExprValue(_ expr: IRExpr) -> IRValue {
        switch expr {
        case .intConst(let value, let type):
            //  注意  指针类型上不能写整数字面量：`ret ptr 0` 会让**整个模块**被 lli 拒
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
            /// `joinAll([a, b, ...])` 吃的是**句柄数组**而不是一个普通实参：字面量形态直接展开，
            /// 免得先建一个数组再拆回来。
            if function == "joinAll" {
                return emitJoinAll(arguments: arguments, returnType: returnType)
            }
            let args = arguments.map { emitExpr($0) }
            /// 异步被调者的调用点就是派发点：判据取被调者自己的 `isAsync`，不取类型。
            /// 调用节点上带的是体协议（`Result`，被调方真的返回什么），句柄类型只活在签名表里 ——
            /// 于是「这次调用是不是派发」只有函数自己的事实能回答。
            if let callee = moduleFunctions[Self.mangle(function)], callee.isAsync,
                let bodyReturn = callee.returnType, case .result = bodyReturn
            {
                /// 派发不走借用：帧把实参整体搬走，名义箱那份 +1 就此归任务 ⇒ 调用点一条也不还。
                return emitTaskSpawn(
                    callee: callee, mangled: Self.mangle(function), args: args,
                    argEffects: arguments.map(\.shareEffect))
            }
            /// `F64(x)` is an instruction, not a symbol: falling through to `call @F64` would reference an
            /// undefined value while the command still exits zero. A double is already there; anything
            /// integral widens with sitofp.
            if function == "F64", args.count == 1 {
                let operand = args[0]
                if operand.llvmType == "double" { return operand }
                let temp = builder.freshTemp()
                bodyIR += " \(temp) = sitofp \(operand.llvmType) \(operand.ssaName) to double\n"
                return IRValue(llvmType: "double", ssaName: temp)
            }

            /// `append` reaches the emitter as a named call rather than a dedicated node, and the interpreter
            /// answers it from the runtime. It is wired to the array family symbol here, using the same element
            /// ABI table as `bk_array_set`.
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

            /// `joinWithin(future, ms)` 是三槽 join 的带时限形态：超时归约为取消在运行时做，
            /// 调用点只多传一个毫秒值。
            if function == "joinWithin", args.count == 2 {
                guard let type = returnType, case .result(let okType) = type else {
                    fatalError(
                        "IREmitter: joinWithin needs a Result return type (IRLowerer guarantees)")
                }
                return emitJoinWithin(
                    handle: args[0], timeout: args[1], type: type, okType: okType)
            }

            let argList = args.map { "\($0.llvmType) \($0.ssaName)" }.joined(separator: ", ")
            /// 字符内建由解释器侧的 `RuntimeOps.characterBuiltins` 按名回答，这里接到 `bk_<名字>` 运行时段上；
            /// 表即白名单，与降载侧同一条规矩 ⇒ 不存在「降下来了却没人答」的名字。
            ///  行不通  谓词不用 C 的 `_Bool`（零扩展的 i8）而回 `i32`：本层 Bool 是 i1，收敛在这里显式做掉。
            if BuiltinSurface.character.contains(function) {
                usesCharacterShims = true
                let symbol = "bk_\(function)"
                let result: IRValue
                switch function {
                case "chars":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call ptr @\(symbol)(\(argList))\n"
                    result = IRValue(llvmType: "%bk_array*", ssaName: temp)
                case "chr":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call ptr @\(symbol)(\(argList))\n"
                    result = IRValue(llvmType: "i8*", ssaName: temp)
                case "ord":
                    let temp = builder.freshTemp()
                    bodyIR += " \(temp) = call i32 @\(symbol)(\(argList))\n"
                    result = IRValue(llvmType: "i32", ssaName: temp)
                default:
                    let raw = builder.freshTemp()
                    bodyIR += " \(raw) = call i32 @\(symbol)(\(argList))\n"
                    let flag = builder.freshTemp()
                    bodyIR += " \(flag) = icmp ne i32 \(raw), 0\n"
                    result = IRValue(llvmType: "i1", ssaName: flag)
                }
                releaseCallArguments(args)
                return result
            }
            // 探测类内建：符号返 `i32`（0/1），此处收敛到 `i1` —— 与谓词同规。
            if function == "exists" || function == "isDir" {
                usesProcessShims = true
                let symbol = function == "exists" ? "bk_exists" : "bk_is_dir"
                let raw = builder.freshTemp()
                bodyIR += " \(raw) = call i32 @\(symbol)(\(argList))\n"
                let flag = builder.freshTemp()
                bodyIR += " \(flag) = icmp ne i32 \(raw), 0\n"
                releaseCallArguments(args)
                return IRValue(llvmType: "i1", ssaName: flag)
            }
            /// 运行时段命名的外呼符号（G14 的 shim）在其 `bk_` 名字上调用，declare 由声明段按同一开关发。
            /// `isCancel` 同规：运行时段回 `i32`（0/1），到 `i1` 在这里显式转 —— `call i1` 对 `declare i32`
            /// 在 arm64 上只是碰巧能跑，不是 ABI。
            if function == "isCancel" {
                usesErrorShims = true
                let raw = builder.freshTemp()
                bodyIR += " \(raw) = call i32 @bk_error_is_cancel(\(argList))\n"
                let flag = builder.freshTemp()
                bodyIR += " \(flag) = icmp ne i32 \(raw), 0\n"
                releaseCallArguments(args)
                return IRValue(llvmType: "i1", ssaName: flag)
            }

            let symbolName: String
            if function == "cstr" {
                usesCStrShim = true
                symbolName = "bk_cstr"
            } else if function == "sleep" {
                // `sleep` 是并发内建里**唯一**被降载成一条普通调用、却又必须由后端实现的：
                // 它按片睡、每片查一次取消 ⇒ 落点是原语层的运行时符号，不是 libc 的睡眠
                // （理由见 `PiniRuntime` 里 `bk_sleep` 的注释）。
                usesSleepShim = true
                symbolName = "bk_sleep"
            } else if function == "argv" {
                /// 宿主环境查询内建：降载侧按名降成既有 `call` 节点，解释器侧由执行器按名回答，
                /// LLVM 侧只差符号本身。接 `bk_argv`（无参、回字符串数组 = `%bk_array*`）。
                usesProcessShims = true
                symbolName = "bk_argv"
            } else if function == "moduleRoot" {
                // 程序基准查询：解释器的答案是 `programBase ?? 进程 CWD`，LLVM 侧由入口注入
                // 同一个值（`bk_set_program_base`），这里取回它，故两通道同一串。
                usesProcessShims = true
                usesModuleRootShim = true
                symbolName = "bk_module_root"
            } else if function == "listDir" {
                /// 目录枚举，同上：降载侧在册，LLVM 侧接 `bk_list_dir`
                /// （一参 String、回**条目名字**数组，排序与错误语义镜像解释器）。
                usesProcessShims = true
                symbolName = "bk_list_dir"
            } else if function == "Error" {
                // 错误对象构造。err 槽装的是**运行时段对象句柄**（一个 i64 字），
                //  行不通  不是名义类型指针：`%struct.Error*` 没有类型定义，落成它就是
                // `use of undefined type`。
                usesErrorShims = true
                symbolName = "bk_error_create"
            } else if function == "CancelError" {
                // 与 `Error` 只差那个「是取消」标志； 行不通  ABI 上不多传一个参数，而是各一个符号。
                usesErrorShims = true
                symbolName = "bk_cancel_error_create"
            } else if function == "cancel" {
                /// `Future.cancel()` 降载成一条普通调用；落点是运行时的取消入口，不是同名外部符号。
                usesTaskCancel = true
                symbolName = "bk_task_cancel"
            } else if function == "pini.err.message" {
                // 只由降载层产出（`print(e)` 与 `e.message`）， 行不通  不是语言内建。
                // 名字带点 ⇒ 不可能是合法的 Pini 标识符，与用户函数无从重名。
                usesErrorShims = true
                symbolName = "bk_error_message"
            } else {
                symbolName = Self.mangle(function)
            }
            let callee = "@\(symbolName)"
            if let returnType = returnType {
                let temp = builder.freshTemp()
                bodyIR += " \(temp) = call \(returnType.llvmSpelling) \(callee)(\(argList))\n"
                releaseCallArguments(args)
                return IRValue(llvmType: returnType.llvmSpelling, ssaName: temp)
            }
            bodyIR += " call void \(callee)(\(argList))\n"
            releaseCallArguments(args)
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
            /// 名义箱：分配器写四格头，标签落在头之后的第一格、载荷从下一格起 —— 槽位问布局。
            /// 与 `emitMatch` 的 enum 分支同一套偏移。
            let ptr = emitNominalAllocation(aggregate: aggregate, typeID: enumTypeIDs[enumName] ?? 0)
            /// 新箱起始 +1；入账由求值出口按效果表统一做。
            let tagPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(
                    name: tagPtr, aggregate: aggregate, base: ptr, indices: [0, layout.enumTagSlot])
                + "\n"
            bodyIR += builder.fmtStore(value: String(tag), type: "i32", ptr: tagPtr) + "\n"
            for (index, payload) in payloads.enumerated() {
                let value = emitExpr(payload)
                let fieldPtr = builder.freshTemp()
                bodyIR +=
                    builder.fmtGEP(
                        name: fieldPtr, aggregate: aggregate, base: ptr,
                        indices: [0, layout.enumPayloadSlot(of: index)])
                    + "\n"
                /// 载荷槽是持有位置 ⇒ 与 `.fieldStore` 同一规：别名（`.load` 出来的名义值）在这里必须 retain，
                /// 结构体则深拷贝。裸 store 会让新箱存着旧箱指针却不多一份份额，写前释放旧值便把它收回 ⇒
                /// 新箱里悬垂，读出来是「match value matched no case」这类非确定性失败。
                let stored = applyAdopt(
                    payloadTypes[index].adoption(of: payload), value, type: payloadTypes[index])
                bodyIR += builder.fmtStore(value: stored.ssaName, type: payloadTypes[index].llvmSpelling, ptr: fieldPtr) + "\n"
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
            let (aggregate, _, fieldIndex) = nominalField(of: base, field: field)
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: baseValue.ssaName, indices: [0, fieldIndex]) + "\n"
            let value = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: value, type: type.llvmSpelling, ptr: fieldPtr) + "\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: value)

        case .stringCase(let isUpper, let receiver):
            let receiverValue = emitExpr(receiver)
            let converted = emitStringCase(isUpper: isUpper, source: receiverValue.ssaName)
            releaseOperand(receiver, receiverValue)
            return converted

        case .stringContains(let receiver, let needle):
            // 契约 §2.9 第 37 条：**字素级**判定。 行不通  旧形状的 `strstr` 是字节查找 ——
            // 分解式 Unicode 下与字素判定分歧（`"café"` 分解式 vs 预组合）。语义在运行时段，
            // 与解释器的 `.stringContains` 同源。
            let receiverValue = emitExpr(receiver)
            let needleValue = emitExpr(needle)
            usesStringShims = true
            let hit = builder.freshTemp()
            bodyIR +=
                " \(hit) = call i32 @bk_string_contains(ptr \(receiverValue.ssaName), "
                + "ptr \(needleValue.ssaName))\n"
            releaseOperand(receiver, receiverValue)
            releaseOperand(needle, needleValue)
            let found = builder.freshTemp()
            bodyIR += " \(found) = icmp ne i32 \(hit), 0\n"
            return IRValue(llvmType: "i1", ssaName: found)

        case .stringSubstring(let receiver, let start, let end):
            /// 契约与解释器都按 end（绝对下标）钉；语义（字素 · 负值尾计数 · 双端夹取 · hi≤lo 得空串）与分配
            /// 一起交给运行时段，与解释器的 `IRExecutor.stringSubstring` 同源。
            /// 发射层自己拼会在调用点发 `alloca i8, len+1`，而循环里的 alloca 到函数返回才回收 ⇒ 吃平方级栈。
            let receiverValue = emitExpr(receiver)
            let startValue = emitExpr(start)
            let endValue = emitExpr(end)
            usesStringShims = true
            let substringResult = builder.freshTemp()
            bodyIR +=
                " \(substringResult) = call ptr @bk_substring(ptr \(receiverValue.ssaName), "
                + "i32 \(startValue.ssaName), i32 \(endValue.ssaName))\n"
            releaseOperand(receiver, receiverValue)
            return IRValue(llvmType: "i8*", ssaName: substringResult)

        case .stringSplit(let receiver, let delim, let type):
            let receiverValue = emitExpr(receiver)
            let delimValue = emitExpr(delim)
            ///  注意  本条**必须**置位：委派到运行时段之后，declare 靠这个标志出现。漏了它 ⇒
            /// 产物里只有 `call`，没有 `declare` ⇒ clang 报 `use of undefined value '@bk_string_split'`。
            usesStringShims = true
            let parts = emitStringSplit(
                source: receiverValue.ssaName, delim: delimValue.ssaName, type: type)
            releaseOperand(receiver, receiverValue)
            releaseOperand(delim, delimValue)
            return parts

        case .stringTrimLeft(let receiver):
            // Runtime-shim delegation (same stance as `.stringSubstring`):
            // the shim owns the U+0020-only rule and the allocation, so the
            // interpreter and this emitter cannot drift.
            let receiverValue = emitExpr(receiver)
            usesStringShims = true
            let trimLeftResult = builder.freshTemp()
            bodyIR +=
                " \(trimLeftResult) = call ptr @bk_string_trim_left(ptr \(receiverValue.ssaName))\n"
            releaseOperand(receiver, receiverValue)
            return IRValue(llvmType: "i8*", ssaName: trimLeftResult)

        case .stringTrimRight(let receiver):
            // Same stance as `.stringTrimLeft`.
            let receiverValue = emitExpr(receiver)
            usesStringShims = true
            let trimRightResult = builder.freshTemp()
            bodyIR +=
                " \(trimRightResult) = call ptr @bk_string_trim_right(ptr \(receiverValue.ssaName))\n"
            releaseOperand(receiver, receiverValue)
            return IRValue(llvmType: "i8*", ssaName: trimRightResult)

        case .stringIndexOf(let receiver, let needle):
            // Same stance as `.stringContains`: the shim runs the grapheme
            // scan and returns the first-occurrence index (0 for an empty
            // needle, -1 when absent).
            let receiverValue = emitExpr(receiver)
            let needleValue = emitExpr(needle)
            usesStringShims = true
            let indexResult = builder.freshTemp()
            bodyIR +=
                " \(indexResult) = call i32 @bk_string_index_of(ptr \(receiverValue.ssaName), "
                + "ptr \(needleValue.ssaName))\n"
            releaseOperand(receiver, receiverValue)
            releaseOperand(needle, needleValue)
            return IRValue(llvmType: "i32", ssaName: indexResult)

        case .arrayJoin(let receiver, let separator):
            let receiverValue = emitExpr(receiver)
            let separatorValue = emitExpr(separator)
            let joined = emitArrayJoin(array: receiverValue, sep: separatorValue.ssaName)
            releaseOperand(receiver, receiverValue)
            releaseOperand(separator, separatorValue)
            return joined

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
            /// 分配入口走运行时段 `bk_str_alloc`，拼接形状逐字不变（`strlen` ×2 → `add` → `add 1` →
            /// 分配 → `strcpy` → `strcat`），差别只在产出的串带引用计数头、进了运行时段登记表。
            ///  行不通  退回裸 `malloc` 会让后续 release 静默变成无操作 —— 看起来发了释放，实际一个字节没回收。
            bodyIR += " \(buf) = call ptr @bk_str_alloc(i64 \(sz1))\n"
            bodyIR += " call ptr @strcpy(ptr \(buf), ptr \(lhsValue.ssaName))\n"
            bodyIR += " call ptr @strcat(ptr \(buf), ptr \(rhsValue.ssaName))\n"
            /// 两个操作数到此用完：只被 `strlen` / `strcpy` / `strcat` 读过，没有持有者接管 ⇒ 就地还掉。
            /// 这一步就是二次方项的处置：`a + b + c` 的中间串既不落槽也不是最终值，除这里没有别的回收点。
            releaseHeldString(lhsValue)
            releaseHeldString(rhsValue)
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

        case .fileAppend(let path, let content):
            return emitFileAppend(path: path, content: content)

        case .fileRead(let path):
            return emitFileRead(path: path)

        case .fileTryWrite(let path, let content):
            return emitFileTryWrite(path: path, content: content)

        case .fileTryAppend(let path, let content):
            return emitFileTryAppend(path: path, content: content)

        case .fileTryRead(let path):
            return emitFileTryRead(path: path)

        case .readLine:
            return emitReadLine()

        case .isAsciiDigit(let argument):
            return emitIsAsciiDigit(argument)

        case .join(let future, let type, let form):
            return emitJoin(future: future, type: type, form: form)

        case .givenInstance(let type):
            /// 物化面的三件套：存放位 + 合成初始化函数 + 运行时取用。
            return emitGivenInstance(type: type)
        }
    }

    /// A libc call or runtime shim answering NULL panics here instead of being handed on: the trap
    /// would otherwise happen inside libc with no message at all. `message` is caller-supplied and
    /// not interpolated — some shapes cannot fold to a constant, and `readFile` can fail at the read.
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

    /// `writeFile(path, content)`: one runtime shim call that writes the whole content with the same
    /// Foundation call as the interpreter's arm — in-place truncation, following symlinks, failing
    /// loud on an unwritable target. Produces no value.
    private func emitFileWrite(path: IRExpr, content: IRExpr) -> IRValue {
        usesFileWrite = true
        let pathValue = emitExpr(path)
        let contentValue = emitExpr(content)
        bodyIR += " call void @bk_write_file(ptr \(pathValue.ssaName), ptr \(contentValue.ssaName))\n"
        releaseOperand(path, pathValue)
        releaseOperand(content, contentValue)
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// `appendFile(path, content)`: 追加到目标末尾；目标不存在则创建（POSIX `"a"`）。
    /// 与写路径一样只发一次运行时调用 —— 路径解析、创建语义与失败形态都在那一侧。
    private func emitFileAppend(path: IRExpr, content: IRExpr) -> IRValue {
        usesFileAppend = true
        let pathValue = emitExpr(path)
        defer { releaseOperand(path, pathValue) }
        let contentValue = emitExpr(content)
        bodyIR += " call void @bk_append_file(ptr \(pathValue.ssaName), ptr \(contentValue.ssaName))\n"
        releaseOperand(content, contentValue)
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// `readFile(path)`: the runtime shim reads the whole file and hands back a NUL-terminated,
    /// malloc-allocated UTF-8 C string, or NULL when it cannot be read; NULL panics via `emitNullGuard`,
    /// which covers the read as well as the open. The path travels as written; the runtime resolves it.
    private func emitFileRead(path: IRExpr) -> IRValue {
        usesFileRead = true
        let pathValue = emitExpr(path)
        defer { releaseOperand(path, pathValue) }
        let content = builder.freshTemp()
        bodyIR += " \(content) = call ptr @bk_read_file(ptr \(pathValue.ssaName))\n"
        emitNullGuard(handle: content, message: "Pini runtime error: readFile could not read the file")
        // "i8*" (not "ptr"): that is the spelling emitScalarPrint treats as a
        // C string; a bare `ptr` falls into the %d default and prints the
        // address.
        return IRValue(llvmType: "i8*", ssaName: content)
    }

    /// `tryReadFile(path)`：读全文，失败作为值返回而不陷阱。
    /// 读的成功值占住返回值，错误只能从 out 参数出来；写与追加没有成功值，错误直接是返回值。
    /// 两边都不引线程局部隐状态 —— 那在嵌套调用下会互相覆盖。发射形态刻意线性：无分支、无 phi。
    private func emitFileTryRead(path: IRExpr) -> IRValue {
        usesFileTryRead = true
        let pathValue = emitExpr(path)
        let errSlot = freshSlot(for: "tryread.err")
        bodyIR += builder.fmtAlloca(name: errSlot, type: "i64") + "\n"
        let content = builder.freshTemp()
        bodyIR +=
            " \(content) = call ptr @bk_try_read_file(ptr \(pathValue.ssaName), ptr \(errSlot))\n"
        let errorWord = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: errorWord, type: "i64", ptr: errSlot) + "\n"
        let spelling = IRType.result(ok: .string).llvmSpelling
        let failed = builder.freshTemp()
        bodyIR += " \(failed) = icmp ne i64 \(errorWord), 0\n"
        let tag = builder.freshTemp()
        bodyIR += " \(tag) = select i1 \(failed), i64 1, i64 0\n"
        // 失败侧塞 null：tag 已经是 1，没有读者会去看 ok 槽 —— 但 SSA 要求每个
        // `insertvalue` 都有个操作数，而「留 undef」会让产物依赖一个未定义值的位模式。
        let okPayload = builder.freshTemp()
        bodyIR += " \(okPayload) = select i1 \(failed), ptr null, ptr \(content)\n"
        let withTag = builder.freshTemp()
        bodyIR += " \(withTag) = insertvalue \(spelling) undef, i64 \(tag), 0\n"
        let withPayload = builder.freshTemp()
        bodyIR += " \(withPayload) = insertvalue \(spelling) \(withTag), i8* \(okPayload), 1\n"
        let aggregate = builder.freshTemp()
        bodyIR +=
            " \(aggregate) = insertvalue \(spelling) \(withPayload), i64 \(errorWord), 2\n"
        return IRValue(llvmType: spelling, ssaName: aggregate)
    }

    /// `tryWriteFile(path, content)` —— 就地截断写，失败**返回** `err`。
    private func emitFileTryWrite(path: IRExpr, content: IRExpr) -> IRValue {
        usesFileTryWrite = true
        let pathValue = emitExpr(path)
        let contentValue = emitExpr(content)
        let errorWord = builder.freshTemp()
        bodyIR +=
            " \(errorWord) = call i64 @bk_try_write_file(ptr \(pathValue.ssaName), ptr \(contentValue.ssaName))\n"
        return emitUnitTryIOResult(errorWord: errorWord)
    }

    /// `tryAppendFile(path, content)` —— 追加写（目标不存在则创建），失败**返回** `err`。
    private func emitFileTryAppend(path: IRExpr, content: IRExpr) -> IRValue {
        usesFileTryAppend = true
        let pathValue = emitExpr(path)
        let contentValue = emitExpr(content)
        let errorWord = builder.freshTemp()
        bodyIR +=
            " \(errorWord) = call i64 @bk_try_append_file(ptr \(pathValue.ssaName), ptr \(contentValue.ssaName))\n"
        return emitUnitTryIOResult(errorWord: errorWord)
    }

    /// 两个「成功不产生值」的可接住写共用的收尾：`{ i64 tag, {  } ok, i64 err }`。
    /// ok 槽是零宽空结构体，填 `undef` 即可；不编一个字节数当载荷 —— 那只是入参的函数，不是新信息。
    private func emitUnitTryIOResult(errorWord: String) -> IRValue {
        let spelling = IRType.result(ok: .tuple(labels: [], fieldTypes: [])).llvmSpelling
        let failed = builder.freshTemp()
        bodyIR += " \(failed) = icmp ne i64 \(errorWord), 0\n"
        let tag = builder.freshTemp()
        bodyIR += " \(tag) = select i1 \(failed), i64 1, i64 0\n"
        let withTag = builder.freshTemp()
        bodyIR += " \(withTag) = insertvalue \(spelling) undef, i64 \(tag), 0\n"
        let withPayload = builder.freshTemp()
        bodyIR += " \(withPayload) = insertvalue \(spelling) \(withTag), \(emptyTupleSpelling) undef, 1\n"
        let aggregate = builder.freshTemp()
        bodyIR += " \(aggregate) = insertvalue \(spelling) \(withPayload), i64 \(errorWord), 2\n"
        return IRValue(llvmType: spelling, ssaName: aggregate)
    }

    /// 零宽空元组的 LLVM 拼写，取自类型本身而不是手写常量 ——
    /// 手写会与 `IRType.tuple` 的拼法漂移，而漂移方向是产物非法。
    private var emptyTupleSpelling: String {
        IRType.tuple(labels: [], fieldTypes: []).llvmSpelling
    }

    /// `readLine()`: a fixed-size stack buffer filled by `fgets` from stdin, yielded as a String; the
    /// cap, the retained line terminator and the buffer size all come from the interpreter's shared limit.
    ///  注意  At EOF `fgets` yields NULL, and printing that as `%s` is undefined, so the guard substitutes "".
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

    /// `is_ascii_digit(s)`: the first byte of the C string tested against [0x30, 0x39]. The empty string
    /// loads its NUL terminator and is false without a length check — the same answer the interpreter's
    /// first-grapheme rule gives in the ASCII domain.
    private func emitIsAsciiDigit(_ argument: IRExpr) -> IRValue {
        let subject = emitExpr(argument)
        defer { releaseOperand(argument, subject) }
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

    /// `assert(cond, msg?)`: the false edge prints the message (or a default) and calls the noreturn
    /// panic; passing asserts fall through. In test mode it records the failure into module slots and
    /// jumps to the test exit, so one failure hides no later test; non-test code keeps the trap path.
    private func emitAssertCall(condition: IRExpr, message: IRExpr?) -> IRValue {
        let cond = emitExpr(condition)
        let passLabel = "assert.pass.\(builder.freshLabel())"
        let failLabel = "assert.fail.\(builder.freshLabel())"
        let endLabel = "assert.end.\(builder.freshLabel())"
        bodyIR += builder.fmtCondBr(cond: cond.ssaName, thenLabelName: passLabel, elseLabelName: failLabel) + "\n"
        bodyIR += "\(failLabel):\n"
        let msg = message ?? .stringConst(value: "assert failed")
        let rendered = emitExpr(msg)
        if let exitLabel = currentTestExitLabel {
            // 顺序即语义：先把消息存好，再置失败事实，最后才离开本函数 ——
            // 反过来的话，驱动器可能读到「已置失败、消息还没写」的中间态。
            bodyIR += " store ptr \(rendered.ssaName), ptr @\(Self.testMsgGlobal)\n"
            bodyIR += " store i32 1, ptr @\(Self.testFailedGlobal)\n"
            bodyIR += builder.fmtBr(labelName: exitLabel) + "\n"
        } else {
            /// 陷阱去向与 `panicStmt` 同规：消息进 stderr、退出码 1、stdout 一个字节不动。
            /// 先 `printf` 再 `bk_panic(null)` 会把断言消息塞进程序输出流，并给 stderr 留一个空行。
            bodyIR += " call void @bk_panic(ptr \(rendered.ssaName))\n"
            bodyIR += builder.fmtBr(labelName: endLabel) + "\n"
        }
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

    /// `store(p, v)`: truncating store for narrow elements, mirroring the interpreter's encode
    /// (`Int8(truncatingIfNeeded:)`). The value's own IR type drives the narrowing chain (an I32 into a
    /// *U8 slot truncates i32 → i8); the element type is the ABI authority.
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

    /// `print(a, b, ...)`: per-argument rendering separated by single spaces, one trailing newline —
    /// the same byte stream as the interpreter's stringify-join. Arguments go through the shared
    /// recursive printer, so a mixed call matches the single-argument form; unrenderable types trap.
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
            /// 与单参打印同规：临时值印完即还。
            releaseHeldTemporary(printed)
        }
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// True for the types neither print path can render: the scalar path would print an aggregate's or
    /// a runtime handle's bits. Scalars, strings, raw pointers and nominal values are excluded — the last
    /// through the shared recursive printer. A `Future` groups with the handles, not the pointers.
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

    /// `LazyRef<T>(closure)`: extract the initializer's fat pointer { code, env }, ensure the
    /// type-specialized boxing wrapper, and call `bk_lazyref_create(wrapper, code, env, bytes, tag)`.
    /// The handle stays an opaque `%bk_lazyref*`.
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

    /// LazyRef element boxing ABI (bytes/tag): strings use the raw-ptr tag (4), NOT the array-family
    /// tag 3 — they are immutable C bytes with no share count, and boxing them as share-counted handles
    /// would corrupt cleanup.
    private func lazyRefElemABI(_ type: IRType) -> (spelling: String, bytes: Int, tag: Int32) {
        switch type {
        case .i32: return ("i32", 4, 0)
        case .f64: return ("double", 8, 1)
        case .boolean: return ("i1", 1, 2)
        case .string: return ("i8*", 8, 4)
        /// `Char`, declared rather than left to the default: it rides on `string` because the representation
        /// is the same, so the raw-ptr tag applies for the reason above — a grapheme has no share count.
        case .char: return ("i8*", 8, 4)
        default:
            refuse(
                node: "lazyRefConstruct", family: .lazyRef,
                reason: "元素类型 \(type.llvmSpelling) 没有装箱 ABI（本通道能装的是 I32 / F64 / Bool / String / Char）")
            return ("i32", 4, 0)
        }
    }

    /// Buffer (deduplicated) the type-specialized boxing wrapper `ptr @__lazyref_wrapper_<T>(code, env,
    /// out)`: it calls the initializer code, stores the element into the runtime-provided heap box, and
    /// returns it — one ptr ABI for every type, and the runtime owns the allocation.
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
    private func nominalField(of base: IRExpr, field: String) -> (aggregate: String, fieldType: IRType, index: Int) {
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
        /// 三族名义箱共用四格头 ⇒ 字段槽位一律问布局，发射器不再做加法。
        /// `isObject` 仍决定聚合名拼写（`%object` / `%struct` 是两个类型名），但不影响字段偏移。
        return (aggregate, decl.fields[index].type, layout.fieldSlot(of: index))
    }

    /// 默认实例的取用点：`bk_given_get(槽位, 初始化函数, 字节数)` → 盒指针，再 `memcpy` 一份到本地。
    /// `using` 取的是实参的副本，与传参一致：盒是程序级唯一的，交给调用点的却是值，写实例自身字段
    /// 等于改参数，只有经引用字段往下写才对所有取用点可见。字节数用过尾指针的整数形式，发两条真指令。
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
        /// 副本也住堆：它是取用方自己的一份（`using` 的副本语义），但会随帧外逃，不能再落栈。
        /// 只搬载荷 —— 源盒的头是未初始化内存（`bk_given_get` 不写头），连头搬会把垃圾带进
        /// 新副本的弱计数与旁表指针；头由分配器按本类型写好。
        let local = emitNominalAllocation(aggregate: aggregate, typeID: nominalTypeID(for: type))
        let dstPayload = builder.freshTemp()
        bodyIR +=
            builder.fmtGEP(
                name: dstPayload, aggregate: aggregate, base: local, indices: [0, layout.headerSlotCount])
            + "\n"
        let srcPayload = builder.freshTemp()
        bodyIR +=
            builder.fmtGEP(
                name: srcPayload, aggregate: aggregate, base: boxed, indices: [0, layout.headerSlotCount])
            + "\n"
        let headerPtr = builder.freshTemp()
        bodyIR +=
            builder.fmtGEP(
                name: headerPtr, aggregate: aggregate, base: "null", indices: [0, layout.headerSlotCount])
            + "\n"
        let headerBytes = builder.freshTemp()
        bodyIR += " \(headerBytes) = ptrtoint ptr \(headerPtr) to i64\n"
        let payloadBytes = builder.freshTemp()
        bodyIR += " \(payloadBytes) = sub i64 \(sizeTemp), \(headerBytes)\n"
        bodyIR += " call ptr @memcpy(ptr \(dstPayload), ptr \(srcPayload), i64 \(payloadBytes))\n"
        return IRValue(llvmType: type.llvmSpelling, ssaName: local)
    }

    /// 默认实例的盒指针 —— 不是它的值：与 `emitGivenInstance` 只差「不做那份本地拷贝」。
    /// 策略层方法会写它自己的字段（入队 / 出队），队列状态必须活过派发点那一帧；把栈上副本的地址
    /// 交给运行时，等于把队列放进随帧消失的对象里，挑选循环随后拿到悬垂指针，症状是随机错乱。
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

    /// 把一个已派发的任务与调度器绑定起来：策略是 Pini 值、方法体是编译产物，而运行时那层是纯 C
    /// ABI、拿不到方法表 ⇒ 由发射层交出三个机器字（策略实例 · 收下入口 · 选择下一任务入口）。
    /// 策略实例取盒指针而非副本（见 `emitGivenBoxPointer`）；方法不存在时不检查，由 `lli` 报未定义符号。
    private func emitSchedulerBinding(handle: String) {
        // 调度器类型不在本模块 ⇒ 没有策略可绑。 行不通  此时不绑：运行时的处置是
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

    /// 合成（并按类型去重）该类型的初始化函数 `define ptr @__given_init_<T>(ptr %out)`。
    /// 字段初值当普通表达式降载，与 `emitConstruct` 同一套算法，只差落点：写进运行时给的 `%out`。
    /// 故保存/恢复发射上下文、在干净的子上下文里发射；可重入（字段初值可能取用另一个给定块）。
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
        let savedCleanupScopeBase = cleanupScopeBase
        let savedReturnType = currentReturnType
        let savedIsMain = currentIsMain
        let savedCaptureSlots = captureSlots
        let savedPendingCleanup = pendingCleanup

        builder = IRBuilder()
        bodyIR = ""
        scopes = [[:]]
        slotCounters = [:]
        terminated = false
        controlStack = []
        breakMergeLabels = []
        cleanupScopeBase = 0
        currentReturnType = nil
        currentIsMain = false
        captureSlots = [:]
        pendingCleanup = []
        /// 给定初始化器也是独立体（新 `IRBuilder`）⇒ 临时箱账本同样换一份。
        heldBoxesStack.append(heldBoxes)
        heldBoxes = [:]

        // 引用计数头（第 0 格）：`%out` 是运行时给的**程序级单例盒**，头格写 1；
        //  注意  它**不参与计数释放**（`bk_given_get` 持有到进程结束），写 1 只是形态一致。
        let rcPtr = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: rcPtr, aggregate: aggregate, base: "%out", indices: [0, 0]) + "\n"
        bodyIR += builder.fmtStore(value: "1", type: "i32", ptr: rcPtr) + "\n"
        for (index, field) in decl.fields.enumerated() {
            let fieldPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: "%out", indices: [0, layout.fieldSlot(of: index)]) + "\n"
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
        cleanupScopeBase = savedCleanupScopeBase
        currentReturnType = savedReturnType
        currentIsMain = savedIsMain
        captureSlots = savedCaptureSlots
        pendingCleanup = savedPendingCleanup
        heldBoxes = heldBoxesStack.popLast() ?? [:]
        return symbol
    }

    /// 名义箱的分配：`bk_nominal_alloc` 写头四格（强计数 1、弱计数 0、类型标识、旁表 null）。
    ///  行不通  不用栈 `alloca`：栈上的箱活不过创建帧，而名义值会随返回值 / 字段 / 闭包捕获跨帧。
    /// 大小用过尾指针的整数形式，只依赖聚合体定义；与 `bk_given_get` 的单例盒不是同一条通道。
    private func emitNominalAllocation(aggregate: String, typeID: Int32) -> String {
        usesNominalBoxes = true
        let sizeEnd = builder.freshTemp()
        bodyIR += builder.fmtGEP(name: sizeEnd, aggregate: aggregate, base: "null", indices: [1]) + "\n"
        let sizeTemp = builder.freshTemp()
        bodyIR += " \(sizeTemp) = ptrtoint ptr \(sizeEnd) to i64\n"
        let ptr = builder.freshTemp()
        bodyIR += " \(ptr) = call ptr @bk_nominal_alloc(i64 \(sizeTemp), i32 \(typeID))\n"
        return ptr
    }

    /// 名义类型在模块内的类型标识；未登记的类型答 0（= 未知）。
    private func nominalTypeID(for type: IRType) -> Int32 {
        switch type {
        case .nominal(let name, _): return structTypeIDs[name] ?? 0
        case .enumeration(let name): return enumTypeIDs[name] ?? 0
        default: return 0
        }
    }

    /// MARK: - 释放胶水（名义箱的寿命）

    /// 收集一棵 IR 子树里所有闭包字面量捕获的变量名（含嵌套闭包自己再捕获的）。
    /// 用 `Mirror` 反射而非手写 `switch`：IR 有几十种节点，漏掉一种的症状是「捕获槽还留在栈上」，
    /// 只在跨帧时炸。反射宁可宽 —— 多收只会多一次堆分配，漏收才出错。
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
    /// `__release_*` 与 `__copy_*` 两族合成函数都按它去重，同名的 struct 与 enum 才不会撞在一起。
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

    /// 释放胶水对某个字段类型要做的动作。
    /// 名义字段递归调它自己的胶水且不判空（`bk_nominal_release(null)` 返回 0）；容器字段用
    /// `bk_*_destroy` 且必须判空（运行时的 destroy 对 null 是 `bk_panic`）；其余无动作。
    private func releaseCallee(for type: IRType) -> (symbol: String, needsNullGuard: Bool)? {
        if nominalKindSpelling(type) != nil {
            return (ensureReleaseFunction(for: type), false)
        }
        /// 字符串字段的释放：`self.字段 = 新串` 的覆盖必须发释放，否则累积形态（`self.buf`）原样二次方。
        /// `needsNullGuard = true`：结构体的字符串字段可能还没写过，是 null。
        if isRefcountedString(type) {
            usesStringRefcount = true
            return ("bk_str_release", true)
        }
        if let destroy = Self.collectionDestroySymbol(for: type) {
            return (destroy, true)
        }
        return nil
    }

    /// 某个类型在释放胶水里有没有动作。与 `releaseCallee` 的分工：那个会递归合成子类型胶水（有副作用），
    /// 这个只回答「要不要」—— 分派结构必须在合成之前算出来，否则会为只有标量载荷的 case 生成空 arm。
    private func needsReleaseAction(for type: IRType) -> Bool {
        if nominalKindSpelling(type) != nil { return true }
        if isRefcountedString(type) { return true }
        return Self.collectionDestroySymbol(for: type) != nil
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

    /// 逐类型合成的值语义拷贝胶水 `define ptr @__copy_struct_<mangled>(ptr %src)`，规则对齐解释器的
    /// `RuntimeOps.copyIfStruct`：结构体字段递归拷贝；对象 / 枚举字段共享 + retain；容器字段共享 +
    /// retain；标量与字符串直接复制。null 入参返回 null，故调用点不必判空；只为结构体合成。
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
        let copyTypeID = nominalTypeID(for: type)
        bodyIR += " \(dst) = call ptr @bk_nominal_alloc(i64 \(sizeTemp), i32 \(copyTypeID))\n"
        for (index, field) in decl.fields.enumerated() {
            let srcPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: srcPtr, aggregate: aggregate, base: "%src", indices: [0, layout.fieldSlot(of: index)]) + "\n"
            let value = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: value, type: field.type.llvmSpelling, ptr: srcPtr) + "\n"
            let stored: String
            switch boxFamily(of: field.type) {
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
            case .string:
                // N76：**字符串字段**在结构体拷贝里也要留一份 —— 源箱与新箱是两个持有者。
                //  注意  与另两族同规：`bk_str_retain` 对非本时段分配的串（全局常量）是无操作。
                usesStringRefcount = true
                bodyIR += " call void @bk_str_retain(ptr \(value))\n"
                stored = value
            case nil:
                stored = value  // 标量 / 外呼指针：直接复制
            }
            let dstPtr = builder.freshTemp()
            bodyIR +=
                builder.fmtGEP(name: dstPtr, aggregate: aggregate, base: dst, indices: [0, layout.fieldSlot(of: index)]) + "\n"
            bodyIR += builder.fmtStore(value: stored, type: field.type.llvmSpelling, ptr: dstPtr) + "\n"
        }
        bodyIR += " ret ptr \(dst)\n"
        copyFunctionDefs.append("define ptr @\(symbol)(ptr %src) {\nentry:\n" + bodyIR + "}\n\n")

        bodyIR = savedBodyIR
        builder = savedBuilder
        usesNominalBoxes = savedUsesNominalBoxes
        return symbol
    }

    /// 按中端填的接收动作落值。发射层不再判「该拷贝还是该保留」—— 只翻译注解。
    @discardableResult
    private func applyAdopt(_ adopt: IRAdopt, _ value: IRValue, type: IRType) -> IRValue {
        switch adopt {
        case .none:
            return value
        case .take:
            /// 临时值被持有位置接管 ⇒ 份额转移，本层不再负责释放它：字符串与箱各出一笔账。
            claimHeldString(value)
            claimHeldBox(value)
            return value
        case .copyStruct:
            guard let symbol = ensureCopyFunction(for: type) else {
                return retainCounted(value, type: type)
            }
            let copied = builder.freshTemp()
            bodyIR += " \(copied) = call ptr @\(symbol)(ptr \(value.ssaName))\n"
            let typed = builder.freshTemp()
            bodyIR += " \(typed) = bitcast ptr \(copied) to \(type.llvmSpelling)\n"
            return IRValue(llvmType: type.llvmSpelling, ssaName: typed)
        case .retain:
            return retainCounted(value, type: type)
        }
    }

    /// 计数族留一份；不在计数族的（标量 · 聚合 · `LazyRef` 缺口）零动作。
    private func retainCounted(_ value: IRValue, type: IRType) -> IRValue {
        guard let family = boxFamily(of: type) else { return value }
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr\n"
        switch family {
        case .container:
            bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
        case .nominal:
            usesNominalBoxes = true
            bodyIR += " call void @bk_nominal_retain(ptr \(raw))\n"
        case .string:
            usesStringRefcount = true
            bodyIR += " call void @bk_str_retain(ptr \(raw))\n"
        }
        return value
    }

    /// 逐类型合成的释放胶水 `define void @__release_<kind>_<mangled>(ptr %box)`：先 `bk_nominal_release`
    /// 减头格，返回 1 表示归零，只有归零才进 sweep 逐字段释放并 `free`。
    /// 自引用类型靠「名字先占位」防合成期无限递归；枚举按 tag 分派，未选中 case 的载荷槽不碰。
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
                    builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: "%box", indices: [0, layout.fieldSlot(of: index)])
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
            bodyIR +=
                builder.fmtGEP(
                    name: tagPtr, aggregate: aggregate, base: "%box", indices: [0, layout.enumTagSlot])
                + "\n"
            let tagValue = builder.freshTemp()
            bodyIR += builder.fmtLoad(name: tagValue, type: "i32", ptr: tagPtr) + "\n"
            ///  注意  判据必须用 case 自己的 `payloadTypes`，不能用 `slotTypes`：同一个槽在不同 case 里可以是不同
            /// 类型（如槽 0 在 `simple` 里是 `String`、在 `tupleType` 里是 `TypeAnnotationList`），按槽统一
            /// 判断会给「槽里其实是字符串常量」的 case 也生成释放。另一半判据是只挑真有释放动作的 case。
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
                        builder.fmtGEP(
                            name: fieldPtr, aggregate: aggregate, base: "%box",
                            indices: [0, layout.enumPayloadSlot(of: slot)])
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
        /// 名义箱：分配器写四格头，字段从头之后的第一格起 —— 槽位问布局。
        /// `isObject` 只影响聚合名拼写 —— 头两边都有，字段偏移不再分类讨论。
        let ptr = emitNominalAllocation(aggregate: aggregate, typeID: nominalTypeID(for: type))
        /// 新箱起始 +1；入账由求值出口按效果表统一做。
        let zero = zeroConst(for:)
        for (index, field) in decl.fields.enumerated() {
            let fieldPtr = builder.freshTemp()
            bodyIR += builder.fmtGEP(name: fieldPtr, aggregate: aggregate, base: ptr, indices: [0, layout.fieldSlot(of: index)]) + "\n"
            if let defaultValue = field.defaultValue {
                let value = emitExpr(defaultValue)
                bodyIR += builder.fmtStore(value: value.ssaName, type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
            } else {
                bodyIR += builder.fmtStore(value: zeroConst(for: field.type), type: field.type.llvmSpelling, ptr: fieldPtr) + "\n"
            }
        }
        return IRValue(llvmType: type.llvmSpelling, ssaName: ptr)
    }

    /// 按字段类型的 LLVM 拼写给出零值常量。
    private func zeroConst(for type: IRType) -> String {
        switch type {
        case .i8, .u8, .i32, .i64, .u64, .boolean: return "0"
        case .f64: return "0.0"
        default: return "null"
        }
    }

    /// `container.slice(start, end)`: a missing bound takes its default (start → 0, end → len), an
    /// integer bound is tail-counted when negative, both clamp to [0, len], and hi < lo yields empty.
    /// Arrays build a new handle (nested handle elements retain); strings copy bytes into a fresh buffer.
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
                // share, so the copy retains one (resource contract 3).
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
            /// 契约 §2.9 第 23 条：String 切片按字素簇，语义与分配一起交给运行时段，与 `IRExecutor.sliceValue`
            /// 的 `.string` 分支同源。按字节切会在非 ASCII 上落进多字节序列内部，自举 `splitLines` 由此切错行。
            ///  注意  开界传标志位而不传哨兵：`s[-1...]` 合法，拿 `-1` 当「开」会与真实下标撞车；开界也不求值。
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

    /// Append one element, yielding a NEW array handle: the input handle and its contents are left alone,
    /// the same functional shape `slice` produces. The element ABI (width + tag) and the alias rule come
    /// from the table the subscript store uses — a borrowed value is retained, a fresh one transfers.
    private func emitArrayAppend(
        receiver: IRValue, elementNode: IRExpr, elementValue: IRValue, elementType: IRType
    ) -> IRValue {
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        adoptElement(elementNode, elementValue, type: elementType)
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

    /// 切片的界是否是开界（`s[lo...]` / `s[...hi]` / `s[...]`）。判据是语法节点
    /// （`optionalConstruct` 的 `isSome == false`）而不是值 ⇒ 发射期即可定死，
    /// 运行时段只收一个标志位（C ABI 面没有 Optional 这个类型）。
    private func sliceBoundIsOpen(_ bound: IRExpr) -> Bool {
        if case .optionalConstruct(let isSome, _, _) = bound, !isSome { return true }
        return false
    }

    /// One Array slice bound: `none` takes the default (start → "0", end → the runtime count); an integer
    /// is tail-counted when negative, then clamped into [0, count] — all via select chains, no branches.
    ///  注意  String slices do not come here: their bounds and clamp live in the runtime (`bk_string_slice`).
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


    /// `arr.get(i)`: tolerant read — tail-counted negative index, bounds check, some(payload) or none.
    /// Arrays go through the runtime handle; strings take the grapheme count and the character from the
    /// runtime too. The aggregate flows through a stack slot so the branch join needs no phi node.
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

    /// Element boxing ABI against the runtime `_BkTag` values: the tag separates raw scalars from nested
    /// container handles (release / COW). Strings use the raw ptr tag, NOT the handle tag — immutable C
    /// strings have no share count, and the handle tag makes dict cowCopy retain constant bytes.
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
        //  重要  `*T` 原始指针走**裸指针 tag**（与 String / Char 同格），不是容器句柄那一格：
        // 它不参与引用计数，而运行时那两条钩子（retain / release）只在 handle tag 上动手。
        //  注意  装箱搬的是**指针值本身** —— 它指向什么，不归本层管（它是不透明句柄）。
        case .pointer: return ("i8*", 8, 3)
        case .future:
            /// 任务句柄是指针字，生命周期由 join / detach 管，数组只暂存 ⇒ 裸指针 tag，不计数。
            return ("ptr", 8, 3)
        default:
            /// 占位 ABI 只为了让发射走完：产物随即因 `refusals` 非空被丢掉，不会有人读到它。
            refuse(
                node: "arrayLiteral", family: .collections,
                reason: "元素类型 \(type.llvmSpelling) 没有装箱 ABI（本通道能装的是整数字 / F64 / Bool / String / 容器句柄 / 指针）")
            return ("i32", 4, 0)
        }
    }

    /// 容器元素落槽：元素按箱共享 ⇒ 结构体也保留而不拷；临时元素移交，账本随之清掉。
    /// 与语句级存储点同一条规则（`IRType.adoption`），差别只在 `sharingStructs`。
    private func adoptElement(_ node: IRExpr, _ value: IRValue, type: IRType) {
        _ = applyAdopt(type.adoption(of: node, sharingStructs: true), value, type: type)
    }

    // MARK: - N76：字符串临时值的账本

    /// 记下一个本层亲手分配、当前持有 +1 引用的字符串 SSA 名。
    /// 只有三类产出入账：`stringConcat` / `interpString` 的拼接结果，以及运行时段返回新分配串的内建。
    ///  行不通  借来的值（`load` / 全局常量 / 形参）不入账 —— 账本正是把这两类分开。
    private func holdString(_ name: String) {
        usesStringRefcount = true
        heldStrings.insert(name)
    }

    /// 交出份额：该值已被某个持有位置（变量槽 / 返回位 / 数组元素槽 / 字段）接管，此后由那里释放。
    /// 它与 `releaseHeldString` 互斥，一个值只能走一条；错成 claim 是泄漏（安全），错成 release 是
    /// 悬垂（危险）⇒ 凡「这个值要存下去」的位置，宁可用 claim。
    private func claimHeldString(_ value: IRValue) {
        guard value.llvmType == "i8*" else { return }
        heldStrings.remove(value.ssaName)
    }

    /// 就地消费掉一个字符串值（用完即扔，没有持有者接管它）：拼接的两个操作数、打印、长度查询、
    /// 作为内建实参。 行不通  对借用值（不在账里）是无操作 ⇒ 常量串、`load` 出的槽值、形参都不会被误释放。
    @discardableResult
    private func releaseHeldString(_ value: IRValue) -> Bool {
        guard value.llvmType == "i8*" else { return false }
        guard heldStrings.remove(value.ssaName) != nil else { return false }
        bodyIR += " call void @bk_str_release(ptr \(value.ssaName))\n"
        return true
    }

    // MARK: - 临时箱的账本（名义箱 / 容器句柄）

    /// 记下一个本层亲手分配、当前持有 +1 的临时箱。它还没有持有位置 ⇒ 调用点 / 打印点用完即还。
    /// 只由构造点（`construct` / `enumConstruct` / 三个字面量）调用：借用值（变量 / 字段 / 形参）从不入账。
    private func holdBox(name: String, type: IRType) {
        heldBoxes[name] = type
    }

    /// 交出份额：该值已被某个持有位置（槽 / 字段 / 返回位 / 载荷槽）接管，此后由那里释放。
    /// 它与 `releaseHeldTemporary` 互斥，一个值只走一条；错成 claim 是泄漏（安全），错成 release 是悬垂。
    private func claimHeldBox(_ value: IRValue) {
        heldBoxes.removeValue(forKey: value.ssaName)
    }

    /// 就地还掉一个本层持有的临时值 —— 调用点与打印点的「用完即扔」。 行不通  借用值不在账里 ⇒ 无操作。
    /// 判据是账本而不是节点形状：只有确实由本层分配、且没被持有位置接管的那些才在账上。
    private func releaseHeldTemporary(_ value: IRValue) {
        if releaseHeldString(value) { return }
        guard let type = heldBoxes.removeValue(forKey: value.ssaName) else { return }
        guard let symbol = releaseSymbol(for: type) else { return }
        bodyIR += " call void @\(symbol)(ptr \(value.ssaName))\n"
    }

    /// 一个只读操作数用完了：它若是本层新造的份额，就地归还；借用值不在账上 ⇒ 无操作。
    /// 与实参同规 —— 内建的操作数也是消费位，只是它不出现在 `call` 的实参表里。
    private func releaseOperand(_ node: IRExpr, _ value: IRValue) {
        guard node.shareEffect == .fresh else { return }
        releaseHeldTemporary(value)
    }

    /// 调用点的收尾：实参一律**借用**。被调方既不 retain 也不在出口释放（形参槽不进释放账本），
    /// 于是临时值的 +1 份额留在调用方，返回后当场还；变量 / 字段的别名份额不在账上，一条也不碰。
    private func releaseCallArguments(_ values: [IRValue]) {
        for value in values { releaseHeldTemporary(value) }
    }

    /// 值在发射层的计数族：容器句柄、名义箱、计数串各走一套 C ABI（`bk_handle_*` / `bk_nominal_*` /
    /// `bk_str_*`），归还规则同一套（别名点 retain · 作用域退出 release · 写前 release 旧值）。
    /// 返回 nil = 该类型不在计数族（标量 · 外部指针 · 聚合 · `LazyRef` 缺口 …）。
    private enum BoxFamily { case container, nominal, string }

    private func boxFamily(of type: IRType) -> BoxFamily? {
        switch type.shareClass {
        case .retained(.string): return .string
        case .retained(.array), .retained(.dict), .retained(.set): return .container
        case .retained(.object), .retained(.enumeration), .valueBox: return .nominal
        /// `LazyRef` 的句柄与他族同一个 `_BkBox` 计数头 ⇒ 保留走通用入口，释放走自己的符号。
        case .retained(.lazyRef): return .container
        case .aggregate, .inert: return nil
        }
    }

    private func emitArrayLiteral(elements: [IRExpr], type: IRType) -> IRValue {
        guard case .array(let elementType) = type else {
            fatalError("IREmitter: arrayLiteral type is not an array (IRLowerer guarantees)")
        }
        let (elemSpelling, width, elemTag) = arrayElementABI(elementType)
        let createTemp = builder.freshTemp()
        bodyIR += " \(createTemp) = call ptr @bk_array_create(i32 \(elements.count))\n"
        /// 构造句柄本就唯一（create 起始 shares==1），但 set 调用仍按同一形状串联，
        /// 好让构造路径与写回路径共用一套代码。
        var curRaw = createTemp
        for (index, element) in elements.enumerated() {
            let value = emitExpr(element)
            let boxPtr = builder.freshTemp()
            bodyIR += builder.fmtAlloca(name: boxPtr, type: elemSpelling) + "\n"
            bodyIR += builder.fmtStore(value: value.ssaName, type: elemSpelling, ptr: boxPtr) + "\n"
            adoptElement(element, value, type: elementType)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_array_set(ptr \(curRaw), i32 \(index), ptr \(boxPtr), i32 \(width), i32 \(elemTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_array*\n"
        /// 新句柄起始 shares == 1；入账由求值出口按效果表统一做。
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
            /// 契约 §2.9 第 23 条：String 下标按字素簇，负值尾计数，越界走安全断言通道（E5-005 parity）。
            /// 按字节取会在非 ASCII 上取出非法 UTF-8，且与 `len` 的计数模型矛盾 —— 自举切错正是这样来的。
            /// 语义（含越界 panic 与单字符结果）都在运行时段，与 `SubscriptReadStrategy` 的 `.string` 同源。
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
        defer { releaseOperand(argument, value) }
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
            //  行不通  旧形状数的是「非续字节」（= Unicode 标量）：纯 ASCII 与 CJK 上同值，
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
            adoptElement(keyNode, keyValue, type: keyType)
            let dictValue = IRValue(llvmType: "%bk_dict*", ssaName: curRaw)
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast %bk_dict* \(dictValue.ssaName) to ptr\n"
            let value = emitExpr(valueNode)
            let valueBox = boxValue(value, spelling: valueSpelling)
            adoptElement(valueNode, value, type: valueType)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_dict_set(ptr \(raw), ptr \(keyBox), i32 \(keyWidth), i32 \(keyTag), ptr \(valueBox), i32 \(valueWidth), i32 \(valueTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_dict*\n"
        /// 新句柄起始 shares == 1；入账由求值出口按效果表统一做。
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
            adoptElement(element, value, type: elementType)
            let nextRaw = builder.freshTemp()
            bodyIR += " \(nextRaw) = call ptr @bk_set_add(ptr \(curRaw), ptr \(box), i32 \(width), i32 \(elemTag))\n"
            curRaw = nextRaw
        }
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(curRaw) to %bk_set*\n"
        /// 新句柄起始 shares == 1；入账由求值出口按效果表统一做。
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
            refuse(
                node: "join", family: .concurrency,
                reason: "载荷 \(value.llvmType) 装不进三槽任务 ABI 的一个字（聚合载荷没有搬运通道）")
            return IRValue(llvmType: "i64", ssaName: "0")
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
            /// Bitwise family: LLVM integer instructions, 1:1 with the interpreter's int×int eval table. Shifts
            /// are arithmetic (ashr), matching Swift's `>>` on signed ints; `shl`/`shr` keep the operand type.
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

    /// Intrinsic print: value + newline. Aggregates print recursively with the interpreter's rendering
    /// (`[e1, e2]`, `some(payload)` / `none`). F64 goes through `bk_double_to_string` (shortest
    /// round-trip), and the malloc'd C string is freed right after printf consumes it.
    private func emitPrint(_ argument: IRExpr) -> IRValue {
        let type = irType(of: argument)
        let value = emitExpr(argument)
        emitValuePrint(value: value, type: type)
        /// 打印是消费点：临时值印完即还，变量 / 字段的份额不在账上 ⇒ 那一条不动作。
        releaseHeldTemporary(value)
        bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_newline)\n"
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// 表达式的静态类型；无值节点（`print`、写文件一类）取 `.i32` 垫底。
    /// 类型表只有一份，住在 `IRExpr.staticType`：本处再写一份必然与它漂。
    private func irType(of expr: IRExpr) -> IRType {
        expr.staticType ?? .i32
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
            /// 为 `%d` 收窄到 i32：`sext i64 -> i32` 是非法 cast，故走 `trunc` 截断。
            let narrow = builder.freshTemp()
            bodyIR += " \(narrow) = trunc i64 \(value.ssaName) to i32\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, i32 \(narrow))\n"
        case "double":
            let rendered = builder.freshTemp()
            bodyIR += " \(rendered) = call ptr @bk_double_to_string(double \(value.ssaName))\n"
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(rendered))\n"
            // N76：这处临时串由本运行时段分配（`bk_double_to_string` 走带头的分配器）
            // ⇒ 释放入口跟着换族。 注意  它是**当场消费掉**的临时值，故直接还，
            //  行不通  不进账本（账本记的是待决定归属的那些）。
            usesStringRefcount = true
            bodyIR += " call void @bk_str_release(ptr \(rendered))\n"
        case "i8*":
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(value.ssaName))\n"
        default:
            bodyIR += " call i32 (ptr, ...) @printf(ptr @fmt_int, \(value.llvmType) \(value.ssaName))\n"
        }
    }

    /// Print a value of any slice type (no newline): arrays iterate the runtime handle (len/get loop,
    /// induction via a stack slot, no phi), optionals branch on the tag, and literal pieces come from
    /// `emitStringConstant` (deduped module constants).
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
            /// Struct / object rendering (interpreter stringify parity): `Name{field: value, ...}` with fields
            /// ordered by name. The order is resolved here, not at run time — positions are static, so an ordered
            /// view can still read each field's original slot. Objects shift every index by one for the head word.
            guard let decl = moduleTypes.first(where: { $0.name == name }),
                let aggregate = type.nominalAggregateSpelling
            else {
                fatalError("IREmitter: printing unregistered nominal (IRLowerer guarantees)")
            }
            let open = emitStringConstant("\(name){")
            bodyIR += " call i32 (ptr, ...) @printf(ptr \(open.ssaName))\n"
            /// 字段槽一律问布局；四格头之后是第 0 个字段， 行不通  不能写死 1。
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
                        indices: [0, layout.fieldSlot(of: entry.offset)]
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
            bodyIR +=
                builder.fmtGEP(
                    name: tagPtr, aggregate: aggregate, base: value.ssaName,
                    indices: [0, layout.enumTagSlot])
                + "\n"
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
                        bodyIR +=
                            builder.fmtGEP(
                                name: fieldPtr, aggregate: aggregate, base: value.ssaName,
                                indices: [0, layout.enumPayloadSlot(of: slot)])
                            + "\n"
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

    /// 登记一个字符串常量（去重），返回它的全局名与字节长度。与 `emitStringConstant` 只差一点：
    /// 取串的 GEP 由谁发 —— 那个函数写进 `bodyIR`，而帧序要一条能排在任何块之前的取串指令，由调用方发。
    ///  行不通  常量登记与去重仍只有这一份实现。`named` 给定时用该名，且不占匿名序号。
    private func registerStringConstant(
        _ value: String, named: String? = nil
    ) -> (name: String, length: Int) {
        if let existing = stringConstants[value] { return existing }
        let name: String
        if let named {
            name = named
        } else {
            name = "@.str\(anonymousStringConstantCount)"
            anonymousStringConstantCount += 1
        }
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

    /// 这个名字是否与发射器自己生成的局部名同形。
    /// 生成名只有四族：`%t<数字>` · `%<mangled>_slot` 与 `_slot_<k>` · `%de6b.*` · `%arg<数字>_slot`。
    /// 源码标识符落进其中任何一族，生成的 IR 里就是两个同名局部值。
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

    /// 形参的 SSA 名，与 `params` 按位置一一对应。
    /// 只在必要时改名：名字落进发射器自有命名族，或与前面某个形参重名；其余原样，故不相撞的程序
    /// 逐字节不变。改名形如 `<原名>.p<序号>` —— `.` 不在语言标识符字符集里，源码名不可能先占。
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

    /// Closure value at the creation point: malloc the env, fill each field with a pointer to the captured
    /// variable's slot (reference capture), and build the `{ code, env }` fat pointer. The body define is
    /// buffered for module end; `emitClosureBody` swaps the per-function state out and back around it.
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

    /// A named top-level function used as a value: an env-ignoring adapter fat pointer. Indirect calls use
    /// the closure ABI `code(ptr env, args...)`, and a bare function's ABI lacks the env slot, so passing
    /// its code pointer directly would shift every argument. The adapter bridges the two.
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
        var argValues: [IRValue] = []
        for argument in arguments {
            let value = emitExpr(argument)
            argValues.append(value)
            argList.append("\(value.llvmType) \(value.ssaName)")
        }
        if let returnType = returnType {
            let retTemp = builder.freshTemp()
            bodyIR += " \(retTemp) = call \(returnType.llvmSpelling) \(code)(\(argList.joined(separator: ", ")))\n"
            releaseCallArguments(argValues)
            return IRValue(llvmType: returnType.llvmSpelling, ssaName: retTemp)
        }
        bodyIR += " call void \(code)(\(argList.joined(separator: ", ")))\n"
        releaseCallArguments(argValues)
        return IRValue(llvmType: "void", ssaName: "")
    }

    /// Buffer (deduplicated) the env-ignoring adapter for a named function:
    /// slot each formparam, reload, tail-call the original with plain ABI.
    private func emitAdapter(mangled: String) {
        guard !adapterNames.contains(mangled) else { return }
        adapterNames.insert(mangled)
        /// The adapter's signature comes from the original define, which lives in bodyIR — rather than parse
        /// param types back out of it, the adapter is generated lazily against the module function registry
        /// in `moduleFunctions`, filled during `emit(module:)`.
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

    // MARK: - 并发接线

    /// 让出点的产出档位：这一处让出要不要把结果交给后续代码。
    /// 抽成档位而不是两份发射函数：四个让出位置只差这一点，其余发射逐字共用；分成两份会让同一条
    /// 约定两处解释，而它（三槽装配、续跑块由入口 switch 跳入）本段只该有一处解释。
    private enum YieldProduce {
        /// 结果**丢弃** —— `S1`（`await f()` 独占一行）。 注意  丢弃的是**结果**，不是**等待**。
        case discard
        /// 结果**存进给定的帧槽** —— `S2` / `S3` / `S4` 都是这一档，只是槽的用途不同
        /// （分别是变量本身 · 判别式 · `try` 的操作数）。
        ///  行不通  必须是**帧槽**：续跑块由入口 `switch` 跳入，让出点所在块里的 SSA 值**不支配**它。
        case frameSlot(String)
    }

    /// 顶层语句根部的 `await` 让出点：S1 裸语句 / S2 绑定 / S3 判别式 / S4 try 位共用同一发射器。
    /// 让出后句柄存帧槽，续跑块由入口 switch 跳入（`%hand` 不支配它），取值一律走帧槽。
    /// 仅允许函数体顶层（blockDepth == 1）：嵌套让出点的外层值不支配续跑块。
    private func emitYieldPoint(awaited: IRExpr, type: IRType, produce: YieldProduce) {
        guard blockDepth == 1 else {
            fatalError(
                "IREmitter: a resumable `await` must sit at the top level of an async body"
                    + " (nested control flow has no resume entry yet)")
        }
        guard case .result(let okType) = type else {
            fatalError("IREmitter: await site type is not a Result (IRLowerer guarantees)")
        }
        //  重要  载荷宽度只在**真搬运**时才成为约束：`S1` 把结果丢弃 ⇒ 没有搬运通道要过，
        // 于是聚合载荷的 `await` 在那条路上是合法的。 行不通  不许把这个检查提到前面 ——
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
        // 让出 = **从栈返回**。 行不通  这里**不**跑 defer、**不**释放句柄：体还没结束。
        let returnSpelling = currentReturnType?.llvmSpelling ?? "void"
        bodyIR += " ret \(returnSpelling) undef\n"

        bodyIR += "de6b.resume.\(index):\n"
        let handleReloaded = builder.freshTemp()
        bodyIR += builder.fmtLoad(name: handleReloaded, type: "ptr", ptr: handleSlot) + "\n"
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        // 返回值**刻意丢弃**：与 `emitJoin` 同一条口径 —— 三槽已由运行时归一化，状态位不必再判。
        bodyIR += " call i32 @bk_task_await(ptr \(handleReloaded), ptr \(out))\n"
        //  重要  产出档位在这里分岔 —— 这是本段唯一的形态差异，其余发射**逐字共用**。
        switch produce {
        case .discard:
            /// `S1`（`await f()` 独占一行）：结果按语言语义丢弃 ⇒ 续跑块到此为止。
            ///  注意  仍保留上面那次 `bk_task_await`：丢弃的是结果，不是等待；省掉它会让「丢弃结果」顺带丢掉等待。
            break
        case .frameSlot(let slot):
            let filled = collectResult(from: out, type: type, okType: okType)
            bodyIR += builder.fmtStore(value: filled.ssaName, type: type.llvmSpelling, ptr: slot) + "\n"
        }
    }

    /// 三槽 → `Result` 聚合（与 `emitJoin` 的装配**同形**；三槽约定只有一处解释）。
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

    /// 一次异步调用在发射层的落点 = 一次派发：建盒、认父、起线程三件做完才返回，故调用方拿到句柄时
    /// 体已在自己推进。实参经堆上的缓冲交给体 —— 体跑在另一条线程，detach 后调用方的帧可能不在，
    /// 栈上实参会悬垂。那块缓冲就是体的持久帧（运行时分配且已清零，故续跑点 = 0 不必再 store）。
    private func emitTaskSpawn(
        callee: IRFunction, mangled: String, args: [IRValue], argEffects: [IRShareEffect]
    ) -> IRValue {
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
            // 容器形参的份额由 wrapper 在体**真跑完**时还回（配对点见该函数；让出时不还 ——
            // 体还在用它们）。借用实参要留一份，临时实参直接把这一份交过去。
            handTaskArgument(arg, type: callee.params[index].type, effect: argEffects[index])
        }
        /// `code` 按空指针传：体的入口是**每函数一个**的 wrapper，调用点不需要再指定一份。
        /// 末尾两个实参是 ok 载荷描述（`elemBytes` / `elemTag`）——
        ///  行不通  此处**刻意留 0**：本段接线的两个符号都不读它们（消费者是聚合 join）。
        let handle = builder.freshTemp()
        bodyIR +=
            " \(handle) = call ptr @bk_task_spawn(ptr @__task_body_\(mangled), ptr null, ptr \(envRaw), i32 0, i32 0)\n"
        // `Q-4` 乙段：把调度器绑定交给运行时。 重要  派发点是「这个任务属于哪个调度器」的
        // **唯一知情处** —— 设计里「派发点把调度器写进盒子」那句话的落点就在这一行。
        emitSchedulerBinding(handle: handle)
        return IRValue(llvmType: "ptr", ssaName: handle)
    }

    /// 每个异步函数一份的体 wrapper（`i32 (code, env, out)` 形态）：运行时要「一个 C 函数指针 + 一段
    /// 实参缓冲」，而被调用方的 IR 签名是它自己的形参表 —— wrapper 拆缓冲、把返回摊进三槽，按 IR 名去重。
    /// 两态报告靠帧头那个字：跑完后是否为 0，精确区分「跑到底」（0，三槽已写）与「已让出」（2）。
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
            /// 形参区自 **8** 起：帧头那 8 字节是续跑点。
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
        ///  行不通  帧**不在这里释放**：帧跨让出存活，只在体**真跑完**时才该交还，而「真跑完」
        /// 是下面那个分支才知道的事；何况份额已归运行时（由它分配、由它交还），
        /// 这里是第二条释放路径的话就是 double free。
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
        /// 三槽：槽 0 = tag · 槽 1 = ok 载荷 · 槽 2 = err 载荷，一律**擦除为 i64 宽度**；
        /// 这与 `_bkTaskRunBody` 读回三槽的方式是同一条约定。
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

    /// `await` / `wait` 的落点（`bk_task_join`）。可恢复体顶层的 `await` 走让出路径，不经过本函数；
    /// 到达这里的只剩拿不到帧的体 —— 无声明返回类型的异步体与闭包体 —— 本段对它们响亮拒绝：
    /// 静默按阻塞处理就是把「让出」的承诺打折而不出声。`wait` 一类的承诺本就是阻塞，不受影响。
    private func emitJoin(future: IRExpr, type: IRType, form: JoinForm) -> IRValue {
        if form == .awaits {
            fatalError(
                "IREmitter: a resumable `await` needs a frame — this body has none"
                    + " (an async body with no declared Result return, or a closure body)."
                    + " Nested and in-expression positions are refused earlier, in lowering")
        }
        guard case .result(let okType) = type else {
            fatalError("IREmitter: join site type is not a Result (IRLowerer guarantees)")
        }
        /// 载荷宽度：三槽把载荷**擦除为 i64** ⇒ 只有单字载荷能原样往返。聚合载荷
        /// （元组 / optional / 嵌套 Result 的值形态）没有搬运通道，故在这里响亮拒绝，
        /// 而不是搬一个错的值回来。
        guard isSingleWordPayload(okType) else {
            fatalError(
                "IREmitter: task ok payload '\(okType.llvmSpelling)' is an aggregate — the three-slot task ABI carries one word")
        }
        let handle = emitExpr(future)
        /// 已在结算值上 `wait`（`wait joinAll(...)` 这类）：没有句柄可等，原样透传。
        if handle.llvmType != "ptr" { return handle }
        usesTaskRuntime = true
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        bodyIR += " call i32 @bk_task_join(ptr \(handle.ssaName), ptr \(out))\n"
        /// 三槽 → `Result` 的装配与让出路径**共用一份**实现：这条约定只该有一处解释。
        return collectResult(from: out, type: type, okType: okType)
    }

    /// `joinWithin(future, ms)`：与 `bk_task_join` 共用三槽装配与 `Result` 收尾，
    /// 只多传一个时限；超时归约为取消由运行时保证。
    private func emitJoinWithin(
        handle: IRValue, timeout: IRValue, type: IRType, okType: IRType
    ) -> IRValue {
        usesTaskJoinWithin = true
        guard handle.llvmType == "ptr" else {
            fatalError("IREmitter: joinWithin operand is not a task handle (IRLowerer guarantees)")
        }
        guard isSingleWordPayload(okType) else {
            fatalError(
                "IREmitter: task ok payload '\(okType.llvmSpelling)' is an aggregate — the three-slot task ABI carries one word")
        }
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        bodyIR += " call i32 @bk_task_join_within(ptr \(handle.ssaName), i32 \(timeout.ssaName), ptr \(out))\n"
        return collectResult(from: out, type: type, okType: okType)
    }

    /// `joinAll`：字面量形态把成员句柄排进连续区，变量形态把数组盒交给运行时逐槽取。
    private func emitJoinAll(arguments: [IRExpr], returnType: IRType?) -> IRValue {
        guard let type = returnType, case .result(let okType) = type, case .array = okType else {
            fatalError(
                "IREmitter: joinAll needs a Result<Array<...>> return type (IRLowerer guarantees)")
        }
        guard arguments.count == 1 else {
            fatalError("IREmitter: joinAll takes exactly one array (IRLowerer guarantees)")
        }
        let out = builder.freshTemp()
        bodyIR += " \(out) = alloca { i64, i64, i64 }, align 8\n"
        if case .arrayLiteral(let elements, _) = arguments[0], !elements.isEmpty {
            usesTaskJoinAll = true
            let handles = builder.freshTemp()
            bodyIR += " \(handles) = alloca [\(elements.count) x ptr], align 8\n"
            for (index, element) in elements.enumerated() {
                let value = emitExpr(element)
                guard value.llvmType == "ptr" else {
                    fatalError("IREmitter: joinAll member is not a task handle (IRLowerer guarantees)")
                }
                let slot = builder.freshTemp()
                bodyIR += " \(slot) = getelementptr inbounds [\(elements.count) x ptr], ptr \(handles), i64 0, i64 \(index)\n"
                bodyIR += " store ptr \(value.ssaName), ptr \(slot)\n"
            }
            bodyIR += " call i32 @bk_task_join_all(ptr \(handles), i32 \(elements.count), ptr \(out))\n"
        } else {
            usesTaskJoinAllBox = true
            let box = emitExpr(arguments[0])
            bodyIR += " call i32 @bk_task_join_all_box(ptr \(box.ssaName), ptr \(out))\n"
        }
        return collectResult(from: out, type: type, okType: okType)
    }

    /// 需要**份额**的句柄类型（容器）：它们的生命周期由运行时的份额计数管，
    /// 跨线程借用必须自己留一份。字符串是裸 C 串、标量是值，都不在此列。
    private func isOwningContainer(_ type: IRType) -> Bool {
        switch type.shareClass {
        case .retained(.array), .retained(.dict), .retained(.set): return true
        case .valueBox, .inert, .aggregate, .retained: return false
        }
    }

    /// 派发点的实参处置。借用的留一份自己的份额（`detach` 之后调用方的帧可能已不在）；临时值
    /// 把手上那一份直接交过去，不再 retain，也不在调用方归还 —— 两次动作会多出一份谁都不还的账。
    private func handTaskArgument(_ value: IRValue, type: IRType, effect: IRShareEffect) {
        guard isOwningContainer(type) else { return }
        usesTaskArgRelease = true
        switch effect {
        case .fresh:
            claimHeldBox(value)
        case .borrowed, .inert:
            let raw = builder.freshTemp()
            bodyIR += " \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr\n"
            bodyIR += " call void @bk_handle_retain(ptr \(raw))\n"
        }
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

    /// 把一个具名值加宽成一个字，返回指令文本。与 `widenToWord` 的分工：那个往调用方的 `bodyIR` 里写，
    /// 这个只返回文本 —— 任务体 wrapper 要写进自己的缓冲，不能碰调用方的 `bodyIR`。
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

    /// Swap in a clean per-function state, emit the closure body into a private buffer, and record the
    /// buffered `define` for module-end assembly. Captures enter as slot pointers (reference capture:
    /// loads and stores go through the same slot the outer variable uses).
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
        let savedCleanupScopeBase = cleanupScopeBase
        let savedReturnType = currentReturnType
        let savedIsMain = currentIsMain
        let savedBodyIR = bodyIR
        let savedBuilder = builder
        let savedCaptureSlots = captureSlots
        let savedCapturedNames = capturedNamesInFunction
        /// A closure is its own release scope: its body block is frame 0 of a fresh stack, exactly like a
        /// function body. Otherwise it would inherit the enclosing frames, and a `return` inside it (which
        /// releases down to frame 0) would drop the enclosing function's top-level handles — over-release.
        let savedPendingCleanup = pendingCleanup
        /// 闭包体是**自己的函数**，而它不是任务 ⇒ 没有帧可依。 行不通  不继承外层体的帧式：
        /// 外层的帧槽是外层的，闭包体内的局部槽若发成「帧槽」，取的会是**外层那一块**（或者根本没有）。
        /// 深度的重置同理 —— 闭包的函数体那一层也应该是 1。
        let savedFrameMode = frameMode
        let savedBlockDepth = blockDepth

        scopes = [[:]]
        slotCounters = [:]
        frameMode = .none
        blockDepth = 0
        terminated = false
        controlStack = []
        breakMergeLabels = []
        /// 闭包体是它自己的函数：清理栈换成空的，`return` 只洗到 0，不碰外层函数的清理。
        cleanupScopeBase = 0
        currentReturnType = returnType
        currentIsMain = false
        builder = IRBuilder()
        bodyIR = ""
        captureSlots = [:]
        pendingCleanup = []
        /// 闭包体重建 `IRBuilder` ⇒ SSA 名从 `%t1` 重新编号，账本必须换新的，否则同名条目指向外层的值。
        heldBoxesStack.append(heldBoxes)
        heldBoxes = [:]
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
            // 根帧的清理已在块尾执行完（`return` 也在自己的 ret 前发过一份副本）。
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
        cleanupScopeBase = savedCleanupScopeBase
        currentReturnType = savedReturnType
        currentIsMain = savedIsMain
        bodyIR = savedBodyIR
        builder = savedBuilder
        captureSlots = savedCaptureSlots
        pendingCleanup = savedPendingCleanup
        heldBoxes = heldBoxesStack.popLast() ?? [:]
        capturedNamesInFunction = savedCapturedNames
        frameMode = savedFrameMode
        blockDepth = savedBlockDepth
    }

    // MARK: - G9 string deepening

    /// `s.upper()` / `s.lower()` —— 契约 §2.9 第 36 条：Unicode 感知，接收者不变。
    /// 逐字节 `toupper`/`tolower` 只在 ASCII 上对（`"café".upper()` 得 `CAFé`），且那个 memcpy 落在
    /// 调用点的变长 alloca 上，与 substring 同一个栈炸弹形状 ⇒ 语义与分配一起交给运行时段。
    private func emitStringCase(isUpper: Bool, source: String) -> IRValue {
        usesStringShims = true
        let symbol = isUpper ? "bk_string_upper" : "bk_string_lower"
        let converted = builder.freshTemp()
        bodyIR += " \(converted) = call ptr @\(symbol)(ptr \(source))\n"
        return IRValue(llvmType: "i8*", ssaName: converted)
    }

    /// `s.split(delim)` — a real `Array<String>`, delegated to the runtime, which mirrors `IRExecutor`'s
    /// `.split` branch: an empty delimiter yields one element per grapheme; otherwise the delimiter is
    /// matched as a substring and empty subsequences are omitted. `strtok` cannot express either rule.
    private func emitStringSplit(source: String, delim: String, type: IRType) -> IRValue {
        let raw = builder.freshTemp()
        bodyIR += " \(raw) = call ptr @bk_string_split(ptr \(source), ptr \(delim))\n"
        let handle = builder.freshTemp()
        bodyIR += " \(handle) = bitcast ptr \(raw) to %bk_array*\n"
        return IRValue(llvmType: "%bk_array*", ssaName: handle)
    }

    /// `arr.join(sep)`：字符串数组的元素用 sep 逐个 strcat 进一块栈缓冲
    /// （元素是裸 C 指针）。
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
        //  注意  结果会**离开本帧**（`let s = xs.join(",")` 之后 s 进变量槽 / 进箱 / 被返回）
        // ⇒ 交出前必须复制到堆，理由见 `heapCopyOfStackString`。
        return heapCopyOfStackString(buf)
    }

    /// 把栈上拼出来的串交出去之前复制到堆（返回堆指针）：插值与 `join` 都在本帧栈缓冲上拼串，
    /// 而结果会离开本帧（如存进 Token 的 `text` 字段）⇒ 不复制就留下悬垂的栈地址。
    /// 复制走 `bk_str_dup`（带计数头）。入账不在本函数：求值出口按效果表统一记。
    private func heapCopyOfStackString(_ buf: String) -> IRValue {
        let dup = builder.freshTemp()
        bodyIR += " \(dup) = call ptr @bk_str_dup(ptr \(buf))\n"
        return IRValue(llvmType: "i8*", ssaName: dup)
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
        return heapCopyOfStackString(buf)
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

    /// Value display into a string: the string-building mirror of `emitValuePrint`, covering the
    /// scalar/container set the corpus interpolates (i32/F64/bool/string/array); optionals, enums and
    /// tuples render through the same buffer-concat shape as their print paths.
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
            refuse(
                node: "interpString", family: .strings,
                reason: "\(type.llvmSpelling) 不在字符串化网格里（标量 / String / Char / 数组 / Optional 之外没有渲染通道）")
            return emitStringConstant("")
        }
    }
}
