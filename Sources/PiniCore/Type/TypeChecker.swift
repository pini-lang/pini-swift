import Foundation

/// 类型检查器
/// 负责静态类型检查，验证表达式和语句的类型正确性
/// 当前三步走计划中使用动态解释器，类型检查为静态校验补充
public final class TypeChecker {
 private let inference: TypeInference
 private let typeEnv: TypeEnvironment

 /// #46-optional / Task #1：暴露给 codegen 复用。
 /// LLVM 后端在 `check(module:)` 之后取 `typeInference.infer(expression:)` 即可拿到已推导的
 /// 局部变量类型（如 `match a:` 中 `a: Optional<I32>`），无需回写 AST。
 public var typeInference: TypeInference { inference }

 /// P2-4 收尾：收集模式（多错同报）运行时态。
 /// 非收集态下 `report` 直接抛出（保持原 throw-first 语义，兼容既有单错测试）；
 /// 收集态下 `report` 将错误累积到 `diagnostics` 并静默——函数体内逐语句恢复（panic-mode），
 /// 跨语句 / 跨方法 / 跨顶级声明均不中断。
 private var diagnostics: [TypeError] = []
 private var collecting = false

 public init() {
 self.typeEnv = TypeEnvironment()
 self.inference = TypeInference(environment: typeEnv)
 registerBuiltinTypes()
 }

 /// 已知内建类型（其成员方法已在 registerBuiltinTypes 登记）。
 /// 这些类型上调用未注册成员应在静态期报错（unknownMember），而非静默跳过（P3-2 ③）。
 private static let builtinTypesWithMembers: Set<String> = ["String", "Array"]

 /// P3-3 加固（与运行时引用语义对齐）：引用类型（object）的 `let` 仅约束引用本身、
 /// 对象内容仍可变，故成员赋值不可变性拦截须豁免这些类型名；值类型（struct）才须拦截。
 /// 类型层将 struct/object 统一注册为 `defineStruct`，无法仅凭类型名区分，故显式维护此集合
 /// （在 registerTopLevelDeclSignature 中按 objectDecl 名填充）。
 private var referenceTypeNames: Set<String> = []

 /// B3-1 任务隔离（消解 R6）：`=>` 并发进程的函数名 → 其形参名列表。
 /// 只登记 async 函数——隔离规则**只**约束跨任务边界，同步调用完全不受影响（零回归）。
 /// 形参名单独存是因为 `TypeEnvironment.FunctionSignature` 只保留类型、不保留名字，
 /// 而一条好的隔离报错必须能指名道姓说出是哪个形参。
 private var asyncFunctionParamNames: [String: [String]] = [:]

 /// B3-1：`Type.method` → 形参名列表，覆盖标了 `=>` 的**方法**（与自由函数同等对待）。
 private var asyncMethodParamNames: [String: [String]] = [:]

 /// ADR-016 规则 3.2/3.14：类型字段表（register 阶段填充），供扩展块方法体检查注入 self 字段作用域。
 private var typeFieldsByName: [String: [(name: String, type: TypeAnnotation)]] = [:]

 /// P4 Phase 3：多文件包分析时的包级符号索引与「当前正在分析的文件」。
 /// 单文件模式（`check(module:)`）下恒为 `nil`，故单文件行为零回归。
 private var packageContext: (index: PackageSymbolIndex, currentFileName: String)? = nil

 /// Phase 2a（ADR-015 FFI）：不安全上下文深度。`|unsafe` 函数体或 `unsafe (...)` 消耗点内 > 0。
 /// `&` 取地址 / 指针解引用仅允许在此深度 > 0 时出现。
 private var unsafeContextDepth: Int = 0

 private func registerBuiltinTypes() {
 let loc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
 // ADR-020 D3：内建静态签名从单点登记表（BuiltinRegistry）派生——
 // 类型层须登记签名，否则示例/用户代码调用这些自由函数会因调用点查不到
 // 签名而被跳过校验。带泛型/指针/通配位的特例（load/store/addressof、
 // ok/err/Error/CancelError、isCancel/joinAll/joinWithin）由专属路径登记，
 // 在表中以 typeSignature = nil 标记。
 // 注：TypeEnvironment.defineFunction 按名覆盖、不支持重载，故 abs 仅登记 I32 形态
 // （示例 abs(-42) 为整数字面量，推断为 I32）。
 for decl in BuiltinRegistry.decls {
 guard let sig = decl.typeSignature else { continue }
 typeEnv.defineFunction(
 name: decl.name,
 params: sig.params,
 returns: sig.returns,
 isVariadic: sig.isVariadic
 )
 }
 let string = TypeAnnotation.simple(name: "String", location: loc)

 // Phase 2a（ADR-015 FFI）：指针原语内建（与 Interpreter.registerPointerBuiltins 对齐）。
 // load/store 参数用 Any 通配——接受任意 `*T`（元素类型由运行时指针值自描述，静态层不约束）。
 let anyType = TypeAnnotation.simple(name: "Any", location: loc)
 let anyPtr = TypeAnnotation.pointer(element: TypeAnnotation.simple(name: "U8", location: loc), location: loc)
 typeEnv.defineFunction(name: "load", params: [anyType], returns: [])
 typeEnv.defineFunction(name: "store", params: [anyType, anyType], returns: [])
 typeEnv.defineFunction(name: "addressof", params: [anyType], returns: [anyPtr])

 registerConcurrencyBuiltins(loc: loc, string: string)

 // ADR-020 步骤 A（D1/D7）：内建特征 collection 声明面。
 // 方法面 = D1 最小集的成员方法部分（append/pop/slice/join/contains + len，
 // len 现为自由函数，方法化随步骤 B 裁决；下标读属运算符通道，不入方法表）。
 // 抽象签名参数/返回一律 `_` 通配位（joinWithin 先例；Any 非顶部类型，
 // isAssignable 对 expected=Any 不放行）——严格形状随步骤 B 的 per-type
 // witness 表钉定。
 // String/Array 的遵循为标记式登记（markConformance），不触发严格校验；
 // 用户源码 `实现: collection` 仍走 verifyTraitConformance 全量校验。
 let any = TypeAnnotation.simple(name: "_", location: loc)
 let selfParam = Parameter(name: "self")
 func collectionMethod(_ name: String, extra: [Parameter], returns: [TypeAnnotation]) -> FuncDecl {
 return FuncDecl(
 name: name,
 modifiers: [],
 genericParams: [],
 params: [selfParam] + extra,
 returnTypes: returns,
 body: nil,
 location: loc
 )
 }
 let collectionTrait = TraitDecl(
 name: "collection",
 genericParams: [],
 signatures: [
 collectionMethod("len", extra: [], returns: [any]),
 collectionMethod("contains", extra: [Parameter(name: "v", typeAnnotation: any)], returns: [any]),
 collectionMethod("append", extra: [Parameter(name: "v", typeAnnotation: any)], returns: [any]),
 collectionMethod("pop", extra: [], returns: [any]),
 collectionMethod("slice", extra: [Parameter(name: "a", typeAnnotation: any), Parameter(name: "b", typeAnnotation: any)], returns: [any]),
 collectionMethod("join", extra: [Parameter(name: "sep", typeAnnotation: any)], returns: [any]),
 ],
 location: loc
 )
 typeEnv.defineTrait(name: "collection", trait: collectionTrait)
 for (typeName, traitNames) in BuiltinRegistry.conformances {
 typeEnv.markConformance(typeName: typeName, traits: traitNames)
 }

 // ADR-020 步骤 B：内建成员方法签名从单点登记表（BuiltinRegistry.memberMethods）
 // 派生——与运行时 evaluateMember 的表驱动派发共用同一张表。未知成员将被
 // 类型层捕获（unknownMember），提前于运行时 undefinedVariable。
 // 注：数组字面量在类型层推断为 nil（TypeInference.arrayLiteral → nil），故 Array 成员校验
 // 仅在接收者类型可解析时生效；注册不引入回归（解析不到类型时仍走原跳过路径）。
 for m in BuiltinRegistry.memberMethods {
 typeEnv.defineMethod(typeName: m.typeName, methodName: m.name, params: m.params, returns: m.returns)
 }
 }

 /// 立场 B 并发内建类型（契约见 Pini草稿.md（异步函数块） ）：
 /// - `Future<T, E>`：`=>` 函数的类型层返回类型（运行中的并发进程句柄）。
 /// - `Result<T, E>`：错误即数据的和类型，`await`/`wait` join 的结果；用例 `ok(v)` / `err(e)`。
 /// - `Error`：内建错误特征的默认实现类型（Q1），`Error("msg")` 快速构造。
 private func registerConcurrencyBuiltins(loc: SourceLocation, string: TypeAnnotation) {
 let t = TypeAnnotation.simple(name: "T", location: loc)
 let e = TypeAnnotation.simple(name: "E", location: loc)

 // Future<T, E>：无字段的不透明句柄类型；登记为泛型结构以便注解与实参个数校验生效。
 // 成员 `cancel()`（B2-1）：递归取消该任务及其所有子孙任务，返回 ()。
 typeEnv.defineGenericStruct(
 name: "Future",
 genericParams: ["T", "E"],
 fields: [],
 methods: [(name: "cancel", params: [], returns: [])]
 )

 // Result<T, E>：内建泛型枚举（B0-1 已打通泛型枚举特化链路）
 typeEnv.defineGenericEnum(
 name: "Result",
 genericParams: ["T", "E"],
 cases: [
 "ok": [(name: nil, type: t)],
 "err": [(name: nil, type: e)]
 ]
 )

 // Error：内建默认错误类型 + 构造函数 Error("msg")
 typeEnv.defineStruct(name: "Error", fields: [(name: "message", type: string)])
 typeEnv.defineFunction(
 name: "Error",
 params: [string],
 returns: [.simple(name: "Error", location: loc)]
 )

 // CancelError（B2-1 / Q5 表示法 A）：取消专用错误，与业务 Error 并列的独立类型。
 // 结构与 Error 相同（message: String），因此 `e.message` 在两者上都可读；
 // 判别靠内建谓词 isCancel(e)，而非字符串约定。
 typeEnv.defineStruct(name: cancelErrorTypeName, fields: [(name: "message", type: string)])
 typeEnv.defineFunction(
 name: cancelErrorTypeName,
 params: [string],
 returns: [.simple(name: cancelErrorTypeName, location: loc)]
 )
 typeEnv.defineFunction(
 name: "isCancel",
 params: [.simple(name: "Error", location: loc)],
 returns: [.simple(name: "Bool", location: loc)]
 )

 // joinAll（B2-4 / Q3）：[Future<T, E>] → Future<[T], Error>，`await`/`wait` joinAll([...])` 得 Result<[T], Error>。
 // 参数登记为裸 `Array`：数组字面量在类型层推断为 nil（见 TypeInference.arrayLiteral），
 // 元素类型此刻不可知，故此处只锚定「是数组」，元素为 Future 的校验落在运行时。
 typeEnv.defineFunction(
 name: "joinAll",
 params: [.simple(name: "Array", location: loc)],
 returns: [.generic(
 name: "Future",
 params: [
 .simple(name: "Array", location: loc),
 .simple(name: "Error", location: loc)
 ],
 location: loc
 )]
 )

 // joinWithin（B2-5 / Q5·超时）：(Future<_, _>, I32) → Result<_, Error>。
 // 本身即阻塞 join，故返回 Result 而非 Future；超时归约为 err(CancelError)。
 // 载荷类型此刻不可解（无泛型函数推断），用 `_` 通配位锚定构造子与元数。
 let wildcard = TypeAnnotation.simple(name: "_", location: loc)
 typeEnv.defineFunction(
 name: "joinWithin",
 params: [
 .generic(name: "Future", params: [wildcard, wildcard], location: loc),
 .simple(name: "I32", location: loc)
 ],
 returns: [.generic(
 name: "Result",
 params: [wildcard, .simple(name: "Error", location: loc)],
 location: loc
 )]
 )

 // detach（ADR-009（甲）escape hatch）：fire-and-forget，把 Future 从父 scope 剪枝，
 // 不消费结果，返回 ()。与 Interpreter.registerBuiltins 对齐登记。
 typeEnv.defineFunction(
 name: "detach",
 params: [.generic(name: "Future", params: [wildcard, wildcard], location: loc)],
 returns: []
 )
 }

