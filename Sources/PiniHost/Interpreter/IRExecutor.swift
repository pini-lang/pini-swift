import Foundation
import PiniSyntax
import PiniSemantics
import PiniIR

/// `break` / `continue` / `return` 越过语句层的方式：IR 携带展开深度，不携带标签。
/// 降级器把标签映射成深度，无法解析的标签降为 `panicStmt`，深度是唯一的通用表示。
/// AST 通道的 `ControlSignal` 讲标签，复用它就得在每个循环内部重做一次映射。
enum IRControlSignal: Error {
    /// 带着该值离开所在函数；`nil` 表示 void 返回。
    case returnSignal(Value?)
    /// 展开 `depth` 层外层循环；1 表示最内层。
    case breakSignal(depth: Int)
    /// 回到第 `depth` 层外层循环的头部；1 表示最内层。
    case continueSignal(depth: Int)
}

/// 函数值无法自带的那半个可调用体：`Value.function` 只存 AST `Block?`，不存 `[IRStmt]`。
/// 因此函数体存在执行器的表里，值本身保留身份、闭包环境和名字。
/// 这里没有环境字段：环境在创建时固定、属于值，两个闭包不得共用一个。
private struct IRCallableBody {
    /// 参数名按声明顺序排列，即实参绑定顺序。
    let paramNames: [String]
    let body: IRBlock
    /// 声明了命名元组返回值时的分量标签；无标签时为空，
    /// 返回点规则正是据此判断。
    let returnLabels: [String?]
    /// `=>` 派发：函数体在 worker 线程运行，调用方拿到 pending Future 而非结果值。
    /// 闭包体在本通道恒为 false：降级后的闭包节点不带 async 标记，也没有用例走到这里。
    /// 这是通道边界，不是遗漏。
    let isAsync: Bool

    init(paramNames: [String], body: IRBlock, returnLabels: [String?], isAsync: Bool = false) {
        self.paramNames = paramNames
        self.body = body
        self.returnLabels = returnLabels
        self.isAsync = isAsync
    }
}

/// 一次函数体运行的结果：两种结局，没有第三种。
/// 要么跑到末尾，要么停在 join 处把任务让出去。
/// 调用方若分不清二者，就无法离开 worker 线程——这正是 `await` 与 `wait` 的区别。
private enum IRBodyStep {
    case finished(Value)
    case givenUp(IRYieldFrame)
}

/// 让出任务时的现场，够用来接着跑。
/// 挂起从运行函数体的 Swift 调用返回，局部变量与线程局部量都随之离去。
/// 它带着调用深度、调用栈、defer 栈（否则恢复时不跑 `defer`）以及精确的环境。
private struct IRYieldFrame {
    /// 函数体正跑到一半的那个可调用体。
    let callable: IRCallableBody
    /// 函数体停下的那条语句，按该函数体语句表计数。
    let index: Int
    /// 用 await 得到的结果补完 `index` 处的语句，然后继续。
    let finish: (Value) throws -> Value?
    /// 函数体为之让出任务的那个 future。
    let awaited: FutureValue
    let env: Environment
    /// 函数体最终结束时交还给调用方的环境。
    /// 携带而非重算：它属于这次运行，恢复后的 Swift 调用方是续体而非进入帧。
    /// 弄错时很安静：只有该线程上后续语句会读到陈旧环境。
    let previousEnv: Environment
    /// 挂起那一刻的 `lastValue` 累加值，原因见
    /// `driveStatements`：它属于「函数体跑到哪了」的一部分。
    let lastValue: Value
    let callDepth: Int
    let callStackNames: [String]
    let deferStack: [[IRBlock]]
    let currentFuture: FutureValue?
}

/// join 可以让出任务的语句位置，即驱动器这一侧的 yield 包络。
/// 降级器拒绝其他一切位置；这里若出现未规划的位置，join 会退化成阻塞等待。
/// 因此是带 `switch`、无 `default`：裸语句、`var` 初始化、`match` 被匹配值、try-else 操作数。
private enum IRYieldPlan {
    /// join 独占整个表达式语句，其值即语句的值。
    case expressionStatement(operand: IRExpr)
    /// join 是 `var` 初始化式。
    case varInitializer(operand: IRExpr, name: String, type: IRType, mutable: Bool)
    /// join 是 `match` 的被匹配值。
    case matchScrutinee(operand: IRExpr, cases: [IRMatchCase])
    /// join 是 try-else 的操作数。
    case tryOperand(operand: IRExpr, errorVar: String, handler: IRBlock, okTarget: String?)

    /// 取值为 future 的表达式：同步求值，早于任何让出任务的判断。
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

/// 直接运行降级后的 `IRModule`：AST 解释器与 IR → LLVM 之外的第三个活通道。
/// 每个节点都被派发且无 `default:`；渲染与运算符沿用解释器的实现（`stringifyValue`）。
/// 跨线程可达（异步体与就绪循环都捕获本实例）：模块表装载后只读，运行时状态在 ThreadLocal 与 `instanceLock` 内。
public final class IRExecutor: DebugHookHost, @unchecked Sendable {

    // MARK: - 宿主接口

    /// 行输出通道。与 `Interpreter.outputSink` 对齐，调用方可以让两个引擎的 stdout
    /// 走同一条管道再逐行比对。
    public var outputSink: (String) -> Void = { line in print(line) }

    /// 调试暂停钩子——`DebugHookHost` 的另一半，与解释器暴露的是同一类型。
    /// 在 `executeStatements` 每条语句前查询，按 `positions` 记录的行走，两个引擎因此一致。
    /// 没有行号的暂停报 `noLocation`，而断点按行匹配，所以钩子需要位置信息。
    public var debugHook: ((DebugContext) throws -> DebugAction)? = nil

    // MARK: - 模块状态

    /// 按名字索引的模块级函数。IR 没有模块级闭包：`main` 及其同类是唯一的可调用体。
    /// 闭包值在 `callableBodies` 里；降级器把 trait 默认体物化到这里，而不是物化进类型。
    private var functions: [String: IRFunction] = [:]

    /// 类型方法，按**降级后**的名字索引（`方法__类型`），从每个 `IRTypeDecl` 里摊平。
    /// 对它的调用是普通 `.call`——接收者作为第一个实参——因此先查模块函数表。
    /// 键就是降级名，绝不重新推导：泛型类型的方法挂在 `盒_I32` 下，再 mangle 一次就会漂移。
    private var methods: [String: IRFunction] = [:]

    private var types: [String: IRTypeDecl] = [:]
    /// 声明了析构的类型名（未经 mangle 的名字，与 `types` 同键）。
    /// 构造时据此决定要不要装归零投递口：绝大多数对象没有析构，不该为它们在释放路径上多留一条记录。
    private var destructorTypes: Set<String> = []
    /// 归零投递的去处。跨线程投递、本线程消费；它是规范里那条「延迟释放队列」的落点。
    private let deinitQueue = DeinitQueue()
    /// 本线程是否已在执行析构：析构体会执行语句，语句边界又会来问一次，不设闸就会在析构里递归解析构。
    private let drainingStorage = ThreadLocal<Bool>()
    /// 默认实例的**记忆表**（类型名 → 物化好的实例）。
    /// 首次取用物化并记住，之后直接返回缓存值；与发射层「槽位 + 两级锁」同语义。
    /// 异步体的取用可能落在工作者线程，故用可重入锁包住「查—造—存」整段，保证恰一次。
    private let instanceLock = NSRecursiveLock()
    private var givenInstances: [String: Value] = [:]
    private var enums: [String: IREnumDecl] = [:]

    /// 本模块声明的外来被调者，来自 `[名称|foreign]` 块，按被调者名字索引。
    /// 这道门很关键：否则没声明 `malloc` 的程序也能在这里调用它，而 AST 通道拒绝那样做。
    /// 用 map 而非 set：垫片查不到时退回原始 C 绑定，而 thunk 需要声明的签名。
    private var foreignDecls: [String: IRForeignFunction] = [:]

    /// 外部数据符号的声明：类型与只读。地址在装载期解析一次，与函数同一时机。
    private var foreignDataDecls: [String: (type: IRType, isReadonly: Bool)] = [:]
    /// 已解析的符号地址。与声明分开：装载期只填这张表，求值只读它，两者生命周期不同。
    private var foreignDataAddresses: [String: RawPointerValue] = [:]

    /// 原始 C 绑定的库句柄，按库名缓存。
    /// 每个引擎各持一份，不是进程级：共享句柄表会让「何时可以安全关闭」无人负责。
    /// 两个引擎、两份缓存、一套解析流程。
    private let ffiLoader = FFILoader()

    /// 包的 `[ffi]` 表，供 `search_paths` 使用。
    private let ffiConfig: FFIConfig

    /// 运行期构造的函数值的函数体，按值身份索引。
    /// 不用名字：每个闭包字面量都叫 `<anon>`，按名字查会让一个闭包跑到另一个的体。
    /// 与 `Value.==` 用的是同一套身份；属于单次运行的状态，由 `prepare` 清空。
    private var callableBodies: [ObjectIdentifier: IRCallableBody] = [:]

    private let globalEnv: Environment

    /// async 函数体的派发去处：阻塞后端，即生产语义，不是占位实现。
    /// 注入的值优先于语言侧默认值（`resolveSchedulerFromLanguage`），并完全跳过解析。
    /// 这个接缝让判据能换上一个拒绝让出的后端，从而验证「降级而不失败」。
    private let injectedScheduler: Scheduler?

    /// 派发点实际用的后端。**只在 `prepare` 里被改写一次** —— 那之后才可能有工作线程
    /// ⇒ 不需要锁。初值取注入值或主后端，故任何路径上它都不是空的。
    private var scheduler: Scheduler

    // MARK: - 每线程执行状态

    /// 这四个描述的是正在执行的线程，不是引擎。
    /// `=>` 派发让 worker 与 join 的调用方同时存活，两者都碰这份状态。
    /// 用 `ThreadLocal` 承载：裸字段会被两个线程并发读写，崩成 SIGTRAP/SIGSEGV。
    private let currentEnvStorage = ThreadLocal<Environment>()
    private let callDepthStorage = ThreadLocal<Int>()
    private let callStackStorage = ThreadLocal<[String]>()
    private let deferStackStorage = ThreadLocal<[[IRBlock]]>()

