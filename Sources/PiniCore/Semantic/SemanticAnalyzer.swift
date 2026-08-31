import Foundation

/// 语义分析器
/// 负责语义检查：变量是否定义、函数是否定义、类型是否定义等
public final class SemanticAnalyzer {
 public var symbolTable: SymbolTable

 /// P3 validated 匹配模式：本模块枚举的「case 名 → 父枚举名列表」与「枚举名 → 全部 case 名」。
 /// 在 `registerTopLevelDecl` 预登记阶段填充，供 `checkValidatedMatch` 做 best-effort 穷尽性校验。
 /// P5-5 HIGH-1 之后 case 名已按枚举命名空间隔离（跨枚举同名共存），故此处天然为「多父」映射，
 /// 穷尽性校验据此对跨枚举同名碰撞做退化处理（不误报穷尽性）。
 private var enumCaseParents: [String: [String]] = [:]
 private var enumAllCases: [String: [String]] = [:]

 /// ADR-016 规则 3.2/3.14：类型字段表（register 阶段填充），供扩展块方法体检查时注入 self 字段作用域。
 private var typeFields: [String: [FieldDecl]] = [:]

 /// T1/B2（2026-08-24）：语义警告（非致命）。首版=未使用局部变量（`emitUnusedWarnings` 检测点=块作用域）。
 public private(set) var warnings: [SemanticWarning] = []

 /// B2：已被读取引用的符号名集合（`requireDefined` 解析命中时记录）。
 /// 已知限制：name 级键，跨作用域同名符号会互相"洗白"未使用判定——首版接受，待符号表结构化（唯一 id）后升级。
 private var usedSymbols: Set<String> = []

 /// G52 批 1（2026-08-31）：import 别名登记表——
 /// 别名 → (publicSymbols 跨模块可引入集, allSymbols 全部顶级符号)。
 /// D-2 静态互斥：本地符号声明与别名同名 → 重声明错误。
 private var importAliasInfos: [String: (publicSymbols: Set<String>, allSymbols: Set<String>)] = [:]

 /// H-1 capture 校验上下文栈：每个活跃匿名函数字面量一层
 ///（boundary = 字面量体作用域边界；captured = 已先行声明的捕获名集合）。
 /// ①引用外层局部未捕获 → captureWithoutDeclaration；嵌套字面量各持独立一层。
 private var captureContexts: [(boundary: Scope, captured: Set<String>)] = []

 /// P4 Phase 3：多文件包分析时的包级符号索引与「当前正在分析的文件」。
 /// 单文件模式（`analyze(module:)`）下恒为 `nil`，故单文件行为零回归。
 private var packageContext: (index: PackageSymbolIndex, currentFileName: String)? = nil

 public init() {
 self.symbolTable = SymbolTable()
 registerBuiltins()
 }

 /// 重置符号表为干净全局作用域并重新登记内建（多文件模式下每个文件独立分析用）。
 private func resetSymbolTable() {
 symbolTable = SymbolTable()
 enumCaseParents = [:]
 enumAllCases = [:]
 usedSymbols = [] // B2：每文件独立的读取引用集（跨文件同名不互相洗白）
 registerBuiltins()
 }

 private func registerBuiltins() {
 let dummyLoc = SourceLocation(line: 0, column: 0, fileName: "<builtin>")
 // ADR-020 D3：内建符号从单点登记表（BuiltinRegistry）派生——
 // 名字与归组只声明一次，解释器 / 类型检查 / 本层各自取用。
 // 静态分析层须先登记，否则示例/用户代码中调用这些自由函数会被误报
 // undefinedFunction。字符串成员方法（s.upper() 等）走成员调用路径，
 // 不经符号表查找，无需在此登记。
 for decl in BuiltinRegistry.decls where decl.definesSymbol {
 symbolTable.define(Symbol(name: decl.name, kind: .function, location: dummyLoc))
 }
 }