 /// 取消专用错误类型名（与 Interpreter.builtinCancelErrorTypeName 对齐）。
 private let cancelErrorTypeName = "CancelError"

 /// 立场 B 语法糖归一（Pini草稿.md（异步函数块） /）：
 /// 源码 `func f() => (T,)` 的**类型层签名返回** `Future<T, Error>`。
 /// 非 async 函数原样返回其声明返回类型。
 private static func signatureReturns(of f: FuncDecl) -> [TypeAnnotation] {
 guard f.isAsync else { return f.returnTypes }
 return [.generic(name: "Future", params: asyncPayloadAndError(of: f), location: f.location)]
 }

 /// `=>` 函数**体内 return 的期望类型**为 `Result<T, Error>`（`return ok(v)` / `return err(e)`）。
 /// `=> ()`（无返回值的并发进程）返回空数组，沿用现有 void 放行路径。
 private static func bodyReturns(of f: FuncDecl) -> [TypeAnnotation] {
 guard f.isAsync, !f.returnTypes.isEmpty else { return f.returnTypes }
 return [.generic(name: "Result", params: asyncPayloadAndError(of: f), location: f.location)]
 }

 private static func asyncPayloadAndError(of f: FuncDecl) -> [TypeAnnotation] {
 let errorType = TypeAnnotation.simple(name: "Error", location: f.location)
 let payload: TypeAnnotation
 if f.returnTypes.count == 1 {
 payload = f.returnTypes[0]
 } else if f.returnTypes.isEmpty {
 payload = .simple(name: "Null", location: f.location)
 } else {
 payload = .tuple(labels: [], elements: f.returnTypes, location: f.location)
 }
 return [payload, errorType]
 }

 /// 检查模块
 public func check(module: Module) throws {
 // 预注册所有 trait 声明，确保后续类型声明（无论出现先后）都能解析其 `traits` 引用
 preregisterTraits(module)
 for decl in module.declarations {
 registerTopLevelDeclSignature(decl)
 }
 for decl in module.declarations {
 try checkTopLevelDecl(decl)
 }
 }

 /// P4 Phase 3：检查包（多文件 / 单文件统一入口）。
 ///
 /// - 单文件包（`fileUnits.count <= 1`）直接委托 `check(module:)`，行为与旧单文件世界完全等价。
 /// - 多文件包：将所有文件的顶级签名**全局注册**进 `typeEnv`，使跨文件函数 / 类型引用
 /// 可被类型检查；每个文件的函数体在 `packageContext` 下检查，调用点 enforce 可见性（private/internal 跨文件调用 → `inaccessibleSymbol`）。
 /// 注：跨文件重声明由语义层 `PackageSymbolIndex.build` 先行拦截，类型层仅在已通过语义的程序上运行。
 public func check(package: Package) throws {
 if package.fileUnits.count <= 1 {
 let module = package.fileUnits.first?.module
 ?? Module(declarations: [], imports: [], exports: [],
 location: SourceLocation(line: 0, column: 0, fileName: package.name))
 try check(module: module)
 return
 }

 let index = PackageSymbolIndex(package: package)
 // 预注册所有 trait + 顶级签名（全局命名空间，供跨文件解析）
 for unit in package.fileUnits {
 preregisterTraits(unit.module)
 }
 for unit in package.fileUnits {
 for decl in unit.module.declarations {
 registerTopLevelDeclSignature(decl)
 }
 }
 // 逐文件检查函数体（函数体内部作用域仍按 push/pop 隔离，跨文件 private 不致泄漏）
 for unit in package.fileUnits {
 packageContext = (index: index, currentFileName: unit.fileName)
 defer { packageContext = nil }
 for decl in unit.module.declarations {
 try enforceDeclTypeVisibility(decl)
 try checkTopLevelDecl(decl)
 }
 }
 }

 // MARK: - 跨文件类型名可见性 enforce（P4 审查修复）

 /// 对一个「命名类型引用」执行跨文件可见性 enforce：若该类型（struct/object/enum/trait）
 /// 定义在另一文件且对当前文件不可见，报 `inaccessibleSymbol`。
 /// 内置类型（String/I32/...）、泛型参数、Self 不在符号索引中，直接跳过（lookup 返回 nil）。
 private func enforceTypeVisibility(name: String, location: SourceLocation) throws {
 guard let ctx = packageContext else { return }
 guard let entry = ctx.index.lookup(name),
 !entry.isVisible(from: ctx.currentFileName) else { return }
 try report(TypeError.inaccessibleSymbol(
 name: name, definedIn: entry.fileName, level: entry.visibility, location: location
 ))
 }

 /// 递归遍历类型注解，对其中的命名类型（含泛型实参、元组元素、函数签名）做可见性 enforce。
 private func enforceAnnotationVisibility(_ annotation: TypeAnnotation) throws {
 switch annotation {
 case .simple(let name, let loc):
 try enforceTypeVisibility(name: name, location: loc)
 case .generic(let name, let params, let loc):
 try enforceTypeVisibility(name: name, location: loc)
 for p in params { try enforceAnnotationVisibility(p) }
 case .tuple(_, let elements, _):
 for e in elements { try enforceAnnotationVisibility(e) }
 case .function(let params, let returns, _, _):
 for p in params { try enforceAnnotationVisibility(p) }
 for r in returns { try enforceAnnotationVisibility(r) }
 case .pointer(let element, _):
 try enforceAnnotationVisibility(element)
 }
 }

 /// 对单个顶层声明提取所有「类型名引用」（字段类型、函数参数/返回、枚举关联值、trait 遵循）
 /// 并执行跨文件可见性 enforce。声明自身名字是定义方、不算引用，故不检查。
 private func enforceDeclTypeVisibility(_ decl: TopLevelDecl) throws {
 switch decl {
 case .structDecl(let s):
 for f in s.fields { try enforceAnnotationVisibility(f.typeAnnotation) }
 for t in s.traits { try enforceTypeVisibility(name: t, location: s.location) }
 case .objectDecl(let o):
 for f in o.fields { try enforceAnnotationVisibility(f.typeAnnotation) }
 for t in o.traits { try enforceTypeVisibility(name: t, location: o.location) }
 case .enumDecl(let e):
 for c in e.cases {
 for ap in c.associatedParams { try enforceAnnotationVisibility(ap.type) }
 }
 case .funcDecl(let f):
 for p in f.params {
 if let ta = p.typeAnnotation { try enforceAnnotationVisibility(ta) }
 }
 for rt in f.returnTypes { try enforceAnnotationVisibility(rt) }
 case .foreignDecl(let fd):
 for f in fd.funcs {
 for p in f.params {
 if let ta = p.typeAnnotation { try enforceAnnotationVisibility(ta) }
 }
 for rt in f.returnTypes { try enforceAnnotationVisibility(rt) }
 }
 case .traitDecl, .extensionDecl, .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 // MARK: - 字段级 type-private 强制（P4.5）

 /// 当前访问者类型：若正处于某类型的方法体内，`self` 在类型环境中被注册为
 /// `.simple(name: 类型名)`，取其类型名即为「当前方法所属类型」。
 /// 不在任何方法体内（顶层函数 / lambda）时返回 nil。
 private func currentSelfTypeName() -> String? {
 guard let selfType = typeEnv.lookupVariable(name: "self") else { return nil }
 switch selfType {
 case .simple(let n, _): return n
 case .generic(let n, _, _): return n
 default: return nil
 }
 }

 /// 对一次「成员访问 / 字段写」执行 type-private 强制：
 /// 当且仅当字段名以 `_` 前缀、且对象静态类型是「确声明了该字段的用户类型」、且当前访问者类型
 /// 不等于声明类型时，报 `inaccessibleField`。内建类型（String/Array）/ Any / 未声明该字段的符号
 /// 一律跳过（交给 unknownMember 或运行时兜底），避免误报。
 private func enforceFieldVisibility(object: Expression, fieldName: String, location: SourceLocation) throws {
 guard fieldName.hasPrefix("_") else { return }
 guard let objType = inference.infer(expression: object) else { return }
 let declaringType: String?
 switch objType {
 case .simple(let n, _): declaringType = n
 case .generic(let n, _, _): declaringType = n
 default: declaringType = nil
 }
 guard let t = declaringType else { return }
 // 仅当用户类型确实声明了该 `_` 字段才强制（同时确认字段真实存在、排除内建 / Any）。
 guard typeEnv.lookupField(typeName: t, fieldName: fieldName) != nil else { return }
 let accessor = currentSelfTypeName()
 if accessor != t {
 try report(TypeError.inaccessibleField(typeName: t, fieldName: fieldName, location: location))
 }
 }

 /// 收集模式入口（P2-4 收尾）：不抛出，返回模块内全部类型错误。
 /// 复用 `check` 的注册 + 检查逻辑；`report` 在收集态下累积并静默，
 /// 函数体内逐语句恢复（跨语句/跨方法/跨顶级声明均不中断），单文件可一次性报出多错。
 public func checkCollecting(module: Module) -> [TypeError] {
 diagnostics = []
 collecting = true
 defer { collecting = false }
 preregisterTraits(module)
 for decl in module.declarations {
 registerTopLevelDeclSignature(decl)
 }
 for decl in module.declarations {
 do {
 try checkTopLevelDecl(decl)
 } catch let error as TypeError {
 diagnostics.append(error)
 } catch {
 // 非 TypeError 不应发生；保持防御
 }
 }
 return diagnostics
 }

 /// 错误上报单点：收集态累积并静默，非收集态直接抛出。
 /// 替换散布的 `throw TypeError.*`，使收集态下错误不再向上传播（全自动逐语句恢复）。
 private func report(_ error: TypeError) throws {
 if collecting {
 diagnostics.append(error)
 } else {
 throw error
 }
 }

 // MARK: - Trait 支持

 /// 预注册所有 trait 声明（在类型声明注册前，保证 `traits` 引用可解析）。
 private func preregisterTraits(_ module: Module) {
 for decl in module.declarations {
 if case .traitDecl(let t) = decl {
 typeEnv.defineTrait(name: t.name, trait: t)
 }
 }
 }

 /// 把类型注解中的 `own`（G50 更名自 Self）替换为具体实现类型名（trait 约束求解与成员可见性需要）。
 private func replaceSelf(_ type: TypeAnnotation, with typeName: String) -> TypeAnnotation {
 switch type {
 case .simple(let name, let loc):
 return name == "own" ? .simple(name: typeName, location: loc) : type
 case .generic(let name, let params, let loc):
 let newName = name == "own" ? typeName : name
 return .generic(name: newName, params: params.map { replaceSelf($0, with: typeName) }, location: loc)
 default:
 return type
 }
 }

 /// 把 trait 的**默认实现**方法（body 非空）签名（Self 替换为具体类型）注册为实现类型的可见方法，
 /// 使 `obj.traitDefaultMethod()` 的成员调用类型检查能通过（lookupMethod 可命中）。
 /// 抽象方法（body 为空）不注册——类型必须自己实现，由 verifyTraitConformance 校验缺失。
 /// 缺省类型注解的形参以 "_" 哨兵占位（validateCallArguments 已对 "_" 放行类型校验）。
 private func registerTraitMethods(for typeName: String, traits: [String], location: SourceLocation) {
 for traitName in traits {
 guard let trait = typeEnv.lookupTrait(name: traitName) else { continue }
 for sig in trait.signatures where sig.body != nil {
 let params = traitParamsWithoutSelf(sig.params, location: location)
 let returns = sig.returnTypes.map { replaceSelf($0, with: typeName) }
 typeEnv.defineMethod(typeName: typeName, methodName: sig.name, params: params, returns: returns)
 }
 }
 }

 /// trait 方法签名参数：剥离首参数若为 `self`（与 struct/object 方法修饰符 self 不进 params 的约定一致，
 /// 也与运行时成员派发剥离 self 对齐）。缺省类型注解以 "_" 占位。
 private func traitParamsWithoutSelf(_ params: [Parameter], location: SourceLocation) -> [TypeAnnotation] {
 let mapped = params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: location) }
 if let first = params.first, first.name == "self" {
 return Array(mapped.dropFirst())
 }
 return mapped
 }