    /// 本线程运行所在的任务（若有）。
    /// 生成新任务时在这里链接，使派发树与取消树是同一棵树，与 AST 侧一致。
    /// 线程局部：worker 不能领养调用方的任务，否则父任务返回会取消错误的一组。
    private let currentFutureStorage = ThreadLocal<FutureValue>()
    private var currentFuture: FutureValue? {
        get { currentFutureStorage.value }
        set { currentFutureStorage.value = newValue }
    }

    /// 本线程当前执行的环境。
    /// 未进入任何环境的线程读到全局环境；worker 的第一件事是进入自己的调用环境。
    private var currentEnv: Environment {
        get { currentEnvStorage.value ?? globalEnv }
        set { currentEnvStorage.value = newValue }
    }

    /// 宿主当前进入了多少层函数体。
    /// 只用于报告，不用于决策：能否再进一层由运行线程的剩余栈决定。
    /// 拿计数当上限会先被重负载压爆栈，所以深度只留作诊断。
    private var callDepth: Int {
        get { callDepthStorage.value ?? 0 }
        set { callDepthStorage.value = newValue }
    }

    /// 当前已进入的函数名，最内层在末尾——调试器读的调用栈。
    /// 压栈出栈的位置与 `callDepth` 完全一致，因此任何深度都不会指向空洞。
    private var callStackNames: [String] {
        get { callStackStorage.value ?? [] }
        set { callStackStorage.value = newValue }
    }

    /// 打开的 defer 作用域，最内层在末尾；一个作用域按注册顺序存它的 `defer` 语句。
    /// 每个 `defer` 持有它包住的语句组，弹出时组按逆序、组内按源码顺序执行。
    /// 若拍平成一个逆序列表，体被降成多个节点的 defer 会顺序颠倒。
    private var deferStack: [[IRBlock]] {
        get { deferStackStorage.value ?? [] }
        set { deferStackStorage.value = newValue }
    }

    /// 无前缀相对 IO 路径的解析基准目录，与 `Interpreter.programBase` 对齐。
    /// 缺了它两个通道会悄悄分歧：读到 CWD 下的副本而不是报错。
    /// 可选，使不碰 IO 的执行器和裸测试宿主行为不受影响。
    private let programBase: String?

    /// 命令行参数（脚本路径之后的裸参数），与解释器的同名属性同义 ——
    /// `argv()` 内建的唯一来源，镜像而不另造。
    public var processArguments: [String] = []

    public convenience init(programBase: String? = nil, ffiConfig: FFIConfig = .default) {
        self.init(programBase: programBase, ffiConfig: ffiConfig, scheduler: nil)
    }

    /// 指定后端的引擎；传 `nil` 则用语言自身的默认后端。
    /// 生产传 `nil`；显式后端覆盖语言的选择，例如一个对 `yieldTask()` 答 `0` 的后端。
    /// 代码不对二者做分支：后端给答案，引擎照办。
    init(programBase: String?, ffiConfig: FFIConfig, scheduler: Scheduler?) {
        self.globalEnv = Environment()
        self.programBase = programBase
        self.ffiConfig = ffiConfig
        self.injectedScheduler = scheduler
        self.scheduler = scheduler ?? GCDScheduler.shared
        // `currentEnv` 故意不做初值：它的每线程盒子在进入前答 `globalEnv`。
        // 初值等于用更绕的方式写同一个值，而 init 期经计算属性写入会读到尚未建好的 `self`。
    }

    // MARK: - 入口

    /// 派发点当前后端的**能力自述**（只读，供诊断与判据），是语言侧接线 `resolveSchedulerFromLanguage` 的读侧。
    /// 降级后的程序结果不变，故光看输出区分不出「声明被读到了」与「引擎根本没理那句声明」。
    /// 没有本属性，「派发点用语言侧那个调度器」这句话就没有可观测面。
    var dispatchBackEndCapabilities: ConcurrencyCapabilities { scheduler.capabilities }