 /// 分析模块
 public func analyze(module: Module) throws {
 warnings = [] // B2：每次分析重置（实例可复用）
 usedSymbols = []
 // G52 批 1：登记 import 别名（加载被引入模块，R1 边界 + R2 禁环由加载器负责）
 for imp in module.imports {
 let dir = (imp.location.fileName as NSString).deletingLastPathComponent
 let loaded = try ModuleDependencyLoader.shared.load(packagePath: imp.packagePath, relativeTo: dir)
 importAliasInfos[imp.alias] = (loaded.publicSymbols, loaded.allSymbols)
 }
 // 第一遍：预注册所有顶级声明
 for decl in module.declarations {
 try registerTopLevelDecl(decl)
 }

 // 第二遍：检查函数体
 for decl in module.declarations {
 try checkTopLevelDecl(decl)
 }
 }

 /// P4 Phase 3：分析包（多文件 / 单文件统一入口）。
 ///
 /// - 单文件包（`fileUnits.count <= 1`）直接委托 `analyze(module:)`，行为与旧单文件世界完全等价。
 /// - 多文件包：构建包级符号索引（跨文件重声明在此抛出），随后逐文件分析——
 /// 每个文件用干净符号表承载**自身**顶级声明，跨文件引用经索引解析并 enforce 4 级可见性。
 public func analyze(package: Package) throws {
 warnings = [] // B2：每包重置（实例可复用）
 if package.fileUnits.count <= 1 {
 let module = package.fileUnits.first?.module
 ?? Module(declarations: [], imports: [], exports: [],
 location: SourceLocation(line: 0, column: 0, fileName: package.name))
 try analyze(module: module)
 return
 }

 let index = try PackageSymbolIndex.build(package: package)
 for unit in package.fileUnits {
 resetSymbolTable()
 packageContext = (index: index, currentFileName: unit.fileName)
 defer { packageContext = nil }

 // 第一遍：预注册当前文件自身的顶级声明（跨文件符号不入本表，防 private 泄漏）
 for decl in unit.module.declarations {
 try registerTopLevelDecl(decl)
 }
 // 第二遍：检查当前文件函数体（引用点经索引做跨文件可见性 enforce）
 for decl in unit.module.declarations {
 try checkTopLevelDecl(decl)
 }
 }
 }

 /// 引用点解析单点：先查当前文件作用域；未命中且处于多文件包时查包级索引，
 /// 按 spec enforce 可见性（private/internal 跨文件不可见 → `inaccessibleSymbol`）。
 /// 单文件模式下 `packageContext` 为 nil，行为与原 `symbolTable.resolve` 判定完全一致。
 private func requireDefined(_ name: String, _ location: SourceLocation, isFunction: Bool) throws {
 // 内建 Optional 枚举类型标识符（裸 Optional / Optional.none 引用），静态层无需注册即可解析，
 // 与解释器对 Optional.some/Optional.none 的特判对齐（闭合 B2 静态缺口）。
 if name == "Optional" { return }
 if let hit = symbolTable.resolveWithScope(name) {
 // H-1①：匿名函数体内引用外层局部变量，其 capture 声明须先于本使用出现
 if let ctx = captureContexts.last,
 !hit.scope.isWithin(ctx.boundary),
 Self.isCapturableKind(hit.symbol.kind),
 !ctx.captured.contains(name) {
 throw SemanticError.captureWithoutDeclaration(name: name, location: location)
 }
 usedSymbols.insert(name) // B2：记录读取引用（未使用检测依据）
 return
 }
 if let ctx = packageContext,
 let entry = ctx.index.lookup(name) {
 if entry.isVisible(from: ctx.currentFileName) { return }
 throw SemanticError.inaccessibleSymbol(
 name: name, definedIn: entry.fileName, level: entry.visibility, location: location
 )
 }
 if isFunction {
 throw SemanticError.undefinedFunction(name: name, location: location)
 } else {
 throw SemanticError.undefinedVariable(name: name, location: location)
 }
 }