 /// 类型层 trait 约束求解：声明 `traits: [T]` 的类型必须满足 T 的全部抽象方法
 /// （body 为空的签名）。已提供的方法需签名匹配（参数个数/类型、返回类型，Self 替换为具体类型）。
 private func verifyTraitConformance(typeName: String, traits: [String], location: SourceLocation) throws {
 for traitName in traits {
 guard let trait = typeEnv.lookupTrait(name: traitName) else {
 try report(TypeError.undefined(name: traitName, location: location))
 continue
 }
 for req in trait.signatures where req.body == nil {
 guard let provided = typeEnv.lookupMethod(typeName: typeName, methodName: req.name) else {
 try report(TypeError.traitRequirementNotSatisfied(
 typeName: typeName, traitName: traitName, methodName: req.name, location: location
 ))
 continue
 }
 let reqParams = traitParamsWithoutSelf(req.params, location: location).map { replaceSelf($0, with: typeName) }
 if reqParams.count != provided.params.count {
 try report(TypeError.traitMethodSignatureMismatch(
 typeName: typeName, traitName: traitName, methodName: req.name,
 detail: "参数个数不符：期望 \(reqParams.count)，实际 \(provided.params.count)",
 location: location
 ))
 continue
 }
 for (i, rp) in reqParams.enumerated() {
 let pp = provided.params[i]
 if case .simple(let pname, _) = pp, (pname == "_" || pname == "Any") { continue }
 if !isAssignable(actual: pp, expected: rp) {
 try report(TypeError.traitMethodSignatureMismatch(
 typeName: typeName, traitName: traitName, methodName: req.name,
 detail: "第 \(i + 1) 个参数类型不符：期望 \(rp.describe())，实际 \(pp.describe())",
 location: location
 ))
 }
 }
 let reqReturns = req.returnTypes.map { replaceSelf($0, with: typeName) }
 if reqReturns.count != provided.returns.count {
 try report(TypeError.traitMethodSignatureMismatch(
 typeName: typeName, traitName: traitName, methodName: req.name,
 detail: "返回个数不符：期望 \(reqReturns.count)，实际 \(provided.returns.count)",
 location: location
 ))
 continue
 }
 for (i, rr) in reqReturns.enumerated() {
 let pr = provided.returns[i]
 if !isAssignable(actual: pr, expected: rr) {
 try report(TypeError.traitMethodSignatureMismatch(
 typeName: typeName, traitName: traitName, methodName: req.name,
 detail: "第 \(i + 1) 个返回类型不符：期望 \(rr.describe())，实际 \(pr.describe())",
 location: location
 ))
 }
 }
 }
 }
 }

 /// 类型可接受性：结构等价优先；其次允许「枚举变体 → 联合类型」（判别联合子类型）。
 /// 例如 `圆` 是 `形状` 的用例时，期望 `形状`、实际 `圆` 视为合法（P2 收尾：enum 进入静态类型检查）。
 /// 立场 B 追加：期望为泛型枚举特化类型（`Result<I32, Error>`）时，其用例名（`ok` / `err`）
 /// 同样视为可赋值——实参精度由 `refineEnumCaseConstruction` 在下推路径上单独校验。
 private func isAssignable(actual: TypeAnnotation, expected: TypeAnnotation) -> Bool {
 if actual.isStructurallyEquivalent(to: expected) { return true }
 // Phase 0：隐式整型宽度转换（对齐解释器 leniency）。整型 primitive 族（I8..I64/U8..U64）
 // 之间可互相赋值，如 I32 字面量 → I8 字段（`var p = P(); p.y = 16`）、I32 → I64。
 // 浮点（F32/F64）与 Bool 不在集合内：`I32 → F64` 仍报 mismatch（语义测试依赖），
 // `I32 → Bool` 亦不放行。String↔I32 等异类仍走结构等价 → 报错。
 if case .simple(let aName, _) = actual,
 case .simple(let eName, _) = expected,
 isNumericPrimitive(aName), isNumericPrimitive(eName) {
 return true
 }
 // 内建签名可在泛型实参位使用 `_` 通配（如 `joinWithin(t: Future<_, _>, ms: I32)`）：
 // 元素类型对内建而言无关紧要，只需锚定外层构造子与元数。顶层 `_` 早在
 // validateCallArguments 放行，此处覆盖嵌套位。
 if matchesWithWildcards(actual: actual, expected: expected) { return true }
 if case .simple(let aName, _) = actual {
 let parent = typeEnv.parentEnum(of: aName)
 if case .simple(let eName, _) = expected, parent == eName { return true }
 if case .generic(let eName, _, _) = expected, parent == eName { return true }
 // B2-1：CancelError 是「取消」的独立类型，但在期望 Error 的位置（如 `err(e)` 的
 // 载荷、`Result<T, Error>` 的错误分量）视为可赋值——等价于 Error 的内建子类型。
 // 待类型层具备 trait 子类型能力后（Q1 原意），此白名单应由 conformance 取代。
 if aName == cancelErrorTypeName,
 case .simple(let eName, _) = expected,
 eName == "Error" {
 return true
 }
 }
 return false
 }

 /// Phase 0：整型 primitive 判定（仅整型宽度族）。用于隐式整型宽度转换放行
 /// （I32 字面量 → I8/I16/I64 字段等），**不含浮点**——`I32 ↔ F64` 仍报 mismatch
 /// （TypeCheckerMultiErrorTests 的语义测试依赖此严格性），也不含 Bool。
 private func isNumericPrimitive(_ name: String) -> Bool {
 switch name {
 case "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64":
 return true
 default:
 return false
 }
 }

 /// `_` / `Any` 通配的逐位匹配：仅当 `expected` 中出现通配位时才可能放行，
 /// 其余情形返回 false 交回原有结构等价路径（零回归）。
 private func matchesWithWildcards(actual: TypeAnnotation, expected: TypeAnnotation) -> Bool {
 if case .simple(let eName, _) = expected, eName == "_" || eName == "Any" {
 return true
 }
 switch (actual, expected) {
 case (.simple(let aName, _), .simple(let eName, _)):
 return aName == eName
 case (.generic(let aName, let aParams, _), .generic(let eName, let eParams, _)):
 guard aName == eName, aParams.count == eParams.count else { return false }
 for (a, e) in zip(aParams, eParams) where !matchesWithWildcards(actual: a, expected: e) {
 return false
 }
 return true
 default:
 return false
 }
 }

 /// 期望类型下推：判定 `expr` 是否为「期望枚举类型的用例构造」，若是则按特化后的用例
 /// 关联参数类型逐一校验实参，并返回 `true`（调用方跳过通用结构等价比对）。
 ///
 /// 覆盖三种写法：
 /// - `ok(v)` / `err(e)`：泛型枚举用例，期望 `Result<T, E>` → 用 `T` / `E` 特化后校验；
 /// - `圆(半径)`：普通枚举用例，期望 `形状`；
 /// - `none`：无关联值用例（标识符形态）。
 ///
 /// 期望类型与表达式不匹配该模式时返回 `false`，走原有比对路径（零回归）。
 private func refineEnumCaseConstruction(expr: Expression, expected: TypeAnnotation) throws -> Bool {
 let caseName: String
 var args: [CallArgument] = []
 let location: SourceLocation

 switch expr {
 case .call(let callee, let arguments, let loc):
 guard case .identifier(let n, _) = callee else { return false }
 caseName = n
 args = arguments
 location = loc
 case .identifier(let n, let loc):
 // 无关联值用例仅当其确为枚举用例、且当前作用域没有同名变量遮蔽时才走此路径
 guard typeEnv.lookupVariable(name: n) == nil else { return false }
 caseName = n
 location = loc
 default:
 return false
 }

 // ADR-026 D1：期望类型命中的候选枚举优先；仅全局唯一时退回单值反查
 let caseCandidates = typeEnv.parentEnums(of: caseName)
 var refinedParent: String? = nil
 switch expected {
 case .simple(let eName, _): if caseCandidates.contains(eName) { refinedParent = eName }
 case .generic(let eName, _, _): if caseCandidates.contains(eName) { refinedParent = eName }
 default: break
 }
 if refinedParent == nil {
 refinedParent = caseCandidates.count == 1 ? caseCandidates[0] : typeEnv.parentEnum(of: caseName)
 }
 guard let parent = refinedParent else { return false }

 // arity（关联参数个数）已由 checkExpression → checkEnumCaseConstruction 统一校验（与期望类型无关），
 // 此处不再重复，避免双重报错。本函数仅补充「泛型枚举特化类型」下的逐参数类型比对：
 // 非泛型枚举的基础类型比对已由 checkEnumCaseConstruction 完成。
 switch expected {
 case .generic(let eName, let typeArgs, _) where eName == parent:
 guard let fields = typeEnv.lookupSpecializedEnumCase(
 typeName: parent, typeArgs: typeArgs, caseName: caseName
 ) else { return true } // 泛型实参个数不符等：已由注解校验路径覆盖，此处不重复报错
 for (i, arg) in args.enumerated() where i < fields.count {
 guard let actual = inference.infer(expression: arg.expression) else { continue }
 if !isAssignable(actual: actual, expected: fields[i].type) {
 try report(TypeError.mismatch(
 expected: fields[i].type.describe(),
 got: actual.describe(),
 location: location
 ))
 }
 }
 return true
 default:
 return false
 }
 }

