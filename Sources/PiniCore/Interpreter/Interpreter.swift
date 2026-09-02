import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 阶段 B 挂起信号：`await`/`wait` 在 suspend 模式下遇到未决 Future 时抛出，
/// 由 `runSuspendableBodyCPS`（CPS 求值器，见 SuspendEvaluator.swift）捕获并登记续体
/// （`whenResolved`），释放当前 OS 线程。
/// 同步路径（`suspendMode == false`）永不会抛此信号，走既有阻塞 `joinFuture`。
struct SuspendSignal: Error {
 let future: FutureValue
}

public class Interpreter {
 private var globalEnv: Environment
 // P5 Phase 2：currentEnv / deferStack 改为线程本地，使并发任务互不污染解释器可变状态。
 // 每个异步任务在独立 worker 线程执行，线程本地存储自然隔离各自求值环境；
 // 同一线程内的函数调用仍遵循栈式 push/pop（executeFunctionBody 的 defer 还原），语义不变。
 // 跨平台线程本地存储（替代 Foundation 仅 macOS 提供的 `Thread.current.threadDictionary`，见 Common/ThreadLocal.swift）。
 private let tlCurrentEnv = ThreadLocal<Environment>()
 private let tlDeferStack = ThreadLocal<[[Statement]]>()
 /// B2-1：当前 worker 线程正在执行的任务节点（取消上下文），与 currentEnv 同机制。
 /// 主线程为 nil（同步路径永不被取消，零开销）。
 private let tlCurrentFuture = ThreadLocal<FutureValue>()

 /// 调用深度护栏：无限递归以可诊断错误终止，而非打穿线程栈（零诊断崩溃）。
 /// 每层 Pini 函数调用对应数层 Swift 帧，上限取保守值，正常递归远不可及。
 private var callDepth = 0
 private let maxCallDepth = 120

 /// 并发调度脊柱（ADR-009 阶段 A）：解释器只依赖 `Scheduler` 协议，
 /// 当前后端为 `GCDScheduler`；阶段 B 可换挂起实现（`SuspendScheduler`）而不改调用点。
 var scheduler: Scheduler = GCDScheduler.shared

 /// 阶段 B（B-2 探针）开关：置 `true` 后，`await`/`wait` 在 Future 未决时抛 `SuspendSignal` 真正挂起
 /// （释放 OS 线程），由 `SuspendScheduler` 驱动续体恢复；默认 `false`，同步/阻塞路径完全不变。
 var suspendMode: Bool = false

 /// 完整 CPS 化：挂起任务状态（闭包即续体，见 SuspendEvaluator.swift）。
 var cpsTasks: [ObjectIdentifier: SuspendTaskCPS] = [:]
 let suspendTaskLock = NSLock()

 /// 当前任务的 Future（取消上下文）。worker 线程在执行异步体期间被设置；
 /// 其体内 `=>` 派发的子任务据此挂到本节点下，形成派发树 = 取消树。
 var currentFuture: FutureValue? {
 get { tlCurrentFuture.value }
 set { tlCurrentFuture.value = newValue }
 }

 /// B2-3 协作式取消检查点：若 `owner`（当前任务）已被取消，抛出 `taskCancelled` 中止任务体。
 ///
 /// 取消不抢占线程，而是在检查点处提前结束：任务体抛出后由 Scheduler reject，
 /// join 方因 `cancelled` 已置位恒得 `err(CancelError)`（见 `joinFuture`）。
 /// 同步路径 `owner == nil`，零开销。
 @inline(__always)
 func checkCancellation(_ owner: FutureValue?) throws {
 if let owner = owner, owner.isCancelled {
 throw FutureValue.cancelError()
 }
 }

 /// 读取线程本地当前任务并检查取消（热路径请改用带参版本，避免重复读线程字典）。
 @inline(__always)
 func checkCancellation() throws {
 try checkCancellation(currentFuture)
 }

 /// CPS 求值器（SuspendEvaluator.swift）需在本线程还原/保存 env。
 var currentEnv: Environment {
 get {
 if let e = tlCurrentEnv.value { return e }
 let e = Environment(enclosing: globalEnv)
 tlCurrentEnv.value = e
 return e
 }
 set { tlCurrentEnv.value = newValue }
 }

 /// CPS 求值器需跨挂起保存/还原 defer 栈。
 var deferStack: [[Statement]] {
 get { tlDeferStack.value ?? [] }
 set { tlDeferStack.value = newValue }
 }
 private var typeDefs: [String: TopLevelDecl] = [:]
 private var typeMethods: [String: [FuncDecl]] = [:]
 private var typeFields: [String: [FieldDecl]] = [:]
 private var typeTraits: [String: [String]] = [:]
 /// ADR-016 规则 3.2/3.14：扩展块方法（按目标类型名），供泛型特化复制合并。
 private var extMethodsByType: [String: [FuncDecl]] = [:]
 // G52 批 1：import 别名 → 被引入模块的运行时命名空间与 public 符号集
 private var importEnvs: [String: Environment] = [:]
 private var importPublicSymbols: [String: Set<String>] = [:]
 private var importAllSymbols: [String: Set<String>] = [:]

 /// Phase 2a（ADR-015 FFI）：原生函数表——`[名称|foreign]` 声明的 C 函数在此解析。
 /// 表为「预注册的 Swift 实现」（原生函数表方案，D1 解释器优先；dlsym 动态符号解析留后续）。
 private var nativeFunctions: [String: ([Value]) throws -> Value] = [:]
 /// 类型注册表锁：执行期 `typeFields`/`typeMethods`/`typeTraits`/`typeDefs` 会被 worker 线程
 /// 并发读写（泛型类型懒登记 + 成员解析），见下方 `withTypeRegistry`。加载期写入为单线程（执行开始前），
 /// 执行期所有访问须经此锁串行化，消除 Dictionary 并发读写 UB（D1 同族竞态）。
 /// 用 NSRecursiveLock：成员解析内的表达式求值可能再次进入本锁，可重入以避免自死锁。
 private let typeRegistryLock = NSRecursiveLock()
 /// 在 `typeRegistryLock` 保护下访问类型注册表（执行期读写均走此路径）。
 private func withTypeRegistry<T>(_ body: () -> T) -> T {
 typeRegistryLock.lock()
 defer { typeRegistryLock.unlock() }
 return body()
 }
 private var traits: [String: TraitDecl] = [:]
 public let arcManager = ARCManager()

 // MARK: - 调试支持（P7-4）

 /// 调试钩子：每条语句执行前被咨询（传 `DebugContext`）；返回 `.quit` 终止程序。
 /// 无调试器时为 nil，调用点 `guard let` 直接返回，**零运行时开销**。
 public var debugHook: ((DebugContext) throws -> DebugAction)? = nil
 /// 程序 stdout 输出通道（默认 stdout）。调试器/DAP 适配器可重定向，
 /// 例如将 debuggee 的 `print` 输出与协议流分离，避免污染 DAP stdio 传输。
 public var outputSink: (String) -> Void = { line in print(line) }
 /// 当前调用深度（main 体为 1，每进入一次函数体 +1）。用于 step-over 判定。
 /// 线程本地（D1 修复）：并发任务各自维护独立调用栈深度，避免与共享实例属性竞态——
 /// 此前该属性在 worker 线程上被无条件 += / -=，与 main 线程的同类操作产生数据竞争（SIGTRAP/SIGSEGV）。
 /// 与 currentEnv / deferStack 同机制（P5 Phase 2 已落地的线程本地化策略）。
 private let tlDebugDepth = ThreadLocal<Int>()
 /// CPS 求值器需跨挂起保存/还原调试深度。
 var debugDepth: Int {
 get { tlDebugDepth.value ?? 0 }
 set { tlDebugDepth.value = newValue }
 }
 /// 当前调用栈函数名（main 在最底）。用于 `backtrace` 展示。
 /// 线程本地（D1 修复）：同上，隔离各并发任务的调用栈快照。
 private let tlCallStackNames = ThreadLocal<[String]>()
 /// CPS 求值器需跨挂起保存/还原调用栈名。
 var callStackNames: [String] {
 get { tlCallStackNames.value ?? [] }
 set { tlCallStackNames.value = newValue }
 }

 /// Phase 2b（ADR-017 FFI dlsym）：合并后的 FFI 配置（搜索路径等）；默认系统路径。
 private var ffiConfig: FFIConfig = .default
 /// Phase 2b（ADR-017 FFI dlsym）：库名 → 句柄缓存 + 符号查找。
 private let ffiLoader = FFILoader()
 /// 批 5（G58，方案 A）：程序基准——模块运行的模块根 / 单文件运行的入口文件所在目录（均为绝对路径）。
 /// IO 相对路径解析基准；nil = 未注入（退回进程 CWD，REPL / 直建解释器的兼容行为）。
 private var programBase: String?
 /// 批 6 D-4：文件 → 该文件 `_` 前缀注入导入（别名 + 目标 public 符号集）。
 /// 裸名兜底的运行时依据；v1 边界：主模块文件生效，被引入模块内部各自的注入
 /// 不跨模块传递（其函数体裸名解析沿闭包环境链，见 loadImports 注释）。
 private var fileInjections: [String: [(alias: String, symbols: Set<String>)]] = [:]

 public init(ffiConfig: FFIConfig = .default, programBase: String? = nil) {
 self.ffiConfig = ffiConfig
 self.programBase = programBase
 self.globalEnv = Environment()
 self.currentEnv = globalEnv
 }

 /// 批 5（G58，D-1 方案 A）：IO 路径按形态三段式解析。
 /// - 绝对路径 → 原样；
 /// - `./` `../` 开头 → 运行时 CWD（原样传给 Foundation，即用户/shell 视角）；
 /// - 其余相对路径 → 程序基准（模块根 / 入口文件所在目录）；未注入基准时退回 CWD（兼容）。
 func resolveIOPath(_ path: String) -> String {
 if path.hasPrefix("/") { return path }
 if path.hasPrefix("./") || path.hasPrefix("../") { return path }
 guard let base = programBase else { return path }
 return base + "/" + path
 }

 public func run(module: Module) throws {
 try prepare(module: module)
 try executeMain()
 }

 /// G52 批 1（2026-08-31）：注册但不执行 main——被引入模块的准备入口。
 /// 递归加载本模块的 import 块（R2 禁环由 ModuleDependencyLoader 保证）。
 public func prepare(module: Module) throws {
 registerBuiltins()
 try loadImports(of: module)
 collectEnumCaseNames(module: module)
 try registerDecls(module: module)
 }

 /// 加载本模块 import 块声明的依赖模块：每个别名绑定一个子解释器
 /// （子模块自己的声明 + 递归加载其依赖），public 符号集用于跨模块门槛（D8）。
 private func loadImports(of module: Module) throws {
 let loader = ModuleDependencyLoader.shared
 for imp in module.imports {
 let dir = (imp.location.fileName as NSString).deletingLastPathComponent
 // R2：全图环检测（loadGraph 递归校验依赖链）
 let loaded = try loader.load(packagePath: imp.packagePath, relativeTo: dir)
 // 批 6 D-4：`_` 前缀别名 = 注入导入——记录文件级裸名表（#2 文件级；#4 可裸调用或 `_别名.符号`）
 if imp.alias.hasPrefix("_") {
 fileInjections[imp.location.fileName, default: []].append(
 (alias: imp.alias, symbols: loaded.publicSymbols))
 }
 // 批 5（G58）：子解释器继承同一程序基准——被引入模块内 IO 相对路径仍相对主程序基准。
 let child = Interpreter(ffiConfig: ffiConfig, programBase: programBase)
 try child.prepare(loaded: loaded)
 importEnvs[imp.alias] = child.globalEnv
 importPublicSymbols[imp.alias] = loaded.publicSymbols
 importAllSymbols[imp.alias] = loaded.allSymbols
 // 传递性合并：被引入模块自身的别名环境上提（跨模块体可能引用孙模块符号）
 for (a, env) in child.importEnvs where importEnvs[a] == nil {
 importEnvs[a] = env
 importPublicSymbols[a] = child.importPublicSymbols[a] ?? []
 importAllSymbols[a] = child.importAllSymbols[a] ?? []
 }
 }
 }

 /// 供 loadImports 递归复用已加载模块（不重复执行其 main——本函数不执行 main）。
 fileprivate func prepare(loaded: ModuleDependencyLoader.LoadedModule) throws {
 registerBuiltins()
 let loadedModule = try rebuildModule(from: loaded)
 try loadImports(of: loadedModule)
 collectEnumCaseNames(module: loadedModule)
 try registerDecls(module: loadedModule)
 }

 /// 从 LoadedModule 重组 Module（声明表中已含子模块自身的 import 块声明）。
 private func rebuildModule(from loaded: ModuleDependencyLoader.LoadedModule) throws -> Module {
 return Module(declarations: loaded.declarations, imports: loaded.imports, exports: [],
               location: SourceLocation(line: 0, column: 0, endLine: 0, endColumn: 0, fileName: loaded.rootPath))
 }

 // MARK: - #46-E G41（test 块，R1/R4）：pini test 的运行时执行入口

 /// 一次 `|test` 函数块的执行结果（供 CLI `pini test` 汇总报告）。
 public struct TestRunResult {
 public let name: String
 public let passed: Bool
 public let message: String
 public init(name: String, passed: Bool, message: String) {
 self.name = name
 self.passed = passed
 self.message = message
 }
 }

 /// 运行模块内所有顶级 `|test` 函数块（草稿「测试函数块必须显示声明|test」）。
 ///
 /// - 收集：顶层 `funcDecl` 且 `modifiers` 含 `"test"`；
 /// - 参数注入（R4，2026-08-24 拍板「允许参数注入」）：按参数声明顺序注入**类型零值**
 /// （I32→0 / F64→0.0 / Bool→false / String→"" / 无标注→null）；后续可按名/按上下文扩展注入协议；
 /// - 失败不中断：某测试抛错（如 `assert` 失败 → `RuntimeError.assertionFailed`）记为失败，
 /// 继续执行其余测试；`runTests` 自身仅对「注册/执行框架错误」抛错。
 /// - 不执行 `main`（测试入口独立于程序入口）。
 public func runTests(module: Module) throws -> [TestRunResult] {
 try prepare(module: module)
 var results: [TestRunResult] = []
 for decl in module.declarations {
 guard case .funcDecl(let f) = decl, f.modifiers.contains("test") else { continue }
 results.append(executeCollectedTest(f))
 }
 return results
 }

 /// G49（issue-tdd-module-blockers-2026-08-28）：包级测试收集——`pini test [path]` 模块模式的
 /// 运行时入口。注册包内**全部文件**声明（跨文件符号可见）后，仅执行 `fileScope` 命中的
 /// 文件单元中的顶级 `|test`（`fileScope == nil` = 模块全量收集）。执行语义与
 /// `runTests(module:)` 一致（参数注入零值、失败不中断）。
 public func runTests(package: Package, fileScope: ((String) -> Bool)? = nil) throws -> [TestRunResult] {
 registerBuiltins()
 collectEnumCaseNames(package: package)
 for unit in package.fileUnits {
 try registerDecls(module: unit.module)
 }
 var results: [TestRunResult] = []
 for unit in package.fileUnits {
 if let scope = fileScope, !scope(unit.fileName) { continue }
 for decl in unit.module.declarations {
 guard case .funcDecl(let f) = decl, f.modifiers.contains("test") else { continue }
 results.append(executeCollectedTest(f))
 }
 }
 return results
 }

 /// 单个已收集 `|test` 函数的执行（注册查询 + 零值注入 + 失败捕获），G41/G49 共用。
 private func executeCollectedTest(_ f: FuncDecl) -> TestRunResult {
 guard case .function(let fv)? = try? globalEnv.get(name: f.name) else {
 return TestRunResult(name: f.name, passed: false, message: "测试函数未注册到全局环境")
 }
 let args = f.params.map { zeroValueForTestParam($0) }
 do {
 _ = try callFunctionValue(fv, args: args)
 return TestRunResult(name: f.name, passed: true, message: "")
 } catch {
 return TestRunResult(name: f.name, passed: false, message: "\(error)")
 }
 }

 /// R4 参数注入：按类型标注注入零值（无标注注入 null）。
 private func zeroValueForTestParam(_ param: Parameter) -> Value {
 guard case .simple(let name, _)? = param.typeAnnotation else { return .null }
 switch name {
 case "I8", "I16", "I32", "I64", "Int": return .int(0)
 case "F32", "F64", "Float", "Double": return .float(0)
 case "Bool": return .bool(false)
 case "String": return .string("")
 default: return .null
 }
 }

 /// P4 Phase 4：运行包（多文件 / 单文件统一入口）。
 ///
 /// - 单文件包（`fileUnits.count <= 1`）直接委托 `run(module:)`，行为与旧单文件世界完全等价。
 /// - 多文件包：将包内**所有文件**的声明（类型 + 函数）注册进同一全局环境，
 /// 使跨文件（同模块）调用在运行时可被解析——可见性 enforce 已在 Phase 3 静态期完成，
 /// 故运行时无需再按可见性过滤（同模块内所有符号共享命名空间）。
 /// `main` 恒全局可见，因所有文件均已注册，跨文件定位 main 自然成立。
 public func run(package: Package) throws {
 if package.fileUnits.count <= 1 {
 let module = package.fileUnits.first?.module
 ?? Module(declarations: [], imports: [], exports: [],
 location: SourceLocation(line: 0, column: 0, fileName: package.name))
 try run(module: module)
 return
 }
 registerBuiltins()
 collectEnumCaseNames(package: package)
 for unit in package.fileUnits {
 // 批 6 修复（批 1 缺口，由批 6 工具链全链路实测暴露）：包模式运行从不加载 import 块，
 // `别名.符号` 在运行时因 importEnvs 为空而 E5-001。语义/类型检查各自加载（不受影响），
 // 唯运行路径漏掉——现补齐（与 prepare(module:) 对齐）。
 try loadImports(of: unit.module)
 try registerDecls(module: unit.module)
 }
 try executeMain()
 }

 // MARK: - 阶段 B（B-2 探针）挂起入口