    public func prepare(module: IRModule) throws {
        // 结构不变量先过一遍：解释器与发射器同样按槽名、字段名、用例名取用，破了不该等运行时撞。
        try IRValidator.check(module)
        callableBodies.removeAll()
        for function in module.functions { functions[function.name] = function }
        for decl in module.types {
            types[decl.name] = decl
            for method in decl.methods { methods[method.name] = method }
        }
        destructorTypes = Set(
            module.types
                .filter { decl in
                    decl.methods.contains { $0.name == IRExecutor.destructorKey(decl.name) }
                }
                .map(\.name))
        deinitQueue.removeAll()
        for decl in module.enums { enums[decl.name] = decl }
        // 一个名字对应一个声明。同名声明分散在两个块里会产生歧义，
        // 语义层已拒绝这类输入；万一漏到这里，取最后一个，与函数表的规则一致。
        foreignDecls = [:]
        foreignDataDecls = [:]
        for block in module.foreigns {
            for function in block.funcs {
                foreignDecls[function.name] = function
            }
            for entry in block.data {
                foreignDataDecls[entry.name] = (type: entry.type, isReadonly: entry.isReadonly)
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

    /// 注册时就把声明的外来符号全部解析：先 libc 垫片表，再按 `[ffi].libs` 与进程镜像做原始查找。
    /// 在注册期失败胜过在首次调用点失败；`FFILoader` 会缓存句柄，调用点不必重复这步。
    private func resolveForeignsEagerly() throws {
        // `[ffi].libs` 在这里一次加载：块名不再是库键，库从清单来。
        try ffiLoader.preload(
            libraries: ffiConfig.libs, searchPaths: ffiConfig.searchPaths,
            location: IRExecutor.noLocation)
        for (name, foreign) in foreignDecls
        where RuntimeOps.libcShim(named: name, params: foreign.params) == nil {
            do {
                _ = try ffiLoader.resolve(symbol: name, location: IRExecutor.noLocation)
            } catch let error as RuntimeError {
                // 句柄符号只活在运行时段里，`pini` 进程解析不到是**预期**而非配置错。
                // 让它过：真被调用时，调用点报 E5-020（换通道），比这里报「库里没有这个符号」准确。
                let mentionsHandle =
                    foreign.params.contains(.stringHandle)
                    || foreign.returnType == .stringHandle
                guard case .symbolNotFound = error, mentionsHandle else { throw error }
            }
        }
        // 数据符号没有 shim 表可让位：声明了就必须解析得到，否则读到的地址无处可来。
        foreignDataAddresses = [:]
        for (name, entry) in foreignDataDecls {
            let symbol = try ffiLoader.resolve(symbol: name, location: IRExecutor.noLocation)
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

    /// 按名字调用一个模块级函数。
    /// `run(module:)` 只跑到 `main`；测试运行要跑到每个 `|test` 函数，因此需要按名入口。
    /// 与普通调用共用 `invoke` 与实参协议，测试体因此面对同一套运行期；必须先跑 `prepare`。
    public func callFunction(named name: String, args: [Value]) throws -> Value {
        guard let function = functions[name] else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: no module-level function named \(name) to call",
                location: IRExecutor.noLocation
            )
        }
        return try call(function, args: args)
    }

    // MARK: - 诊断

    /// 本引擎所有诊断使用的占位位置。
    /// 文件名用 `<ir>` 而非 `""`，这样诊断不会被误认为挂了真实但为空的文件。
    static let noLocation = SourceLocation(line: 0, column: 0, fileName: "<ir>")

    // MARK: - 表达式

    private func evaluate(_ expr: IRExpr) throws -> Value {
        switch expr {

        // 所有整数宽度在运行期都塌缩成一个 `int`，与解释器的建模一致：u8/i8/u64 只是 ABI 宽度。
        // 因此 `intConst` 忽略它携带的类型。

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

        case .shortCircuit(let op, let lhs, let rhs, _):
            // 左值定下结果就不再求值右侧：这是短路，右操作数的副作用与陷阱随之不发生。
            guard case .bool(let decided) = try evaluate(lhs) else {
                throw RuntimeError.invalidOperation(
                    reason: "logical '\(op)' needs a Bool left operand", location: IRExecutor.noLocation)
            }
            switch op {
            case .and where !decided: return .bool(false)
            case .or where decided: return .bool(true)
            case .and, .or: break
            }
            guard case .bool(let value) = try evaluate(rhs) else {
                throw RuntimeError.invalidOperation(
                    reason: "logical '\(op)' needs a Bool right operand", location: IRExecutor.noLocation)
            }
            return .bool(value)

        case .binary(let op, let lhs, let rhs, _):
            let left = try evaluate(lhs)
            let right = try evaluate(rhs)
            // min/max 在 IR 里是运算符，在解释器通道上却是内建调用，
            // 没有可映射的运算符，因此直接调共享内建而不报错。
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

        case .unary(let op, let operand, let type):
            // 显式转换：解释器把整数建模为单一 `Int`，窄化按目标宽度截断、加宽恒等。
            if case .cast = op {
                return IRExecutor.castValue(try evaluate(operand), to: type)
            }
            // 与上面的 min/max 同理：abs 在 IR 里是一元运算符，
            // 在解释器通道上是内建调用。
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
            // 先解析被调者再求值实参，因此名字不认识时不会跑任何实参。
            // 三种被调者共用一个节点形状：模块级函数、mangle 成 `方法__类型` 的类型方法、内建。
            // 函数与方法在这里执行；内建来自共享的 `RuntimeOps` 表，不依赖活的解释器。
            if let target = functions[name] ?? methods[name] {
                return try call(target, args: try arguments.map { try evaluate($0) })
            }
            // 在 `[名称|foreign]` 块里声明的被调者分两级解析：先 libc 垫片表（与 AST 通道共用），
            // 否则作为原始 C 绑定在 `[ffi].libs` 与进程镜像里查找，再包进按签名生成的 thunk。
            // 块名只是标签。
            if let foreign = foreignDecls[name] {
                // 变参在解释器上没有实现路径：转发靠把地址位转成固定槽位，
                // 而 Apple arm64 把变参放在栈上，位转调用读到的是垃圾。拒绝要早于求值实参。
                if foreign.isVariadic {
                    throw RuntimeError.variadicCallUnsupported(
                        name: name, location: IRExecutor.noLocation)
                }
                // 句柄的符号只活在运行时段里，`pini` 进程装载不到它 —— 与变参同规，
                // 拒绝早于求值实参：要么换通道，要么把句柄留在 C 侧。
                if foreign.params.contains(.stringHandle)
                    || foreign.returnType == .stringHandle
                {
                    throw RuntimeError.stringHandleCallUnsupported(
                        name: name, location: IRExecutor.noLocation)
                }
                let args = try arguments.map { try evaluate($0) }
                if let shim = RuntimeOps.libcShim(named: name, params: foreign.params) {
                    return try shim(args)
                }
                let symbol = try ffiLoader.resolve(symbol: name, location: IRExecutor.noLocation)
                let thunk = try ForeignThunk.make(
                    symbol: symbol, name: name,
                    params: foreign.params,
                    returnType: foreign.returnType,
                    location: IRExecutor.noLocation,
                    invokeCallback: { [unowned self] function, values in
                        try self.callFunctionValue(function, args: values)
                    }
                )
                return try thunk(args)
            }
            // sin / cos 以 `llvm.sin.f64` / `llvm.cos.f64` 形式到达，tan 是两者的除法。
            // 它们由共享三角函数内建作答，不会被当成缺失的模块级函数。
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
            // 取回：`*U8 → String`。与 LLVM 的 `bk_str_from_cstr` 同一条语义，实现留在 `RuntimeOps`。
            if name == "fromCString" {
                let args = try arguments.map { try evaluate($0) }
                guard args.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: fromCString expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                return try RuntimeOps.stringFromCString(args[0])
            }
            // 句柄构造只由降载层在句柄形参位产出；能走到这里说明外层调用没被识别成外部函数。
            // 仍然按「句柄只有运行时段能给」报， 行不通  退回「未知函数」。
            if name == IRLowerer.stringHandleMakeName {
                throw RuntimeError.stringHandleCallUnsupported(
                    name: "StringHandle", location: IRExecutor.noLocation)
            }

            // 字符内建，由 AST 通道调用的同一份实现作答，
            // 一处定义、两个引擎。
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

            // 普通调用能携带的并发内建，从降级器白名单读取的同一张表作答。
            // `sleep` 阻塞本线程、不让出：这就是它在 IR 侧的全部语义。
            // 取消检查点在这里是空操作（没有任务句柄），所以共享规则把它作为参数。
            if let concurrency = RuntimeOps.concurrencyBuiltins[name] {
                let args = try arguments.map { try evaluate($0) }
                return try concurrency(args)
            }

            // 返回 Future 的并发内建：在这里匹配而不进共享表，因为它们需要任务句柄。
            // 降级器出于同样原因匹配同样的名字，两侧要对着读。
            // 等待、聚合与「泄漏失败翻转」在 `RuntimeOps` 里：两个引擎共用一份定义。
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
                // 这是内建而非关键字点：`joinWithin` 没有 `await` 形式，
                // 因此它构造出来就是占用式等待。
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
            // 数值构造器，与 AST 遍历用的规则同源（`RuntimeOps.builtinF64`），
            // 一处定义、两个引擎，和上面的字符内建一样。
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
            // Array 的成员面（`append` / `last` / `pop`）：AST 遍历执行的同一套规则，一处定义供两个引擎。
            // 接收者作为第一个实参传入。
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
            // 建目录：幂等、中间层一并创建；失败即抛 —— 与运行时段 `bk_ensure_dir` 的陷阱姿态同源，
            // 两条通道因此对同一输入要么都成功、要么都报错。无值，返回空元组。
            if name == "ensureDir" {
                guard arguments.count == 1 else {
                    throw RuntimeError.invalidOperation(
                        reason: "IR executor: ensureDir expects exactly one argument",
                        location: IRExecutor.noLocation
                    )
                }
                let rawPath = try requireString(try evaluate(arguments[0]), for: name)
                let path = RuntimeOps.resolveIOPath(rawPath, programBase: programBase)
                do {
                    try FileManager.default.createDirectory(
                        atPath: path, withIntermediateDirectories: true)
                } catch {
                    throw RuntimeError.invalidOperation(
                        reason: "IO 错误: 无法创建目录 \(path): \(error.localizedDescription)",
                        location: IRExecutor.noLocation
                    )
                }
                return .tuple(labels: [], elements: [])
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
            // 与解释器的单参数 `print` 管道一致：
            // 先字符串化，再把整行一次性交给 sink。
            outputSink(RuntimeOps.stringifyValue(try evaluate(argument)))
            return .null

        // MARK: 集合

        case .arrayLiteral(let elements, _):
            // 保持源码顺序，生成一个新数组。这里不做 `copyIfStruct`：
            // 解释器在绑定处（`varDecl`、成员赋值）施加它，而不是在构造字面量时。
            return .array(try elements.map { try evaluate($0) })

        case .dictLiteral(let entries, _):
            // 按书写顺序保留条目，`print(dict)` 的格式依赖这个顺序。
            return .dictionary(
                try entries.map { entry in
                    (try evaluate(entry.key), try evaluate(entry.value))
                })

        case .setLiteral(let elements, _):
            // 插入序，首次出现者胜，按值比较——与解释器的 `setLiteral` 逐字一致，不做「改进」，
            // 因为 `{2, 3, 3, 5}` 打印出来的顺序是可观察结果。
            var unique: [Value] = []
            for element in elements {
                let value = try evaluate(element)
                if !unique.contains(value) { unique.append(value) }
            }
            return .set(unique)

        case .subscriptGet(let container, let index, _):
            // 读取规则（负值从尾部数、越界 panic）只存在于一处：解释器的策略表。
            // 在这里重新决定这些规则，正是两个引擎开始分歧的方式。
            return try SubscriptReadStrategy.read(
                container: try evaluate(container),
                index: try evaluate(index),
                location: IRExecutor.noLocation
            )

        case .lenCall(let argument):
            // 与解释器的 `len` 内建共用，规则见那边的实现。
            return try RuntimeOps.containerLength(try evaluate(argument))

        case .sliceCall(let container, let start, let end, _):
            return try sliceValue(
                container: try evaluate(container),
                start: try evaluate(start),
                end: try evaluate(end)
            )

        // MARK: 元组

        case .tupleConstruct(let labels, let elements, _):
            // 保持源码顺序，标签原样传递。位置字面量保留自己的 `nil` 标签，
            // 依声明标注补标签是绑定处的规则，不在字面量上施加。
            var values: [Value] = []
            for element in elements { values.append(try evaluate(element)) }
            return .tuple(labels: labels, elements: values)

        case .tupleIndexGet(let base, let index, _):
            // 下标在静态期已解析：`.0` 与带标签的 `.name` 到这里都是整数。
            // 因此这一支只对齐「下标意味着什么」，调用解释器的规则而不复述。
            return try RuntimeOps.tupleElement(
                try evaluate(base),
                index: index,
                location: IRExecutor.noLocation
            )

        // MARK: 字符串

        case .stringConcat(let lhs, let rhs):
            // `s1 + s2` 只有一个含义，就是解释器的含义：这一支走同一个 `binaryValue`。
            // 该节点与 `.binary` 分开，是因为契约把拼接沉到字节语义通道。
            // 它留在这一组里，是因为 defer 用例靠拼接构造期望字符串。
            return try RuntimeOps.binaryValue(
                try evaluate(lhs), .plus, try evaluate(rhs)
            )

        // MARK: Optional / Result / 枚举值

        case .resultConstruct(let isOk, let payload, _, _, _, _):
            // 唯一的 `makeResult`，两个通道对「Result 是什么」因此不可能有分歧。
            // err 载荷在 LLVM 侧是一个擦除类型的机器字，读取走同一个 `pini.err.message` 名字。
            return RuntimeOps.makeResult(
                caseName: isOk ? "ok" : "err",
                payload: try evaluate(payload)
            )

        case .optionalConstruct(let isSome, let payload, _):
            // Optional 的运行期形态就是 `some` / `none` 两个用例，没有父枚举。
            // `nil`、`Optional.none`、越界的 `.get`、开区间切片写法取到的是同一个值。
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
            // 规则在解释器的 `builtinGet` 里：负值从尾部数、字典按键相等、越界给 `none`。
            // 本节点是 `.get(i)` 的具名写法；降级器只为 Array 和 String 生成它，且总是带检查。
            return try RuntimeOps.builtinGet(
                receiver: try evaluate(container),
                index: try evaluate(index),
                checked: true,
                location: IRExecutor.noLocation
            )

        case .enumConstruct(let enumName, let caseName, let tag, let payloads, _, _):
            // 关联值名字来自声明，顺序与解释器写在构造值上的一致。
            // 只有一个读者消费它们——`match` 的具名绑定；渲染从不看。
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

        case .enumTagGet(let value):
            // Optional 与 Result 在运行期就是 `some` / `none` 和 `ok` / `err`，同一个读者兼顾两者。
            // 用户枚举答它声明顺序里的下标——即 `enumConstruct` 写入的数字。
            let subject = try evaluate(value)
            guard case .enumValue(let enumValue) = subject else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: enumTagGet on a value that is not enum, optional or result",
                    location: IRExecutor.noLocation
                )
            }
            if let parent = enumValue.parentEnum, let decl = enums[parent],
                let position = decl.cases.firstIndex(where: { $0.name == enumValue.caseName })
            {
                return .int(position)
            }
            switch enumValue.caseName {
            case "some", "ok": return .int(0)
            case "none", "err": return .int(1)
            default:
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: enumTagGet on case '\(enumValue.caseName)' with no declaration",
                    location: IRExecutor.noLocation
                )
            }

        case .enumPayloadGet(let value, let caseName, let index, _):
            // 用例名是调用方对「哪一支匹配上了」的断言；不匹配会悄悄读到兄弟用例的载荷，因此这里直接报错。
            let subject = try evaluate(value)
            guard case .enumValue(let enumValue) = subject, enumValue.caseName == caseName,
                enumValue.associatedValues.indices.contains(index)
            else {
                throw RuntimeError.invalidOperation(
                    reason: "IR executor: enumPayloadGet wants case '\(caseName)' payload \(index)",
                    location: IRExecutor.noLocation
                )
            }
            return enumValue.associatedValues[index]

        // MARK: 名义类型实例与其字段

        case .construct(let type):
            return try constructValue(type)

        case .fieldGet(let base, let slot, _):
            // 静态类型随节点传入，在这里丢弃：由接收者自己的值种类决定读哪张字段表，
            // 与 `Interpreter.evaluateMember` 的判断方式一致。
            return try fieldRead(from: try evaluate(base), slot: slot)

        // MARK: 闭包与函数值

        case .closureLiteral(_, let paramNames, _, _, _, let body, _):
            // 闭包 id 与捕获列表故意不用：id 只是编译侧注册表的键。
            // 这里的环境本身就是引用，把值挂到当前环境上即按引用捕获每个名字。
            // 与解释器的函数字面量分支相同：之后对捕获名的写入仍可见；快照式列表则不会。
            return makeFunctionValue(
                name: "<anon>",
                paramNames: paramNames,
                body: body,
                returnLabels: [],
                closure: currentEnv
            )

        case .functionValue(let name, _):
            return try namedFunctionValue(name: name)

        case .cFunctionAddress(let name, _):
            // 回调实参：C 要的是地址，解释器交出去的是可调用体 —— 地址由 `CallbackBridge` 的桩提供，
            // 绑定时再把这个值挂上去。这里与 `functionValue` 同一个构造，不另造一套。
            return try namedFunctionValue(name: name)

        case .indirectCall(let callee, let arguments, _):
            // 先算被调者再算实参，与解释器间接调用分支的顺序一致。
            // 实参求值可观察，因此这个顺序是语义而非实现细节。
            let calleeValue = try evaluate(callee)
            guard case .function(let function) = calleeValue else {
                throw RuntimeError.notCallable(location: IRExecutor.noLocation)
            }
            return try callFunctionValue(function, args: try arguments.map { try evaluate($0) })

        // MARK: 字符串与内建

        case .interpString(let parts):
            // 与解释器的 `.stringInterpolation` 分支一致；降级器已把各段拍平。
            // 字面量以 `stringConst` 到达，表达式是各自的节点，纯字面量的连续段已折叠。
            // 字符串在 `stringifyValue` 下原样渲染，因此字面量段贡献的文本不变。
            var text = ""
            for part in parts {
                text += RuntimeOps.stringifyValue(try evaluate(part))
            }
            return .string(text)

        case .isAsciiDigit(let argument):
            // 与解释器的 `is_ascii_digit` 分支一致，包括它在非 ASCII 上不报错的行为。
            // 非 ASCII 标量都大于 "9"，不需要第二次区间判断；空字符串为 false。
            let s = try requireChar(try evaluate(argument), for: "is_ascii_digit")
            guard let first = s.first else { return .bool(false) }
            return .bool(first >= "0" && first <= "9")

        case .printMulti(let arguments):
            // 解释器的多参数 `print`：每个值渲染后用一个空格连接，整行交给 sink。
            // 一次输出一行，并发任务无法插进行内；实参从左到右求值，这可观察。
            let values = try arguments.map { try evaluate($0) }
            outputSink(values.map { RuntimeOps.stringifyValue($0) }.joined(separator: " "))
            return .null

        case .assertCall(let condition, let message):
            // 与解释器的 `assert` 分支一致：先求值两个操作数，再判断条件。
            // 解释器在调用点求实参，之后分支才读到值。
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
            // 与解释器的 `join` 分支一致：逐元素字符串化，中间插入分隔符。
            // 共享渲染器无条件执行：降级器要求 `[String]`，但数组里实际装什么由运行期决定。
            guard case .array(let elements) = try evaluate(receiver) else {
                throw RuntimeError.invalidOperation(
                    reason: "join needs an Array receiver",
                    location: IRExecutor.noLocation
                )
            }
            let sep = try requireString(try evaluate(separator), for: "join")
            return .string(elements.map { RuntimeOps.stringifyValue($0) }.joined(separator: sep))

        case .stringCase(let isUpper, let receiver):
            // 契约要求 Unicode 感知，且接收者不变。
            // 权威是解释器的 `upper` / `lower` 分支——`String.uppercased()` / `.lowercased()`。
            // 发射器的纯 ASCII 字节遍历是偏离的一侧，因此这里对齐契约，而不是第三种读法。
            let text = try requireString(try evaluate(receiver), for: "upper/lower")
            return .string(isUpper ? text.uppercased() : text.lowercased())

        case .stringContains(let receiver, let needle):
            // 判据与编译通道同一条：按 UTF-8 字节序列查找，不做规范等价（NFD 的 é 不含预组合的 é）。
            // 空 needle 为真。这里逐字节比对而非建 `[Character]`：后者要为整串做一次字素分段。
            let haystack = Array(try requireString(try evaluate(receiver), for: "contains").utf8)
            let needleBytes = Array(try requireString(try evaluate(needle), for: "contains").utf8)
            if needleBytes.isEmpty { return .bool(true) }
            var i = 0
            while i + needleBytes.count <= haystack.count {
                if haystack[i..<(i + needleBytes.count)].elementsEqual(needleBytes) {
                    return .bool(true)
                }
                i += 1
            }
            return .bool(false)

        case .stringSubstring(let receiver, let start, let end):
            // 契约规定第二个实参是**终点**而非长度，但发射器仍按长度读。
            // 契约是权威：负值从尾部数，两个边界都夹到 `[0, len]`。
            // `hi < lo` 给空串；计数与切片都走 `GraphemeCursor`，因此切片是 O(n) 而非 O(n²)。
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
            // 契约要求**真正的 `Array<String>`**，空段被跳过，与 LLVM 的 `strtok` 循环一致。
            // 解释器保留空段；对齐那是 `stringSplit` 用例组的事，本节点服从契约。
            // 空分隔符按字素逐个切分；LLVM 侧对该情形没有防护。
            let text = try requireString(try evaluate(receiver), for: "split")
            let delimText = try requireString(try evaluate(delim), for: "split")
            let bytes = Array(text.utf8)
            let delimBytes = Array(delimText.utf8)
            var parts: [Value] = []
            if delimBytes.isEmpty {
                // 空定界符 ⇒ 一个元素恰一字素（自举 textAtoms 靠它建原子数组）。
                return .array(text.map { .string(String($0)) })
            }
            var start = 0
            var i = 0
            while i + delimBytes.count <= bytes.count {
                if bytes[i..<(i + delimBytes.count)].elementsEqual(delimBytes) {
                    if i > start {
                        parts.append(.string(String(decoding: bytes[start..<i], as: UTF8.self)))
                    }
                    i += delimBytes.count
                    start = i
                } else {
                    i += 1
                }
            }
            if start < bytes.count {
                parts.append(.string(String(decoding: bytes[start..<bytes.count], as: UTF8.self)))
            }
            return .array(parts)

        case .stringTrimLeft(let receiver):
            // 只剥 U+0020——制表符不剥。按字符从头部连续丢弃空格，
            // 每个空格就是一个字素，字素遍历没有额外开销。
            let text = try requireString(try evaluate(receiver), for: "trimLeft")
            return .string(String(text.drop(while: { $0 == " " })))

        case .stringTrimRight(let receiver):
            // 与 trimLeft 同一条规则，从尾部反向走：跨过尾部连续空格，取到它之前的长度。
            let text = try requireString(try evaluate(receiver), for: "trimRight")
            var end = text.endIndex
            while end > text.startIndex && text[text.index(before: end)] == " " {
                end = text.index(before: end)
            }
            return .string(String(text[..<end]))

        case .stringIndexOf(let receiver, let needle):
            // 位置单位是**字素**（与 `s[i]` 一致）；查找本身按字节做，命中后只数一次前缀字素。
            // 空 needle 得 0；未找到得 -1。判据与 `.stringContains` 同一条。
            let text = try requireString(try evaluate(receiver), for: "indexOf")
            let needleText = try requireString(try evaluate(needle), for: "indexOf")
            if needleText.isEmpty { return .int(0) }
            let haystack = Array(text.utf8)
            let needleBytes = Array(needleText.utf8)
            guard needleBytes.count <= haystack.count else { return .int(-1) }
            var i = 0
            while i + needleBytes.count <= haystack.count {
                if haystack[i..<(i + needleBytes.count)].elementsEqual(needleBytes) {
                    let prefix = String(decoding: haystack[0..<i], as: UTF8.self)
                    return .int(prefix.count)
                }
                i += 1
            }
            return .int(-1)

        // MARK: 指针与 LazyRef

        case .pointerLoad(let pointer, _):
            // 与解释器的 `load` 内建一致：元素类型取自指针本身，不取本节点的 `type` 载荷。
            // 降级器也从同一个实参推导该载荷，因此指针是唯一来源。
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerLoad expects a *T pointer operand",
                    location: IRExecutor.noLocation
                )
            }
            return try RuntimeOps.decodePointer(raw)

        case .pointerStore(let pointer, let value, _):
            // 与解释器的 `store` 内建一致：按指针的元素类型编码，窄元素截断。
            guard case .rawPointer(let raw) = try evaluate(pointer) else {
                throw RuntimeError.invalidOperation(
                    reason: "pointerStore expects a *T pointer operand",
                    location: IRExecutor.noLocation
                )
            }
            try RuntimeOps.encode(try evaluate(value), to: raw.pointer, type: raw.elemType)
            return .null

        case .foreignDataAddress(let name, _):
            // 符号地址本身，不是快照：写进去的值外部可见，外部写的值这里读得到。
            guard let address = foreignDataAddresses[name] else {
                throw RuntimeError.invalidOperation(
                    reason: "外部数据符号 '\(name)' 没有解析到地址", location: IRExecutor.noLocation)
            }
            return .rawPointer(address)

        case .addressOfVar(let name, _):
            // 与解释器对齐：`&x` 把值快照进新内存，因此经指针写入不会落到变量身上。
            // 真引用语义不由本节点承担：取真引用会与 AST 通道的行为不一致。
            return try RuntimeOps.snapshotPointer(
                of: try currentEnv.get(name: name),
                location: IRExecutor.noLocation
            )

        case .lazyRefConstruct(let closure, _):
            // 与 `Interpreter.makeLazyRefBox` 一致：实参是初始化闭包，盒子自身带着「只算一次」的规则。
            guard case .function(let function) = try evaluate(closure) else {
                throw RuntimeError.invalidOperation(
                    reason: "lazyRefConstruct expects an initialiser closure",
                    location: IRExecutor.noLocation
                )
            }
            return .lazyRef(LazyRefBox(initializer: function))

        case .lazyRefValue(let handle, _):
            // 与解释器的 `.value` 成员访问一致。盒子负责「算一次然后缓存」，
            // 本节点只提供计算这一步——与 AST 侧同样的分工。
            guard case .lazyRef(let box) = try evaluate(handle) else {
                throw RuntimeError.invalidOperation(
                    reason: "lazyRefValue expects a LazyRef handle",
                    location: IRExecutor.noLocation
                )
            }
            return try box.value { function in
                try self.callFunctionValue(function, args: [])
            }

        case .weakRefConstruct(let target, _):
            // 弱引用不拖住对象：box 里只放 Swift 弱引用，对象销毁后自动归零。
            guard case .objectReference(let object) = try evaluate(target) else {
                throw RuntimeError.invalidOperation(
                    reason: "weakRefConstruct expects an object operand",
                    location: IRExecutor.noLocation
                )
            }
            return .weakRef(WeakRefBox(target: object))

        case .weakRefValue(let handle, _):
            // 与 `optionalConstruct` 同一个 Optional 表示：`some` 带目标，`none` 无载荷。
            guard case .weakRef(let box) = try evaluate(handle) else {
                throw RuntimeError.invalidOperation(
                    reason: "weakRefValue expects a WeakRef handle",
                    location: IRExecutor.noLocation
                )
            }
            guard let target = box.target else {
                return .enumValue(EnumValue(caseName: "none", associatedValues: []))
            }
            return .enumValue(EnumValue(caseName: "some", associatedValues: [.objectReference(target)]))

        case .unownedRefConstruct(let target, _):
            // 无主引用不记账：box 里放 Swift `unowned`，目标归零后不自动置空（访问即未定义行为）。
            guard case .objectReference(let object) = try evaluate(target) else {
                throw RuntimeError.invalidOperation(
                    reason: "unownedRefConstruct expects an object operand",
                    location: IRExecutor.noLocation
                )
            }
            return .unownedRef(UnownedRefBox(target: object))

        case .unownedRefValue(let handle, _):
            guard case .unownedRef(let box) = try evaluate(handle) else {
                throw RuntimeError.invalidOperation(
                    reason: "unownedRefValue expects an UnownedRef handle",
                    location: IRExecutor.noLocation
                )
            }
            return .objectReference(box.target)

        case .fileWrite(let pathExpr, let contentExpr):
            // 就地写入，已存在的文件被截断；不是原子替换。
            // 路径按程序基准目录解析。打开或写入失败在此抛出，调用成功则返回 `()`。
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
            // 追加到末尾，目标缺失时创建（POSIX 的 "a"）。
            // 路径按程序基准目录解析。打开失败或短写在此抛出，调用成功则返回 `()`。
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
            // 整个文件，不设上限：不丢内容，也不做静默截断。
            // 两个通道都整份读出，语言不会因为没说明的理由读不到源文件。
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
            // 与解释器分支一致：保留行终止符，行长度受契约的字节上限约束。
            // EOF 给空字符串，正因为终止符没被剥掉，它与空行可区分。
            guard let line = readLine(strippingNewline: false) else {
                return .string("")
            }
            return .string(IOLimits.truncateToLineLimit(line))

        // MARK: join 与等待

        // `await f` / `wait f`：挂起引擎是 CPS 求值器，本引擎没有它。
        // 这一支必须存在，因为节点集合与契约条目同进同出——覆盖检查双向读。
        // 它按名字大声失败而非静默返回 `.null`，没有引擎支撑的降级规则因此会暴露成错误。
        case .join(let futureExpr, _, let form):
            // `await f` / `wait f`：求值操作数，等它落定，再拆开携带的 ok / err。
            // `form` 记录调用点用了哪个关键字；两种形式等待方式相同——让出任务需要可恢复的函数体。
            // 给 `join` 的操作数不是 future，就是运行期类型不匹配。
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

        // 取某类型的默认实例。本臂没有降级入口，因此当前不可达，但必须存在：覆盖检查双向对账。
        // 故按名字报错，不静默返回一个看起来合理的值。
        case .givenInstance(let type):
            // 物化面：与发射层同语义（惰性 · 恰一次 · 取副本）。
            return try materializeGivenInstance(type)
        }
    }