 /// MED-3：枚举用例构造的 arity（关联参数个数）**始终**校验，与是否有期望类型上下文无关。
 /// 同时在不依赖期望类型的路径上做基础类型比对——但仅对非泛型枚举：泛型枚举的字段类型是占位符
 /// （如 `T`），比对无意义，留待 `refineEnumCaseConstruction` 在「期望特化类型」下推路径单独校验，
 /// 以免误报。覆盖所有构造现场：变量初始化、`return`、赋值右值、函数实参、表达式语句（均经 `checkExpression`）。
 /// P5-5 B3：枚举用例构造 arity/类型校验。
 /// - `parent == nil`：未限定构造（圆(5.0)），经 `typeEnv.parentEnum(of:)` 反查父枚举（唯一名场景）；
 /// - `parent != nil`：限定构造（形状.圆(5.0)），直接按 (父, case) 校验（支持跨枚举同名 case）。
 private func checkEnumCaseConstruction(
 parent: String?, caseName: String, args: [CallArgument], location: SourceLocation
 ) throws {
 let resolvedParent: String?
 if let p = parent {
 resolvedParent = p
 } else {
 resolvedParent = typeEnv.parentEnum(of: caseName)
 }
 guard let parent = resolvedParent else { return }
 // ADR-026 D1：同名 case 跨枚举歧义时，不得按单一猜测父枚举做 arity/类型校验
 // （E4-005 错误参量数即由此而来）；退化为「拟合任一候选即放行」，精度交由
 // refineEnumCaseConstruction（期望类型下推）与运行时动态消歧承担。
 let caseCandidates = typeEnv.parentEnums(of: caseName)
 if caseCandidates.count > 1 {
 var fitsSome = false
 for cand in caseCandidates {
 guard let req = typeEnv.enumCaseRequiredArity(enumName: cand, caseName: caseName) else { continue }
 let total = typeEnv.lookupEnumCaseFields(enumName: cand, caseName: caseName)?.count ?? 0
 if (req...total).contains(args.count) { fitsSome = true; break }
 }
 if !fitsSome {
 try report(TypeError.argumentCountMismatch(
 expected: args.count, got: args.count, location: location
 ))
 }
 return
 }
 // 具名关联值决议（2026-08-29）：声明为具名形态时标签实参合法（按名对位）；
 // 位置声明仍拒绝具名实参（规则 3.15 残余）。
 let declaredNames = typeEnv.lookupEnumCaseFields(enumName: parent, caseName: caseName) ?? []
 let declaredNamed = declaredNames.allSatisfy { $0.name != nil } && !declaredNames.isEmpty
 if !declaredNamed, let labeled = args.first(where: { $0.label != nil }) {
 try report(TypeError.enumCaseArgumentLabel(
 label: labeled.label!, caseName: caseName, location: location
 ))
 return
 }
 let fields = typeEnv.lookupEnumCaseFields(enumName: parent, caseName: caseName) ?? []
 let total = fields.count
 // arity 合法区间 = [必填个数 … 总字段数]；必填个数 = 总字段数 − 带默认值的字段数
 // （如 `东(0)` 的 `东()` 合法）。既不容许多传也不容少传必填项。
 guard let required = typeEnv.enumCaseRequiredArity(enumName: parent, caseName: caseName) else { return }
 guard (required...total).contains(args.count) else {
 let expected = args.count < required ? required : total
 try report(TypeError.argumentCountMismatch(
 expected: expected, got: args.count, location: location
 ))
 return
 }
 // 泛型枚举的关联值类型为占位符（如 `T`），基础比对会误报；类型校验交由
 // refineEnumCaseConstruction 在期望特化类型下推路径处理。
 if typeEnv.genericEnumParamCount(name: parent) == nil {
 for (i, arg) in args.enumerated() {
 guard let actual = inference.infer(expression: arg.expression) else { continue }
 if !isAssignable(actual: actual, expected: fields[i].type) {
 try report(TypeError.mismatch(
 expected: fields[i].type.describe(),
 got: actual.describe(),
 location: location
 ))
 }
 }
 }
 }

 private func checkEnumCaseConstruction(
 calleeName: String, args: [CallArgument], location: SourceLocation
 ) throws {
 try checkEnumCaseConstruction(parent: nil, caseName: calleeName, args: args, location: location)
 }