 /// 收集模式分析（P2-4.3 / 呼应 analyze 顶部预留钩子）：不抛出，返回模块内全部语义错误。
 /// 用于『多错误同报』——单文件可一次性报出多个重声明 / 未定义符号等。
 /// 注册阶段逐顶级声明 catch 并继续（遇重声明仍尝试登记该名，避免后续误报未定义）；
 /// 检查阶段逐顶级声明 catch 并继续（函数体内仍『遇错即抛』单错误，不跨函数累积）。
 public func analyzeCollecting(module: Module) -> [SemanticError] {
 warnings = [] // B2：收集模式同样重置（实例可复用）
 usedSymbols = []
 var errors: [SemanticError] = []
 // G52 批 1：登记 import 别名（与 analyze(module:) 同规则）；加载失败收集为诊断
 for imp in module.imports {
 let dir = (imp.location.fileName as NSString).deletingLastPathComponent
 do {
 let loaded = try ModuleDependencyLoader.shared.load(packagePath: imp.packagePath, relativeTo: dir)
 importAliasInfos[imp.alias] = (loaded.publicSymbols, loaded.allSymbols)
 } catch let e as SemanticError {
 errors.append(e)
 } catch {
 errors.append(.moduleRootMissing(path: imp.packagePath))
 }
 }

 for decl in module.declarations {
 do {
 try registerTopLevelDecl(decl)
 } catch let error as SemanticError {
 errors.append(error)
 recoverRegister(decl)
 } catch {
 // 非 SemanticError 不阻断后续（理论不应发生）
 }
 }

 for decl in module.declarations {
 do {
 try checkTopLevelDecl(decl)
 } catch let error as SemanticError {
 errors.append(error)
 } catch {
 // 同上
 }
 }

 return errors
 }