    // MARK: - 操作数辅助

    // 一个 `String` 操作数，否则按调用方名字大声报错。
    // AST 通道先做类型检查；这里类型不对说明模块不是降级器产出的，因此直接失败。
    private func requireString(_ value: Value, for what: String) throws -> String {
        guard case .string(let text) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects a String operand, got \(value)",
                location: IRExecutor.noLocation
            )
        }
        return text
    }

    // 一个 `Char` 操作数，取它的字素文本，否则按调用方名字大声报错。
    // `Char` 与 `String` 共用表示且加宽合法，因此 `String` 也接受：仍是一个字素。
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

    /// 一个 `I32` 操作数，否则按调用方名字大声报错。见 `requireString`。
    private func requireInt(_ value: Value, for what: String) throws -> Int {
        guard case .int(let number) = value else {
            throw RuntimeError.invalidOperation(
                reason: "\(what) expects an integer operand, got \(value)",
                location: IRExecutor.noLocation
            )
        }
        return number
    }

    // `enumConstruct` 所指的声明，先按用例名查，再退回 tag。
    // 降级器两者都带，所以两者都落空是真不一致：手工构造的模块，或丢掉的声明。
    // 调用方直接失败，而不是编造一个空的关联值列表。
    private func resolveEnumCase(enumName: String, caseName: String, tag: Int) -> IREnumCase? {
        guard let decl = enums[enumName] else { return nil }
        if let named = decl.cases.first(where: { $0.name == caseName }) { return named }
        guard decl.cases.indices.contains(tag) else { return nil }
        return decl.cases[tag]
    }

    // MARK: - 名义类型实例

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

    /// 析构在方法表里的键：与降载器拼实例方法名同规（`mangle(方法)__mangle(类型)`）。
    /// 不在这里另写一套转写 —— 两边拼出同一个符号，析构才找得到自己的方法。
    static func destructorKey(_ typeName: String) -> String {
        "deinit__" + IRName.mangle(typeName)
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
            let object = ObjectReference(typeName: name, fields: fieldValues)
            if destructorTypes.contains(name) { object.deinitQueue = deinitQueue }
            return .objectReference(object)
        }
        return .structInstance(StructInstance(typeName: name, fields: fieldValues))
    }

    /// 槽位换名字：解释器按名字存字段，节点只带槽位，故读写的这一刻把槽换回名字。
    /// 越界不可达：降载期按声明序算槽，验证器在读取模块前已核过一遍。
    private func fieldName(of typeName: String, slot: Int) throws -> String {
        guard let decl = types[typeName], slot >= 0, slot < decl.fields.count else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: '\(typeName)' carries no field at slot \(slot)",
                location: IRExecutor.noLocation
            )
        }
        return decl.fields[slot].name
    }

    /// `base.field`——解释器成员分支的读半边；查不到就报告不一致，绝不返回 `.null`。
    /// 字段缺失不可达：降级器静态解析字段并拒绝生成本节点。
    /// 未镜像：`_` 可见性门与绑定方法回退——检查器与降级器都拒绝这两者。
    private func fieldRead(from base: Value, slot: Int) throws -> Value {
        switch base {
        case .structInstance(let instance):
            let name = try fieldName(of: instance.typeName, slot: slot)
            guard let value = instance.fields[name] else {
                throw missingField(name, on: instance.typeName)
            }
            return value
        case .objectReference(let object):
            let name = try fieldName(of: object.typeName, slot: slot)
            guard let value = object.fields[name] else {
                throw missingField(name, on: object.typeName)
            }
            return value
        default:
            throw RuntimeError.invalidOperation(
                reason: "IR executor: field read at slot \(slot) needs a nominal receiver, got "
                    + "\(RuntimeOps.describeValueKind(base))",
                location: IRExecutor.noLocation
            )
        }
    }

    /// 自追加形态 `x = x.append(v)`：元素先求值（它可能读同名变量），再取走槽里的数组就地追加写回。
    /// 命中返回 true；接收者不是数组时按内建原路径算出新值，报同一个错。
    private func storeVarByAppending(name: String, value: IRExpr) throws -> Bool {
        guard case .call(let function, let arguments, _) = value,
            function == "Array.append",
            arguments.count == 2,
            case .load(let receiver, _) = arguments[0],
            receiver == name
        else { return false }
        let element = try evaluate(arguments[1])
        guard var slot = try currentEnv.take(name: name) else { return false }
        if RuntimeOps.appendConsuming(&slot, element) {
            try currentEnv.assign(name: name, value: slot)
            return true
        }
        let appended = try RuntimeOps.builtinArrayAppend([slot, element])
        try currentEnv.assign(name: name, value: appended)
        return true
    }

    /// 字段位的自追加形态 `obj.f = obj.f.append(v)`：只认接收者与目标同一处，接收者求值两次会多跑副作用。
    private func storeFieldByAppending(base: IRExpr, slot: Int, value: IRExpr) throws -> Bool {
        guard case .call(let function, let arguments, _) = value,
            function == "Array.append",
            arguments.count == 2,
            case .fieldGet(let receiverBase, let receiverSlot, _) = arguments[0],
            receiverSlot == slot,
            receiverBase == base
        else { return false }
        let element = try evaluate(arguments[1])
        let receiver = try evaluate(base)
        if case .load(let rootName, _) = base, rootName != "self",
            case .structInstance = receiver,
            let mutable = currentEnv.isMutable(name: rootName), !mutable
        {
            throw RuntimeError.immutableVariable(name: rootName, location: IRExecutor.noLocation)
        }
        // 字段先让出：槽位不空则数组存两份引用，就地增长永远判不成立。
        switch receiver {
        case .structInstance(let instance):
            let name = try fieldName(of: instance.typeName, slot: slot)
            guard var current = instance.fields[name] else { return false }
            instance.fields[name] = .null
            if RuntimeOps.appendConsuming(&current, element) {
                instance.fields[name] = current
                return true
            }
            instance.fields[name] = try RuntimeOps.builtinArrayAppend([current, element])
            return true
        case .objectReference(let object):
            let name = try fieldName(of: object.typeName, slot: slot)
            guard var current = object.fields[name] else { return false }
            object.fields[name] = .null
            if RuntimeOps.appendConsuming(&current, element) {
                object.fields[name] = current
                return true
            }
            object.fields[name] = try RuntimeOps.builtinArrayAppend([current, element])
            return true
        default:
            return false
        }
    }

    /// `base.field = value`——解释器 `performMemberAssign` 的写半边，逐支对应。
    /// `let` 绑定结构体的规则在接收者写成 `self` 以外的标识符时触发；`self` 豁免。
    /// 未镜像：入值的深拷贝（没有用例观察到）与 `_` 门（静态拒绝）。
    private func storeField(base: IRExpr, slot: Int, value: Value) throws {
        try storeField(on: try evaluate(base), base: base, slot: slot, value: value)
    }

    /// `storeField` 的**已求值接收者**那一半：让 `obj.field[i] = v` 复用**同一次**接收者求值。
    /// 那里若改调 `storeField(base:…)`，接收者会被求值两次，带副作用时（`f().xs[i] = v`）会多跑一次调用。
    /// 发射侧只求值一次，故两腿不等价 —— 拆分正是为了避免这一点。
    private func storeField(on receiver: Value, base: IRExpr, slot: Int, value: Value) throws {
        if case .load(let rootName, _) = base, rootName != "self",
            case .structInstance = receiver,
            let mutable = currentEnv.isMutable(name: rootName), !mutable
        {
            throw RuntimeError.immutableVariable(name: rootName, location: IRExecutor.noLocation)
        }
        switch receiver {
        case .structInstance(let instance):
            instance.fields[try fieldName(of: instance.typeName, slot: slot)] = value
        case .objectReference(let object):
            object.fields[try fieldName(of: object.typeName, slot: slot)] = value
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

    /// `container.slice(start, end)`——切片语法糖语义。
    /// `slice` 是本引擎自己实现体的宿主成员：下面的 `switch` 是它唯一定义。
    /// 开边界取全体、负值从尾部数、夹到 `[0, len]`、`hi < lo` 给空串；`String` 按字素切。
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

    /// 一个切片边界：`none` / `.null` 是开形式；整数为负时从尾部数；其余拒绝。
    /// 规则与上面 `sliceValue` 对两个边界施加的相同。
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

    /// 数值显式转换。解释器把整数建模为单一 `Int`：窄化按目标宽度截断、加宽恒等，
    /// 故 I8/I32/U8 的截断与 U64 的回绕都在这一层完成。浮点与整数之间按参考件的显式转换条款：
    /// 整数列浮点按最近可表示值，浮点列整数向零截断；越界与 NaN 规范标为待定，此处落 0。
    static func castValue(_ value: Value, to target: IRType) -> Value {
        switch target {
        case .i8:
            if case .int(let i) = value { return .int(Int(Int8(truncatingIfNeeded: i))) }
            return value
        case .u8:
            if case .int(let i) = value { return .int(Int(UInt8(truncatingIfNeeded: i))) }
            return value
        case .i32:
            if case .int(let i) = value { return .int(Int(Int32(truncatingIfNeeded: i))) }
            if case .float(let d) = value { return IRExecutor.integer(from: d) }
            return value
        case .i64, .u64:
            if case .float(let d) = value { return IRExecutor.integer(from: d) }
            return value
        case .f64:
            if case .int(let i) = value { return .float(Double(i)) }
            return value
        default:
            return value
        }
    }

    /// 浮点列整数：向零截断；越界与 NaN 不在规范定义域内，统一落 0 而不 trap。
    private static func integer(from d: Double) -> Value {
        let truncated = d.rounded(.towardZero)
        if let exact = Int(exactly: truncated) { return .int(exact) }
        return .int(0)
    }

    /// `IRBinaryOp` → `BinaryOperator`；AST 通道用内建调用承担该运算时返回 nil。
    /// 映射是 IR 的词汇；每个运算符的含义在 `Interpreter.binaryValue` 里，两个通道因此不会分歧。
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
        // LLVM 里 min/max 降为 select；解释器以内建调用到达它们，
        // 因此没有可映射的运算符。
        case .minOf, .maxOf: return nil
        }
    }

    /// `IRUnaryOp` → `UnaryOperator`；见 `operatorFor(_ op: IRBinaryOp)`。
    static func operatorFor(_ op: IRUnaryOp) -> UnaryOperator? {
        switch op {
        case .negate: return .minus
        case .logicalNot: return .not
        // `~` 映射到解释器自己的 `.bitwiseNot`，两个引擎因此都走到共享的 `RuntimeOps.unaryValue` 入口。
        case .bitwiseNot: return .bitwiseNot
        // `abs` 在 AST 通道上是内建调用，不是一元运算符。
        case .abs: return nil
        // 转换不走 `RuntimeOps` 的一元入口：它要目标类型，由 `castValue` 单独承担。
        case .cast: return nil
        }
    }

    // MARK: - defer 作用域

    /// 与 `Interpreter.pushDeferScope` 对应。
    private func pushDeferScope() {
        deferStack.append([])
    }

    /// 与 `Interpreter.popDeferScope` 对应：按 LIFO 跑本作用域内的 defer。
    /// 作用域在跑 defer 之前先移除，因此 defer 里的语句注册到外层作用域。
    /// defer 抛出的错误由调用方吞下——见 `executeBlock`。
    private func popDeferScope() throws {
        guard !deferStack.isEmpty else { return }
        let groups = deferStack.removeLast()
        for group in groups.reversed() {
            for statement in group { try execute(statement) }
        }
    }

    /// 把语句表当成**块**来跑：开一个 defer 作用域和一个子变量作用域，任何退出路径都关掉。
    /// 在 `if` / `else`、`while`、`for-in` 边界调用；函数体自己内联开作用域。
    /// 恢复父环境先注册，因此 defer 在子作用域下跑，仍能看到块内绑定。
    private func executeBlock(_ block: IRBlock) throws {
        let parentEnv = currentEnv
        currentEnv = parentEnv.pushScope()
        defer { currentEnv = parentEnv }
        pushDeferScope()
        defer { try? popDeferScope() }
        try executeStatements(block)
    }

    // MARK: - 语句

    /// 跑到期的析构：从队列逐条取出，交一份带同样字段的替身给 `deinit__<类型>`，按普通方法调用跑。
    /// 替身不装投递口，否则它的死会再触发一次析构；字段随替身释放逐层交接，故「A → 字段 B → B」在同一轮里
    /// 按链式顺序发生，不递归不积栈。本线程已在析构中直接返回，外层那一轮会取到新投递的记录。
    private func drainDestructors() throws {
        guard drainingStorage.value != true else { return }
        drainingStorage.value = true
        defer { drainingStorage.value = false }
        while let record = deinitQueue.takeOne() {
            guard let method = methods[IRExecutor.destructorKey(record.typeName)] else { continue }
            let standIn = ObjectReference(typeName: record.typeName, fields: record.fields)
            _ = try call(method, args: [.objectReference(standIn)])
        }
    }

    /// 块交出值的那个位置：**末句**是普通表达式语句时就是末句本身，否则 -1（没有值）。
    /// 与降载侧的尾表达式位同一条规则；更早的表达式语句没人读它的值，当场丢才能让析构落在自己那句的边界上。
    private static func trailingExprIndex(in block: IRBlock) -> Int {
        guard let last = block.last, case .exprStmt = last else { return -1 }
        return block.count - 1
    }

    /// 按顺序跑语句表，返回末尾表达式语句的值（否则 `.null`）。
    /// 即解释器的 `lastValue` 规则，控制流与函数体因此共用一个跑法；其余调用方丢弃该值。
    /// 这里也是暂停点：没有位置的块被跳过，绝不停在编出来的行上。
    @discardableResult
    private func executeStatements(_ block: IRBlock) throws -> Value {
        var lastValue: Value = .null
        let trailingIndex = IRExecutor.trailingExprIndex(in: block)
        for (index, statement) in block.enumerated() {
            if debugHook != nil, let location = block.position(at: index) {
                try debugPause(at: location)
            }
            if case .exprStmt(let expr) = statement {
                let value = try evaluate(expr)
                if index == trailingIndex { lastValue = value }
            } else {
                try execute(statement)
            }
            // 语句边界是一个安全点：这一句之前死掉的对象在这里跑析构，输出次序与源码里的语句对齐。
            try drainDestructors()
        }
        return lastValue
    }

    /// 每条语句执行前询问调试器。
    /// 与 `Interpreter.debugPause(at:)` 对应：位置由调用方给出而非节点，因此节点形状无关。
    /// `.quit` 以 `DebuggerError.quit` 展开；先查钩子，没有调试器的引擎不付代价。
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
            // 没有初始化式也注册，值为 `.null`：读未初始化变量是一个值，不是未定义变量错误。
            // 结构体逐字段拷贝；不做的话经副本的写入会静默落到原值上。
            var value = try initializer.map { RuntimeOps.copyIfStruct(try evaluate($0)) } ?? .null
            // 绑定处补标签：绑到带分量名的槽类型上的值，采用那些名字。
            // 判据是「至少有一个具名」，不是「非空」：`[nil, nil]` 会把值已有的名字抹掉。
            // 哪些槽具名在降级期决定；对合成的 `allocVar` 这是空操作。
            if case .tuple(let labels, _) = type, labels.contains(where: { $0 != nil }) {
                value = RuntimeOps.relabelled(value, with: labels)
            }
            currentEnv.define(name: name, value: value, isMutable: mutable)

        case .storeVar(let name, _, let value, _, _):
            // 自追加形态走消费路径：槽位清空后数组只剩一份引用，就地增长。
            // 其余形态照旧深拷结构体 —— 否则写穿副本会悄悄改到原值。
            if try !storeVarByAppending(name: name, value: value) {
                try currentEnv.assign(name: name, value: RuntimeOps.copyIfStruct(try evaluate(value)))
            }

        case .releaseVar(let name, _):
            // 合成临时局部的提前失效：置空即松手，值语义对象由 ARC 在旧值失去最后一个引用时释放。
            try currentEnv.clear(name: name)

        case .ifStmt(let label, let condition, let thenBody, let elseBody):
            // 每个分支自成一个 defer 作用域：`elif` 链会折成嵌套 `ifStmt`，因此三个分支是三个作用域。
            // 带标签的 `if` 是可中断帧，其分支在 catch 下运行，标签 break 才能定向到这里。
            // 无标签的 `if` 裸跑——为它加 catch 会吞掉指向外层循环的深度 1 信号。
            if label == nil {
                try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
            } else {
                do {
                    try executeIfBranch(condition: condition, thenBody: thenBody, elseBody: elseBody)
                } catch let signal as IRControlSignal {
                    switch signal {
                    case .breakSignal(let depth):
                        // `depth == 1` ⇒ 本帧就是目标：`break` 离开该块，控制落到 `if` 之后。
                        // 更深的属于外层帧，减一层后重新抛出。
                        if depth > 1 { throw IRControlSignal.breakSignal(depth: depth - 1) }
                    case .continueSignal(let depth):
                        // `if` 帧永远不会是 `continue` 的目标——`continue` 只解析到循环帧。
                        // 因此到达这里的信号指向更外层，其剩余深度 >= 2。
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
            // 在这里丢弃；`executeStatements` 才在需要它的路径上把它当作函数体的结果值捕获。
            _ = try evaluate(expr)

        case .captureMarker(let name):
            // 不是「未实现」：契约规定本节点降级为空。
            // 捕获在闭包字面量处由自由变量分析解决；`captureStatement` 同样是空操作。
            // 在这里报错会把一个明确的空操作误报成缺口。
            _ = name

        case .subscriptStore(let container, let index, let value, _, _):
            // 求值顺序照搬解释器：值、下标、容器链——副作用能观察到这个顺序。
            // 结构体逐字段拷贝；不做的话经副本的写入会出现在原值上。
            let newValue = RuntimeOps.copyIfStruct(try evaluate(value))
            let targetIndex = try evaluate(index)
            try storeSubscript(target: container, index: targetIndex, newValue: newValue)

        // MARK: 控制流

        case .forInStmt(let pattern, _, let kind, let iterable, let body, let step):
            // `elementTypes` 只在降级期有用：运行期的行分解沿用解释器的实现，不复述。
            try executeForIn(
                pattern: pattern, kind: kind, iterable: iterable,
                body: body, step: step
            )

        case .deferStmt(let body):
            // 只注册不执行：LIFO 顺序属于作用域（`popDeferScope`）。
            // 这个守卫来自解释器：没有外层作用域的 `defer` 是错误，而降级后的源码到不了这里。
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
            // `detach <expr>`：把任务从父任务上剪掉，使其返回不再取消它——fire-and-forget 的合法出口。
            // 先求值操作数，非 future 是运行期类型不匹配，与解释器报告的位置一致。
            // 在降级期拒绝会把错误移出两个引擎保持一致的运行期边界。
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
            // 消息由降级器给出——它点出解释器只能在运行期发现的越界——原样透传。
            throw RuntimeError.invalidOperation(
                reason: message,
                location: IRExecutor.noLocation
            )

        // MARK: try 与 match

        case .tryStmt(let operand, let errorVar, let handler, let okTarget, _):
            // 与解释器的 `tryExpression` 一致：`ok` 产出载荷，`err` 绑定载荷并跑处理器。
            // 处理器语句就地处执行、不另开块，因此其中的 `return` / `break` / `continue` 以信号逸出。
            // 末尾的裸 `pass` 只结束语句——两点都与解释器同形。
            let result = try evaluate(operand)
            try runTryResult(result, errorVar: errorVar, handler: handler, okTarget: okTarget)

        case .matchStmt(let scrutinee, let cases, _):
            // 节点携带的 `scrutineeType` 故意不读：解释器的规则是基于值的。
            // 静态类型已经选定了分支族；在这里再读一次会形成第二套可能分歧的派发。
            let scrutineeValue = try evaluate(scrutinee)
            try runMatch(cases, scrutinee: scrutineeValue)

        // MARK: 名义类型字段写入

        case .fieldStore(let base, let slot, let value, _, _, _):
            // 先右侧、后接收者——解释器赋值路径用的就是这个顺序。
            // 只有两侧都有副作用时才可观察，而那正是照抄猜错会被抓到的地方。
            // 字段位的自追加形态同样走消费路径；其余形态照旧深拷结构体。
            if try !storeFieldByAppending(base: base, slot: slot, value: value) {
                try storeField(base: base, slot: slot, value: RuntimeOps.copyIfStruct(try evaluate(value)))
            }
        }
    }

    /// 跑一条 `match` 分支，方式与 `Interpreter.executeMatch` 相同。
    /// 绑定放在新的链式环境里，分支体是一个**块**；`defer` 保证任何退出都丢掉分支环境。
    /// 绑定按载荷下标定位——声明顺序由降级器解析——`nil` 是 `_` 占位。
    private func executeArm(_ arm: IRMatchCase, scrutinee value: Value) throws {
        let caseEnv = Environment(enclosing: currentEnv)
        if case .enumValue(let ev) = value {
            // 解释器的元数门：绑定个数不符是运行期错误，不是静默 `.null`。
            // 没有绑定的分支（零载荷用例、字面量、通配）豁免。
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

    /// `target[index] = newValue`，值语义：一次写入产出**新**容器，并逐层重新绑定。
    /// 与 `Interpreter.writeSubscript` 一致：变量目标经 `Environment.assign` 重绑，因此 `let` 被拒。
    /// 嵌套时先写内层再存回；内层下标被求值两次，与解释器相同。
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

        case .fieldGet(let baseExpr, let slot, _):
            // `obj.field[i] = v` —— 对**字段值**写下标，再把新容器**写回该字段**。
            // 写回是必需的：容器写入可能分裂出新句柄，不回写则那次写会**静默丢失**。
            // `base` 只求值**一次**（同一接收者用于读字段与写回），理由见 `storeField(on:base:slot:value:)`。
            let receiver = try evaluate(baseExpr)
            let containerValue = try fieldRead(from: receiver, slot: slot)
            let updated = try SubscriptWriteStrategy.write(
                container: containerValue,
                index: index,
                newValue: newValue,
                location: IRExecutor.noLocation
            )
            try storeField(on: receiver, base: baseExpr, slot: slot, value: updated)

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

    /// 拿到被匹配值之后的 `match` 分支选择。
    /// 抽出来是为了让 yield 驱动用同一段代码补完挂起的 `match`；末尾那条规则太细，不该抄一份。
    /// 抄一份会让两个引擎对「未匹配的枚举是不是错误」产生分歧。
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
        // 没有分支命中：枚举值意味着运行期不穷尽，报错时带上它的用例名。
        // 裸值静默穿过，因为字面量的取值空间无限，剩余情况由 `case _:` 承担。
        // 穷尽性是检查器的职责（`E3-007`），因此到达这里的枚举本来就无法静态覆盖。
        if case .enumValue(let ev) = value {
            throw RuntimeError.matchNotExhaustive(
                value: ev.caseName, location: IRExecutor.noLocation
            )
        }
    }

    /// 拿到操作数的 `Result` 之后，try-else 的结局处理。抽取理由同 `runMatch`，规则也相同。
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
            // 表达式位置以 `allocVar(x, initializer: nil)` 加本节点的 `okTarget: x` 到达。
            // 因此这次写入是已声明槽的**初始化**；用 `assign` 会被误读成给 `let` 赋值。
            if let okTarget = okTarget {
                try currentEnv.initialize(name: okTarget, value: payload)
            }
            return
        }

        // 处理器语句就地执行、不另开块，因此 `return` / `break` / `continue` 以信号逸出。
        // 末尾的裸 `pass` 只结束语句。
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

    /// 选一个 `if`/`elif`/`else` 分支并执行。抽出来是为了让 `ifStmt` 里的帧处理
    /// 包住这次选择而不复述——无论 `if` 带不带标签，选择过程都一样。
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

    /// 与 `Interpreter.executeWhile` 一致，只是展开用深度而非标签来表达。
    /// 体正常结束，或对本题循环的 `continue` → 跑 step；对本题循环的 `break` → 不跑 step 直接返回。
    /// 指向外层循环的信号减一层后重抛并跳过 step，`return` 原样上传。
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

    /// 与 `Interpreter.executeFor` 一致：先分解可迭代对象，因此空集合上的元数不符也会报错。
    /// 字典行是 `(key, value)` 并跳过逐元素分解；那个两字段守卫是它唯一的元数检查。
    /// 每次迭代拿一个新的链式环境；step 在其内部跑，展开规则同 `executeWhile`。
    private func executeForIn(
        pattern: [String],
        kind: IRForIterableKind,
        iterable: IRExpr,
        body: IRBlock,
        step: IRBlock?
    ) throws {
        let iterValue = try evaluate(iterable)
        var rows: [[Value]] = []
        // `kind` 由契约定义（「`kind` 决定元素如何读」），运行期形状由解释器的检查决定；
        // 要求二者一致，才不至于在这里形成第二套更松的语义。
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
                // 指向本循环：step 仍要跑，且跑在循环环境里——
                // 因此跨过这个 catch 时 `currentEnv` 故意留在 `loopEnv` 上。
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

    // MARK: - 调用

    /// 构造可调用体的值半边，并把体半边登记在它旁边。
    /// 函数值只在这里创建，因此两半不可能分开构造。
    /// 查不到体说明值来自别处——例如手工构造的模块——而不是漏了某次 `make` 调用。
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

    /// 声明的返回类型携带的分量名，仅当它是命名元组时（`-> (商: I32, 余: I32,)`）。
    /// 标量、位置元组与 void 返回都不给标签，`applyReturnLabels` 原样返回值。
    private static func declaredReturnLabels(_ type: IRType?) -> [String?] {
        guard let type = type, case .tuple(let labels, _) = type else { return [] }
        return labels
    }

    /// 按声明调用模块级函数。
    /// 它的父环境是全局环境，返回标签来自它的返回类型——调用路径的普通情形。
    /// 加上 `evaluate` 里的函数值分支，就构成了调用的全部。
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

    /// 具名函数的运行时值。`functionValue` 与 `cFunctionAddress` 都从这里取：
    /// 一个进闭包调用协议，一个交给回调桥当可调用体 —— 「这个函数是谁」只有一次查表。
    private func namedFunctionValue(name: String) throws -> Value {
        guard let target = functions[name] else {
            throw RuntimeError.invalidOperation(
                reason: "IR executor: function value '\(name)' names no module-level "
                    + "function in this module",
                location: IRExecutor.noLocation
            )
        }
        // 具名函数不闭包任何东西：解释器把它的值登记在全局环境上。
        // 这里照此办理，而不去编造一个并不存在的创建点环境。
        return makeFunctionValue(
            name: name,
            paramNames: target.params.map { $0.name },
            body: target.body,
            returnLabels: IRExecutor.declaredReturnLabels(target.returnType),
            closure: globalEnv
        )
    }

    /// 调用引擎持有函数体的函数值：按身份索引，因为每个匿名 `func` 都叫 `<anon>`。
    /// 它的父环境是值自带的环境，不是全局——这是闭包调用与模块级调用唯一不同的规则。
    /// 两者都走 `invoke`，元数、深度守卫、defer 作用域、返回标签与末尾表达式规则因此只存在一份。
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

        // 元数检查故意放在派发之上：它是调用的属性，不属于函数体落到哪个线程。
        // 放到派发之下，spawn 出去的函数体的元数错误会表现为一个调用方可能从不检查的失败 Future。
        if callable.isAsync {
            return try spawnAsync(callable, parent: parent, args: args, name: name)
        }
        return try invokeBody(callable, parent: parent, args: args, name: name)
    }

    /// 在 worker 线程上跑 async 函数体，给调用方一个 pending Future。
    /// 与解释器的 `isAsync` 分支一致：函数体开跑前先链接子任务，句柄放到 worker 上。
    /// 两条退出路径都要关闭作用域；做错会泄漏子任务或静默丢掉失败。
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
                    // 结构化严格规则的收尾动作：取消从未被 join 的任务，
                    // 并让无人消费的失败在这个边界浮现，而不是消失。
                    return .finished(IRExecutor.closeTask(future, value: result))
                case .givenUp(let frame):
                    // 线程空手回到池里，什么也没往 future 上发：函数体还没跑完。
                    // 此后由恢复方负责完成——这就是「任务已被让出」的全部含义。
                    self.attachResume(frame, task: future)
                    return .suspended
                }
            } catch {
                // 抛错的路径同样关闭作用域：死掉的函数体不能把它的子任务留在运行中。
                future.closeScope()
                throw error
            }
        }
        scheduler.spawn(future) { try work.run() }
        return .future(future)
    }

    /// 任务无论跑了几轮，只做一次的收尾动作。
    private static func closeTask(_ future: FutureValue, value: Value) -> Value {
        RuntimeOps.flipIfLeaked(value, leaked: future.closeScope())
    }

    /// 同步函数体路径：绑定实参、跑语句、拆开 return 信号。
    /// 它是 `invokeBodyStep` 的外壳，共用同一段前奏与出口规则；拆信号即「同步」的全部内容。
    /// 同步体一直守在 join 上，因此这里收到挂起说明驱动有缺陷，报错时点名。
    private func invokeBody(
        _ callable: IRCallableBody,
        parent: Environment,
        args: [Value],
        name: String
    ) throws -> Value {
        let step: IRBodyStep
        do {
            step = try invokeBodyStep(callable, parent: parent, args: args, name: name)
        } catch {
            // 抛出去的那条路也放掉这一帧的对象：帧的局部在 `invokeBodyStep` 退出时就没了，
            // 故此刻队列里已经有它们的记录，只是没人再往下走到语句边界。
            try? drainDestructors()
            throw error
        }
        switch step {
        case .finished(let value):
            // 帧收尾就是这一层局部变量的死点：它们在里面已无引用，析构在这里落地，
            // 而不是攒到调用方的下一条语句 —— 编译侧同样在帧退出时释放。
            try drainDestructors()
            return value
        case .givenUp:
            throw RuntimeError.invalidOperation(
                reason: "IR executor: a synchronous body gave its task up at a join "
                    + "— the yield envelope and the driver disagree about what can suspend",
                location: IRExecutor.noLocation
            )
        }
    }

    /// 进入函数体并运行，把挂起如实上报而非隐瞒。
    /// 前奏与 `invokeBody` 相同：栈守卫、实参绑定、环境、defer 作用域；不同在于出口。
    /// 让出的函数体不能展开：展开会让它的 `defer` 在挂起处运行；`standDown` 把线程留干净。
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

        // 函数体自成一个 defer 作用域，与 `executeFunctionBody` 相同，因为它同样拥有 `lastValue`。
        // defer 在恢复环境之前跑，因此它们仍看到函数自己的环境。
        // `exitBody` 把这些写在一处而不是用两个 `defer`，因为挂起的函数体两者都不能走。
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
            // 死掉的函数体不留下任何东西：作用域关闭，上下文按正常返回的方式展开。
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

    /// 把让出的函数体接回来，在等待的 future 落定的那个线程上。
    /// 没有前奏：实参在挂起前已绑定，它们的环境就在帧里。
    /// 重进前奏会在已经越过实参的函数体上重新绑定，用新参数把它从头再跑一遍。
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

    /// 离开 worker 线程，不留下本函数体的任何东西。
    /// 四个线程局部量是**清空**而非恢复：挂起的函数体在该线程上没有外层帧。
    /// 留着不清，下一个任务会继承别人的深度、回溯和 defer；真实值由帧携带。
    private func standDown() {
        callDepthStorage.value = nil
        callStackNames = []
        deferStack = []
        currentEnvStorage.value = nil
    }

    /// 函数体循环的信号规则，共用一处，使首轮与每次恢复都只施加一次。
    /// `return` 属于函数体本身，成为结果值并施加返回点标签；其他信号一律重抛。
    private func bodyOutcome(
        returnLabels: [String?],
        _ run: () throws -> IRBodyStep
    ) throws -> IRBodyStep {
        do {
            return try run()
        } catch let signal as IRControlSignal {
            if case .returnSignal(let value) = signal {
                // 解释器的返回点规则，输入取自声明的返回类型而非 AST 的 `returnLabels`。
                // 只有显式 `return` 路径补标签；隐式末尾表达式保持原样，与解释器的做法一致。
                // 闭包不传标签，对应一个没有挂声明的 `FunctionValue`。
                return .finished(RuntimeOps.applyReturnLabels(returnLabels, to: value ?? .null))
            }
            throw signal
        }
    }

    /// 跑函数体的语句，上报挂起；`lastValue` 随帧走，因为它属于「函数体跑到哪了」。
    /// `pending` 用于接回恢复后的运行：`from` 处的语句用等待到的值补完，然后循环继续。
    /// - Parameter yieldable: 只有 async 函数体可以让出任务；同步体守着线程，正如 `wait`。
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
        let trailingIndex = IRExecutor.trailingExprIndex(in: body)
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
                // 操作数同步求值是刻意的：它**产出** future，因此不能等待某个 future。
                // 嵌在里面的 join 由降级器拒绝，这次调用因此不在递归路径上。
                let operand = try evaluate(plan.operand)
                guard case .future(let fut) = operand else {
                    throw RuntimeError.typeMismatch(
                        expected: "Future<T, Error>",
                        got: RuntimeOps.describeValueKind(operand),
                        location: IRExecutor.noLocation
                    )
                }

                // 已落定的 future 不构成让出任务的理由：取值让 `await` 走 `wait` 的路径，不发生任务切换。
                // 第三种情况是后端说「这次不行」：合规而非故障，因此等待静默占用线程。
                // 在那里挂起会死锁，那不是 `await` 的降级读法，而是程序停住。
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
                                // 子任务的生命周期在这里被消费掉，而这是进入 `finishYield` 的路径中唯一必须自己声明的一处。
                                // 不声明的话子任务仍留在本函数体的作用域里，返回边界就会把已等待的失败读成「未 join」。
                                // 于是函数体自己的 `ok` 会变成 `err(聚合)`，它对错误做的事全被丢弃。
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
                let value = try evaluate(expr)
                if position == trailingIndex { last = value }
            } else {
                try execute(statement)
            }
            // 与 `executeStatements` 同一处安全点：函数体是长跑的那一类语句序列，析构不该攒到调用方。
            try drainDestructors()
            position += 1
        }
        return .finished(last)
    }

    /// 驱动器知道如何让出任务的语句位置，且仅限这些。白名单的理由见 `IRYieldPlan`。
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

    /// 用等待到的值补完让出的函数体停下的那条语句。
    /// `var` 情形要把该分支的整段尾巴重放——结构体拷贝与补标签——朴素地恢复会跳过它们。
    /// 返回 `nil` 表示该语句不贡献值，因为 `lastValue` 只计表达式语句。
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

    /// 等待函数体为之让出任务的 future，落定时把函数体交给策略。
    /// 落定是把任务交给调度器队列，而不是就地恢复，因此顺序由策略决定。
    /// 登记以被等待的 future 为单位而非帧；函数体等待期间没有线程被占住。
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
            // 函数体永远拿不到值，因此走不到收尾动作；作用域在这里关闭，否则子任务继续运行。
            // 关闭所报的泄漏被丢弃：本任务有自己的失败原因，聚合会把它替换掉。
            for item in batch {
                _ = item.task.closeScope()
                item.task.reject(error)
            }
        }
    }

    /// 把恢复的函数体跑到下一个停点，并结算任务。
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
            // `resumeBody` 会把 return 信号变成值，因此这里的控制信号是越出了函数体——驱动缺陷。
            // 按驱动缺陷上报，而不是读成 await 失败；泄漏的子任务出于同样原因被丢弃。
            _ = task.closeScope()
            task.reject(GCDScheduler.coerce(error))
        }
    }
}