 private func registerTopLevelDeclSignature(_ decl: TopLevelDecl) {
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 switch decl {
 case .funcDecl(let f):
 // 保留形参个数（即使未标注类型也用 "_" 哨兵占位），以保证参数个数校验不因缺省类型而失真
 let paramTypes = f.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: f.location) }
 // 立场 B：`=>` 函数的签名返回类型为 Future<T, Error>（`=> T` 是语法糖）
 let returnTypes = TypeChecker.signatureReturns(of: f)
 // B3-1：登记并发进程的形参名，供任务隔离检查在报错时指名道姓
 if f.isAsync { asyncFunctionParamNames[f.name] = f.params.map { $0.name } }
 if !f.genericParams.isEmpty {
 // P3-0：泛型函数模板注册——供调用点 T 占位通配比对（端到端）
 typeEnv.defineGenericFunction(
 name: f.name,
 genericParams: f.genericParams.map { $0.name },
 params: paramTypes,
 returns: returnTypes
 )
 } else {
 typeEnv.defineFunction(name: f.name, params: paramTypes, returns: returnTypes)
 }
 case .structDecl(let s):
 typeFieldsByName[s.name] = s.fields.map { ($0.name, $0.typeAnnotation ?? .simple(name: "_", location: $0.location)) }
 if !s.genericParams.isEmpty {
 let fieldInfos = s.fields.map { (name: $0.name, type: $0.typeAnnotation) }
 let methodInfos = s.methods.map {
 (name: $0.name,
 params: $0.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: loc) },
 returns: $0.returnTypes)
 }
 typeEnv.defineGenericStruct(
 name: s.name,
 genericParams: s.genericParams.map { $0.name },
 fields: fieldInfos,
 methods: methodInfos
 )
 } else {
 let fieldInfos = s.fields.map { (name: $0.name, type: $0.typeAnnotation) }
 typeEnv.defineStruct(name: s.name, fields: fieldInfos)
 for method in s.methods {
 let paramTypes = method.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: loc) }
 typeEnv.defineMethod(typeName: s.name, methodName: method.name, params: paramTypes, returns: method.returnTypes)
 if method.isAsync { asyncMethodParamNames["\(s.name).\(method.name)"] = method.params.map { $0.name } }
 }
 registerTraitMethods(for: s.name, traits: s.traits, location: loc)
 }
 case .objectDecl(let o):
 referenceTypeNames.insert(o.name)
 typeFieldsByName[o.name] = o.fields.map { ($0.name, $0.typeAnnotation ?? .simple(name: "_", location: $0.location)) }
 if !o.genericParams.isEmpty {
 let fieldInfos = o.fields.map { (name: $0.name, type: $0.typeAnnotation) }
 let methodInfos = o.methods.map {
 (name: $0.name,
 params: $0.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: loc) },
 returns: $0.returnTypes)
 }
 typeEnv.defineGenericStruct(
 name: o.name,
 genericParams: o.genericParams.map { $0.name },
 fields: fieldInfos,
 methods: methodInfos
 )
 } else {
 let fieldInfos = o.fields.map { (name: $0.name, type: $0.typeAnnotation) }
 typeEnv.defineStruct(name: o.name, fields: fieldInfos)
 for method in o.methods {
 let paramTypes = method.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: loc) }
 typeEnv.defineMethod(typeName: o.name, methodName: method.name, params: paramTypes, returns: method.returnTypes)
 if method.isAsync { asyncMethodParamNames["\(o.name).\(method.name)"] = method.params.map { $0.name } }
 }
 registerTraitMethods(for: o.name, traits: o.traits, location: loc)
 }
 case .enumDecl(let e):
 // 注册判别联合：将各用例的关联参数（字段名? + 类型）存入类型环境，
 // 供 variant→union 可赋值性校验与 match 模式绑定类型注入使用。
 // 同时记录「带默认值的字段数」，使构造期 arity 校验可容忍字面量默认值。
 var caseMap: [String: [(name: String?, type: TypeAnnotation)]] = [:]
 var defaultedCounts: [String: Int] = [:]
 for c in e.cases {
 caseMap[c.name] = c.associatedParams.map { (name: $0.name, type: $0.type) }
 defaultedCounts[c.name] = c.associatedParams.filter { $0.defaultValue != nil }.count
 }
 if !e.genericParams.isEmpty {
 // P5 B0-1：泛型枚举模板注册（特化路径闭合 R1）
 typeEnv.defineGenericEnum(
 name: e.name,
 genericParams: e.genericParams.map { $0.name },
 cases: caseMap,
 defaultedCounts: defaultedCounts
 )
 } else {
 typeEnv.defineEnum(name: e.name, cases: caseMap, defaultedCounts: defaultedCounts)
 }
 case .traitDecl(let t):
 typeEnv.defineTrait(name: t.name, trait: t)
 case .extensionDecl(let x):
 // ADR-016 规则 3.2/3.14：扩展块方法注册到目标类型（与类型自身方法同等对待）。
 registerExtensionMethods(x)
 case .foreignDecl(let fd):
 // Phase 2a（ADR-015 FFI）：外部 C 函数签名注册为模块级函数（块内函数自动 |unsafe）。
 for f in fd.funcs {
 let paramTypes = f.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: f.location) }
 typeEnv.defineFunction(name: f.name, params: paramTypes, returns: f.returnTypes)
 }
 case .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 // MARK: - Phase 2a ADR-015：`*T` C 兼容性校验（ARC 隔离）

 /// 遍历声明的全部类型注解并校验 `*T` 元素 C 兼容性。
 private func validateDeclPointerTypes(_ decl: TopLevelDecl) throws {
 switch decl {
 case .structDecl(let s):
 for f in s.fields { try validatePointerAnnotations(f.typeAnnotation) }
 for m in s.methods { try validateFuncDeclPointerTypes(m) }
 case .objectDecl(let o):
 for f in o.fields { try validatePointerAnnotations(f.typeAnnotation) }
 for m in o.methods { try validateFuncDeclPointerTypes(m) }
 case .enumDecl(let e):
 for c in e.cases {
 for ap in c.associatedParams { try validatePointerAnnotations(ap.type) }
 }
 for m in e.methods { try validateFuncDeclPointerTypes(m) }
 case .funcDecl(let f):
 try validateFuncDeclPointerTypes(f)
 case .traitDecl(let t):
 for sig in t.signatures { try validateFuncDeclPointerTypes(sig) }
 case .extensionDecl(let x):
 for m in x.methods { try validateFuncDeclPointerTypes(m) }
 case .foreignDecl(let fd):
 for f in fd.funcs { try validateFuncDeclPointerTypes(f) }
 case .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 private func validateFuncDeclPointerTypes(_ f: FuncDecl) throws {
 for p in f.params {
 if let ta = p.typeAnnotation { try validatePointerAnnotations(ta) }
 }
 for r in f.returnTypes { try validatePointerAnnotations(r) }
 }

 /// 递归校验一个类型注解内的所有 `*T`：元素须 C 兼容（标量/纯值结构体/另一指针），
 /// 禁 object 及含 object 字段的复合类型（ ARC 隔离）。
 private func validatePointerAnnotations(_ annotation: TypeAnnotation) throws {
 switch annotation {
 case .pointer(let element, let loc):
 try validatePointerAnnotations(element)
 var visiting: Set<String> = []
 if let hit = cCompatibilityFailure(in: element, visiting: &visiting) {
 try report(TypeError.mismatch(
 expected: "C 兼容类型（标量 / 纯值结构体 / 另一指针）",
 got: "`\(element.describe())` 含非 C 兼容类型 \(hit)（`*T` 不得指向 object 或含 object 的复合类型，ARC 隔离）",
 location: loc
 ))
 }
 case .tuple(_, let elements, _):
 for e in elements { try validatePointerAnnotations(e) }
 case .generic(_, let params, _):
 for p in params { try validatePointerAnnotations(p) }
 case .function(let params, let returns, _, _):
 for p in params { try validatePointerAnnotations(p) }
 for r in returns { try validatePointerAnnotations(r) }
 case .simple:
 break
 }
 }

 /// 返回类型中首个非 C 兼容的类型名（object / 含 object 字段的结构体），否则 nil。
 /// `visiting` 防自引用结构体（如链表节点 `next: Node`）无限递归。
 private func cCompatibilityFailure(in type: TypeAnnotation, visiting: inout Set<String>) -> String? {
 switch type {
 case .simple(let name, _):
 if referenceTypeNames.contains(name) { return name }
 if isCScalarType(name) { return nil }
 guard let fields = typeFieldsByName[name] else { return nil } // 未知类型保守放行
 guard !visiting.contains(name) else { return nil }
 visiting.insert(name)
 for (_, ftype) in fields {
 if let hit = cCompatibilityFailure(in: ftype, visiting: &visiting) { return hit }
 }
 return nil
 case .pointer:
 return nil // 指针本身 C 兼容
 case .tuple(_, let elements, _):
 for e in elements {
 if let hit = cCompatibilityFailure(in: e, visiting: &visiting) { return hit }
 }
 return nil
 case .generic(_, let params, _):
 for p in params {
 if let hit = cCompatibilityFailure(in: p, visiting: &visiting) { return hit }
 }
 return nil
 case .function:
 return "函数类型"
 }
 }

 private func isCScalarType(_ name: String) -> Bool {
 switch name {
 case "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64",
 "F32", "F64", "Bool", "Char", "Void", "Unit":
 return true
 default:
 return false
 }
 }

 /// 把扩展块方法注册进目标类型的方法表（struct/object/enum 统一走 defineMethod）。
 /// 目标类型必须已注册（扩展块与其类型同文件、声明顺序由「数据与逻辑分离」保证类型在前）。
 private func registerExtensionMethods(_ x: ExtensionDecl) {
 for method in x.methods {
 let paramTypes = method.params.map { $0.typeAnnotation ?? TypeAnnotation.simple(name: "_", location: method.location) }
 typeEnv.defineMethod(typeName: x.targetType, methodName: method.name, params: paramTypes, returns: method.returnTypes)
 if method.isAsync { asyncMethodParamNames["\(x.targetType).\(method.name)"] = method.params.map { $0.name } }
 }
 // trait 扩展（<<T>>）：方法追加进 trait 签名，供后续 conformance 校验可见。
 if x.kind == .traitExt, let trait = typeEnv.lookupTrait(name: x.targetType) {
 let merged = TraitDecl(
 name: trait.name,
 genericParams: trait.genericParams,
 signatures: trait.signatures + x.methods,
 location: trait.location
 )
 typeEnv.defineTrait(name: x.targetType, trait: merged)
 }
 }

 // MARK: - 声明检查

 private func checkTopLevelDecl(_ decl: TopLevelDecl) throws {
 // Phase 2a（ADR-015 FFI）：`*T` 元素须为 C 兼容类型（标量/纯值结构体/指针），
 // 禁 object 及含 object 字段的复合类型（ARC 隔离）。此时 register 已完成，类型表完整。
 try validateDeclPointerTypes(decl)
 switch decl {
 case .funcDecl(let f):
 try checkFuncBody(f)
 case .structDecl(let s):
 for method in s.methods {
 try checkFuncBody(method, fields: s.fields.map { ($0.name, $0.typeAnnotation ?? .simple(name: "_", location: $0.location)) }, typeName: s.name)
 }
 if !s.traits.isEmpty { try verifyTraitConformance(typeName: s.name, traits: s.traits, location: s.location) }
 case .objectDecl(let o):
 for method in o.methods {
 try checkFuncBody(method, fields: o.fields.map { ($0.name, $0.typeAnnotation ?? .simple(name: "_", location: $0.location)) }, typeName: o.name)
 }
 if !o.traits.isEmpty { try verifyTraitConformance(typeName: o.name, traits: o.traits, location: o.location) }
 case .enumDecl(let e):
 for method in e.methods { try checkFuncBody(method) }
 case .extensionDecl(let x):
 // 扩展方法体检查：注入目标类型字段（同文件扩展块可访问私有字段）。
 let targetFields = typeFieldsByName[x.targetType] ?? []
 for method in x.methods {
 try checkFuncBody(method, fields: targetFields, typeName: x.targetType)
 }
 case .foreignDecl(let fd):
 // Phase 2a（ADR-015 FFI）：顶层签名静态校验——拒绝 by-value 结构体（Phase 2c）、
 // 元组、函数指针、泛型；标量 / 指针 / 引用类型（含 shim 友好的 String）放行（shim 经原生函数表解析，
 // 裸 C 绑定 C 兼容校验见 Phase 2b）。
 try checkForeignDeclSignatures(fd)
 case .traitDecl, .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 // MARK: - Phase 2a ADR-015 FFI：顶层签名静态校验

 /// 顶层 FFI 签名白名单（C 兼容标量，含 Char；Void/Unit 兼容 void 返回）。
 private static let ffiTopLevelScalars: Set<String> = [
 "I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64",
 "F32", "F64", "Bool", "Void", "Unit"
 ]

 /// 校验 `[名称|foreign]` 块内每个函数的顶层参数与返回类型。
 /// 仅拒绝 by-value 结构体（Phase 2c）、元组、函数指针、泛型；
 /// 标量 / 指针 / 引用类型（含 shim 友好的 String/Optional/Result）放行——
 /// 后者由解析期 fail-fast（shim 须在原声函数表）与 Phase 2b 裸绑定 C 兼容校验兜底。
 private func checkForeignDeclSignatures(_ fd: ForeignDecl) throws {
 for f in fd.funcs {
 for p in f.params {
 if let ta = p.typeAnnotation { try checkFFITopLevelType(ta, location: f.location) }
 }
 for r in f.returnTypes { try checkFFITopLevelType(r, location: f.location) }
 }
 }

 private func checkFFITopLevelType(_ t: TypeAnnotation, location: SourceLocation) throws {
 switch t {
 case .simple(let name, let loc):
 if Self.ffiTopLevelScalars.contains(name) { return }
 // 引用类型（object，含内建 String 等）：仅 shim 可承载，放行（解析期 fail-fast 兜底）。
 if referenceTypeNames.contains(name) { return }
 // by-value 结构体：Phase 2c（可选）才支持；此处已排除 object（referenceTypeNames 先行返回），必为 struct。
 if typeFieldsByName[name] != nil {
 try report(TypeError.mismatch(
 expected: "C 兼容标量 / 指针 / 引用类型（shim）",
 got: "by-value 结构体 `\(name)` 不可作为 FFI 顶层类型（Phase 2c 才支持，见 ）",
 location: loc
 ))
 return
 }
 // 其它已知用户类型（枚举等）与未知简单名：shim 可能承载，放行（解析期 fail-fast 兜底）。
 return
 case .pointer:
 return // 元素由 validatePointerAnnotations 独立校验（禁 object / 含 object 复合类型）
 case .tuple:
 try report(TypeError.mismatch(
 expected: "C 兼容标量 / 指针",
 got: "元组类型不可作为 FFI 顶层类型（元组 ❌，见 ）",
 location: location
 ))
 case .generic, .function:
 try report(TypeError.mismatch(
 expected: "C 兼容标量 / 指针",
 got: "泛型/函数指针类型不可作为 FFI 顶层类型（函数指针属 Phase 2b，见 ）",
 location: location
 ))
 }
 }

 private func checkFuncBody(_ funcDecl: FuncDecl, fields: [(name: String, type: TypeAnnotation)] = [], typeName: String? = nil) throws {
 guard let body = funcDecl.body else { return }
 // Phase 2a（ADR-015 FFI）：`|unsafe` 函数体自动处于不安全上下文。
 // foreign 块内函数声明时已被注入 `unsafe` 修饰符（本路径无 body，不进入）。
 let bodyUnsafe = funcDecl.modifiers.contains("unsafe")
 if bodyUnsafe { unsafeContextDepth += 1 }
 defer { if bodyUnsafe { unsafeContextDepth -= 1 } }
 typeEnv.pushScope()
 // 方法体作用域：注册 self 与所属类型字段，使字段引用可参与类型推断（P3-1 示例 trait.pini 触发）。
 // 字段先于参数注册，参数可遮蔽同名字段。
 if !fields.isEmpty {
 if let tn = typeName {
 typeEnv.defineVariable(name: "self", type: .simple(name: tn, location: funcDecl.location))
 }
 for (fname, ftype) in fields {
 typeEnv.defineVariable(name: fname, type: ftype)
 }
 }
 for param in funcDecl.params {
 if let paramType = param.typeAnnotation {
 typeEnv.defineVariable(name: param.name, type: paramType)
 }
 }
 for stmt in body.statements {
 try checkStatement(stmt)
 }
 if !funcDecl.returnTypes.isEmpty {
 // P2-1.3 + P2-2：返回类型经结构等价精确比对（含元组返回与多返回）；
 // void（returnTypes 为空，即 -> ()）已在上方 !isEmpty 守卫跳过（放行带值返回）。
 // 立场 B：`=>` 函数体内 return 的期望类型为 Result<T, Error>（错误即数据）。
 let expected = TypeChecker.bodyReturns(of: funcDecl)

 var findings: [ReturnFinding] = []
 try collectReturnFindings(in: body, into: &findings)
 for f in findings {
 if !f.hasValue {
 // 非 void 函数中裸 return（返回 void）→ 期望返回类型，实际 void
 let expectedDesc = expected.map { $0.describe() }.joined(separator: ", ")
 try report(TypeError.mismatch(expected: expectedDesc, got: "()", location: f.location))
 }
 // 立场 B / 判别联合：`return ok(v)` / `return err(e)` / `return 圆(r)` 这类
 // 「枚举用例构造」在期望类型为该枚举（或其特化）时，按期望类型下推校验实参，
 // 而非拿用例名做结构等价比对（用例名不是类型名，直接比对必然失配）。
 if expected.count == 1, let e = f.expr,
 try refineEnumCaseConstruction(expr: e, expected: expected[0]) {
 continue
 }
 guard let actual = f.type else { continue } // 无法推断则跳过
 if expected.count == 1 {
 if !expected[0].isStructurallyEquivalent(to: actual) {
 try report(TypeError.mismatch(expected: expected[0].describe(), got: actual.describe(), location: f.location))
 }
 } else {
 // 多返回：actual 须为同长度元组且逐分量等价
 if case .tuple(_, let actualElems, _) = actual, actualElems.count == expected.count {
 for (i, exp) in expected.enumerated() {
 if !exp.isStructurallyEquivalent(to: actualElems[i]) {
 try report(TypeError.mismatch(expected: exp.describe(), got: actualElems[i].describe(), location: f.location))
 }
 }
 } else {
 let expectedDesc = expected.map { $0.describe() }.joined(separator: ", ")
 try report(TypeError.mismatch(expected: expectedDesc, got: actual.describe(), location: f.location))
 }
 }
 }
 }
 typeEnv.popScope()
 }

 /// 收集函数体内所有 return 语句的返回信息（是否带值 + 推断类型 + 位置）。
 /// 用于 P2-1.3 / P2-2 返回类型一致性校验；不递归进入内层 lambda（lambda 有独立返回语义）。
 private typealias ReturnFinding = (
 hasValue: Bool,
 type: TypeAnnotation?,
 expr: Expression?,
 location: SourceLocation
 )

 /// 在类型环境中为单个 match case 推入作用域并注入模式绑定的变量（取自枚举用例关联参数类型），
 /// 执行闭包后弹出作用域。供「语句检查」与「return 收集」两处复用，确保绑定变量在类型层可用。
 ///
 /// `subjectType` 为被 match 的表达式类型：当它是**泛型枚举的特化类型**（如 `Result<I32, Error>`）
 /// 时，用其类型实参特化用例关联参数，使 `case ok(v)` 中的 `v` 精确得到 `I32`
 /// （G12，：`await`/`wait` fut 结果 match 是错误即数据的主要收口路径）。为空或非泛型时沿用原路径。
 private func withMatchCaseBindings(
 _ c: MatchCase,
 subjectType: TypeAnnotation? = nil,
 _ body: () throws -> Void
 ) throws {
 typeEnv.pushScope()
 // ADR-026 D2：歧义 case 名按 scrutinee 类型在候选集中解析，
 // 不得信任单值反查（跨枚举同名会绑到错误父枚举的字段，E4-005）。
 var resolvedParent: String? = nil
 if case .enumCase(let name) = c.pattern {
 let candidates = typeEnv.parentEnums(of: name)
 if candidates.count == 1 {
 resolvedParent = candidates[0]
 } else if let st = subjectType {
 let sName: String?
 switch st {
 case .simple(let n, _): sName = n
 case .generic(let n, _, _): sName = n
 default: sName = nil
 }
 if let sName = sName, candidates.contains(sName) { resolvedParent = sName }
 }
 if resolvedParent == nil { resolvedParent = typeEnv.parentEnum(of: name) }
 }
 if case .enumCase(let name) = c.pattern,
 let parent = resolvedParent,
 case .generic(let subjectName, let typeArgs, _)? = subjectType,
 subjectName == parent,
 let fields = typeEnv.lookupSpecializedEnumCase(
 typeName: parent, typeArgs: typeArgs, caseName: name
 ) {
 try bindMatchCaseVariables(c, fields: fields)
 } else if case .enumCase(let name) = c.pattern,
 let parent = resolvedParent,
 let fields = typeEnv.lookupEnumCase(enumName: parent, caseName: name) {
 try bindMatchCaseVariables(c, fields: fields)
 }
 try body()
 typeEnv.popScope()
 }

 /// 将 match 用例的解构绑定按「具名优先、否则按位」注入当前作用域。
 /// 绑定数与关联值数不匹配 → E4 类型错误（ADR 具名关联值决议 2026-08-29 决策 D；
 /// 此前静默错绑/兜底 Any）。`_` 占位计入数量但不注入变量。
 private func bindMatchCaseVariables(
 _ c: MatchCase,
 fields: [(name: String?, type: TypeAnnotation)]
 ) throws {
 if !c.bindings.isEmpty, c.bindings.count != fields.count {
 try report(TypeError.argumentCountMismatch(
 expected: fields.count,
 got: c.bindings.count,
 location: c.location
 ))
 return
 }
 for (index, binding) in c.bindings.enumerated() {
 if binding.varName == "_" { continue }
 let type: TypeAnnotation
 if let pname = binding.paramName,
 let matched = fields.first(where: { $0.name == pname }) {
 type = matched.type
 } else if index < fields.count {
 type = fields[index].type
 } else {
 type = TypeAnnotation.simple(name: "Any", location: c.location)
 }
 typeEnv.defineVariable(name: binding.varName, type: type)
 }
 }

 private func collectReturnFindings(in block: Block, into result: inout [ReturnFinding]) throws {
 for stmt in block.statements {
 switch stmt {
 case .returnStatement(let value, let location):
 if let v = value {
 // 注：即使推断为 nil（如枚举用例构造、lambda 等），仍记为「带值返回」并保留原
 // 表达式，供 checkFuncBody 按期望类型下推（refineEnumCaseConstruction）复核。
 result.append((
 hasValue: true,
 type: inference.infer(expression: v),
 expr: v,
 location: location
 ))
 } else {
 result.append((hasValue: false, type: nil, expr: nil, location: location))
 }
 case .ifStatement(_, let thenBlock, let elifs, let elseBlock, _, _):
 try collectReturnFindings(in: thenBlock, into: &result)
 for elif in elifs {
 try collectReturnFindings(in: elif.block, into: &result)
 }
 if let eb = elseBlock {
 try collectReturnFindings(in: eb, into: &result)
 }
 case .whileStatement(_, let body, let step, _, _):
 try collectReturnFindings(in: body, into: &result)
 if let step = step { try collectReturnFindings(in: step, into: &result) }
 case .forStatement(_, _, let body, let step, _, _):
 try collectReturnFindings(in: body, into: &result)
 if let step = step { try collectReturnFindings(in: step, into: &result) }
 case .matchStatement(let subject, let cases, _):
 let subjectType = inference.infer(expression: subject)
 for c in cases {
 try withMatchCaseBindings(c, subjectType: subjectType) {
 try collectReturnFindings(in: c.block, into: &result)
 }
 }
 // D3①：`case _:` 通配已作为 case 进入 cases（case 循环覆盖），无独立 default/wildcard 块。
 case .tryStatement(_, let tryBlock, let exceptClauses, _):
 try collectReturnFindings(in: tryBlock, into: &result)
 for exc in exceptClauses {
 try collectReturnFindings(in: exc.body, into: &result)
 }
 default:
 break
 }
 }
 }

 private func typeName(from annotation: TypeAnnotation) -> String {
 switch annotation {
 case .simple(let name, _):
 return name
 case .tuple, .generic, .function:
 return "" // 复杂类型暂不深入比较
 case .pointer:
 return "" // 指针类型暂不参与类型名比较（C 兼容性校验在别处）
 }
 }

 // MARK: - 语句检查

 private func checkStatement(_ stmt: Statement) throws {
 switch stmt {
 case .varDecl(let name, _, let initializer, let isMutable, let location):
 let declaredType: TypeAnnotation
 if let initExpr = initializer {
 try checkExpression(initExpr)
 declaredType = inference.infer(expression: initExpr) ?? .simple(name: "Any", location: location)
 } else {
 declaredType = .simple(name: "Any", location: location)
 }
 typeEnv.defineVariable(name: name, type: declaredType, isMutable: isMutable)

 case .varDestructure(let names, _, let initializer, let isMutable, let location):
 // 草稿 A1（批次 1）：右值必须推断为元组且分量数等于绑定数（含 `_` 占位）。
 guard let initExpr = initializer else {
 try report(TypeError.mismatch(expected: "tuple", got: "missing initializer", location: location))
 break
 }
 try checkExpression(initExpr)
 guard let tupleType = inference.infer(expression: initExpr) else { break }
 var elemTypes: [TypeAnnotation] = []
 switch tupleType {
 case .tuple(_, let elems, _):
 elemTypes = elems
 default:
 try report(TypeError.mismatch(expected: "tuple", got: tupleType.describe(), location: location))
 break
 }
 if names.count != elemTypes.count {
 try report(TypeError.mismatch(
 expected: "tuple(\(elemTypes.count))",
 got: "bind \(names.count)",
 location: location
 ))
 break
 }
 for (i, name) in names.enumerated() where name != "_" {
 typeEnv.defineVariable(name: name, type: elemTypes[i], isMutable: isMutable)
 }

 case .assign(let target, let value, let location):
 try checkExpression(value)
 switch target {
 case .identifier(let name):
 // P3-3：`let` 不可变边界静态检查——提前于运行时 immutableVariable 捕获重赋值。
 if let mutable = typeEnv.lookupVariableMutability(name: name), !mutable {
 try report(TypeError.reassignmentToImmutable(variableName: name, location: location))
 }
 if let varType = typeEnv.lookupVariable(name: name),
 let valType = inference.infer(expression: value) {
 if !isAssignable(actual: valType, expected: varType) {
 try report(TypeError.mismatch(expected: typeName(from: varType), got: typeName(from: valType), location: location))
 }
 }
 case .member(let object, let name):
 // P4.5：字段写同样受 type-private 约束（与读对称）；写入方须为声明类型自身方法。
 try enforceFieldVisibility(object: object, fieldName: name, location: location)
 // P3-3 加固：根是不可变 let 绑定时拒绝字段写。
 // 但引用类型（object）的 let 仅约束引用本身、对象内容仍可变，须豁免（见 referenceTypeNames）；
 // 仅值类型（struct）整体不可变才拦截。self 豁免——方法内实例字段写按设计走 self.字段 路径。
 if case .identifier(let rootName, _) = object, rootName != "self" {
 if let mutable = typeEnv.lookupVariableMutability(name: rootName), !mutable {
 let rootTypeName: String? = {
 guard let t = typeEnv.lookupVariable(name: rootName) else { return nil }
 switch t {
 case .simple(let n, _): return n
 case .generic(let n, _, _): return n
 default: return nil
 }
 }()
 if let typeName = rootTypeName, referenceTypeNames.contains(typeName) {
 // 引用类型：let 只约束引用，字段写允许——豁免
 } else {
 try report(TypeError.reassignmentToImmutable(variableName: rootName, location: location))
 }
 }
 }
 // 字段类型校验：成员赋值须与字段声明类型一致（P3-3 加固——此前成员赋值完全不做类型检查）。
 // AssignTarget.member 为 (object, name) 二元组，需重组为 Expression.member(object, name, location) 再推断字段类型。
 if let fieldType = inference.infer(expression: .member(object: object, name: name, location: location)),
 let valType = inference.infer(expression: value),
 !isAssignable(actual: valType, expected: fieldType) {
 try report(TypeError.mismatch(expected: typeName(from: fieldType), got: typeName(from: valType), location: location))
 }
 case .subscript(let containerExpr, let indexExpr):
 // #46-D D1.5：数组下标写。元素级类型不进入类型系统（D1 决策），仅做索引检查 +
 // identifier 容器 `let` 不可变静态拦截（与解释器运行时 immutableVariable 锁步）。
 try checkExpression(indexExpr)
 if case .identifier(let name, _) = containerExpr {
 if let mutable = typeEnv.lookupVariableMutability(name: name), !mutable {
 try report(TypeError.reassignmentToImmutable(variableName: name, location: location))
 }
 }
 }
 case .returnStatement(let value, _):
 if let v = value { try checkExpression(v) }

 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
 try checkExpression(condition)
 for s in thenBlock.statements { try checkStatement(s) }
 for elif in elifs {
 try checkExpression(elif.condition)
 for s in elif.block.statements { try checkStatement(s) }
 }
 if let els = elseBlock {
 for s in els.statements { try checkStatement(s) }
 }

 case .whileStatement(let condition, let body, let step, _, _):
 try checkExpression(condition)
 for s in body.statements { try checkStatement(s) }
 if let step = step { for s in step.statements { try checkStatement(s) } }

 case .forStatement(_, let iterable, let body, let step, _, _):
 try checkExpression(iterable)
 for s in body.statements { try checkStatement(s) }
 if let step = step { for s in step.statements { try checkStatement(s) } }

 case .scopedBlock(_, let body, _):
 for s in body.statements { try checkStatement(s) }

 case .matchStatement(let value, let cases, _):
 try checkExpression(value)
 let subjectType = inference.infer(expression: value)
 for c in cases {
 try withMatchCaseBindings(c, subjectType: subjectType) {
 for s in c.block.statements { try checkStatement(s) }
 }
 }
 // D3①：`case _:` 通配已作为 case 进入 cases（case 循环覆盖），无独立 default/wildcard 块。

 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 try checkExpression(expression)
 for s in tryBlock.statements { try checkStatement(s) }
 for exc in exceptClauses {
 for s in exc.body.statements { try checkStatement(s) }
 }

 case .expressionStmt(let expr, _):
 try checkExpression(expr)

 case .detachStatement(let expr, _):
 try checkExpression(expr)

 case .deferStatement(let statement, _):
 try checkStatement(statement)

 case .breakStatement, .continueStatement:
 break
 case .passStatement(_):
 break
 }
 }

 // MARK: - 表达式检查

 private func checkExpression(_ expr: Expression) throws {
 switch expr {
 case .binary(let left, let op, let right, let location):
 try checkExpression(left)
 try checkExpression(right)
 try checkBinaryOperandTypes(left: left, op: op, right: right, location: location)

 case .unary(let op, let operand, let location):
 if op == .forceUnwrap {
 // 强制解包 `!` 仅在 unsafe 上下文可用（与 `&` 取地址同构）。
 guard unsafeContextDepth > 0 else {
 try report(TypeError.mismatch(
 expected: "unsafe 上下文（`|unsafe` 函数体或 `unsafe (...)` 消耗点）",
 got: "强制解包 `!` 出现在非 unsafe 上下文",
 location: location
 ))
 return
 }
 try checkExpression(operand)
 // 操作数须为 Optional<T>；可静态解析为具体非 Optional 类型时报错，不可推断（nil）时放行。
 if let operandType = inference.infer(expression: operand) {
 let isOptional: Bool
 if case .generic(let name, _, _) = operandType { isOptional = (name == "Optional") }
 else { isOptional = false }
 if !isOptional {
 try report(TypeError.mismatch(
 expected: "Optional<T>",
 got: operandType.describe(),
 location: location
 ))
 }
 }
 return
 }
 try checkExpression(operand)

 case .resultUnwrap(let operand, let location):
 // 草稿 A2（批次 1.4，D2）：`^expr` 要求操作数推断为 Result<T, E>（静态拦截）；
 // `ok(...)`/`err(...)` 为 Result 的用例构造（推断为 case 名），同样放行；推断不可达时由运行时兜底。
 try checkExpression(operand)
 if let t = inference.infer(expression: operand) {
 let isResult: Bool
 switch t {
 case .generic(let name, _, _): isResult = (name == "Result")
 case .simple(let name, _): isResult = (name == "Result" || name == "ok" || name == "err")
 default: isResult = false
 }
 if !isResult {
 try report(TypeError.mismatch(expected: "Result<T, E>", got: t.describe(), location: location))
 }
 }

 case .call(let callee, let arguments, let location):
 try checkExpression(callee)
 for arg in arguments { try checkExpression(arg.expression) }

 // P2-1 / P2-1.4 调用点校验：按被调用者形态分派
 switch callee {
 case .identifier(let calleeName, _):
 // MED-3：枚举用例构造 arity 始终校验（与期望类型无关），覆盖变量初始化/return/实参等
 try checkEnumCaseConstruction(calleeName: calleeName, args: arguments, location: location)
 if let sig = typeEnv.lookupFunction(name: calleeName) {
 try validateCallArguments(arguments: arguments, signature: sig, location: location)
 // B3-1：并发进程调用点的任务隔离——引用类型不得越过 `=>` 边界（消解 R6）
 if let paramNames = asyncFunctionParamNames[calleeName] {
 try enforceTaskIsolation(
 functionName: calleeName, paramNames: paramNames,
 arguments: arguments, signature: sig, location: location
 )
 }
 // P4 Phase 3：跨文件可见性 enforce——被调函数定义在其他文件且不可见时报错。
 if let ctx = packageContext,
 let entry = ctx.index.lookup(calleeName),
 !entry.isVisible(from: ctx.currentFileName) {
 try report(TypeError.inaccessibleSymbol(
 name: calleeName, definedIn: entry.fileName, level: entry.visibility, location: location
 ))
 }
 } else if let varType = typeEnv.lookupVariable(name: calleeName),
 case .function(let params, let returns, _, _) = varType {
 // 函数类型变量调用（f(...)：高阶函数形参 / 匿名函数绑定变量）——
 // 按变量函数类型校验实参（闭合 L1：匿名函数参数标注 + 函数类型实参校验）。
 try validateCallArguments(
 arguments: arguments,
 signature: TypeEnvironment.FunctionSignature(params: params, returns: returns),
 location: location
 )
 }
 case .member(let object, let memberName, _):
 // P5-5 B3：限定枚举构造 形状.圆(...) → 按 (父, case) 校验 arity/类型
 // （支持跨枚举同名 case，不依赖全局唯一反查）。Optional.some/none 内建不在
 // 用户枚举注册表，lookupEnumCase 返回 nil，自然落到下方成员方法校验分支。
 if case .identifier(let parentName, _) = object,
 typeEnv.lookupEnumCase(enumName: parentName, caseName: memberName) != nil {
 try checkEnumCaseConstruction(parent: parentName, caseName: memberName, args: arguments, location: location)
 } else if let sig = lookupMethodSignature(for: object, memberName: memberName) {
 try validateCallArguments(arguments: arguments, signature: sig, location: location)
 // B3-1：标了 `=>` 的方法与自由函数同等对待（方法也是并发进程的派发入口）
 if let recv = inference.infer(expression: object) {
 let recvName: String?
 switch recv {
 case .simple(let n, _): recvName = n
 case .generic(let n, _, _): recvName = n
 default: recvName = nil
 }
 if let typeName = recvName,
 let paramNames = asyncMethodParamNames["\(typeName).\(memberName)"] {
 try enforceTaskIsolation(
 functionName: "\(typeName).\(memberName)", paramNames: paramNames,
 arguments: arguments, signature: sig, location: location
 )
 }
 }
 } else if let objType = inference.infer(expression: object) {
 // P3-2 ③：已知内建类型（String/Array）上调用未注册成员 → 静态报错。
 // 接收者可能是简单类型（String）或泛型特化（Array<T>），取基类型名统一判定。
 // （P3 审查修复：原实现仅匹配 .simple，导致 Array<T> 静态未知成员检测完全失效，只能运行时兜底。）
 let baseName: String?
 switch objType {
 case .simple(let n, _): baseName = n
 case .generic(let n, _, _): baseName = n
 default: baseName = nil
 }
 if let typeName = baseName,
 TypeChecker.builtinTypesWithMembers.contains(typeName),
 typeEnv.lookupMethod(typeName: typeName, methodName: memberName) == nil {
 try report(TypeError.unknownMember(typeName: typeName, memberName: memberName, location: location))
 }
 }
 default:
 // 函数类型变量调用（f(...)：高阶函数形参 / 匿名函数绑定变量）——按 callee
 // 推断的函数类型校验实参（闭合 L1：匿名函数参数标注 + 函数类型实参校验）。
 if let calleeType = inference.infer(expression: callee),
 case .function(let params, let returns, _, _) = calleeType {
 try validateCallArguments(
 arguments: arguments,
 signature: TypeEnvironment.FunctionSignature(params: params, returns: returns),
 location: location
 )
 }
 }

 case .member(let object, let name, let location):
 try checkExpression(object)
 // 草稿 A2（批次 1.3，D1）：命名元组 `.名称` 标签访问——object 为元组类型时，
 // name 必须在 labels 中存在，未知标签报 unknownMember；命中则跳过字段可见性检查。
 if let t = inference.infer(expression: object), case .tuple(let labels, _, _) = t {
 if !labels.contains(where: { $0 == name }) {
 try report(TypeError.unknownMember(typeName: t.describe(), memberName: name, location: location))
 }
 break
 }
 // P4.5：字段级 type-private 强制。`_`-前缀字段仅声明类型自身方法可访问；
 // 同文件普通函数 / 跨类型方法 / 跨文件访问均报 inaccessibleField。
 try enforceFieldVisibility(object: object, fieldName: name, location: location)

 case .tuple(_, let elements, _):
 for elem in elements { try checkExpression(elem) }

 case .tupleIndex(let object, let index, let location):
 // 草稿 A2（批次 1）：`.0` 位置访问——object 必须推断为元组类型且索引不越界；
 // 非元组或越界均报类型错误（静态拦截，运行时另有兜底）。
 try checkExpression(object)
 if let t = inference.infer(expression: object) {
 switch t {
 case .tuple(_, let elements, _):
 if index < 0 || index >= elements.count {
 try report(TypeError.mismatch(
 expected: "tuple(\(elements.count))",
 got: "index \(index)",
 location: location
 ))
 }
 default:
 try report(TypeError.mismatch(
 expected: "tuple",
 got: t.describe(),
 location: location
 ))
 }
 }

 case .arrayLiteral(let elements, _):
 for elem in elements { try checkExpression(elem) }

 case .dictionaryLiteral(let entries, _):
 for entry in entries { try checkExpression(entry.key); try checkExpression(entry.value) }

 case .setLiteral(let elements, _):
 for elem in elements { try checkExpression(elem) }

 case .subscript(let container, let index, _):
 try checkExpression(container)
 try checkExpression(index)

 case .genericConstruct(let typeName, let typeArgs, let arguments, let location):
 // P3-0：泛型函数调用点比对（T 占位通配，端到端）——优先于类型构造分派
 if let expectedG = typeEnv.genericFunctionParamCount(name: typeName) {
 if typeArgs.count != expectedG {
 try report(TypeError.genericArgumentCountMismatch(
 typeName: typeName,
 expected: expectedG,
 got: typeArgs.count,
 location: location
 ))
 } else if let sig = typeEnv.lookupSpecializedFunctionSignature(name: typeName, typeArgs: typeArgs) {
 try validateCallArguments(arguments: arguments, signature: sig, location: location)
 }
 } else if let expectedCount = typeEnv.genericParamCount(name: typeName) {
 // P2-2.3：泛型实例化实参个数须与声明泛型形参个数一致
 if typeArgs.count != expectedCount {
 try report(TypeError.genericArgumentCountMismatch(
 typeName: typeName,
 expected: expectedCount,
 got: typeArgs.count,
 location: location
 ))
 }
 } else if let expectedG = typeEnv.genericEnumParamCount(name: typeName) {
 // P5 B0-1：泛型枚举实参个数校验（闭合 R1）
 if typeArgs.count != expectedG {
 try report(TypeError.genericArgumentCountMismatch(
 typeName: typeName,
 expected: expectedG,
 got: typeArgs.count,
 location: location
 ))
 }
 }

 case .funcLiteral(let decl, _):
 // 匿名函数体内部类型检查：复用 checkFuncBody——标注参数定义 + body 语句检查 +
 // 返回类型一致性（闭合缺口①）。无标注参数保持推断（checkFuncBody 跳过无标注参数，
 // body 里无类型信息时不误报）。
 try checkFuncBody(decl)

 case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral, .stringInterpolation,
 .identifier, .selfKeyword, .selfTypeKeyword:
 break

 case .join(let inner, let location):
 try checkExpression(inner)
 // （G12）：`await`/`wait` 的操作数必须是 Future<_,_>（或后续的 Chan<_>）；
 // 对普通值 join 是类型错误（收紧了早期 await 的「非 Future 透传」行为）。
 // 操作数类型不可推断时跳过（沿用类型层既有容忍策略，避免误报）。
 if let operandType = inference.infer(expression: inner) {
 var isJoinable = false
 if case .generic(let name, let params, _) = operandType,
 name == "Future" || name == "Chan",
 params.count == 2 {
 isJoinable = true
 }
 if !isJoinable {
 try report(TypeError.mismatch(
 expected: "Future<T, Error>",
 got: operandType.describe(),
 location: location
 ))
 }
 }

 case .unsafe(let operand, let location):
 // Phase 2a（ADR-015 FFI）：不安全消耗点——进入不安全上下文检查操作数。
 unsafeContextDepth += 1
 defer { unsafeContextDepth -= 1 }
 try checkExpression(operand)

 case .addressOf(let operand, let location):
 // Phase 2a（ADR-015 FFI）：`&` 取地址仅在 unsafe 上下文可用。
 guard unsafeContextDepth > 0 else {
 try report(TypeError.mismatch(
 expected: "unsafe 上下文（`|unsafe` 函数体或 `unsafe (...)` 消耗点）",
 got: "& 取地址在非 unsafe 上下文",
 location: location
 ))
 return
 }
 try checkExpression(operand)
 }
 }

 /// 检查二元运算左右操作数类型是否兼容
 private func checkBinaryOperandTypes(
 left: Expression,
 op: BinaryOperator,
 right: Expression,
 location: SourceLocation
 ) throws {
 // 逻辑运算符 && || 要求 Bool 操作数，此处仅做左右一致性检查
 let needsConsistency: Bool
 switch op {
 case .plus, .minus, .multiply, .divide, .modulo, .power,
 .bitwiseAnd, .bitwiseOr, .bitwiseXor, .leftShift, .rightShift,
 .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
 needsConsistency = true
 case .and, .or, .logicalAnd, .logicalOr,
 .assign, .plusAssign, .minusAssign, .multiplyAssign, .divideAssign,
 .moduloAssign, .andAssign, .orAssign, .xorAssign,
 .leftShiftAssign, .rightShiftAssign:
 needsConsistency = false
 }

 guard needsConsistency else { return }

 guard let leftType = inference.infer(expression: left),
 let rightType = inference.infer(expression: right) else {
 // 类型无法推断（如标识符、调用等），交由运行时处理
 return
 }

 let leftName = typeName(from: leftType)
 let rightName = typeName(from: rightType)

 if leftName != rightName {
 try report(TypeError.mismatch(expected: leftName, got: rightName, location: location))
 }
 }

 // MARK: - 调用点校验辅助（P2-1 / P2-1.4 共用）

 /// 校验一次调用的实参数目与实参类型（结构等价，P2-2.1）。
 /// 跳过未标注形参 "_" 与 Any 形参；实参无法推断则跳过。
 private func validateCallArguments(
 arguments: [CallArgument],
 signature sig: TypeEnvironment.FunctionSignature,
 location: SourceLocation
 ) throws {
 if !sig.isVariadic && arguments.count != sig.params.count {
 try report(TypeError.argumentCountMismatch(
 expected: sig.params.count,
 got: arguments.count,
 location: location
 ))
 }
 for (index, arg) in arguments.enumerated() {
 guard index < sig.params.count else { break }
 let paramType = sig.params[index]
 if case .simple(let pname, _) = paramType, (pname == "_" || pname == "Any") { continue }
 guard let argType = inference.infer(expression: arg.expression, expected: paramType) else { continue }
 if !isAssignable(actual: argType, expected: paramType) {
 try report(TypeError.mismatch(expected: paramType.describe(), got: argType.describe(), location: location))
 }
 }
 }

 // MARK: - B3-1 任务隔离（消解 R6 数据竞争）

 /// 校验一次**并发调用**（被调方标了 `=>`）的实参未把引用类型带过任务边界。
 ///
 /// 取类型的优先级：形参声明类型 > 实参推断类型。形参标注为 `_`/`Any` 哨兵时声明类型不携带信息，
 /// 退回按实参推断，避免「不标注形参类型即可绕过隔离」的后门。两者都拿不到时跳过
 /// （与既有 validateCallArguments 的保守策略一致——推断不了就不误报）。
 private func enforceTaskIsolation(
 functionName: String,
 paramNames: [String],
 arguments: [CallArgument],
 signature sig: TypeEnvironment.FunctionSignature,
 location: SourceLocation
 ) throws {
 for (index, arg) in arguments.enumerated() {
 var candidate: TypeAnnotation? = nil
 if index < sig.params.count {
 let declared = sig.params[index]
 if case .simple(let pname, _) = declared, pname == "_" || pname == "Any" {
 candidate = inference.infer(expression: arg.expression)
 } else {
 candidate = declared
 }
 } else {
 candidate = inference.infer(expression: arg.expression)
 }
 // 缺口②修复：函数类型实参携带闭包捕获集，而 declared 形参类型
 // 不携带捕获信息——须从实参**实际类型**取 captured 并入检测，否则闭包捕获的
 // 引用类型可借「闭包 + => 边界」双重通道偷渡（R6 数据竞争）。
 // 仅当实参实际类型确为带捕获的函数类型时才覆盖（非函数实参走原 declared/推断路径）。
 if let actual = inference.infer(expression: arg.expression),
 case .function(_, _, let actualCaptured, _) = actual, !actualCaptured.isEmpty {
 candidate = actual
 }
 guard let argType = candidate else { continue }
 var visiting: Set<String> = []
 guard let leaked = escapingReferenceType(in: argType, visiting: &visiting) else { continue }
 let paramName = index < paramNames.count ? paramNames[index] : "#\(index + 1)"
 try report(TypeError.sharedReferenceAcrossTasks(
 typeName: leaked,
 paramName: paramName,
 functionName: functionName,
 location: location
 ))
 }
 }

 /// 递归判定一个类型是否**携带**引用语义（object）。返回首个命中的引用类型名，否则 nil。
 ///
 /// 必须递归的原因：把 `Counter` 包一层 struct（`{Box} c: Counter`）或塞进容器（`Array<Counter>`、
 /// `Future<Counter, Error>`）就能偷渡同一个 `ObjectReference` 到另一个线程——只查顶层等于没查。
 /// `visiting` 防自引用类型（如链表节点 `next: Node`）导致的无限递归。
 /// 函数类型**下钻其捕获集**（缺口②修复）：`.function` 携带闭包捕获的变量类型列表，
 /// 这些变量在闭包创建点被捕获、随函数值（fat pointer 的 env）越过 `=>` 边界，故须递归钻入
 /// `captured` 检测引用类型。（函数自身的参数/返回类型仅描述契约、不持有实例，不在隔离检测范围内。）
 private func escapingReferenceType(in type: TypeAnnotation, visiting: inout Set<String>) -> String? {
 switch type {
 case .simple(let name, _):
 if referenceTypeNames.contains(name) { return name }
 guard !visiting.contains(name) else { return nil }
 visiting.insert(name)
 guard let fieldTypes = typeEnv.lookupFieldTypes(typeName: name) else { return nil }
 for field in fieldTypes {
 if let hit = escapingReferenceType(in: field, visiting: &visiting) { return hit }
 }
 return nil
 case .tuple(_, let elements, _):
 for element in elements {
 if let hit = escapingReferenceType(in: element, visiting: &visiting) { return hit }
 }
 return nil
 case .generic(let name, let params, _):
 if referenceTypeNames.contains(name) { return name }
 for param in params {
 if let hit = escapingReferenceType(in: param, visiting: &visiting) { return hit }
 }
 return nil
 case .function(_, _, let captured, _):
 for cap in captured {
 if let hit = escapingReferenceType(in: cap, visiting: &visiting) { return hit }
 }
 return nil
 case .pointer(let element, _):
 // Phase 2a（ADR-015 FFI）：`*T` 禁 object（ARC 隔离），元素理论上不会是引用类型；
 // 仍递归下钻以防御含 object 的纯值结构体被误用作指针元素。
 return escapingReferenceType(in: element, visiting: &visiting)
 }
 }

 /// 经接收者表达式推断对象类型，分派 lookupMethod / lookupSpecializedMethod（P2-1.4）。
 private func lookupMethodSignature(for object: Expression, memberName: String) -> TypeEnvironment.FunctionSignature? {
 guard let objType = inference.infer(expression: object) else { return nil }
 switch objType {
 case .simple(let typeName, _):
 return typeEnv.lookupMethod(typeName: typeName, methodName: memberName)
 case .generic(let typeName, let typeArgs, _):
 return typeEnv.lookupSpecializedMethod(typeName: typeName, typeArgs: typeArgs, methodName: memberName)
 default:
 return nil
 }
 }
}