 /// B-2 探针：注册内建 + 模块声明，**不执行** main。供挂起模式复用前端，
 /// 之后测试可反复 `runSuspendableEntry(main)` 验证有界池下的挂起行为。
 func prepareSuspend(_ module: Module) throws {
 registerBuiltins()
 collectEnumCaseNames(module: module)
 try registerDecls(module: module)
 }

 /// 取全局环境中的 `main` 函数值（挂起模式直接驱动，不经 `executeMain` 的同步路径）。
 func mainFunctionValue() -> FunctionValue? {
 guard case .function(let fv)? = try? globalEnv.get(name: "main") else { return nil }
 return fv
 }

 /// B-2 探针：跑一个模块，返回顶层 main 的 Future（挂起模式，`await`/`wait` 真正释放 OS 线程）。
 func runSuspendable(module: Module) throws -> FutureValue {
 try prepareSuspend(module)
 guard let main = mainFunctionValue() else {
 throw RuntimeError.mainNotFound(location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 return runSuspendableEntry(main)
 }

 /// B-2 探针：把 `fv` 作为挂起任务入队，返回其 Future；由 `SuspendScheduler` 驱动。
 /// 完整 CPS 化（B-2 完整版）：任务体经 `runSuspendableBodyCPS`（闭包即续体）执行，
 /// 任意表达式深度挂起、精确恢复、不重跑已执行副作用（取代语句游标重跑模型）。
 func runSuspendableEntry(_ fv: FunctionValue, args: [Value] = []) -> FutureValue {
 let future = FutureValue()
 let target = fv
 let boundArgs = args
 self.scheduler.spawn(future) { [weak self] in
 try self?.runSuspendableBodyCPS(future: future, fv: target, args: boundArgs)
 return .null
 }
 return future
 }

 // MARK: - 注册

 /// ADR-020 D2：语言内标准库成员实现表（typeName -> methodName -> FuncDecl）。
 /// 源 = StdlibPini.source，registerBuiltins 期解析（固化资产，失败 fail-fast）。
 private var stdlibMembers: [String: [String: FuncDecl]] = [:]

 /// 查询内建类型的语言内成员实现（Pini 下沉表）。
 fileprivate func stdlibMemberImpl(typeName: String, name: String) -> FuncDecl? {
 return stdlibMembers[typeName]?[name]
 }

 private func registerBuiltins() {
 // ADR-020 D3：运行时 FunctionValue 从单点登记表（BuiltinRegistry）派生——
 // 名字/形参/归属声明一次，三层各自取用；分发实现按函数值名在各 dispatch 分支，
 // 不进本表。专属路径（并发 registerConcurrencyBuiltins / 指针 registerPointerBuiltins /
 // 枚举构造器）定义表中 definesRuntimeValue = false 的条目，互不重叠。
 for decl in BuiltinRegistry.decls where decl.definesRuntimeValue {
 let fn = FunctionValue(
 name: decl.name,
 params: decl.paramNames.map { Parameter(name: $0) },
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: decl.name, value: .function(fn), isMutable: false)
 }

 // 并发内建（ok/err/Error/CancelError/isCancel/joinAll/joinWithin）：专属路径，
 // 覆盖表中 definesRuntimeValue = false 的条目（ADR-020 D3）。
 registerConcurrencyBuiltins()

 // 内置 Error 特征（空特征）
 let errorTrait = TraitDecl(
 name: "Error",
 genericParams: [],
 signatures: [],
 location: SourceLocation(line: 0, column: 0, fileName: "<builtin>")
 )
 traits["Error"] = errorTrait

 // Phase 2a（ADR-015 FFI）：指针原语内建（load/store/addressof， 经 runtime bk_*）。
 registerPointerBuiltins()

 // Phase 2a（ADR-015 FFI）：libc 原生函数表（`[名称|foreign]` 声明解析）。
 registerNativeFunctions()

 // ADR-020 D2：解析语言内标准库源（Pini 实现表）。固化资产，解析失败 fail-fast。
 do {
 let stdlibTokens = try Lexer(source: StdlibPini.source, fileName: "<stdlib.pini>").tokenize()
 let stdlibModule = try Parser(tokens: stdlibTokens, fileName: "<stdlib.pini>").parseModule()
 var impls: [String: [String: FuncDecl]] = [:]
 for decl in stdlibModule.declarations {
 if case .extensionDecl(let ext) = decl {
 for m in ext.methods { impls[ext.targetType, default: [:]][m.name] = m }
 }
 }
 stdlibMembers = impls
 } catch {
 fatalError("StdlibPini source broken: \(error)")
 }
 }

 // MARK: - Phase 2a ADR-015 FFI：指针原语内建

 private func registerPointerBuiltins() {
 let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

 // load(p)：按指针元素类型读出一个值。
 let loadFunc = FunctionValue(
 name: "load",
 params: [Parameter(name: "p", typeAnnotation: .pointer(element: .simple(name: "U8", location: loc), location: loc))],
 returnTypes: [],
 body: nil, decl: nil, closure: globalEnv
 )
 loadFunc.nativeImpl = { [weak self] args in
 guard let self else { throw RuntimeError.invalidOperation(reason: "load：解释器已销毁", location: loc) }
 let rp = try Self.ptrArg(args, name: "load", self: self)
 return try self.decodePointer(rp)
 }
 globalEnv.define(name: "load", value: .function(loadFunc), isMutable: false)

 // store(p, v)：把值按指针元素类型写入。
 let storeFunc = FunctionValue(
 name: "store",
 params: [Parameter(name: "p"), Parameter(name: "v")],
 returnTypes: [],
 body: nil, decl: nil, closure: globalEnv
 )
 storeFunc.nativeImpl = { [weak self] args in
 guard let self else { throw RuntimeError.invalidOperation(reason: "store：解释器已销毁", location: loc) }
 guard args.count >= 2 else { throw RuntimeError.argumentCountMismatch(name: "store", expected: 2, got: args.count, location: loc) }
 guard case .rawPointer(let rp) = args[0] else {
 throw RuntimeError.invalidOperation(reason: "store 的第一个参数必须是 `*T` 指针", location: loc)
 }
 try self.encode(args[1], to: rp.pointer, type: rp.elemType)
 return .null
 }
 globalEnv.define(name: "store", value: .function(storeFunc), isMutable: false)

 // addressof(v)：对值分配内存写入并返回指针（= `&v` 的函数形式；解释器快照语义）。
 let addrFunc = FunctionValue(
 name: "addressof",
 params: [Parameter(name: "v")],
 returnTypes: [],
 body: nil, decl: nil, closure: globalEnv
 )
 addrFunc.nativeImpl = { [weak self] args in
 guard let self else { throw RuntimeError.invalidOperation(reason: "addressof：解释器已销毁", location: loc) }
 guard args.count >= 1 else { throw RuntimeError.argumentCountMismatch(name: "addressof", expected: 1, got: args.count, location: loc) }
 return try self.snapshotPointer(of: args[0], location: loc)
 }
 globalEnv.define(name: "addressof", value: .function(addrFunc), isMutable: false)
 }

 // MARK: - Phase 2a ADR-015 FFI：libc 原生函数表

 /// 预注册 libc 内存/字符串函数（原生函数表方案，D1 解释器优先）。
 /// 平台不支持（非 Darwin/Glibc）时留空表——`[名称|foreign]` 声明未解析函数在注册期报错。
 private func registerNativeFunctions() {
 #if canImport(Darwin) || canImport(Glibc)
 let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

 // malloc(size: U64) -> *U8：C 语义——内存归用户，free 释放。
 nativeFunctions["malloc"] = { args in
 let n = try Self.intArg(args, name: "malloc")
 guard let p = malloc(n) else {
 throw RuntimeError.invalidOperation(reason: "malloc 失败：内存不足", location: loc)
 }
 return .rawPointer(RawPointerValue(
 pointer: p,
 elemType: .simple(name: "U8", location: loc),
 ownsMemory: false
 ))
 }

 // free(p: *U8) -> ()：C 语义。
 nativeFunctions["free"] = { args in
 let p = try Self.ptrArg(args, name: "free", self: nil)
 free(p.pointer)
 return .null
 }

 // memcpy(dst: *U8, src: *U8, n: U64) -> *U8。
 nativeFunctions["memcpy"] = { args in
 guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memcpy", expected: 3, got: args.count, location: loc) }
 guard case .rawPointer(let dst) = args[0] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 1 参须为指针", location: loc) }
 guard case .rawPointer(let src) = args[1] else { throw RuntimeError.invalidOperation(reason: "memcpy 第 2 参须为指针", location: loc) }
 let n = try Self.intArg(args, name: "memcpy", offset: 2)
 memcpy(dst.pointer, src.pointer, n)
 return args[0]
 }

 // memset(p: *U8, v: I32, n: U64) -> *U8。
 nativeFunctions["memset"] = { args in
 guard args.count >= 3 else { throw RuntimeError.argumentCountMismatch(name: "memset", expected: 3, got: args.count, location: loc) }
 guard case .rawPointer(let p) = args[0] else { throw RuntimeError.invalidOperation(reason: "memset 第 1 参须为指针", location: loc) }
 let v = try Self.intArg(args, name: "memset", offset: 1)
 let n = try Self.intArg(args, name: "memset", offset: 2)
 memset(p.pointer, Int32(truncatingIfNeeded: v), n)
 return args[0]
 }

 // strlen(s: *U8) -> U64。
 nativeFunctions["strlen"] = { args in
 let p = try Self.ptrArg(args, name: "strlen", self: nil)
 let s = p.pointer.assumingMemoryBound(to: CChar.self)
 return .int(strlen(s))
 }

 // puts(s: *U8) -> I32：向 stdout 写一行 C 字符串。
 nativeFunctions["puts"] = { args in
 let p = try Self.ptrArg(args, name: "puts", self: nil)
 let s = p.pointer.assumingMemoryBound(to: CChar.self)
 let r = puts(s)
 return .int(Int(r))
 }

 // strcmp(a: *U8, b: *U8) -> I32。
 nativeFunctions["strcmp"] = { args in
 guard args.count >= 2 else { throw RuntimeError.argumentCountMismatch(name: "strcmp", expected: 2, got: args.count, location: loc) }
 guard case .rawPointer(let a) = args[0] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 1 参须为指针", location: loc) }
 guard case .rawPointer(let b) = args[1] else { throw RuntimeError.invalidOperation(reason: "strcmp 第 2 参须为指针", location: loc) }
 let r = strcmp(a.pointer.assumingMemoryBound(to: CChar.self),
 b.pointer.assumingMemoryBound(to: CChar.self))
 return .int(Int(r))
 }

 // cstr(s: String) -> *U8：把 Pini 字符串转成 null 结尾的 C 字符串（malloc 分配，用户 free）。
 nativeFunctions["cstr"] = { args in
 guard args.count >= 1 else { throw RuntimeError.argumentCountMismatch(name: "cstr", expected: 1, got: args.count, location: loc) }
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(reason: "cstr：第 1 个参数须为 String", location: loc)
 }
 let bytes = Array(s.utf8)
 guard let ptr = malloc(bytes.count + 1) else {
 throw RuntimeError.invalidOperation(reason: "cstr：malloc 失败", location: loc)
 }
 if bytes.count > 0 { memcpy(ptr, bytes, bytes.count) }
 ptr.advanced(by: bytes.count).storeBytes(of: 0, as: UInt8.self) // null terminator
 return .rawPointer(RawPointerValue(
 pointer: ptr,
 elemType: .simple(name: "U8", location: loc),
 ownsMemory: false
 ))
 }
 #endif
 }

 // MARK: - Phase 2a ADR-015 FFI：指针编解码辅助

 /// `&v` 快照取址（解释器限制）：分配内存写入值的 C 表示并返回指针。
 /// 与 LLVM 端的真引用不同——写回不更新原变量（文档化限制，见 CHANGELOG）。
 private func snapshotPointer(of value: Value, location: SourceLocation) throws -> Value {
 switch value {
 case .rawPointer(let rp):
 // 指针取址：返回自身（地址即值；`*T` 的 T 保持元素类型不变）。
 return value
 default:
 let elem = RawPointerValue.elemType(for: value) ?? .simple(name: "U8", location: location)
 let stride = RawPointerValue.stride(of: elem) ?? 1
 let ptr = UnsafeMutableRawPointer.allocate(byteCount: stride, alignment: 1)
 try encode(value, to: ptr, type: elem)
 return .rawPointer(RawPointerValue(pointer: ptr, elemType: elem, ownsMemory: true))
 }
 }

 /// 从指针读出一个值（load 语义）。
 private func decodePointer(_ rp: RawPointerValue) throws -> Value {
 let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
 guard let elem = rp.elemType else {
 throw RuntimeError.invalidOperation(reason: "load：指针元素类型未知（`&` 快照 / malloc 未标注 `*T` 元素）", location: loc)
 }
 switch elem {
 case .simple(let name, _):
 switch name {
 case "I8", "U8": return .int(Int(rp.pointer.load(as: Int8.self)))
 case "I16", "U16": return .int(Int(rp.pointer.load(as: Int16.self)))
 case "I32", "U32": return .int(Int(rp.pointer.load(as: Int32.self)))
 case "I64", "U64": return .int(rp.pointer.load(as: Int.self))
 case "F32": return .float(Double(rp.pointer.load(as: Float.self)))
 case "F64": return .float(rp.pointer.load(as: Double.self))
 case "Bool": return .bool(rp.pointer.load(as: Bool.self))
 case "Char": return .int(Int(rp.pointer.load(as: UInt8.self)))
 default:
 throw RuntimeError.invalidOperation(reason: "load：不支持的指针元素类型 `\(name)`", location: loc)
 }
 case .pointer:
 let p = rp.pointer.load(as: UnsafeMutableRawPointer.self)
 return .rawPointer(RawPointerValue(pointer: p, elemType: elem, ownsMemory: false))
 default:
 throw RuntimeError.invalidOperation(reason: "load：不支持的指针元素类型 `\(elem.describe())`", location: loc)
 }
 }

 /// 把一个值按元素类型编码写入指针（store 语义）。
 private func encode(_ value: Value, to ptr: UnsafeMutableRawPointer, type: TypeAnnotation?) throws {
 let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
 guard let elem = type else {
 throw RuntimeError.invalidOperation(reason: "store：指针元素类型未知", location: loc)
 }
 switch elem {
 case .simple(let name, _):
 switch name {
 case "I8", "U8":
 guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: Int8(truncatingIfNeeded: i), as: Int8.self)
 case "I16", "U16":
 guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: Int16(truncatingIfNeeded: i), as: Int16.self)
 case "I32", "U32":
 guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: Int32(truncatingIfNeeded: i), as: Int32.self)
 case "I64", "U64":
 guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: i, as: Int.self)
 case "F32":
 guard case .float(let f) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: Float(f), as: Float.self)
 case "F64":
 guard case .float(let f) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: f, as: Double.self)
 case "Bool":
 guard case .bool(let b) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: b, as: Bool.self)
 case "Char":
 guard case .int(let i) = value else { throw Self.typeMismatch(name: name, value: value, loc: loc) }
 ptr.storeBytes(of: UInt8(truncatingIfNeeded: i), as: UInt8.self)
 default:
 throw RuntimeError.invalidOperation(reason: "store：不支持的指针元素类型 `\(name)`", location: loc)
 }
 case .pointer:
 guard case .rawPointer(let rp) = value else { throw Self.typeMismatch(name: "*\(elem.describe())", value: value, loc: loc) }
 ptr.storeBytes(of: rp.pointer, as: UnsafeMutableRawPointer.self)
 default:
 throw RuntimeError.invalidOperation(reason: "store：不支持的指针元素类型 `\(elem.describe())`", location: loc)
 }
 }

 private static func typeMismatch(name: String, value: Value, loc: SourceLocation) -> RuntimeError {
 RuntimeError.invalidOperation(reason: "store：期望 `\(name)`，实际 \(Self.valueKindName(value))", location: loc)
 }

 private static func valueKindName(_ v: Value) -> String {
 switch v {
 case .int: return "int"
 case .float: return "float"
 case .bool: return "bool"
 case .string: return "string"
 case .rawPointer: return "指针"
 default: return "其它"
 }
 }

 private static func intArg(_ args: [Value], name: String, offset: Int = 0) throws -> Int {
 guard args.count > offset else {
 throw RuntimeError.argumentCountMismatch(name: name, expected: offset + 1, got: args.count,
 location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 guard case .int(let v) = args[offset] else {
 throw RuntimeError.invalidOperation(
 reason: "\(name)：第 \(offset + 1) 个参数须为整型",
 location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 return v
 }

 private static func ptrArg(_ args: [Value], name: String, self: AnyObject?) throws -> RawPointerValue {
 guard !args.isEmpty else {
 throw RuntimeError.argumentCountMismatch(name: name, expected: 1, got: args.count,
 location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 guard case .rawPointer(let rp) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "\(name)：第 1 个参数须为 `*T` 指针",
 location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 return rp
 }

 /// 预扫描：统计枚举 case 名的父枚举归属并判定歧义（同名跨枚举 → 歧义，
 /// 须改用 形状.圆(...) 限定写法，避免 globalEnv 互相覆盖）。
 ///
 /// 必须在**任何** registerDecls 之前、对**全部**文件完成：否则单个文件的局部
 /// 统计会把仅在该文件出现的 case 名判为不歧义并注册到 globalEnv，而后处理文件
 /// 的同名 case 会覆盖它（构造到错误的父枚举）。
 func collectEnumCaseNames(module: Module) {
 for decl in module.declarations {
 if case .enumDecl(let e) = decl {
 for ec in e.cases { enumCaseNameParents[ec.name, default: []].insert(e.name) }
 }
 }
 ambiguousEnumCases = Set(enumCaseNameParents.filter { $0.value.count > 1 }.map { $0.key })
 }

 /// 包级预扫描：对包内所有文件单元累积统计（跨文件可见性的前提）。
 func collectEnumCaseNames(package: Package) {
 for unit in package.fileUnits { collectEnumCaseNames(module: unit.module) }
 }

 private func registerDecls(module: Module) throws {
 // 第一遍：注册所有类型定义（不处理组合）
 for decl in module.declarations {
 switch decl {
 case .structDecl(let s):
 typeDefs[s.name] = .structDecl(s)
 typeFields[s.name] = s.fields
 typeMethods[s.name] = s.methods
 typeTraits[s.name] = s.traits
 case .objectDecl(let o):
 typeDefs[o.name] = .objectDecl(o)
 typeFields[o.name] = o.fields
 typeMethods[o.name] = o.methods
 typeTraits[o.name] = o.traits
 case .enumDecl(let e):
 typeDefs[e.name] = .enumDecl(e)
 typeMethods[e.name] = e.methods
 case .traitDecl(let t):
 traits[t.name] = t
 default:
 break
 }
 }

 // ADR-016 规则 3.2/3.14：收集扩展块方法（typeMethods 合并 + 泛型特化复制源）。
 // 扩展块可与类型声明任意顺序出现，故在类型注册后统一合并。
 var extMethodsByType: [String: [FuncDecl]] = [:]
 for decl in module.declarations {
 if case .extensionDecl(let x) = decl {

 if x.kind == .traitExt {
 if let t = traits[x.targetType] {
 traits[x.targetType] = TraitDecl(name: t.name, genericParams: t.genericParams, signatures: t.signatures + x.methods, location: t.location)
 }
 } else {
 extMethodsByType[x.targetType, default: []].append(contentsOf: x.methods)
 }
 }
 }
 self.extMethodsByType = extMethodsByType
 for (typeName, methods) in extMethodsByType {
 typeMethods[typeName] = (typeMethods[typeName] ?? []) + methods
 }

 // 第二遍：处理类型组合（合并父类型字段和方法），并注册构造器
 for decl in module.declarations {
 switch decl {
 case .structDecl(let s):
 if let parent = s.composedType {
 try checkComposedTypeAllowed(parent: parent)
 // ADR-016 规则 3.2/3.14：子类型方法含扩展块方法（类型体自身已无方法）。
 let allChildMethods = s.methods + (extMethodsByType[s.name] ?? [])
 mergeComposedType(child: s.name, parent: parent,
 childFields: s.fields, childMethods: allChildMethods)
 }
 registerTypeConstructor(typeName: s.name, kind: .structKind)
 case .objectDecl(let o):
 registerTypeConstructor(typeName: o.name, kind: .objectKind)
 case .enumDecl(let e):
 let isGeneric = !e.genericParams.isEmpty
 for (index, enumCase) in e.cases.enumerated() {
 let defaults = enumCase.associatedParams.map { param in
 param.defaultValue
 }
 registerEnumCaseConstructor(
 caseName: enumCase.name,
 associatedParams: enumCase.associatedParams,
 isGeneric: isGeneric,
 parentName: e.name,
 genericParamCount: e.genericParams.count,
 enumParamDefaults: defaults
 )
 }
 case .funcDecl(let f):
 // 同时登记到 typeDefs，供运行时 genericConstruct 识别泛型函数调用并单态化
 typeDefs[f.name] = .funcDecl(f)
 let fv = FunctionValue(
 name: f.name,
 params: f.params,
 returnTypes: f.returnTypes,
 body: f.body,
 decl: f,
 closure: globalEnv
 )
 globalEnv.define(name: f.name, value: .function(fv), isMutable: false)
 default:
 break
 }
 }

 // Phase 2a（ADR-015 FFI）：foreign 块注册——外部 C 函数经原生函数表解析为 Swift 实现。
 // 未注册的原生函数在注册期报错（fail-fast），提示可用原生函数表。
 for decl in module.declarations {
 if case .foreignDecl(let fd) = decl {
 for f in fd.funcs {
 // fd.name（块名）即库绑定键（Phase 2b 升级，ADR-017）。
 let native = try resolveForeignImpl(f, library: fd.name, location: f.location)
 let fv = FunctionValue(
 name: f.name,
 params: f.params,
 returnTypes: f.returnTypes,
 body: nil,
 decl: f,
 closure: globalEnv
 )
 fv.nativeImpl = native
 globalEnv.define(name: f.name, value: .function(fv), isMutable: false)
 }
 }
 }
 }

 /// 解析 `[名称|foreign]` 块内函数的实现。
 /// 解析顺序固定：① 预注册 shim 白名单（nativeFunctions）→ ② 裸 C 绑定（dlsym，Phase 2b）。
 private func resolveForeignImpl(_ f: FuncDecl, library: String, location: SourceLocation) throws -> ([Value]) throws -> Value {
 // ① shim 白名单优先（cstr 等 Pini 友好签名）。
 if let native = nativeFunctions[f.name] { return native }
 // ② 裸 C 绑定：dlsym 查符号 + 每签名 thunk 工厂。
 let sym = try ffiLoader.resolve(library: library, symbol: f.name, searchPaths: ffiConfig.searchPaths, location: location)
 return try ForeignThunk.make(symbol: sym, decl: f, location: location)
 }

 private func checkComposedTypeAllowed(parent: String) throws {
 if let parentDecl = typeDefs[parent] {
 if case .objectDecl = parentDecl {
 throw RuntimeError.invalidOperation(
 reason: "引用块不可组合",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 }

 /// 合并类型组合的父类型字段和方法（子类型同名定义覆盖父类型）
 private func mergeComposedType(
 child: String,
 parent: String,
 childFields: [FieldDecl],
 childMethods: [FuncDecl]
 ) {
 guard let parentFields = typeFields[parent] else { return }
 guard let parentMethods = typeMethods[parent] else { return }

 let childFieldNames = Set(childFields.map { $0.name })
 var mergedFields = childFields
 for f in parentFields where !childFieldNames.contains(f.name) {
 mergedFields.append(f)
 }
 typeFields[child] = mergedFields

 let childMethodNames = Set(childMethods.map { $0.name })
 var mergedMethods = childMethods
 for m in parentMethods where !childMethodNames.contains(m.name) {
 mergedMethods.append(m)
 }
 typeMethods[child] = mergedMethods
 }

 private func registerTypeConstructor(typeName: String, kind: FunctionValue.TypeKind) {
 let fv = FunctionValue(
 name: typeName,
 params: [],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 fv.isTypeConstructor = true
 fv.typeKind = kind
 fv.typeName = typeName
 globalEnv.define(name: typeName, value: .function(fv), isMutable: false)
 }

 /// P5-5 B2：枚举 case 构造器按 (父枚举 → case) 注册，供限定构造 形状.圆(...) 解析。
 /// 键为 parentName → caseName → 构造 FunctionValue；未限定全局函数仅在 case 名全局唯一时注册。
 private var enumCaseConstructors: [String: [String: FunctionValue]] = [:]

 /// P5-5 B2 跨文件修正（H1，2026-08-30）：case 名 → 父枚举名集合，**跨文件累积**。
 /// 此前该统计是 registerDecls 的局部变量、每次调用整体覆盖，导致包内后处理的
 /// 文件看不到先前文件的枚举，未限定 case 构造器因此漏注册到 globalEnv
 /// （外部表现为「枚举 case 是文件作用域」）。
 private var enumCaseNameParents: [String: Set<String>] = [:]
 /// 跨枚举同名的歧义 case 名集合（预扫描填充）：这些名不挂未限定全局函数。
 private var ambiguousEnumCases: Set<String> = []

 private func registerEnumCaseConstructor(
 caseName: String,
 associatedParams: [AssociatedParam],
 isGeneric: Bool = false,
 parentName: String = "",
 genericParamCount: Int = 0,
 enumParamDefaults: [Expression?] = []
 ) {
 let params = associatedParams.enumerated().map { i, ap in
 let paramName = ap.name ?? "arg\(i)"
 return Parameter(name: paramName)
 }
 let fv = FunctionValue(
 name: caseName,
 params: params,
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 fv.isEnumCaseConstructor = true
 fv.enumCaseName = caseName
 fv.enumParamDefaults = enumParamDefaults
 fv.enumIsGeneric = isGeneric
 fv.enumParentName = parentName
 fv.enumGenericParamCount = genericParamCount
 fv.enumCaseParamTypeNames = associatedParams.map { $0.type.describe() }
 // P5-5 B2：按 (父枚举 → case) 注册，供限定构造 形状.圆(...) 解析（跨枚举同名不冲突）。
 if enumCaseConstructors[parentName] == nil { enumCaseConstructors[parentName] = [:] }
 enumCaseConstructors[parentName]![caseName] = fv
 // 未限定全局函数仅当 case 名全局唯一时注册；同名跨枚举（歧义）不挂全局，
 // 迫使调用方改用限定写法，避免 globalEnv 互相覆盖导致构造到错误父枚举。
 if ambiguousEnumCases.contains(caseName) { return }
 globalEnv.define(name: caseName, value: .function(fv), isMutable: false)
 }


 // MARK: - 立场 B 并发内建（Result / Error）

 /// 内建错误类型名与 Result 枚举名（与 TypeChecker.registerConcurrencyBuiltins 对齐）。
 static let builtinErrorTypeName = "Error"
 static let builtinResultEnumName = "Result"
 /// B2-1（Q5·表示法 A）：取消专用错误类型，与业务 `Error` 并列的独立结构；
 /// 类型层白名单允许它出现在期望 `Error` 的位置，用户用 `isCancel(e)` 判别。
 static let builtinCancelErrorTypeName = "CancelError"

 /// 注册 `Result<T, E>` 的用例构造器 `ok` / `err`，以及内建默认错误构造 `Error("msg")`。
 /// 用户若自行声明同名枚举/类型，registerDecls 会覆盖这些内建（后注册优先），行为与既有语义一致。
 private func registerConcurrencyBuiltins() {
 registerEnumCaseConstructor(
 caseName: "ok",
 associatedParams: [AssociatedParam(name: nil, type: .simple(name: "T", location: Interpreter.builtinLocation))],
 isGeneric: true,
 parentName: Interpreter.builtinResultEnumName,
 genericParamCount: 2
 )
 registerEnumCaseConstructor(
 caseName: "err",
 associatedParams: [AssociatedParam(name: nil, type: .simple(name: "E", location: Interpreter.builtinLocation))],
 isGeneric: true,
 parentName: Interpreter.builtinResultEnumName,
 genericParamCount: 2
 )

 let errorFunc = FunctionValue(
 name: Interpreter.builtinErrorTypeName,
 params: [Parameter(name: "message")],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: Interpreter.builtinErrorTypeName, value: .function(errorFunc), isMutable: false)

 // B2-1：CancelError("msg") 构造 + isCancel(e) 判别谓词。
 let cancelErrorFunc = FunctionValue(
 name: Interpreter.builtinCancelErrorTypeName,
 params: [Parameter(name: "message")],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: Interpreter.builtinCancelErrorTypeName, value: .function(cancelErrorFunc), isMutable: false)

 let isCancelFunc = FunctionValue(
 name: "isCancel",
 params: [Parameter(name: "e")],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: "isCancel", value: .function(isCancelFunc), isMutable: false)

 // B2-4（Q3）：joinAll([a, b, c]) → Future<[T], Error>，再 `await`/`wait` 一次完成多任务汇合。
 let joinAllFunc = FunctionValue(
 name: "joinAll",
 params: [Parameter(name: "futures")],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: "joinAll", value: .function(joinAllFunc), isMutable: false)

 // B2-5（Q5·超时）：joinWithin(t, ms) → Result<T, Error>，超时归约为 err(CancelError)。
 // 刻意做成内建函数而非 `within` 语法糖：超时是库能力，不值得占用语法预算。
 let joinWithinFunc = FunctionValue(
 name: "joinWithin",
 params: [Parameter(name: "future"), Parameter(name: "ms")],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: globalEnv
 )
 globalEnv.define(name: "joinWithin", value: .function(joinWithinFunc), isMutable: false)

 // 任务 #13：detach 由内建函数升格为语句关键字 `detach <expr>`（ detach-expr-stmt）。
 // 剪枝逻辑在 executeStatement 的 .detachStatement 分支；此处不再注册内建。
 }

 static let builtinLocation = SourceLocation(line: 0, column: 0, fileName: "<builtin>")

 /// `await`/`wait` join：阻塞当前线程直至 Future 完成，结果恒归一为 `Result<T, Error>` 值（错误即数据，不抛出）。
 /// - 体已返回 `Result` 用例（`return ok(v)` / `return err(e)`）→ 原样透传；
 /// - 体返回普通值（含 `=> ()` 无值返回的 `.null`）→ 自动包 `ok(v)`；
 /// - 体执行抛出运行时错误 → 归约为 `err(Error("..."))`。
 /// - 任务被取消（手动 / 父返回 / 超时）→ 归约为 `err(CancelError("..."))`（B2-1）。
 func joinFuture(_ fut: FutureValue) -> Value {
 return joinFuture(fut, timeoutMs: nil)
 }

 /// `joinWithin(t, ms)`（B2-5）：至多等待 `ms` 毫秒的阻塞 join。
 ///
 /// 超时归约到取消（契约）：到点即 `t.cancel()` 并返回 `err(CancelError("任务超时: Nms"))`，
 /// 因此超时与手动取消在调用方看来同构，`isCancel(e)` 对两者都为 true。
 /// 取消是协作式的：被取消的任务在下一个检查点结束，不会被强杀。
 func joinFuture(_ fut: FutureValue, timeoutMs: Int?) -> Value {
 // 被 join 的子任务脱离父节点：生命周期已被显式消费，不再受「父返回自动取消」约束（B2-2）。
 defer { fut.detachFromParent() }
 do {
 let value: Value
 if let timeoutMs = timeoutMs {
 guard let joined = try fut.wait(timeout: Double(max(0, timeoutMs)) / 1000.0) else {
 fut.cancel()
 return Interpreter.makeResult(
 caseName: "err",
 payload: Interpreter.makeCancelError("任务超时: \(timeoutMs)ms")
 )
 }
 value = joined
 } else {
 value = try fut.wait()
 }
 if Interpreter.isResultValue(value) { return value }
 return Interpreter.makeResult(caseName: "ok", payload: value)
 } catch RuntimeError.taskCancelled(let reason, _) {
 return Interpreter.makeResult(
 caseName: "err",
 payload: Interpreter.makeCancelError(reason)
 )
 } catch let runtimeError as RuntimeError {
 return Interpreter.makeResult(
 caseName: "err",
 payload: Interpreter.makeError(runtimeError.description)
 )
 } catch {
 return Interpreter.makeResult(
 caseName: "err",
 payload: Interpreter.makeError("\(error)")
 )
 }
 }

 /// B2-4（Q3）：`joinAll([a, b, c])` → 聚合 `Future<[T], Error>`。
 ///
 /// 语义（契约）：
 /// - 全部成功 → `ok([v1, v2, ...])`，顺序与入参一致；
 /// - **fail-fast**：任一成员归约为 `err(e)`（业务错误或取消）→ 聚合立刻返回该 `err`，
 /// 并取消其余尚未完成的成员（结构化：无人再等的任务不该继续烧线程）；
 /// - 聚合节点自身被 `cancel()` → 经 `onCancel` 联动取消全部成员。
 /// 成员的父作用域保持不变（聚合不篡改父链），仅做取消联动。
 private func makeJoinAllFuture(_ argument: Value) throws -> Value {
 guard case .array(let items) = argument else {
 throw RuntimeError.typeMismatch(
 expected: "Array<Future<T, Error>>",
 got: describeValueKind(argument),
 location: Interpreter.builtinLocation
 )
 }
 var members: [FutureValue] = []
 for item in items {
 guard case .future(let fut) = item else {
 throw RuntimeError.typeMismatch(
 expected: "Future<T, Error>",
 got: describeValueKind(item),
 location: Interpreter.builtinLocation
 )
 }
 members.append(fut)
 }

 let aggregate = FutureValue()
 currentFuture?.addChild(aggregate)
 aggregate.onCancel { members.forEach { $0.cancel() } }

 let captured = members
 self.scheduler.spawn(aggregate) { [weak self] in
 guard let self = self else {
 throw RuntimeError.invalidOperation(
 reason: "joinAll 执行时解释器已释放",
 location: Interpreter.builtinLocation
 )
 }
 let previousFuture = self.currentFuture
 self.currentFuture = aggregate
 defer {
 aggregate.cancelUnjoinedChildren()
 self.currentFuture = previousFuture
 }

 var values: [Value] = []
 for (index, member) in captured.enumerated() {
 try self.checkCancellation(aggregate)
 let joined = self.joinFuture(member)
 guard case .enumValue(let ev) = joined else { continue }
 if ev.caseName == "err" {
 // fail-fast：放弃其余成员，避免无人等待的任务继续占用线程池
 for rest in captured.dropFirst(index + 1) where !rest.isFinished {
 rest.cancel()
 }
 // 显式 resolve：调度器无关（GCD 用返回值 resolve、SuspendScheduler 由 work 自行
 // resolve——统一在此 resolve，两种后端都正确，重复 resolve 由 isResolved 守卫忽略）。
 aggregate.resolve(joined)
 return .null
 }
 values.append(ev.associatedValues.first ?? .null)
 }
 aggregate.resolve(Interpreter.makeResult(caseName: "ok", payload: .array(values)))
 return .null
 }
 return .future(aggregate)
 }

 // 跨文件 extension（SuspendEvaluator）复用，访问级别由 private 放宽为 internal。
 func describeValueKind(_ value: Value) -> String {
 switch value {
 case .int: return "I32"
 case .float: return "F64"
 case .string: return "String"
 case .bool: return "Bool"
 case .tuple: return "Tuple"
 case .array: return "Array"
 case .dictionary: return "Dictionary"
 case .set: return "Set"
 case .structInstance(let si): return si.typeName
 case .objectReference(let obj): return obj.typeName
 case .enumValue(let ev): return ev.parentEnum ?? ev.caseName
 case .function: return "Function"
 case .future: return "Future"
 case .weakRef: return "WeakRef"
 case .lazyRef: return "LazyRef"
 case .rawPointer: return "Pointer"
 case .null: return "Null"
 }
 }

 /// 构造内建错误值 `Error { message }`。
 static func makeError(_ message: String) -> Value {
 return .structInstance(StructInstance(
 typeName: builtinErrorTypeName,
 fields: ["message": .string(message)]
 ))
 }

 /// 构造取消错误值 `CancelError { message }`（B2-1）。
 static func makeCancelError(_ message: String) -> Value {
 return .structInstance(StructInstance(
 typeName: builtinCancelErrorTypeName,
 fields: ["message": .string(message)]
 ))
 }

 /// 判定一个值是否为取消错误（内建谓词 `isCancel(e)` 的实现）。
 static func isCancelErrorValue(_ value: Value) -> Bool {
 guard case .structInstance(let si) = value else { return false }
 return si.typeName == builtinCancelErrorTypeName
 }

 /// 构造 `Result` 用例值。
 static func makeResult(caseName: String, payload: Value) -> Value {
 return .enumValue(EnumValue(
 caseName: caseName,
 associatedValues: [payload],
 paramNames: [nil],
 parentEnum: builtinResultEnumName
 ))
 }

 /// 判定一个值是否已是 `Result` 用例（`ok` / `err`）。
 static func isResultValue(_ value: Value) -> Bool {
 guard case .enumValue(let ev) = value else { return false }
 if ev.parentEnum == builtinResultEnumName { return true }
 return false
 }

 /// 判定一个值是否为 `Result` 的 `err` 用例（`ok` 返回 false）。
 static func isErrResultValue(_ value: Value) -> Bool {
 guard case .enumValue(let ev) = value else { return false }
 return ev.parentEnum == builtinResultEnumName && ev.caseName == "err"
 }

 /// （甲）唯一有界 override：函数局部结果为 `ok(v)`（或裸值）却存在 leaked 失败子任务时，
 /// 收口结果翻为 `err(aggregate)`；局部已显式 `err` 则不覆盖（errors-as-data 已有失败值）。
 /// 翻转发生在显式 `return` 边界、以 `Result` 值形式、可被 `await`/`wait` 取 `Result` 后 `match`——不构成隐式注入。
 func flipIfLeaked(_ result: Value, leaked: [Value]) -> Value {
 guard !leaked.isEmpty else { return result }
 if Interpreter.isErrResultValue(result) { return result }
 let detail = leaked.map { stringify($0) }.joined(separator: "; ")
 return Interpreter.makeResult(
 caseName: "err",
 payload: Interpreter.makeError("未 join 子任务失败（结构化并发兜底）: " + detail)
 )
 }

 private func executeMain() throws {
 guard let mainVal = try? globalEnv.get(name: "main") else {
 throw RuntimeError.mainNotFound(location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 guard case .function(let fv) = mainVal else {
 throw RuntimeError.notCallable(location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 let result = try callFunctionValue(fv, args: [])
 // 立场 B：若 main 自身是 `=>` 进程，其返回的是 pending Future，须 join 至完成。
 // main 的 `err` 无处可交（顶层无调用者），归约为程序级运行时错误（非静默成功）。
 if case .future(let fut) = result {
 let joined = joinFuture(fut)
 if case .enumValue(let ev) = joined,
 ev.parentEnum == Interpreter.builtinResultEnumName,
 ev.caseName == "err" {
 let detail = ev.associatedValues.first.map { stringify($0) } ?? "未知错误"
 throw RuntimeError.invalidOperation(
 reason: "main 以 err 结束: \(detail)",
 location: Interpreter.builtinLocation
 )
 }
 } else if case .int(let v) = result {
 _ = v
 }
 }

 func copyIfStruct(_ value: Value) -> Value {
 if case .structInstance(let si) = value {
 var copiedFields: [String: Value] = [:]
 for (k, v) in si.fields {
 copiedFields[k] = copyIfStruct(v)
 }
 return .structInstance(StructInstance(typeName: si.typeName, fields: copiedFields))
 }
 return value
 }

 // MARK: - 语句执行

 // MARK: 调试钩子辅助

 /// 在每条语句执行前咨询调试器；命中时由 `Debugger` 驱动交互，返回 `.quit` 抛错终止。
 private func debugPause(_ stmt: Statement) throws {
 guard let hook = debugHook else { return }
 let loc: SourceLocation
 switch stmt {
 case .varDecl(_, _, _, _, let l): loc = l
 case .varDestructure(_, _, _, _, let l): loc = l
 case .assign(_, _, let l): loc = l
 case .returnStatement(_, let l): loc = l
 case .breakStatement(_, let l): loc = l
 case .continueStatement(_, let l): loc = l
 case .ifStatement(_, _, _, _, _, let l): loc = l
 case .whileStatement(_, _, _, _, let l): loc = l
 case .forStatement(_, _, _, _, _, let l): loc = l
 case .matchStatement(_, _, let l): loc = l
 case .tryStatement(_, _, _, let l): loc = l
 case .detachStatement(_, let l): loc = l
 case .expressionStmt(_, let l): loc = l
 case .deferStatement(_, let l): loc = l
 case .passStatement(let l): loc = l
 case .captureStatement(_, let l): loc = l
 case .scopedBlock(_, _, let l): loc = l
 }
 let ctx = DebugContext(
 location: loc,
 depth: debugDepth,
 callStack: callStackNames,
 variables: currentEnv.listBindings().map { ($0.name, stringify($0.value)) }
 )
 if try hook(ctx) == .quit {
 throw DebuggerError.quit
 }
 }

 /// 执行一条表达式语句并求值其结果，统一处理后缀 `++`/`--`（标识符上）的回写。
 /// 被 `executeStatement` 与 `executeFunctionBody` 共用，避免内联逻辑重复，
 /// 保证函数体内裸表达式语句同样能命中调试钩子。
 @discardableResult
 func runExpressionStatement(_ expr: Expression) throws -> Value {
 let result = try evaluateExpression(expr)
 if case .unary(let op, let operand, _) = expr,
 case .identifier(let name, _) = operand,
 op == .increment || op == .decrement {
 try currentEnv.assign(name: name, value: result)
 }
 return result
 }

 /// #46-D D1.5：递归完成下标写（支持嵌套路径 `m[0][1] = v` 与 `obj.arr[i] = v`）。
 /// 数组在解释器侧为值语义，故每层写都产生新容器值并写回上一层，最终绑定到根变量 / 对象字段。
 /// 与 LLVM 端 `generateSubscriptWrite` 形成双后端锁步（LLVM 经 opaque handle 原生支持任意嵌套）。
 func writeSubscript(target: Expression, index: Value, newValue: Value, location: SourceLocation) throws {
 switch target {
 case .identifier(let name, _):
 let cur = try currentEnv.get(name: name)
 let newC = try SubscriptWriteStrategy.write(container: cur, index: index, newValue: newValue, location: location)
 try currentEnv.assign(name: name, value: newC)
 case .member(let obj, let field, _):
 // 复用 .member 赋值的不可变校验（let 绑定 struct/object 字段写拦截）。
 let objValue = try evaluateExpression(obj)
 if case .identifier(let rootName, _) = obj, rootName != "self" {
 if case .structInstance = objValue {
 if let mutable = currentEnv.isMutable(name: rootName), !mutable {
 throw RuntimeError.immutableVariable(name: rootName, location: location)
 }
 }
 }
 let cur: Value
 switch objValue {
 case .structInstance(let si): cur = si.fields[field] ?? .null
 case .objectReference(let or): cur = or.fields[field] ?? .null
 default:
 throw RuntimeError.invalidOperation(reason: "无法对对象下标写: \(objValue)", location: location)
 }
 let newC = try SubscriptWriteStrategy.write(container: cur, index: index, newValue: newValue, location: location)
 if case .structInstance(let si) = objValue { si.fields[field] = newC }
 else if case .objectReference(let or) = objValue { or.fields[field] = newC }
 case .subscript(let outerContainer, let innerIndexExpr, _):
 // 嵌套：`m[0][1] = v` 的调用约定是 target = `m[0]`、index = 1。
 // 故本层被写的容器值是 **target 自身求值**（`m[0]`），而不是上一层容器（`m`）——
 // 取错会把内层值写进外层槽位（#46-D D4.2.2 修复：`[[99,[3,4]],[3,4]]` 类错误结构）。
 // 写出新内层后，再以 `m[0]` 的下标（innerIdx=0）递归写回上一层容器 `m`。
 let innerIdx = try evaluateExpression(innerIndexExpr)
 let innerContainerVal = try evaluateExpression(target)
 let newInner = try SubscriptWriteStrategy.write(container: innerContainerVal, index: index, newValue: newValue, location: location)
 try writeSubscript(target: outerContainer, index: innerIdx, newValue: newInner, location: location)
 default:
 throw RuntimeError.invalidOperation(reason: "不支持的下标赋值目标: \(target)", location: location)
 }
 }

 public func executeStatement(_ stmt: Statement) throws {
 try debugPause(stmt)
 switch stmt {
 case .varDecl(let name, let typeAnnotation, let initializer, let isMutable, _):
 let value: Value
 if let initializer = initializer {
 value = copyIfStruct(try evaluateExpression(initializer))
 } else {
 value = .null
 }
 // 草稿 A2（批次 1.3，D1）：位置字面量绑定命名元组类型时，以类型注解补写值标签。
 currentEnv.define(name: name, value: applyTypeAnnotationLabels(typeAnnotation, to: value), isMutable: isMutable)
 case .varDestructure(let names, _, let initializer, let isMutable, let location):
 // 草稿 A1（批次 1）：求值右值元组并逐分量绑定（`_` 占位跳过）。
 guard let initializer = initializer else {
 throw RuntimeError.invalidOperation(reason: "解构声明缺少初始值", location: location)
 }
 let value = copyIfStruct(try evaluateExpression(initializer))
 guard case .tuple(_, let elements) = value else {
 throw RuntimeError.typeMismatch(expected: "tuple", got: describeValueKind(value), location: location)
 }
 guard names.count == elements.count else {
 throw RuntimeError.invalidOperation(
 reason: "解构分量数不匹配：声明 \(names.count) 个，元组 \(elements.count) 个",
 location: location
 )
 }
 for (i, name) in names.enumerated() where name != "_" {
 currentEnv.define(name: name, value: elements[i], isMutable: isMutable)
 }
 case .returnStatement(let value, _):
 let returnValue: Value?
 if let value = value {
 returnValue = try evaluateExpression(value)
 } else {
 returnValue = nil
 }
 throw ControlSignal.returnSignal(returnValue)
 case .detachStatement(let expr, let detachLoc):
 // 任务 #13：`detach <expr>` 剪枝子任务（fire-and-forget 唯一合法出口）。
 let value = try evaluateExpression(expr)
 guard case .future(let fut) = value else {
 throw RuntimeError.typeMismatch(
 expected: "Future<T, Error>",
 got: describeValueKind(value),
 location: detachLoc
 )
 }
 fut.detachFromParent()
 case .expressionStmt(let expr, _):
 _ = try runExpressionStatement(expr)
 case .assign(let target, let value, let location):
 let v = copyIfStruct(try evaluateExpression(value))
 switch target {
 case .identifier(let name):
 try currentEnv.assign(name: name, value: v)
 case .member(let obj, let name):
 // 先求值接收者，以区分值类型（struct）与引用类型（object）；字段写细节见
 // `performMemberAssign`（同步路径与 CPS 求值器共用，避免语义分叉）。
 let objValue = try evaluateExpression(obj)
 try performMemberAssign(objValue: objValue, objExpr: obj, name: name, value: v, location: location)
 case .subscript(let containerExpr, let indexExpr):
 // #46-D D1.5：数组下标写 `a[i] = v`（含嵌套 m[0][1]=v、obj.arr[i]=v）。
 // 数组为值语义 → 写策略返回新容器值，递归写回路径上每一层后重新绑定。
 let idx = try evaluateExpression(indexExpr)
 try writeSubscript(target: containerExpr, index: idx, newValue: v, location: location)
 }
 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, let label, _):
 try executeIf(condition: condition, thenBlock: thenBlock, elifs: elifs, elseBlock: elseBlock, label: label)
 case .whileStatement(let condition, let body, let step, let label, _):
 try executeWhile(condition: condition, body: body, step: step, label: label)
 case .forStatement(let pattern, let iterable, let body, let step, let label, let location):
 try executeFor(pattern: pattern, iterable: iterable, body: body, step: step, label: label, location: location)
 case .matchStatement(let value, let cases, let location):
 try executeMatch(value: value, cases: cases, location: location)
 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 try executeTry(expression: expression, tryBlock: tryBlock, exceptClauses: exceptClauses)
 case .breakStatement(let label, _):
 throw ControlSignal.breakSignal(label: label)
 case .continueStatement(let label, _):
 throw ControlSignal.continueSignal(label: label)
 case .deferStatement(let statement, _):
 guard !deferStack.isEmpty else {
 throw RuntimeError.invalidOperation(reason: "defer 必须在块作用域内使用", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 deferStack[deferStack.count - 1].append(statement)
 case .passStatement(_):
 return
 case .captureStatement:
 // H-1：capture 是静态纯度声明，运行时无操作（捕获经环境链自然达成）
 return
 case .scopedBlock(let label, let body, _):
 try executeScope(label: label, body: body)
 default:
 throw RuntimeError.invalidOperation(reason: "未实现的语句类型", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }

 /// 字段写：struct 值语义（let 整体不可变 → 拒绝）/ object 引用语义（内容可变）分派
 /// + P4.5 type-private 约束。同步路径与 CPS 求值器共用，避免语义分叉。
 func performMemberAssign(objValue: Value, objExpr: Expression, name: String, value: Value, location: SourceLocation) throws {
 // P4.5：字段写受 type-private 约束（与读对称）；写入方须为声明类型自身方法。
 // 仅对「确已注册的用户类型」强制，排除内建类型与 WeakRef。
 if name.hasPrefix("_") {
 let declaringType: String? = {
 switch objValue {
 case .structInstance(let si): return si.typeName
 case .objectReference(let oref): return oref.typeName
 default: return nil
 }
 }()
 if let t = declaringType, withTypeRegistry({ typeFields[t] != nil }) {
 let accessor = currentSelfTypeName()
 if accessor != t {
 throw RuntimeError.inaccessibleField(typeName: t, fieldName: name, location: location)
 }
 }
 }
 // struct 为值语义：let 绑定整体不可变 → 字段写必须拒绝（self 豁免）。
 if case .identifier(let rootName, _) = objExpr, rootName != "self" {
 if case .structInstance = objValue {
 if let mutable = currentEnv.isMutable(name: rootName), !mutable {
 throw RuntimeError.immutableVariable(name: rootName, location: location)
 }
 }
 }
 if case .structInstance(let si) = objValue {
 si.fields[name] = value
 } else if case .objectReference(let or) = objValue {
 or.fields[name] = value
 } else {
 throw RuntimeError.invalidOperation(reason: "无法赋值的对象类型", location: location)
 }
 }

 // MARK: - 表达式求值

 public func evaluateExpression(_ expr: Expression) throws -> Value {
 switch expr {
 case .integerLiteral(let v, _): return .int(v)
 case .floatLiteral(let v, _): return .float(v)
 case .stringLiteral(let v, _): return .string(v)
 case .stringInterpolation(let segments, _):
 var result = ""
 for seg in segments {
 switch seg {
 case .literal(let s): result += s
 case .expression(let e):
 let v = try evaluateExpression(e)
 result += stringify(v)
 }
 }
 return .string(result)
 case .boolLiteral(let v, _): return .bool(v)
 case .identifier(let name, let identLoc):
 if name == "self" {
 return try currentEnv.get(name: "self")
 }
 let value: Value
 do {
 value = try currentEnv.get(name: name)
 } catch {
 // 批 6 D-4：裸名兜底——本文件注入的 public 符号（全导入；冲突已在语义层排除）。
 if let injected = try resolveInjectedBare(name, location: identLoc) {
 value = injected
 } else {
 throw error
 }
 }
 if case .function(let fv) = value, fv.isEnumCaseConstructor, fv.params.isEmpty {
 return .enumValue(EnumValue(
 caseName: fv.enumCaseName,
 associatedValues: [],
 parentEnum: fv.enumParentName.isEmpty ? nil : fv.enumParentName
 ))
 }
 return value
 case .binary(let left, let op, let right, _):
 let l = try evaluateExpression(left)
 let r = try evaluateExpression(right)
 return try evaluateBinaryOp(l, op, r)
 case .unary(let op, let operand, let location):
 if op == .forceUnwrap {
 // 后缀强制解包 `!`：some(x) → x；none → trap（与严格枚举语义一致，强制取元素时越界即崩溃）。
 let v = try evaluateExpression(operand)
 guard case .enumValue(let ev) = v else {
 throw RuntimeError.invalidOperation(reason: "强制解包 `!` 的操作数不是 Optional 值: \(v)", location: location)
 }
 if ev.caseName == "some", let inner = ev.associatedValues.first {
 return inner
 }
 if ev.caseName == "none" {
 throw RuntimeError.invalidOperation(reason: "强制解包 `!` 命中 Optional.none（元素不存在）", location: location)
 }
 throw RuntimeError.invalidOperation(reason: "强制解包 `!` 的操作数不是 Optional 值: \(v)", location: location)
 }
 let v = try evaluateExpression(operand)
 return try evaluateUnaryOp(op, v)
 case .call(let callee, let arguments, let loc):
 // P5-5 B2：限定枚举构造 形状.圆(...) → 直接解析 (父→case) 注册表构造，
 // 无需 globalEnv 全局函数（支持跨枚举同名 case 不冲突）。
 if case .member(let objExpr, let caseName, _) = callee,
 case .identifier(let parentName, _) = objExpr,
 let ctor = enumCaseConstructors[parentName]?[caseName] {
 var argValues: [Value] = []
 for arg in arguments { argValues.append(try evaluateExpression(arg.expression)) }
 return try callFunctionValue(ctor, args: argValues)
 }

 // ADR-026 D1（静态收敛版）：歧义 case 的裸名构造 → 查静态决议表。
 // checker 在期望类型命中的构造位记录父枚举；无记录 = 未静态解析 → 报错
 // 要求限定形式。运行期不做动态猜测（case 由复合类型确定，不由实参嗅探）。
 if case .identifier(let caseName, _) = callee,
 ambiguousEnumCases.contains(caseName),
 (try? globalEnv.get(name: caseName)) == nil {
 guard let parent = BareCaseResolutionRegistry.parent(at: loc),
 let ctor = enumCaseConstructors[parent]?[caseName] else {
 throw RuntimeError.invalidOperation(
 reason: "歧义 case 构造 \(caseName) 缺少可解析的期望类型，请使用限定形式 枚举名.\(caseName)(...)",
 location: loc
 )
 }
 var argValues: [Value] = []
 for arg in arguments { argValues.append(try evaluateExpression(arg.expression)) }
 return try callFunctionValue(ctor, args: argValues)
 }

 if case .member(let objExpr, let memberName, _) = callee,
 case .identifier(let typeName, _) = objExpr,
 typeName == "Optional" {
 switch memberName {
 case "some":
 guard !arguments.isEmpty else {
 throw RuntimeError.invalidOperation(reason: "Optional.some 需要一个参数", location: loc)
 }
 let value = try evaluateExpression(arguments[0].expression)
 return .enumValue(EnumValue(caseName: "some", associatedValues: [value]))
 case "none":
 return .enumValue(EnumValue(caseName: "none", associatedValues: []))
 default:
 break
 }
 }

 if case .identifier(let funcName, _) = callee, funcName == "WeakRef", arguments.count == 1 {
 let targetVal = try evaluateExpression(arguments[0].expression)
 guard case .objectReference(let obj) = targetVal else {
 throw RuntimeError.invalidOperation(reason: "WeakRef 只能引用 object 类型", location: loc)
 }
 // G42（Ref 系引用语义）：独立 class box 承载（weakRetain 在 box init、weakRelease 在 deinit，
 // 对称配对）；复制共享同一 box，非 StructInstance 值拷贝。
 return .weakRef(WeakRefBox(target: obj, manager: arcManager))
 }

 // G40（LazyRef，D1 推断糖）：`LazyRef(初始化闭包)` —— 类型推断形态，与显式 `LazyRef<T>(闭包)` 同语义。
 if case .identifier(let funcName, _) = callee, funcName == "LazyRef", arguments.count == 1 {
 let argVal = try evaluateExpression(arguments[0].expression)
 return try makeLazyRefBox(from: argVal, location: loc)
 }

 let calleeValue = try evaluateExpression(callee)
 guard case .function(let fv) = calleeValue else {
 throw RuntimeError.notCallable(location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 
 var argValues: [Value] = []
 let hasLabeledArgs = arguments.contains { $0.label != nil }
 
 if hasLabeledArgs {
 var orderedArgs: [Value] = Array(repeating: .null, count: fv.params.count)
 for (i, arg) in arguments.enumerated() {
 let value = try evaluateExpression(arg.expression)
 if let label = arg.label {
 if let paramIdx = fv.params.firstIndex(where: { $0.name == label }) {
 orderedArgs[paramIdx] = value
 } else {
 throw RuntimeError.invalidOperation(reason: "未知参数名: \(label)", location: loc)
 }
 } else {
 if i < orderedArgs.count {
 orderedArgs[i] = value
 }
 }
 }
 argValues = orderedArgs
 } else {
 for arg in arguments {
 argValues.append(try evaluateExpression(arg.expression))
 }
 }
 
 return try callFunctionValue(fv, args: argValues)
 case .tuple(let labels, let elements, _):
 // 草稿 A2（批次 1.3，D1）：命名元组字面量把标签传入运行时值（labels 与 elements 一一对应）。
 var values: [Value] = []
 for e in elements {
 values.append(try evaluateExpression(e))
 }
 return .tuple(labels: labels, elements: values)
 case .arrayLiteral(let elements, _):
 var values: [Value] = []
 for e in elements {
 values.append(try evaluateExpression(e))
 }
 return .array(values)
 case .dictionaryLiteral(let entries, _):
 var result: [(Value, Value)] = []
 for entry in entries {
 let kv = try evaluateExpression(entry.key)
 let vv = try evaluateExpression(entry.value)
 result.append((kv, vv))
 }
 return .dictionary(result)
 case .setLiteral(let elements, _):
 var values: [Value] = []
 for e in elements {
 let v = try evaluateExpression(e)
 if !values.contains(v) { values.append(v) }
 }
 return .set(values)
 case .subscript(let containerExpr, let indexExpr, let loc):
 // 容器是任意表达式（非 identifier-only）：先求值再按容器类型策略化分派。
 let container = try evaluateExpression(containerExpr)
 let index = try evaluateExpression(indexExpr)
 return try SubscriptReadStrategy.read(container: container, index: index, location: loc)
 case .genericConstruct(let typeName, let typeArgs, let arguments, let loc):
 // G40（LazyRef，D1 显式优先）：`LazyRef<T>(初始化闭包)` —— 内建泛型包装类型，
 // 在 typeDefs 查询之前特判（LazyRef 非用户注册类型）。
 if typeName == "LazyRef" {
 guard arguments.count == 1 else {
 throw RuntimeError.invalidOperation(
 reason: "LazyRef 构造需要恰 1 个参数（初始化闭包），实际 \(arguments.count)",
 location: loc
 )
 }
 let argVal = try evaluateExpression(arguments[0].expression)
 return try makeLazyRefBox(from: argVal, location: loc)
 }
 // P5 B0-1：泛型枚举用例构造器——ok<I32,String>(42) 优先于类型/函数分派。
 // 用例构造器注册在 globalEnv（非 typeDefs），故先在此识别泛型枚举用例。
 if let val = try? globalEnv.get(name: typeName),
 case .function(let fv) = val, fv.isEnumCaseConstructor, fv.enumIsGeneric {
 guard fv.enumGenericParamCount == typeArgs.count else {
 throw RuntimeError.invalidOperation(
 reason: "泛型枚举 \(fv.enumParentName) 的用例 \(typeName) 实参个数不符：期望 \(fv.enumGenericParamCount)，实际 \(typeArgs.count)",
 location: loc
 )
 }
 let parent = fv.enumParentName + "<" + typeArgs.map { $0.describe() }.joined(separator: ", ") + ">"
 var argValues: [Value] = []
 for arg in arguments { argValues.append(try evaluateExpression(arg.expression)) }
 return .enumValue(EnumValue(
 caseName: fv.enumCaseName,
 associatedValues: argValues,
 paramNames: [],
 parentEnum: parent
 ))
 }
 // P3-0：运行时单态化（monomorphization，闭合张力 T10）+ 泛型函数调用点单态化
 guard let decl = withTypeRegistry({ typeDefs[typeName] }) else {
 throw RuntimeError.invalidOperation(reason: "未定义的泛型类型: \(typeName)", location: loc)
 }
 // P3-0：泛型函数调用点单态化——name 对应函数声明时，单态化后立即执行调用
 // （genericConstruct 节点已含调用实参 arguments；若仅返回 .function 会使嵌套实参误传函数值）。
 // 运行时执行不解析 body 内类型注解（var x: T 的 T 被忽略），故直接包 FunctionValue 执行即可。
 if case .funcDecl(let f) = decl {
 guard f.genericParams.count == typeArgs.count else {
 throw RuntimeError.invalidOperation(
 reason: "泛型函数 \(typeName) 实参个数不符：期望 \(f.genericParams.count)，实际 \(typeArgs.count)",
 location: loc
 )
 }
 let specializedName = "\(typeName)<\(typeArgs.map { $0.describe() }.joined(separator: ","))>"
 let fv = FunctionValue(
 name: specializedName,
 params: f.params,
 returnTypes: f.returnTypes,
 body: f.body,
 decl: f,
 closure: globalEnv
 )
 var argValues: [Value] = []
 for arg in arguments { argValues.append(try evaluateExpression(arg.expression)) }
 return try callFunctionValue(fv, args: argValues)
 }
 // 以下为泛型类型构造（struct/object）：懒登记字段/方法/特性后走 createInstance
 let specializedName = TypeAnnotation.generic(name: typeName, params: typeArgs, location: loc).describe()
 withTypeRegistry {
 if typeFields[specializedName] == nil {
 switch decl {
 case .structDecl(let s):
 typeFields[specializedName] = s.fields
 typeMethods[specializedName] = s.methods + (extMethodsByType[s.name] ?? [])
 typeTraits[specializedName] = s.traits
 case .objectDecl(let o):
 typeFields[specializedName] = o.fields
 typeMethods[specializedName] = o.methods + (extMethodsByType[o.name] ?? [])
 typeTraits[specializedName] = o.traits
 default:
 break
 }
 typeDefs[specializedName] = decl
 }
 }
 let kind: FunctionValue.TypeKind
 switch decl {
 case .objectDecl:
 kind = .objectKind
 default:
 kind = .structKind
 }
 return try createInstance(typeName: specializedName, kind: kind)
 case .member(let object, let name, let loc):
 // G52 批 1：`别名.符号` 跨模块限定访问（D-2：只走跨模块通道）
 if case .identifier(let aliasName, _) = object, importEnvs[aliasName] != nil {
 return try resolveQualified(alias: aliasName, symbol: name, location: loc)
 }
 if case .identifier(let typeName, _) = object, typeName == "Optional" {
 if name == "none" {
 return .enumValue(EnumValue(caseName: "none", associatedValues: []))
 }
 }
 let objValue = try evaluateExpression(object)
 return try evaluateMember(objValue, memberName: name, location: loc)
 case .tupleIndex(let object, let index, let loc):
 // 草稿 A2（批次 1）：`.0` 位置访问——求值 object 后按索引取元组元素。
 let objValue = try evaluateExpression(object)
 return try evaluateTupleIndex(objValue, index: index, location: loc)
 case .selfKeyword(_):
 return try currentEnv.get(name: "self")
 case .funcLiteral(let decl, _):
 let fv = FunctionValue(
 name: decl.name,
 params: decl.params,
 returnTypes: decl.returnTypes,
 body: decl.body,
 decl: nil,
 closure: currentEnv
 )
 if decl.isAsync { fv.markAsync() }
 return .function(fv)
 case .selfTypeKeyword(_):
 throw RuntimeError.invalidOperation(reason: "Self 关键字不能在运行时求值", location: SourceLocation(line: 0, column: 0, fileName: ""))
 case .join(let inner, let loc):
 // B2-3 检查点：阻塞点前先看自己是否已被取消，避免「已取消的任务仍去等别人」。
 try checkCancellation()
 let v = try evaluateExpression(inner)
 guard case .future(let fut) = v else {
 // （G12）：`await`/`wait` 仅接受 Future/Chan；对普通值 join 是错误
 // （静态期已由 TypeChecker 拦截，此处为运行时兜底，覆盖类型不可推断的路径）。
 throw RuntimeError.typeMismatch(
 expected: "Future<T, Error>",
 got: describeValueKind(v),
 location: loc
 )
 }
 if suspendMode, !fut.isFinished {
 // 真正挂起——抛 SuspendSignal 交 CPS 求值器（runSuspendableBodyCPS）登记续体，
 // 释放当前 OS 线程（非阻塞）。同步路径（suspendMode=false）仍走阻塞 joinFuture。
 throw SuspendSignal(future: fut)
 }
 return joinFuture(fut)
 case .resultUnwrap(let operand, let loc):
 // 草稿 A2（批次 1.4，D2）：`^expr` 解包 Result 值——`ok(v)` → v；
 // `err(e)` → 抛 UnwrapErrSignal 交函数边界捕获（错误注入返回元组末槽）。
 let v = try evaluateExpression(operand)
 guard case .enumValue(let ev) = v, ev.parentEnum == "Result" else {
 throw RuntimeError.typeMismatch(expected: "Result", got: describeValueKind(v), location: loc)
 }
 if ev.caseName == "ok" {
 return ev.associatedValues.first ?? .null
 }
 throw UnwrapErrSignal(error: ev.associatedValues.first ?? .null)
 case .unsafe(let operand, _):
 // Phase 2a（ADR-015 FFI）：`unsafe expr` 不安全消耗点——求值操作数即可
 // （不安全上下文对解释器无运行时屏障；静态约束由 TypeChecker 承载）。
 return try evaluateExpression(operand)
 case .addressOf(let operand, let loc):
 // Phase 2a（ADR-015 FFI）：`&x` 不安全取地址——解释器快照语义：
 // 指针值返回自身；其它值分配内存写入 C 表示后返回指针（写回不更新原变量，文档化限制）。
 return try snapshotPointer(of: evaluateExpression(operand), location: loc)
 default:
 throw RuntimeError.invalidOperation(reason: "未实现的表达式类型", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }
 func evaluateBinaryOp(_ l: Value, _ op: BinaryOperator, _ r: Value) throws -> Value {
 switch (l, r, op) {
 case (.int(let a), .int(let b), .plus): return .int(a + b)
 case (.int(let a), .int(let b), .minus): return .int(a - b)
 case (.int(let a), .int(let b), .multiply): return .int(a * b)
 case (.int(let a), .int(let b), .divide):
 if b == 0 { throw RuntimeError.divisionByZero(location: SourceLocation(line: 0, column: 0, fileName: "")) }
 return .int(a / b)
 case (.int(let a), .int(let b), .modulo):
 if b == 0 { throw RuntimeError.divisionByZero(location: SourceLocation(line: 0, column: 0, fileName: "")) }
 return .int(a % b)
 case (.int(let a), .int(let b), .equal): return .bool(a == b)
 case (.int(let a), .int(let b), .notEqual): return .bool(a != b)
 case (.int(let a), .int(let b), .lessThan): return .bool(a < b)
 case (.int(let a), .int(let b), .lessThanOrEqual): return .bool(a <= b)
 case (.int(let a), .int(let b), .greaterThan): return .bool(a > b)
 case (.int(let a), .int(let b), .greaterThanOrEqual): return .bool(a >= b)
 case (.float(let a), .float(let b), .plus): return .float(a + b)
 case (.float(let a), .float(let b), .minus): return .float(a - b)
 case (.float(let a), .float(let b), .multiply): return .float(a * b)
 case (.float(let a), .float(let b), .divide): return .float(a / b)
 case (.string(let a), .string(let b), .plus): return .string(a + b)
 case (.string(let a), .string(let b), .equal): return .bool(a == b)
 // ADR-020 D2 试点发现：String 缺 notEqual 分派（语言内 contains 需要）——补齐。
 case (.string(let a), .string(let b), .notEqual): return .bool(a != b)
 case (.bool(let a), .bool(let b), .equal): return .bool(a == b)
 case (.bool(let a), .bool(let b), .notEqual): return .bool(a != b)
 case (.bool(let a), .bool(let b), .and): return .bool(a && b)
 case (.bool(let a), .bool(let b), .or): return .bool(a || b)
 case (.int(let a), .int(let b), .bitwiseAnd): return .int(a & b)
 case (.int(let a), .int(let b), .bitwiseOr): return .int(a | b)
 case (.int(let a), .int(let b), .bitwiseXor): return .int(a ^ b)
 case (.int(let a), .int(let b), .leftShift): return .int(a << b)
 case (.int(let a), .int(let b), .rightShift): return .int(a >> b)
 default:
 throw RuntimeError.typeMismatch(expected: "compatible", got: "\(l), \(r)", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }

 func evaluateUnaryOp(_ op: UnaryOperator, _ v: Value) throws -> Value {
 switch (op, v) {
 case (.minus, .int(let a)): return .int(-a)
 case (.plus, .int(let a)): return .int(a)
 case (.not, .bool(let a)): return .bool(!a)
 case (.increment, .int(let a)): return .int(a + 1)
 case (.decrement, .int(let a)): return .int(a - 1)
 case (.bitwiseNot, .int(let a)): return .int(~a)
 case (.minus, .float(let a)): return .float(-a)
 case (.plus, .float(let a)): return .float(a)
 default:
 throw RuntimeError.invalidOperation(reason: "无效的一元运算", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }

 /// 将实例字段注入方法闭包环境，使方法体内可直接引用字段（读取）。
 /// 与类型层/语义层方法体字段可见性保持一致（P3-1 示例 trait.pini 的覆盖方法
 /// `描述|self()` 返回 `名字` 字段触发此需求）。字段以不可变绑定注入；
 /// 方法内字段写入仍应走 `self.字段 = ...` 成员赋值路径。
 private func bindInstanceFields(_ env: Environment, fields: [String: Value]) {
 for (name, value) in fields {
 env.define(name: name, value: value, isMutable: false)
 }
 }

 /// 当前访问者类型：若正处于某类型的方法体内，`self` 绑定在当前环境链中，
 /// 取其类型名即为「当前方法所属类型」；不在任何方法体内时 `self` 未定义，返回 nil。
 private func currentSelfTypeName() -> String? {
 do {
 let selfVal = try currentEnv.get(name: "self")
 switch selfVal {
 case .structInstance(let si): return si.typeName
 case .objectReference(let oref): return oref.typeName
 default: return nil
 }
 } catch {
 return nil
 }
 }

 /// 元组位置访问求值（草稿 A2，批次 1）：`.0` / `.1` 取元组第 index 个元素。
 /// 非元组对象或索引越界均报运行错误（类型层另有静态拦截）。
 func evaluateTupleIndex(_ objValue: Value, index: Int, location: SourceLocation) throws -> Value {
 guard case .tuple(_, let elements) = objValue else {
 throw RuntimeError.typeMismatch(expected: "tuple", got: describeValueKind(objValue), location: location)
 }
 guard index >= 0 && index < elements.count else {
 throw RuntimeError.invalidOperation(
 reason: "元组索引越界：index \(index)，元组大小 \(elements.count)",
 location: location
 )
 }
 return elements[index]
 }

 /// 草稿 A2（批次 1.3，D1）：命名元组类型注解给值补写标签——位置字面量绑定到命名类型时，
 /// 值的 labels 以类型注解为准，`.名称` 标签访问才能命中；非命名元组类型或值原样返回。
 func applyTypeAnnotationLabels(_ typeAnnotation: TypeAnnotation?, to value: Value) -> Value {
 guard let ta = typeAnnotation, case .tuple(let labels, _, _) = ta else { return value }
 guard case .tuple(_, let elements) = value else { return value }
 return .tuple(labels: labels, elements: elements)
 }

 /// 草稿 A2（批次 1.3，D1）：函数命名返回元组给结果值补写标签——函数体 `return (a, b)` 为位置
 /// 元组，声明 `-> (商: I32, 余: I32,)` 的 returnLabels 补写后 `.名称` 访问才可命中。
 func applyReturnLabels(_ labels: [String?], to value: Value) -> Value {
 guard !labels.isEmpty else { return value }
 guard case .tuple(_, let elements) = value, elements.count == labels.count else { return value }
 return .tuple(labels: labels, elements: elements)
 }

 /// 草稿 A2（批次 1.4，D2）：`^` 解包 err 的控制返回值——
 /// 返回元组（分量数 = 函数返回类型数）末槽注入错误、其余槽 null；
 /// 单返回/无返回（returnTypes.count < 2）时返回 `err(e)` 值（Result 语义，调用方可 `await`/`wait` 取 `Result` 后 `match`）。
 func makeUnwrapErrorReturn(_ error: Value, returnTypes: [TypeAnnotation]) -> Value {
 if returnTypes.count >= 2 {
 var elements = Array(repeating: Value.null, count: returnTypes.count)
 elements[returnTypes.count - 1] = error
 return .tuple(labels: [], elements: elements)
 }
 return Interpreter.makeResult(caseName: "err", payload: error)
 }

 func evaluateMember(_ objValue: Value, memberName: String, location: SourceLocation) throws -> Value {
 // P4.5：字段级 type-private 强制。`_`-前缀字段仅声明类型自身方法可访问；
 // 同文件普通函数 / 跨类型方法 / 跨文件访问一律拒绝。仅对「确已注册的用户类型」强制，
 // 排除内建类型（String/Array）与 WeakRef（其 `_target` 为运行时内部字段，非用户声明字段）。
 if memberName.hasPrefix("_") {
 let declaringType: String? = {
 switch objValue {
 case .structInstance(let si): return si.typeName
 case .objectReference(let oref): return oref.typeName
 default: return nil
 }
 }()
 if let t = declaringType, typeFields[t] != nil {
 let accessor = currentSelfTypeName()
 if accessor != t {
 throw RuntimeError.inaccessibleField(typeName: t, fieldName: memberName, location: location)
 }
 }
 }
 switch objValue {
 case .tuple(let labels, let elements):
 // 草稿 A2（批次 1.3，D1）：`.名称` 标签访问——按标签在 labels 中找索引取元素；
 // 未找到（位置元组或未知标签）抛 undefinedVariable（静态层另有拦截）。
 if let idx = labels.firstIndex(where: { $0 == memberName }) {
 return elements[idx]
 }
 throw RuntimeError.undefinedVariable(name: memberName, location: location)
 case .lazyRef(let box):
 // G40（D2）：`.value` 成员访问即触发 once 求值缓存（同步阻塞获取）。
 // （.valueFuture 已于 2026-08-24 抛弃——LazyRef 仅保留同步 .value。）
 switch memberName {
 case "value":
 return try box.value { fv in try self.callFunctionValue(fv, args: []) }
 case "isInitialized":
 return .bool(box.isInitialized)
 default:
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 case .weakRef(let box):
 // G42（Ref 系引用语义）：WeakRef 独立承载——.target / .isAlive 成员访问。
 switch memberName {
 case "target":
 return .objectReference(box.target)
 case "isAlive":
 return .bool(arcManager.isAlive(box.target))
 default:
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 case .structInstance(let si):
 if si.typeName == "WeakRef" {
 guard case .objectReference(let target) = si.fields["_target"] else {
 throw RuntimeError.invalidOperation(reason: "WeakRef 状态异常", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 switch memberName {
 case "target":
 return .objectReference(target)
 case "isAlive":
 return .bool(arcManager.isAlive(target))
 default:
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }
 if let v = si.fields[memberName] {
 return v
 }
 if let methods = withTypeRegistry({ typeMethods[si.typeName] }) {
 if let method = methods.first(where: { $0.name == memberName }) {
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .structInstance(si), isMutable: false)
 methodEnv.define(name: "self", value: .structInstance(si), isMutable: false)
 bindInstanceFields(methodEnv, fields: si.fields)
 let actualParams = method.params.first?.name == "self" ? Array(method.params.dropFirst()) : method.params
 let fv = FunctionValue(
 name: method.name,
 params: actualParams,
 returnTypes: method.returnTypes,
 body: method.body,
 decl: method,
 closure: methodEnv
 )
 return .function(fv)
 }
 }
 if let traitNames = withTypeRegistry({ typeTraits[si.typeName] }) {
 for traitName in traitNames {
 if let trait = traits[traitName] {
 if let method = trait.signatures.first(where: { $0.name == memberName && $0.body != nil }) {
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .structInstance(si), isMutable: false)
 let actualParams = method.params.first?.name == "self" ? Array(method.params.dropFirst()) : method.params
 let fv = FunctionValue(
 name: method.name,
 params: actualParams,
 returnTypes: method.returnTypes,
 body: method.body,
 decl: method,
 closure: methodEnv
 )
 return .function(fv)
 }
 }
 }
 }
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 case .objectReference(let oref):
 if let v = oref.fields[memberName] {
 return v
 }
 if let methods = withTypeRegistry({ typeMethods[oref.typeName] }) {
 if let method = methods.first(where: { $0.name == memberName }) {
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .objectReference(oref), isMutable: false)
 bindInstanceFields(methodEnv, fields: oref.fields)
 let actualParams = method.params.first?.name == "self" ? Array(method.params.dropFirst()) : method.params
 let fv = FunctionValue(
 name: method.name,
 params: actualParams,
 returnTypes: method.returnTypes,
 body: method.body,
 decl: method,
 closure: methodEnv
 )
 return .function(fv)
 }
 }
 if let traitNames = withTypeRegistry({ typeTraits[oref.typeName] }) {
 for traitName in traitNames {
 if let trait = traits[traitName] {
 if let method = trait.signatures.first(where: { $0.name == memberName && $0.body != nil }) {
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .objectReference(oref), isMutable: false)
 let actualParams = method.params.first?.name == "self" ? Array(method.params.dropFirst()) : method.params
 let fv = FunctionValue(
 name: method.name,
 params: actualParams,
 returnTypes: method.returnTypes,
 body: method.body,
 decl: method,
 closure: methodEnv
 )
 return .function(fv)
 }
 }
 }
 }
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 case .string(let s):
 // ADR-020 步骤 B：成员派发表驱动（BuiltinRegistry.memberMethods，
 // 与 TypeChecker.defineMethod 共用同一张表）。未知成员 → undefinedVariable。
 // 步骤 C：语言内默认实现（Pini body）优先，缺失时回落宿主原生实现。
 // H-3（2026-08-31）：三级派发——**用户扩展 > 语言内标准库 > 宿主原生**。
 // 用户扩展按名匹配（非按签名），既可覆盖同名内建成员（不再被静默压过），
 // 也可新增内建表没有的方法；内建表 guard 因此后移到用户查表之后。
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .string(s), isMutable: false)
 if let methods = extMethodsByType["String"],
 let userMethod = methods.first(where: { $0.name == memberName }) {
 let actualParams = userMethod.params.first?.name == "self" ? Array(userMethod.params.dropFirst()) : userMethod.params
 return .function(FunctionValue(
 name: userMethod.name,
 params: actualParams,
 returnTypes: userMethod.returnTypes,
 body: userMethod.body,
 decl: userMethod,
 closure: methodEnv
 ))
 }
 guard let member = BuiltinRegistry.member(typeName: "String", name: memberName) else {
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 if let impl = stdlibMemberImpl(typeName: "String", name: memberName) {
 return .function(FunctionValue(
 name: impl.name,
 params: impl.params.first?.name == "self" ? Array(impl.params.dropFirst()) : impl.params,
 returnTypes: impl.returnTypes,
 body: impl.body,
 decl: impl,
 closure: methodEnv
 ))
 }
 return .function(FunctionValue(
 name: member.name,
 params: member.paramNames.map { Parameter(name: $0) },
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: methodEnv
 ))
 case .enumValue(let ev):
 // ADR-016 规则 3.14：枚举方法（含扩展块方法）——`枚举值.方法()` 按 parentEnum 查方法表。
 let enumTypeName = ev.parentEnum ?? ev.caseName
 if let methods = withTypeRegistry({ typeMethods[enumTypeName] }) {
 if let method = methods.first(where: { $0.name == memberName }) {
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .enumValue(ev), isMutable: false)
 let actualParams = method.params.first?.name == "self" ? Array(method.params.dropFirst()) : method.params
 return .function(FunctionValue(
 name: method.name,
 params: actualParams,
 returnTypes: method.returnTypes,
 body: method.body,
 decl: method,
 closure: methodEnv
 ))
 }
 }
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 case .future(let fut):
 // B2-1：Future 是一等值，取消是对值的操作 —— `t.cancel()`。
 switch memberName {
 case "cancel":
 let methodEnv = Environment(enclosing: globalEnv)
 methodEnv.define(name: "self", value: .future(fut), isMutable: false)
 return .function(FunctionValue(
 name: "cancel",
 params: [],
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: methodEnv
 ))
 default:
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 case .array(let arr):
 // ADR-020 步骤 B：同 .string——H-3 三级派发（用户扩展 > 语言内标准库 > 宿主原生）。
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .array(arr), isMutable: false)
 if let methods = extMethodsByType["Array"],
 let userMethod = methods.first(where: { $0.name == memberName }) {
 let actualParams = userMethod.params.first?.name == "self" ? Array(userMethod.params.dropFirst()) : userMethod.params
 return .function(FunctionValue(
 name: userMethod.name,
 params: actualParams,
 returnTypes: userMethod.returnTypes,
 body: userMethod.body,
 decl: userMethod,
 closure: methodEnv
 ))
 }
 guard let member = BuiltinRegistry.member(typeName: "Array", name: memberName) else {
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 if let impl = stdlibMemberImpl(typeName: "Array", name: memberName) {
 return .function(FunctionValue(
 name: impl.name,
 params: impl.params.first?.name == "self" ? Array(impl.params.dropFirst()) : impl.params,
 returnTypes: impl.returnTypes,
 body: impl.body,
 decl: impl,
 closure: methodEnv
 ))
 }
 return .function(FunctionValue(
 name: member.name,
 params: member.paramNames.map { Parameter(name: $0) },
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: methodEnv
 ))
 // 批 2（G48 通道 2/3）：字典此前无成员面（下标为语法级），随 D-5（三通道对三种
 // 容器一致）补上成员派发通道，供 `d.get(k)` / `unsafe d.getUnchecked(k)` 使用。
 case .dictionary(let entries):
 let methodEnv = Environment(enclosing: currentEnv)
 methodEnv.define(name: "self", value: .dictionary(entries), isMutable: false)
 guard let member = BuiltinRegistry.member(typeName: "Dictionary", name: memberName) else {
 throw RuntimeError.undefinedVariable(name: memberName, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 return .function(FunctionValue(
 name: member.name,
 params: member.paramNames.map { Parameter(name: $0) },
 returnTypes: [],
 body: nil,
 decl: nil,
 closure: methodEnv
 ))
 default:
 throw RuntimeError.invalidOperation(reason: "无法访问成员", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }

 // MARK: - 控制流

 private func executeIf(condition: Expression, thenBlock: Block, elifs: [ElifBranch], elseBlock: Block?, label: String? = nil) throws {
 if let label = label {
 // 带标签 if：拦截匹配标签的 break（跳出 if）；未匹配则向上重抛。
 // continue 到 if 语义未定义，不在此捕获，交由上层处理。
 do {
 try executeIfBody(condition: condition, thenBlock: thenBlock, elifs: elifs, elseBlock: elseBlock)
 } catch ControlSignal.breakSignal(let breakLabel) {
 if breakLabel == label { return }
 throw ControlSignal.breakSignal(label: breakLabel)
 }
 } else {
 try executeIfBody(condition: condition, thenBlock: thenBlock, elifs: elifs, elseBlock: elseBlock)
 }
 }

 private func executeIfBody(condition: Expression, thenBlock: Block, elifs: [ElifBranch], elseBlock: Block?) throws {
 let condValue = try evaluateExpression(condition)
 guard case .bool(let cond) = condValue else {
 throw RuntimeError.typeMismatch(expected: "bool", got: "\(condValue)", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }

 if cond {
 try executeBlock(thenBlock)
 return
 }

 for elif in elifs {
 let elifCond = try evaluateExpression(elif.condition)
 guard case .bool(let c) = elifCond else {
 throw RuntimeError.typeMismatch(expected: "bool", got: "\(elifCond)", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 if c {
 try executeBlock(elif.block)
 return
 }
 }

 if let elseBlock = elseBlock {
 try executeBlock(elseBlock)
 }
 }

 private func executeWhile(condition: Expression, body: Block, step: Block?, label: String?) throws {
 // B2-3 检查点：循环头。线程本地读取只做一次（循环期间当前任务不变），
 // 每轮仅付一次原子标志读取；主线程 owner == nil 时完全零开销。
 let owner = currentFuture
 while true {
 try checkCancellation(owner)
 let condValue = try evaluateExpression(condition)
 guard case .bool(let cond) = condValue else {
 throw RuntimeError.typeMismatch(expected: "bool", got: "\(condValue)", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 if !cond {
 break
 }

 // body 正常结束或收到 continue（匹配本 while 标签）都执行 step；
 // 收到 break（匹配本 while 标签）则跳过 step 并跳出循环。
 var shouldRunStep = true
 do {
 try executeBlock(body)
 } catch let signal as ControlSignal {
 switch signal {
 case .breakSignal(let breakLabel):
 if breakLabel == nil || breakLabel == label {
 return
 } else {
 throw signal
 }
 case .continueSignal(let continueLabel):
 if continueLabel == nil || continueLabel == label {
 shouldRunStep = true
 } else {
 throw signal
 }
 default:
 throw signal
 }
 }

 if shouldRunStep, let step = step {
 do {
 try executeBlock(step)
 } catch let signal as ControlSignal {
 switch signal {
 case .breakSignal(let breakLabel):
 if breakLabel == nil || breakLabel == label {
 return
 } else {
 throw signal
 }
 case .continueSignal(let continueLabel):
 if continueLabel == nil || continueLabel == label {
 continue
 } else {
 throw signal
 }
 default:
 throw signal
 }
 }
 }
 }
 }

 /// `for (模式元组,) in 集合值: body [step: block]`（G36）
 /// 模式元组 ↔ 集合元素一一对应：数组/集合=1 字段（元素为元组则逐字段）、字典=2 字段 (k,v)；`_` 占位忽略。
 /// break/continue 语义与 while 一致（step 在 body 正常结束/continue 后执行，break 跳过）。
 private func executeFor(pattern: [String], iterable: Expression, body: Block, step: Block?, label: String?, location: SourceLocation) throws {
 let iterValue = try evaluateExpression(iterable)
 var rows: [[Value]] = []
 switch iterValue {
 case .array(let els):
 rows = try els.map { try decomposePatternRow($0, patternCount: pattern.count, location: location) }
 case .set(let els):
 rows = try els.map { try decomposePatternRow($0, patternCount: pattern.count, location: location) }
 case .dictionary(let pairs):
 guard pattern.count == 2 else {
 throw RuntimeError.typeMismatch(expected: "字典迭代需 2 字段模式元组 (k, v)", got: "\(pattern.count) 字段", location: location)
 }
 rows = pairs.map { [$0.0, $0.1] }
 default:
 throw RuntimeError.typeMismatch(expected: "可迭代集合（数组/字典/集合）", got: "\(iterValue)", location: location)
 }

 for row in rows {
 let loopEnv = Environment(enclosing: currentEnv)
 for (idx, name) in pattern.enumerated() where name != "_" {
 loopEnv.define(name: name, value: row[idx], isMutable: true)
 }
 let previousEnv = currentEnv
 currentEnv = loopEnv
 var shouldRunStep = true
 do {
 try executeBlock(body)
 } catch let signal as ControlSignal {
 switch signal {
 case .breakSignal(let bLabel):
 currentEnv = previousEnv
 if bLabel == nil || bLabel == label { return }
 throw signal
 case .continueSignal(let cLabel):
 if cLabel == nil || cLabel == label { shouldRunStep = true } else { currentEnv = previousEnv; throw signal }
 default:
 currentEnv = previousEnv
 throw signal
 }
 }
 if shouldRunStep, let step = step {
 do {
 try executeBlock(step)
 } catch let signal as ControlSignal {
 switch signal {
 case .breakSignal(let bLabel):
 currentEnv = previousEnv
 if bLabel == nil || bLabel == label { return }
 throw signal
 case .continueSignal(let cLabel):
 currentEnv = previousEnv
 if cLabel == nil || cLabel == label { continue }
 throw signal
 default:
 currentEnv = previousEnv
 throw signal
 }
 }
 }
 currentEnv = previousEnv
 }
 }

 /// ADR-013：执行带标签无条件子块 `scope 块标签:`。
 /// 块体默认执行一次；内部抛出的 `breakSignal(label)`（标签匹配）终止 scope（正常返回）；
 /// `continueSignal(label)`（标签匹配）续行到 scope —— 重跑块体（语义同「续行到对应 scope 块」）；
 /// 非本 scope 标签的信号继续向上传播，交由外层循环 / scope 处理。
 /// 非 ControlSignal 的抛出（RuntimeError / 挂起 SuspendSignal 等）不在此捕获，直接向上传播。
/// 批 6 D-4：裸名兜底——按当前文件查注入表；多模块同名 → 运行时歧义错（防御，
/// 语义层哨兵已排除）；命中唯一 → 复用 resolveQualified（public 门槛照走，D8）。
 private func resolveInjectedBare(_ name: String, location: SourceLocation) throws -> Value? {
 guard let inj = fileInjections[location.fileName], !inj.isEmpty else { return nil }
 let hits = inj.filter { $0.symbols.contains(name) }
 if hits.isEmpty { return nil }
 if hits.count > 1 {
 throw RuntimeError.invalidOperation(
 reason: "符号 '\(name)' 由多个注入模块同时导出（\(hits.map(\.alias).joined(separator: ", "))）——歧义，"
 + "请改用显式别名并以 `别名.符号` 限定调用",
 location: location)
 }
 return try resolveQualified(alias: hits[0].alias, symbol: name, location: location)
 }

 /// G52 批 1：跨模块限定符号解析——存在性（运行时）+ public 门槛（D8）。
 private func resolveQualified(alias: String, symbol: String, location: SourceLocation) throws -> Value {
 guard let imported = importEnvs[alias] else {
 throw RuntimeError.undefinedVariable(name: alias, location: location)
 }
 guard let all = importAllSymbols[alias] else {
 throw RuntimeError.undefinedVariable(name: "\(alias).\(symbol)", location: location)
 }
 guard all.contains(symbol) else {
 throw RuntimeError.undefinedVariable(name: "\(alias).\(symbol)", location: location)
 }
 guard let publicSet = importPublicSymbols[alias], publicSet.contains(symbol) else {
 throw SemanticError.crossModuleAccessDenied(symbol: "\(alias).\(symbol)", location: location)
 }
 return try imported.get(name: symbol)
 }

 private func executeScope(label: String?, body: Block) throws {
 while true {
 do {
 try executeBlock(body)
 return
 } catch let signal as ControlSignal {
 switch signal {
 case .breakSignal(let breakLabel):
 if breakLabel == label { return }
 throw signal
 case .continueSignal(let continueLabel):
 if continueLabel == label { continue }
 throw signal
 default:
 throw signal
 }
 }
 }
 }

 /// 模式元组 ↔ 集合元素一一对应：元素为元组 → 逐字段；否则单字段（标量/容器值）。字段数须与模式元组一致。
 func decomposePatternRow(_ element: Value, patternCount: Int, location: SourceLocation) throws -> [Value] {
 let fields: [Value]
 switch element {
 case .tuple(_, let t): fields = t
 default: fields = [element]
 }
 guard fields.count == patternCount else {
 throw RuntimeError.typeMismatch(
 expected: "\(patternCount) 字段模式元组",
 got: "\(fields.count) 字段元素（模式元组须与集合元素一一对应）",
 location: location
 )
 }
 return fields
 }

 private func executeMatch(value: Expression, cases: [MatchCase], location: SourceLocation) throws {
 let matchValue = try evaluateExpression(value)

 for matchCase in cases {
 if matchCaseMatches(matchCase.pattern, matchValue) {
 let caseEnv = Environment(enclosing: currentEnv)

 // 仅 enumCase 模式携带绑定（命名/位置）；字面量/通配模式无关联值
 if case .enumCase = matchCase.pattern, case .enumValue(let ev) = matchValue {
 // 绑定数 vs 关联值数校验（ADR 具名关联值决议 2026-08-29 决策 D）：
 // 不匹配此前静默绑 .null——现改为运行时报错（类型层同批加 E4 校验）。
 // `_` 占位仍占一个位置但不产生绑定变量。
 if !matchCase.bindings.isEmpty, matchCase.bindings.count != ev.associatedValues.count {
 throw RuntimeError.arityMismatch(
 expected: ev.associatedValues.count,
 got: matchCase.bindings.count,
 location: location
 )
 }
 for (bindingIndex, binding) in matchCase.bindings.enumerated() {
 if binding.varName == "_" { continue }
 let boundValue: Value
 if let paramName = binding.paramName {
 if let idx = ev.paramNames.firstIndex(where: { $0 == paramName }), idx < ev.associatedValues.count {
 boundValue = ev.associatedValues[idx]
 } else {
 throw RuntimeError.arityMismatch(
 expected: ev.associatedValues.count,
 got: matchCase.bindings.count,
 location: location
 )
 }
 } else {
 boundValue = bindingIndex < ev.associatedValues.count ? ev.associatedValues[bindingIndex] : .null
 }
 caseEnv.define(name: binding.varName, value: boundValue, isMutable: true)
 }
 }

 let previousEnv = currentEnv
 currentEnv = caseEnv
 do {
 try executeBlock(matchCase.block)
 } catch let signal as ControlSignal {
 currentEnv = previousEnv
 throw signal
 }
 currentEnv = previousEnv
 return
 }
 }

 // D3①（2026-08-23）：`case _:` 通配已作为 wildcard case 进入 cases（循环自然兜底）。
 // 到达此处 = 无任何 case（含通配）命中：枚举值报 matchNotExhaustive（MED-1，P5-1），
 // 非枚举值保持静默（R3：字面量值域无限，未命中无通配时静默）。
 if case .enumValue(let ev) = matchValue {
 throw RuntimeError.matchNotExhaustive(value: ev.caseName, location: location)
 }
 }

 /// 模式匹配谓词（P5-4 HIGH-2）：枚举 case 名 / 整数字面量 / 浮点 / 字符串 / 布尔 / 通配 `_`
 func matchCaseMatches(_ pattern: MatchPattern, _ value: Value) -> Bool {
 switch pattern {
 case .enumCase(let name):
 if case .enumValue(let ev) = value { return ev.caseName == name }
 return false
 case .intLiteral(let n):
 if case .int(let v) = value { return v == n }
 return false
 case .floatLiteral(let f):
 if case .float(let v) = value { return v == f }
 return false
 case .stringLiteral(let s):
 if case .string(let v) = value { return v == s }
 return false
 case .boolLiteral(let b):
 if case .bool(let v) = value { return v == b }
 return false
 case .wildcard:
 return true
 }
 }

 private func executeTry(expression: Expression, tryBlock: Block, exceptClauses: [ExceptClause]) throws {
 let result = try evaluateExpression(expression)

 // 尝试从结果中提取错误值（元组第二个元素）
 var errorValue: Value = .null
 var hasErrorTuple = false
 if case .tuple(_, let elements) = result, elements.count >= 2 {
 hasErrorTuple = true
 errorValue = elements[1]
 }

 // 错误值为空 → 执行 tryBlock（成功路径）
 // null 或空字符串均视为"无错误"
 if case .null = errorValue {
 try executeBlock(tryBlock)
 return
 }
 if case .string(let s) = errorValue, s.isEmpty {
 try executeBlock(tryBlock)
 return
 }

 // 错误值非空 → 执行 except 子句
 // 仅当结果为元组形式时才视为错误；否则无 except 可匹配则直接返回
 if hasErrorTuple || !exceptClauses.isEmpty {
 for clause in exceptClauses {
 let exceptEnv = Environment(enclosing: currentEnv)
 exceptEnv.define(name: clause.errorVar, value: errorValue, isMutable: true)
 let previousEnv = currentEnv
 currentEnv = exceptEnv
 do {
 try executeBlock(clause.body)
 } catch let signal as ControlSignal {
 currentEnv = previousEnv
 throw signal
 }
 currentEnv = previousEnv
 return
 }
 }
 }

 // MARK: - Defer 栈管理

 func pushDeferScope() {
 deferStack.append([])
 }

 func popDeferScope() throws {
 guard !deferStack.isEmpty else { return }
 let defers = deferStack.removeLast()
 // LIFO：逆序执行
 for stmt in defers.reversed() {
 try executeStatement(stmt)
 }
 }

 // MARK: - 块执行

 private func executeBlock(_ block: Block) throws {
 pushDeferScope()
 defer {
 try? popDeferScope()
 }
 for stmt in block.statements {
 try executeStatement(stmt)
 }
 }

// MARK: - 内置方法接收者取值

/// 切片边界解析（P2-B）：开放边界（nil = Optional.none 或 .null）→ 取默认值；
/// 整数支持负索引尾部计数（i<0 → count+i）；其余类型报错。
private func sliceBound(_ v: Value, count: Int, defaultWhenOpen: Int) throws -> Int {
 if case .enumValue(let ev) = v, ev.caseName == "none" { return defaultWhenOpen }
 if case .null = v { return defaultWhenOpen }
 guard case .int(let i) = v else {
 throw RuntimeError.invalidOperation(
 reason: "slice 边界必须是整数或省略",
 location: Interpreter.builtinLocation
 )
 }
 return i < 0 ? count + i : i
}

private func builtinStringReceiver(_ fv: FunctionValue) throws -> String { guard case .string(let s) = try fv.closure.get(name: "self") else {
 throw RuntimeError.invalidOperation(
 reason: "该操作仅可用于字符串接收者",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return s
 }

 private func builtinArrayReceiver(_ fv: FunctionValue) throws -> [Value] {
 guard case .array(let a) = try fv.closure.get(name: "self") else {
 throw RuntimeError.invalidOperation(
 reason: "该操作仅可用于数组接收者",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return a
 }

 /// 批 2（G48 通道 2/3）：越界落点分派。
 /// - `.get`：返回 `Optional.none`（安全可选通道，调用方显式解包）。
 /// - `.getUnchecked`：调用方违反前置条件。真正的 UB 在解释器无法表达（Swift 越界直接
 ///   trap，不可诊断也不可测试），故以「未定义行为陷阱」报错近似——与 LLVM 端的语义
 ///   约定一致：调用方须证明界内，违反即未定义行为（此处表现为运行时错误）。
 private func uncheckedOrNone(fv: FunctionValue, location: SourceLocation) throws -> Value {
 if fv.name == "get" { return .enumValue(EnumValue(caseName: "none", associatedValues: [])) }
 throw RuntimeError.invalidOperation(
 reason: "getUnchecked 越界：调用方违反前置条件（解释器以 UB 陷阱近似；LLVM 端为真 UB）",
 location: location
 )
 }

 // MARK: - 函数调用

 /// G40（LazyRef）：构造 `LazyRef<T>`——参数必须是初始化闭包（函数值），产出引用语义 box。
 /// 显式 `LazyRef<T>(闭包)`（genericConstruct）与推断糖 `LazyRef(闭包)` 共用此构造。
 private func makeLazyRefBox(from arg: Value, location: SourceLocation) throws -> Value {
 guard case .function(let fv) = arg else {
 throw RuntimeError.invalidOperation(
 reason: "LazyRef 的参数必须是初始化闭包（函数值）",
 location: location
 )
 }
 return .lazyRef(LazyRefBox(initializer: fv))
 }

 public func callFunctionValue(_ fv: FunctionValue, args: [Value]) throws -> Value {
 callDepth += 1
 defer { callDepth -= 1 }
 if callDepth > maxCallDepth {
 throw RuntimeError.invalidOperation(
 reason: "调用深度超过上限 \(maxCallDepth)，疑似无限递归",
 location: Interpreter.builtinLocation
 )
 }
 if fv.isTypeConstructor {
 // G-P10(c)：类型构造不接受实参（字段经初始化器/赋值设置）；
 // 此前实参被静默丢弃（位置形式），属静默数据丢失，改为元数报错。
 guard args.isEmpty else {
 throw RuntimeError.arityMismatch(
 expected: 0,
 got: args.count,
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return try createInstance(typeName: fv.typeName, kind: fv.typeKind)
 }

 if fv.isEnumCaseConstructor {
 var finalArgs = args
 if finalArgs.count < fv.params.count {
 // 实参不足：用关联值默认表达式补位（字面量默认，注册期原样保留）
 for i in finalArgs.count..<fv.params.count {
 guard let def = fv.enumParamDefaults[i] else {
 throw RuntimeError.arityMismatch(
 expected: fv.params.count,
 got: args.count,
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 finalArgs.append(try evaluateExpression(def))
 }
 } else if finalArgs.count > fv.params.count {
 throw RuntimeError.arityMismatch(
 expected: fv.params.count,
 got: args.count,
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return .enumValue(EnumValue(
 caseName: fv.enumCaseName,
 associatedValues: finalArgs,
 // 具名关联值决议（2026-08-29）：声明参数名进入运行时值，
 // 供 match 具名绑定 `case c(关联值名: 变量)` 按名对位。
 paramNames: fv.params.map { $0.name },
 parentEnum: fv.enumParentName.isEmpty ? nil : fv.enumParentName
 ))
 }

 // Phase 2a（ADR-015 FFI）：native 实现优先（`[名称|foreign]` 声明 / load/store/addressof 内建）。
 if let native = fv.nativeImpl {
 return try native(args)
 }

 // 立场 B 内建：Error("msg") → 内建默认错误值
 if fv.name == Interpreter.builtinErrorTypeName, args.count == 1 {
 guard case .string(let message) = args[0] else {
 throw RuntimeError.typeMismatch(
 expected: "String",
 got: describeValueKind(args[0]),
 location: Interpreter.builtinLocation
 )
 }
 return Interpreter.makeError(message)
 }

 // B2-1 内建：CancelError("msg") → 取消错误值
 if fv.name == Interpreter.builtinCancelErrorTypeName, args.count == 1 {
 guard case .string(let message) = args[0] else {
 throw RuntimeError.typeMismatch(
 expected: "String",
 got: describeValueKind(args[0]),
 location: Interpreter.builtinLocation
 )
 }
 return Interpreter.makeCancelError(message)
 }

 // B2-1 内建：isCancel(e) → 该错误值是否为「被取消」而非业务错误
 if fv.name == "isCancel", args.count == 1 {
 return .bool(Interpreter.isCancelErrorValue(args[0]))
 }

 // B2-4 内建：joinAll([...]) —— 多任务汇合，返回聚合 Future（`await`/`wait` 一次拿全部结果）
 if fv.name == "joinAll", fv.body == nil, args.count == 1 {
 return try makeJoinAllFuture(args[0])
 }

 // B2-5 内建：joinWithin(t, ms) —— 带超时的阻塞 join，超时归约为 err(CancelError)
 if fv.name == "joinWithin", fv.body == nil, args.count == 2 {
 // 阻塞点检查点：已被取消的任务不应再去等别人（与 `await`/`wait` 一致）
 try checkCancellation()
 guard case .future(let fut) = args[0] else {
 throw RuntimeError.typeMismatch(
 expected: "Future<T, Error>",
 got: describeValueKind(args[0]),
 location: Interpreter.builtinLocation
 )
 }
 guard case .int(let ms) = args[1] else {
 throw RuntimeError.typeMismatch(
 expected: "I32",
 got: describeValueKind(args[1]),
 location: Interpreter.builtinLocation
 )
 }
 return joinFuture(fut, timeoutMs: ms)
 }

 // 任务 #13：detach 已升格为语句关键字 `detach <expr>`（见 executeStatement 的 .detachStatement），
 // 不再走内建函数分派（函数调用 `detach(...)` 因 detach 为保留关键字无法解析）。

 // B2-1 内建成员：t.cancel() —— 递归取消该任务及其所有子孙任务（协作式）
 if fv.name == "cancel", fv.body == nil, args.isEmpty,
 let receiver = try? fv.closure.get(name: "self"),
 case .future(let fut) = receiver {
 fut.cancel()
 return .null
 }

 // ADR-020 D2：语言内默认实现优先——带 Pini body 的内建成员函数值先于
 // 按名原生分派执行。isAsync 函数（body 非空）不受影响：`=>` 派生在后方
 // 按 isAsync 分支处理，不经过本分支（本分支要求 !isAsync）。
 if fv.body != nil, !fv.isAsync {
 return try executeFunctionBody(fv, args: args)
 }

 // print 支持多参数（空格连接 + 换行），不受下方单参计数守卫限制
 if fv.name == "print" {
 // 整行一次性写出，保证并发任务下逐行输出原子（不与其他任务的 content/newline 交错）。
 // 经 outputSink 重定向：调试器/DAP 适配器可将 debuggee 输出与协议流分离。
 outputSink(args.map { stringify($0) }.joined(separator: " "))
 return .null
 }

 // G41（test 块，R2）：assert 内建——`assert(条件)` / `assert(条件, 消息)`。
 // 消息参数可选（1-2 参），故在下方单参计数守卫之前特判。
 // 条件必须为 Bool；false 时抛 RuntimeError.assertionFailed，消息缺省 "assert failed"。
 if fv.name == "assert" {
 guard args.count >= 1, args.count <= 2 else {
 throw RuntimeError.arityMismatch(expected: 1, got: args.count, location: Interpreter.builtinLocation)
 }
 guard case .bool(let cond) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "assert 的参数 1 必须是 Bool（条件）",
 location: Interpreter.builtinLocation
 )
 }
 let message: String
 if args.count == 2 {
 guard case .string(let m) = args[1] else {
 throw RuntimeError.invalidOperation(
 reason: "assert 的参数 2 必须是 String（消息）",
 location: Interpreter.builtinLocation
 )
 }
 message = m
 } else {
 message = "assert failed"
 }
 if !cond {
 throw RuntimeError.assertionFailed(message: message, location: Interpreter.builtinLocation)
 }
 return .null
 }

 guard fv.params.count == args.count else {
 throw RuntimeError.arityMismatch(expected: fv.params.count, got: args.count, location: SourceLocation(line: 0, column: 0, fileName: ""))
 }
 if fv.name == "len" {
 switch args[0] {
 case .tuple(_, let v): return .int(v.count)
 case .array(let v): return .int(v.count)
 case .dictionary(let v): return .int(v.count)
 case .set(let v): return .int(v.count)
 case .string(let v): return .int(v.count)
 default:
 throw RuntimeError.invalidOperation(
 reason: "len 不支持的类型: \(args[0])",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }

 if fv.name == "is_letter" {
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "is_letter 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 guard let first = s.first else { return .bool(false) }
 return .bool(first.isLetter)
 }

 // ADR-019 D4：is_ascii_digit——ASCII [0-9]（数字字面量扫描用；INT 严格 ASCII）。
 if fv.name == "is_ascii_digit" {
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "is_ascii_digit 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 guard let first = s.first else { return .bool(false) }
 return .bool(first >= "0" && first <= "9")
 }

 // ADR-019 D4 / D3：is_number——Unicode numeric property（IDENT 续字符用；
 // 严格超集 \p{N}，含 三/万 等带数值 Lo 类汉字；宿主 Character.isNumber 语义）。
 if fv.name == "is_number" {
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "is_number 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 guard let first = s.first else { return .bool(false) }
 return .bool(first.isNumber)
 }

 // ADR-019 性能项：chars——按 grapheme cluster 预切字符数组（与 Swift Character 一致，
 // 代理对不劈开）；空串 → 空数组。len(chars(s)) == len(s)（grapheme 数）恒成立。
 // 词法门禁 H1：ord——首 Unicode scalar 的码点值；空串哨兵 -1；
 // 多 scalar grapheme 取首 scalar（ADR-019 D1 grapheme 模型，行为已登记）。
 if fv.name == "ord" {
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "ord 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 guard let first = s.unicodeScalars.first else { return .int(-1) }
 return .int(Int(first.value))
 }

 // 词法门禁 H1：chr——码点值转单字符字符串；越界（负值 / 超出 scalar 上限 /
 // 代理区）哨兵返回空串。
 if fv.name == "chr" {
 guard case .int(let code) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "chr 的参数必须是整数",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 guard code >= 0, code <= 0x10FFFF, !(0xD800...0xDFFF).contains(code),
 let scalar = UnicodeScalar(UInt32(code)) else { return .string("") }
 return .string(String(scalar))
 }

 if fv.name == "chars" {
 guard case .string(let s) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "chars 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return .array(s.map { .string(String($0)) })
 }

 // 成员方法实现入口（非全局自由函数）：
 // 剩余原生成员 = upper/lower/join/append/last/pop（各自的前置缺口见
 // Common/StdlibPini.swift 头注释）。已下沉方法（contains/substring/split/slice）
 // 的语言内实现经 callFunctionValue 的 body-first 通道执行，先于本链——
 // 请勿为已下沉方法在本链恢复按名分支（会造成死代码与双实现漂移）。
 if fv.name == "upper" {
 return .string(try builtinStringReceiver(fv).uppercased())
 }
 if fv.name == "lower" {
 return .string(try builtinStringReceiver(fv).lowercased())
 }
 if fv.name == "join" {
 let arr = try builtinArrayReceiver(fv)
 guard case .string(let sep) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "join 的参数必须是字符串",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return .string(arr.map { stringify($0) }.joined(separator: sep))
 }
 if fv.name == "append" {
 let arr = try builtinArrayReceiver(fv)
 return .array(arr + [args[0]])
 }
 if fv.name == "last" {
 let arr = try builtinArrayReceiver(fv)
 return arr.last ?? .null
 }
 if fv.name == "pop" {
 let arr = try builtinArrayReceiver(fv)
 guard let last = arr.last else {
 return .tuple(labels: [nil, nil], elements: [.array([]), .null])
 }
 return .tuple(labels: [nil, nil], elements: [.array(Array(arr.dropLast())), last])
 }
 // 批 2（G48 通道 2/3）：`.get(i)` 安全可选（越界 .none）；`.getUnchecked(i)` 不安全
 // （跳过检查）。三者共用负索引尾部计数（与下标通道一致）。
 // 注意：解释器无法提供真正的 UB——`getUnchecked` 越界在此以「未定义行为陷阱」
 // 报错近似（可诊断、可测试）；LLVM 端若实现才为真 UB（签名语义不变）。
 if fv.name == "get" || fv.name == "getUnchecked" {
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 let receiver = try fv.closure.get(name: "self")
 // 字典键是任意值（字符串/整数…），数组与字符串下标才是整数索引——先按接收者
 // 类型分流，再各自校验参数，避免把键误当索引（批 2 遗留缺陷，批 3 取证发现）。
 if case .dictionary(let entries) = receiver {
 for (k, v) in entries where k == args[0] {
 return fv.name == "get" ? .enumValue(EnumValue(caseName: "some", associatedValues: [v])) : v
 }
 return try uncheckedOrNone(fv: fv, location: loc)
 }
 guard case .int(let raw) = args[0] else {
 throw RuntimeError.invalidOperation(reason: "\(fv.name) 的参数必须是整数索引", location: loc)
 }
 switch receiver {
 case .array(let arr):
 let idx = raw < 0 ? arr.count + raw : raw
 guard idx >= 0, idx < arr.count else { return try uncheckedOrNone(fv: fv, location: loc) }
 return fv.name == "get" ? .enumValue(EnumValue(caseName: "some", associatedValues: [arr[idx]])) : arr[idx]
 case .string(let s):
 let idx = raw < 0 ? s.count + raw : raw
 guard idx >= 0, idx < s.count else { return try uncheckedOrNone(fv: fv, location: loc) }
 let cidx = s.index(s.startIndex, offsetBy: idx)
 let ch: Value = .string(String(s[cidx]))
 return fv.name == "get" ? .enumValue(EnumValue(caseName: "some", associatedValues: [ch])) : ch
 default:
 throw RuntimeError.invalidOperation(reason: "\(fv.name) 的接收者必须是数组/字符串/字典", location: loc)
 }
 }
 if fv.name == "abs" {
 switch args[0] {
 case .int(let v):
 // Int.min 的绝对值超出 Int 表示范围，必须显式拦截，否则 abs(Int.min) 触发整数溢出 trap
 if v == .min {
 throw RuntimeError.invalidOperation(
 reason: "abs 整数溢出: \(v) 超出 Int 表示范围",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 return .int(abs(v))
 case .float(let v): return .float(abs(v))
 default:
 throw RuntimeError.invalidOperation(
 reason: "abs 的参数必须是数值",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if fv.name == "min" || fv.name == "max" {
 switch (args[0], args[1]) {
 case (.int(let a), .int(let b)):
 return fv.name == "min" ? .int(Swift.min(a, b)) : .int(Swift.max(a, b))
 case (.float(let a), .float(let b)):
 return fv.name == "min" ? .float(Swift.min(a, b)) : .float(Swift.max(a, b))
 default:
 throw RuntimeError.invalidOperation(
 reason: "min/max 的参数必须是同类型数值",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if fv.name == "F64" {
 // G-P1：值构造（见 BuiltinRegistry 同名条目注释）
 switch args[0] {
 case .float(let f): return .float(f)
 case .int(let i): return .float(Double(i))
 default:
 throw RuntimeError.invalidOperation(
 reason: "F64 的参数必须是数值（int/float）",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if fv.name == "sqrt" {
 switch args[0] {
 case .int(let v): return .float(sqrt(Double(v)))
 case .float(let v): return .float(sqrt(v))
 default:
 throw RuntimeError.invalidOperation(
 reason: "sqrt 的参数必须是数值",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if ["sin", "cos", "tan"].contains(fv.name) {
 let v: Double
 switch args[0] {
 case .int(let i): v = Double(i)
 case .float(let f): v = f
 default:
 throw RuntimeError.invalidOperation(
 reason: "\(fv.name) 的参数必须是数值",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 let result: Double
 switch fv.name {
 case "sin": result = sin(v)
 case "cos": result = cos(v)
 default: result = tan(v)
 }
 return .float(result)
 }

 // 批 5（G58，D-2）：moduleRoot() —— 程序基准查询（模块根 / 单文件所在目录，绝对路径）。
 // 未注入基准（REPL / 直建解释器）时返回进程 CWD——如实呈现当前基准，不伪造模块根。
 if fv.name == "moduleRoot", args.isEmpty {
 let base = programBase ?? FileManager.default.currentDirectoryPath
 return .string(base)
 }

 if fv.name == "readFile" {
 guard case .string(let rawPath) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "readFile 的参数必须是字符串路径",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 // 批 5（G58）：相对路径按三段式基准解析（方案 A）。
 let path = resolveIOPath(rawPath)
 do {
 let content = try String(contentsOfFile: path, encoding: .utf8)
 return .string(content)
 } catch {
 throw RuntimeError.invalidOperation(
 reason: "IO 错误: 无法读取文件 \(path): \(error.localizedDescription)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if fv.name == "writeFile" {
 guard case .string(let rawPath) = args[0], case .string(let content) = args[1] else {
 throw RuntimeError.invalidOperation(
 reason: "writeFile 的参数必须是 (路径: String, 内容: String)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 // 批 5（G58）：相对路径按三段式基准解析（方案 A）。
 let path = resolveIOPath(rawPath)
 do {
 try content.write(toFile: path, atomically: true, encoding: .utf8)
 return .null
 } catch {
 throw RuntimeError.invalidOperation(
 reason: "IO 错误: 无法写入文件 \(path): \(error.localizedDescription)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 }
 if fv.name == "readLine" {
 if let line = readLine() {
 return .string(line)
 }
 return .string("")
 }
 if fv.name == "sleep" {
 guard case .int(let ms) = args[0] else {
 throw RuntimeError.invalidOperation(
 reason: "sleep 的参数必须是整数（毫秒）",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 // B2-3 检查点：sleep 是典型阻塞点。按 20ms 分片休眠，每片检查一次取消，
 // 使「取消一个正在 sleep 的任务」在毫秒级生效，而非等满整段睡眠。
 let owner = currentFuture
 try checkCancellation(owner)
 var remaining = max(0, Double(ms)) / 1000.0
 let slice = 0.02
 while remaining > 0 {
 let step = min(slice, remaining)
 Thread.sleep(forTimeInterval: step)
 remaining -= step
 try checkCancellation(owner)
 }
 return .null
 }

 if fv.isAsync {
 // P5 Phase 1：异步函数体在 worker 线程执行，调用方立即拿到 pending Future；
 // 体执行完毕（resolve / reject）前，Future 处于未决状态，await 会真实挂起。
 let future = FutureValue()
 // B2-1：派发树 = 取消树。若当前线程正在执行某个任务体，则新任务挂到它下面；
 // 链接在 spawn 时建立，与调用方是否保留句柄无关（句柄被丢弃的子任务也不漏网）。
 currentFuture?.addChild(future)
 let target = fv
 let boundArgs = args
 self.scheduler.spawn(future) { [weak self] in
 guard let self = self else {
 throw RuntimeError.invalidOperation(
 reason: "异步任务执行时解释器已释放",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }
 // worker 线程上把「当前任务」设为本 Future，供检查点与子任务挂树使用。
 let previousFuture = self.currentFuture
 self.currentFuture = future
 defer { self.currentFuture = previousFuture }
 do {
 if self.suspendMode {
 // 完整 CPS 化：挂起模式走可恢复求值器（`await`/`wait` 释放 OS 线程，
 // 任意表达式深度挂起/精确恢复），结果由 `runSuspendableBodyCPS` 直接 resolve/reject。
 try self.runSuspendableBodyCPS(future: future, fv: target, args: boundArgs)
 return .null
 }
 // B2-2 + （甲）：任务体结束（正常 / 抛错 / 被取消）时，经单一 scope 收口例程
 // 取消未 join 且未完成的子（防泄漏），并收集 leaked 失败（未 join 且已 err 的子）。
 let result = try self.executeFunctionBody(target, args: boundArgs)
 let leaked = future.closeScope()
 let finalResult = self.flipIfLeaked(result, leaked: leaked)
 return finalResult
 } catch {
 future.closeScope() // 抛错路径同样取消未完成子，防泄漏
 throw error
 }
 }
 return .future(future)
 }
 return try executeFunctionBody(fv, args: args)
 }

 /// 在调用线程（或调度器 worker 线程）上执行函数体，返回最终值。
 /// 处理 `return` 信号；其它控制流信号向上抛出。
 private func executeFunctionBody(_ fv: FunctionValue, args: [Value]) throws -> Value {
 // B2-3 检查点：函数入口（覆盖「`=>` 体入口 / 递归入口」）。
 try checkCancellation()

 let callEnv = Environment(enclosing: fv.closure)
 for (i, param) in fv.params.enumerated() {
 callEnv.define(name: param.name, value: args[i], isMutable: true)
 }

 let previousEnv = currentEnv
 currentEnv = callEnv
 defer { currentEnv = previousEnv }

 // P7-4 调试：进入函数体时增加调用深度并压入栈名，供 step-over / backtrace 使用。
 debugDepth += 1
 callStackNames.append(fv.name)
 defer {
 debugDepth -= 1
 if !callStackNames.isEmpty { callStackNames.removeLast() }
 }

 guard let body = fv.body else { return .null }

 var lastValue: Value = .null
 pushDeferScope()
 // defer 作用域在任意退出路径（正常 / return 信号 / 运行时错误 / 取消）都要弹出，
 // 否则错误路径会在线程本地 deferStack 中残留一层（B2-3 引入取消抛出后此路径变常见）。
 // 注册顺序保证 popDeferScope 先于 currentEnv 还原执行，与改造前一致。
 defer { try? popDeferScope() }
 do {
 for stmt in body.statements {
 if case .expressionStmt(let expr, _) = stmt {
 // P7-4 P2：函数体内的裸表达式语句也经过调试钩子，使其能命中断点/单步。
 try debugPause(stmt)
 lastValue = try runExpressionStatement(expr)
 } else {
 try executeStatement(stmt)
 }
 }
 } catch let signal as UnwrapErrSignal {
 // 草稿 A2（批次 1.4，D2）：`^` 解包 err 的控制返回——错误注入返回元组末槽。
 return makeUnwrapErrorReturn(signal.error, returnTypes: fv.returnTypes)
 } catch let signal as ControlSignal {
 if case .returnSignal(let value) = signal {
 // 草稿 A2（批次 1.3，D1）：命名返回元组给结果值补写标签，`.名称` 访问才可命中。
 return applyReturnLabels(fv.decl?.returnLabels ?? [], to: value ?? .null)
 }
 throw signal
 }
 return lastValue
 }

 static func coerceRuntimeError(_ error: Error) -> RuntimeError {
 if let re = error as? RuntimeError { return re }
 return RuntimeError.invalidOperation(
 reason: "异步任务执行失败: \(error.localizedDescription)",
 location: SourceLocation(line: 0, column: 0, fileName: "")
 )
 }

 private func createInstance(typeName: String, kind: FunctionValue.TypeKind?) throws -> Value {
 var fieldValues: [String: Value] = [:]
 if let fields = withTypeRegistry({ typeFields[typeName] }) {
 for field in fields {
 if let initializer = field.initializer {
 fieldValues[field.name] = try evaluateExpression(initializer)
 } else {
 fieldValues[field.name] = .null
 }
 }
 }
 switch kind {
 case .structKind:
 return .structInstance(StructInstance(typeName: typeName, fields: fieldValues))
 case .objectKind:
 let obj = ObjectReference(typeName: typeName, fields: fieldValues)
 arcManager.register(obj)
 return .objectReference(obj)
 default:
 return .structInstance(StructInstance(typeName: typeName, fields: fieldValues))
 }
 }

 /// 将运行时值格式化为展示字符串，作为值→字符串的唯一事实源（供 `print` 与字符串插值求值复用）。
 func stringify(_ value: Value) -> String {
 switch value {
 case .int(let v): return String(v)
 case .float(let v): return String(v)
 case .string(let v): return v
 case .bool(let v): return String(v)
 case .null: return "null"
 case .tuple(let labels, let vs):
 // 草稿 A2（批次 1.3，D1）：命名元组显示 `[商: 2, 余: 1]`，位置元组保持 `[2, 1]`。
 return "[" + vs.enumerated().map { i, v in
 let prefix = (labels.indices.contains(i) && labels[i] != nil) ? "\(labels[i]!): " : ""
 return (i > 0 ? ", " : "") + prefix + stringify(v)
 }.joined() + "]"
 case .array(let vs):
 return "[" + vs.enumerated().map { i, v in (i > 0 ? ", " : "") + stringify(v) }.joined() + "]"
 case .dictionary(let entries):
 return "{" + entries.enumerated().map { i, kv in (i > 0 ? ", " : "") + stringify(kv.0) + ": " + stringify(kv.1) }.joined() + "}"
 case .set(let vs):
 return "{" + vs.enumerated().map { i, v in (i > 0 ? ", " : "") + stringify(v) }.joined() + "}"
 case .weakRef(let box):
 // G42：WeakRef 引用语义承载——打印为 `WeakRef(目标类型)`（不展开内部状态）。
 return "WeakRef(\(box.target.typeName))"
 case .lazyRef:
 // G40：LazyRef 引用语义承载——打印为 `LazyRef`（不展开内部状态）。
 return "LazyRef"
 case .structInstance(let si):
 // 内建 Error / CancelError 直接呈现其 message，便于 `print(<= t)` 输出 `err(boom)`
 // 而非结构体转储；两者呈现一致，判别仍靠 isCancel(e) 而非输出文本。
 if si.typeName == Interpreter.builtinErrorTypeName
 || si.typeName == Interpreter.builtinCancelErrorTypeName,
 case .string(let message)? = si.fields["message"] {
 return message
 }
 // 字段按名排序输出：Dictionary 迭代顺序非声明序，非确定性；排序保证解释器与
 // LLVM 后端 `generateStringifyAggregate` 的展示顺序逐字节一致（T2 对齐）。
 let sorted = si.fields.sorted { $0.key < $1.key }
 return "\(si.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringify(kv.value) }.joined() + "}"
 case .objectReference(let oref):
 let sorted = oref.fields.sorted { $0.key < $1.key }
 return "\(oref.typeName){" + sorted.enumerated().map { i, kv in (i > 0 ? ", " : "") + "\(kv.key): " + stringify(kv.value) }.joined() + "}"
 case .enumValue(let ev):
 if ev.associatedValues.isEmpty {
 return "\(ev.caseName)"
 }
 // 渲染不带关联值名（项目契约：`圆(5.0)` 而非 `圆(r: 5.0)`——paramNames
 // 仅供 match 具名绑定按名对位，不进渲染；2026-08-29 具名关联值决议）。
 let inner = ev.associatedValues.map { stringify($0) }.joined(separator: ", ")
 return "\(ev.caseName)(\(inner))"
 case .function(let fv): return "<\(fv.name)>"
 case .future(let fv):
 if fv.isResolved, let result = fv.result {
 return "Future(\(stringify(result)))"
 }
 return "<pending Future>"
 case .rawPointer(let rp):
 // Phase 2a（ADR-015 FFI）：打印 `*T@0x...`（元素类型 + 地址）。
 let t = rp.elemType.map { $0.describe() } ?? "?"
 return "*\(t)@\(rp.pointer)"
 }
 }
}