 /// 重声明导致 registerTopLevelDecl 中途失败时，尽力把该声明头登记进符号表，
 /// 以免后续合法引用被误报为未定义（P2-4.3 收集模式专用）。
 private func recoverRegister(_ decl: TopLevelDecl) {
 switch decl {
 case .structDecl(let s):
 symbolTable.define(Symbol(name: s.name, kind: .struct, location: s.location))
 case .objectDecl(let o):
 symbolTable.define(Symbol(name: o.name, kind: .object, location: o.location))
 case .enumDecl(let e):
 symbolTable.define(Symbol(name: e.name, kind: .enum, location: e.location))
 for enumCase in e.cases {
 symbolTable.define(Symbol(name: enumCase.name, kind: .enumCase, location: enumCase.location))
 }
 case .funcDecl(let f):
 symbolTable.define(Symbol(name: f.name, kind: .function, location: f.location))
 case .traitDecl(let t):
 symbolTable.define(Symbol(name: t.name, kind: .trait, location: t.location))
 case .extensionDecl, .foreignDecl, .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 // MARK: - 注册阶段（P2-3 重声明检测）

 // 第一遍预注册：若同名顶级符号已存在则抛出 redeclaredSymbol。
 // 注：当前为「遇错即抛」单错误模式；待接入「错误收集」(P2-4.1) 后可改为累积多错误。
 private func registerTopLevelDecl(_ decl: TopLevelDecl) throws {
 switch decl {
 case .structDecl(let s):
 typeFields[s.name] = s.fields
 return try registerStructLike(s.name, fields: s.fields, methods: s.methods, location: s.location)
 case .objectDecl(let o):
 typeFields[o.name] = o.fields
 return try registerStructLike(o.name, fields: o.fields, methods: o.methods, location: o.location)
 case .enumDecl(let e):
 try defineUnique(name: e.name, kind: .enum, location: e.location)
 // P5-5 HIGH-1：case 名按枚举命名空间隔离，不再全局唯一。
 // 仅检测「同一枚举内」case 名重复；跨枚举同名 case（如 形状.圆 与 几何.圆）允许共存。
 // case 名仍以 symbolTable.define 登记（覆盖、不抛错），保证未限定构造 圆(5.0) 的
 // requireDefined 解析通过；全局唯一性硬拒改由「同枚举内查重」承担。
 var seenInEnum: Set<String> = []
 for enumCase in e.cases {
 if seenInEnum.contains(enumCase.name) {
 throw SemanticError.redeclaredSymbol(name: enumCase.name, location: enumCase.location)
 }
 seenInEnum.insert(enumCase.name)
 symbolTable.define(Symbol(name: enumCase.name, kind: .enumCase, location: enumCase.location))
 }
 // P3/P5-5：填充本模块枚举映射，供 validated 匹配模式做 best-effort 穷尽性校验。
 for enumCase in e.cases {
 enumCaseParents[enumCase.name, default: []].append(e.name)
 }
 enumAllCases[e.name] = e.cases.map { $0.name }
 case .funcDecl(let f):
 try defineUnique(name: f.name, kind: .function, location: f.location)
 case .traitDecl(let t):
 try defineUnique(name: t.name, kind: .trait, location: t.location)
 case .extensionDecl(let x):
 // 扩展块不引入新符号；方法名须与目标类型字段/其它方法不冲突（ADR-016 规则 3.2/3.14）。
 let targetFields = typeFields[x.targetType] ?? []
 var seen: [String: SourceLocation] = [:]
 for f in targetFields { seen[f.name] = f.location }
 for method in x.methods {
 if let previous = seen[method.name] {
 throw SemanticError.redeclaredSymbol(name: method.name, location: method.location)
 }
 seen[method.name] = method.location
 }
 return
 case .foreignDecl(let fd):
 // Phase 2a（ADR-015 FFI）：foreign 函数注册为模块级函数符号（调用点可解析）；
 // 块本身不引入新符号，外部 C 符号运行时经原生函数表解析。
 for f in fd.funcs {
 try defineUnique(name: f.name, kind: .function, location: f.location)
 }
 return
 case .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 /// struct/object 的注册公共路径（含方法成员冲突检测）。
 private func registerStructLike(_ name: String, fields: [FieldDecl], methods: [FuncDecl], location: SourceLocation) throws {
 try defineUnique(name: name, kind: .struct, location: location)
 try checkMemberNameConflicts(fields: fields, methods: methods)
 }

 private func defineUnique(name: String, kind: SymbolKind, location: SourceLocation) throws {
 if symbolTable.resolve(name) != nil {
 throw SemanticError.redeclaredSymbol(name: name, location: location)
 }
 // G52 D-2 静态互斥：本地顶级符号不得与 import 别名同名
 if importAliasInfos[name] != nil {
 throw SemanticError.redeclaredSymbol(name: name, location: location)
 }
 symbolTable.define(Symbol(name: name, kind: kind, location: location))
 }

 /// 类型成员名冲突检测（P2-3.3）：结构体/对象内部的字段与字段、方法与字段、
 /// 方法与方法之间不允许同名。名字在「类型自身」范围内唯一，不污染全局符号表。
 private func checkMemberNameConflicts(fields: [FieldDecl], methods: [FuncDecl]) throws {
 var seen: [String: SourceLocation] = [:]
 for field in fields {
 if let previous = seen[field.name] {
 throw SemanticError.redeclaredSymbol(name: field.name, location: field.location)
 }
 seen[field.name] = field.location
 }
 for method in methods {
 if let previous = seen[method.name] {
 throw SemanticError.redeclaredSymbol(name: method.name, location: method.location)
 }
 seen[method.name] = method.location
 }
 }

 // MARK: - 检查阶段

 private func checkTopLevelDecl(_ decl: TopLevelDecl) throws {
 switch decl {
 case .funcDecl(let f):
 try checkFuncDecl(f)
 case .structDecl(let s):
 for method in s.methods {
 try checkFuncDecl(method, fields: s.fields)
 }
 case .objectDecl(let o):
 for method in o.methods {
 try checkFuncDecl(method, fields: o.fields)
 }
 case .enumDecl(let e):
 for method in e.methods {
 try checkFuncDecl(method)
 }
 case .extensionDecl(let x):
 // 扩展方法体检查：注入目标类型字段作用域（同文件扩展块可访问私有字段）。
 let targetFields = typeFields[x.targetType] ?? []
 for method in x.methods {
 try checkFuncDecl(method, fields: targetFields)
 }
 case .foreignDecl:
 // Phase 2a（ADR-015 FFI）：仅签名、无函数体，无检查项。
 break
 case .traitDecl, .varDecl, .statement, .importDecl, .exportDecl:
 break
 }
 }

 private func checkFuncDecl(_ funcDecl: FuncDecl, fields: [FieldDecl] = []) throws {
 symbolTable.enterScope(name: funcDecl.name)
 defer { symbolTable.exitScope() }

 // 方法体作用域：注册 self 与所属类型的字段，使方法体可直接引用字段
 // （P3-1 示例 trait.pini 的 `描述|self() -> (String,)` 返回 `名字` 字段触发此需求）。
 // 字段先于参数注册，参数可遮蔽同名字段。
 if !fields.isEmpty {
 symbolTable.define(Symbol(name: "self", kind: .variable(isMutable: false), location: funcDecl.location))
 for field in fields {
 symbolTable.define(Symbol(name: field.name, kind: .variable(isMutable: false), location: field.location))
 }
 }

 // 注册参数
 for param in funcDecl.params {
 symbolTable.define(Symbol(name: param.name, kind: .parameter, location: funcDecl.location))
 }

 // 检查函数体：包一层 body scope，使局部 var 在独立作用域——B2 未使用检测只在此与嵌套块
 // （checkBlock）执行，参数（函数 scope）、方法字段（函数 scope）、for 模式变量（for-loop scope）天然排除。
 if let body = funcDecl.body {
 symbolTable.enterScope(name: "body")
 defer {
 emitUnusedWarnings()
 symbolTable.exitScope()
 }
 for stmt in body.statements {
 try checkStatement(stmt)
 }
 }
 }

 // MARK: - 语句检查

 private func checkStatement(_ stmt: Statement) throws {
 if case .captureStatement(let name, let location) = stmt {
 // H-1：解析器已把 capture 限制在匿名函数体缩进体顶层；此处防御非常规构造路径
 guard !captureContexts.isEmpty else {
 throw SemanticError.invalidCaptureTarget(
 name: name, reason: "capture 仅允许出现在匿名函数体顶层语句位", location: location)
 }
 // ②捕获一致性：目标必须是创建点外层的局部变量
 if name == "self" {
 throw SemanticError.invalidCaptureTarget(
 name: name, reason: "self 由 |self 修饰符表达，不进 capture 列表（A2）", location: location)
 }
 if symbolTable.isDefinedInCurrentScope(name) {
 throw SemanticError.invalidCaptureTarget(
 name: name, reason: "已是本匿名函数的参数或体内已声明局部", location: location)
 }
 let boundary = captureContexts[captureContexts.count - 1].boundary
 guard let hit = symbolTable.resolveWithScope(name),
 Self.isCapturableKind(hit.symbol.kind),
 !hit.scope.isWithin(boundary) else {
 throw SemanticError.invalidCaptureTarget(
 name: name, reason: "须是创建点外层的局部变量（参数/体内局部/内建函数/类型/不可见名不可捕获）", location: location)
 }
 captureContexts[captureContexts.count - 1].captured.insert(name)
 usedSymbols.insert(name) // capture 即引用（B2 未使用判定）
 return
 }
 switch stmt {
 case .varDecl(let name, _, let initializer, let isMutable, let location):
 if let initExpr = initializer {
 try checkExpression(initExpr)
 }
 if symbolTable.isDefinedInCurrentScope(name) {
 throw SemanticError.redeclaredSymbol(name: name, location: location)
 }
 try checkAliasNameConflict(name, location)
 symbolTable.define(Symbol(name: name, kind: .variable(isMutable: isMutable), location: location))

 case .varDestructure(let names, _, let initializer, let isMutable, let location):
 // 草稿 A1（批次 1）：逐个定义非 `_` 分量（`_` 为占位不定义）；先检查初始值子表达式。
 if let initExpr = initializer {
 try checkExpression(initExpr)
 }
 for name in names where name != "_" {
 if symbolTable.isDefinedInCurrentScope(name) {
 throw SemanticError.redeclaredSymbol(name: name, location: location)
 }
 try checkAliasNameConflict(name, location)
 symbolTable.define(Symbol(name: name, kind: .variable(isMutable: isMutable), location: location))
 }

 case .assign(let target, let value, let location):
 switch target {
 case .identifier(let name):
 try requireDefined(name, location, isFunction: false)
 case .member(let obj, _):
 try checkExpression(obj)
 case .subscript(let containerExpr, let indexExpr):
 try checkExpression(containerExpr)
 try checkExpression(indexExpr)
 }
 try checkExpression(value)

 case .returnStatement(let value, _):
 if let v = value {
 try checkExpression(v)
 }

 case .breakStatement, .continueStatement:
 break

 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
 try checkExpression(condition)
 try checkBlock(thenBlock)
 for elif in elifs {
 try checkExpression(elif.condition)
 try checkBlock(elif.block)
 }
 if let elseBlk = elseBlock {
 try checkBlock(elseBlk)
 }

 case .whileStatement(let condition, let body, let step, _, _):
 try checkExpression(condition)
 try checkBlock(body)
 if let step = step { try checkBlock(step) }

 case .forStatement(let pattern, let iterable, let body, let step, _, let loc):
 try checkExpression(iterable)
 // 模式变量注入 for 作用域（`_` 占位不登记），否则 body/step 内引用会被误报 undefinedVariable
 symbolTable.enterScope(name: "for-loop")
 for name in pattern where name != "_" {
 symbolTable.define(Symbol(name: name, kind: .variable(isMutable: true), location: loc))
 }
 try checkBlock(body)
 if let step = step { try checkBlock(step) }
 symbolTable.exitScope()

 case .scopedBlock(_, let body, _):
 try checkBlock(body)

 case .matchStatement(let value, let cases, let location):
 try checkExpression(value)
 for matchCase in cases {
 // 将 match 模式绑定变量（如 case 圆(半径: r,): 中的 r）注入该 case 作用域，
 // 否则 case 体内引用绑定变量会被误报 undefinedVariable。
 symbolTable.enterScope(name: "match-case")
 for binding in matchCase.bindings {
 symbolTable.define(Symbol(name: binding.varName, kind: .variable(isMutable: false), location: matchCase.location))
 }
 try checkBlock(matchCase.block)
 symbolTable.exitScope()
 }
 // R1（D3①，2026-08-23）：穷尽性/可达性检查总是开启（取代 validated pass 开关），
 // `case _:` 通配兜底豁免；default:/pass 通配子块已随字段删除。
 try checkMatchExhaustive(value: value, cases: cases, location: location)

 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 try checkExpression(expression)
 try checkBlock(tryBlock)
 for except in exceptClauses {
 try checkBlock(except.body)
 }

 case .expressionStmt(let expr, _):
 try checkExpression(expr)

 case .detachStatement(let expr, _):
 try checkExpression(expr)

 case .deferStatement(let statement, _):
 try checkStatement(statement)
 case .passStatement(_):
 break
 case .captureStatement:
 return
 }
 }

 // MARK: - R1 穷尽性/可达性检查（D3① 取代 P3 validated 开关）

 /// 穷尽性校验：**总是开启**（R1，2026-08-23 D3①），`case _:` 通配兜底豁免。
 /// 策略（best-effort，避免误报、不阻断跨枚举/导入场景）：
 /// 1. 区分每个 case 模式能否解析到本模块已知枚举；
 /// 2. 若「存在已知 case」却夹带「未知 case」→ 视为拼写错误（`unknownMatchCase`）；
 /// 3. 全部 case 均无法解析（可能是内建/导入枚举，本模块无登记）→ 跳过（无法校验）；
 /// 4. 全部 case 解析到同一枚举 → 校验穷尽覆盖，缺 case 且无 `case _:` 通配则 `nonExhaustiveMatch`；
 /// 5. 跨枚举同名碰撞（多父）→ 退化为仅合法性校验，不报穷尽性（HIGH-1/MED-2 立项前不误报）。
 private func checkMatchExhaustive(
 value: Expression, cases: [MatchCase], location: SourceLocation
 ) throws {
 var resolvedPatterns: [String] = []
 var unresolvedEnumCases: [MatchCase] = []
 var parentUnion = Set<String>()
 var hasWildcardPattern = false

 for mc in cases {
 switch mc.pattern {
 case .enumCase(let name):
 let parents = enumCaseParents[name] ?? []
 if parents.isEmpty {
 unresolvedEnumCases.append(mc)
 } else {
 resolvedPatterns.append(name)
 parentUnion.formUnion(parents)
 }
 case .wildcard:
 hasWildcardPattern = true
 case .intLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
 break // 标量模式不参与枚举穷尽性校验
 }
 }

 // 合法性：已知 enum case 与未知 enum case 并存 → 未知项大概率是拼写错误
 if !resolvedPatterns.isEmpty && !unresolvedEnumCases.isEmpty {
 let bad = unresolvedEnumCases[0]
 if case .enumCase(let name) = bad.pattern {
 throw SemanticError.unknownMatchCase(caseName: name, location: bad.location)
 }
 }

 // 无枚举 case 模式可校验（全标量/通配）→ best-effort 跳过
 if resolvedPatterns.isEmpty {
 return
 }

 // P5-5 MED-2：若被匹配值是限定枚举构造 形状.圆(...)（.call(.member(.identifier(父), case), ...)）
 // 且 父 是本模块已知枚举，则穷尽性校验锁定到该枚举——跨枚举同名 case 不再串味
 // （如 形状.圆 与 几何.圆 共存时，match 形状.圆(...) 只校验 形状 的全部 case）。
 // 变量/参数匹配（match x）因语义层无变量类型跟踪，仍走下方多父退化逻辑（best-effort）。
 var pinnedParent: String? = nil
 if case .call(let callee, _, _) = value,
 case .member(let objExpr, _, _) = callee,
 case .identifier(let parentName, _) = objExpr,
 enumAllCases[parentName] != nil {
 pinnedParent = parentName
 }

 // 所有 enum case 解析到同一枚举（或限定值锁定到单父）→ 校验穷尽性；跨枚举碰撞且无
 // 限定值锁定时 → 退化（不误报穷尽性）。`case _:` 视为覆盖全部（与旧 default 同权）。
 let exhaustivenessTarget: String? = pinnedParent ?? (parentUnion.count == 1 ? parentUnion.first : nil)
 if let enumName = exhaustivenessTarget {
 let allCases = enumAllCases[enumName] ?? []
 let covered = Set(resolvedPatterns)
 let missing = allCases.filter { !covered.contains($0) }
 if missing.isEmpty || hasWildcardPattern {
 return
 }
 throw SemanticError.nonExhaustiveMatch(missingCases: missing, location: location)
 }
 }

 private func checkBlock(_ block: Block) throws {
 symbolTable.enterScope(name: "block")
 defer {
 emitUnusedWarnings() // B2：块作用域结束检测未使用局部变量（参数/顶层/字段/for 模式变量不在本作用域，天然排除）
 symbolTable.exitScope()
 }
 for stmt in block.statements {
 try checkStatement(stmt)
 }
 }

 // MARK: - B2 未使用变量检测

 /// 块作用域退出时：对当前作用域内 `kind == .variable` 且未被读取、非 `_`/`_xxx` 前缀的局部变量发 warning。
 private func emitUnusedWarnings() {
 for (name, symbol) in symbolTable.current.symbols {
 guard case .variable = symbol.kind else { continue }
 if name.hasPrefix("_") { continue }
 if usedSymbols.contains(name) { continue }
 warnings.append(.unusedVariable(name: name, location: symbol.location))
 }
 }

 // MARK: - 表达式检查

 private func checkExpression(_ expr: Expression) throws {
 switch expr {
 case .identifier(let name, let location):
 try requireDefined(name, location, isFunction: false)

 case .integerLiteral, .floatLiteral, .stringLiteral, .boolLiteral:
 break

 case .stringInterpolation(let segments, _):
 for seg in segments {
 if case .expression(let e) = seg {
 try checkExpression(e)
 }
 }

 case .binary(let left, _, let right, _):
 try checkExpression(left)
 try checkExpression(right)

 case .unary(_, let operand, _):
 try checkExpression(operand)

 case .resultUnwrap(let operand, _):
 // 草稿 A2（批次 1.4，D2）：递归检查被解包表达式。
 try checkExpression(operand)

 case .call(let callee, let arguments, _):
 // 检查是否是未定义的函数调用
 if case .identifier(let name, let location) = callee {
 try requireDefined(name, location, isFunction: true)
 }
 // G52 批 1：`别名.符号(...)` 跨模块限定调用——符号存在性 + public 门槛
 if case .member(let objExpr, let memberName, _) = callee,
 case .identifier(let aliasName, let aliasLoc) = objExpr,
 let info = importAliasInfos[aliasName] {
 guard info.allSymbols.contains(memberName) else {
 throw SemanticError.undefinedVariable(name: "\(aliasName).\(memberName)", location: aliasLoc)
 }
 guard info.publicSymbols.contains(memberName) else {
 throw SemanticError.crossModuleAccessDenied(symbol: "\(aliasName).\(memberName)", location: aliasLoc)
 }
 }
 for arg in arguments {
 try checkExpression(arg.expression)
 }

 case .member(let object, _, _):
 // G52 批 1：别名 base 不走本地 requireDefined（限定访问只走跨模块通道，D-2）
 if case .identifier(let aliasName, _) = object, importAliasInfos[aliasName] == nil {
 try checkExpression(object)
 }

 case .tupleIndex(let object, _, _):
 // 草稿 A2（批次 1）：`.0` 位置访问——递归检查 object 内的标识符定义。
 try checkExpression(object)

 case .tuple(_, let elements, _):
 for elem in elements {
 try checkExpression(elem)
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

 case .funcLiteral(let decl, _):
 symbolTable.enterScope(name: "funcLiteral")
 for param in decl.params {
 symbolTable.define(Symbol(name: param.name, kind: .parameter, location: decl.location))
 }
 // H-1：作用域边界——此之后解析命中点若在边界之外，即为「外层局部」。
 // captured 集**按语句序增量**填充（checkStatement 的 captureStatement 分支），
 // 使「先用后 capture」（①）在语句序上可判定。
 let captureBoundary = symbolTable.current
 if let body = decl.body {
 captureContexts.append((boundary: captureBoundary, captured: []))
 for stmt in body.statements {
 try checkStatement(stmt)
 }
 captureContexts.removeLast()
 }
 symbolTable.exitScope()

 case .selfKeyword, .selfTypeKeyword:
 break

 case .genericConstruct:
 break

 case .join(let inner, _):
 try checkExpression(inner)

 case .unsafe(let operand, _):
 // Phase 2a（ADR-015 FFI）：不安全消耗点——递归检查操作数。
 try checkExpression(operand)
 case .addressOf(let operand, _):
 // Phase 2a（ADR-015 FFI）：取地址——递归检查操作数。
 try checkExpression(operand)
 }
 }

 /// H-1：可捕获的符号种类——外层局部变量（含外层函数参数）。
 /// 函数/类型/枚举用例等按名字即可引用，不属于「捕获的外部对象」。
 private static func isCapturableKind(_ kind: SymbolKind) -> Bool {
 switch kind {
 case .variable, .parameter: return true
 default: return false
 }
 }

 /// G52 D-2 静态互斥：局部符号不得与 import 别名同名。
 private func checkAliasNameConflict(_ name: String, _ location: SourceLocation) throws {
 if importAliasInfos[name] != nil {
 throw SemanticError.redeclaredSymbol(name: name, location: location)
 }
 }
}
