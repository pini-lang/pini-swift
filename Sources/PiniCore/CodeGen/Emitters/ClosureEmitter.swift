import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 闭包与一等函数：匿名函数收集与提升、捕获变量分析、env 结构构建、
/// 闭包定义体延迟发射、函数指针间接调用。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - 阶段 B：闭包辅助方法

 /// 预遍历：递归收集模块中所有 funcLiteral，分配稳定 id（键为位置 "行:列"）。
 func collectFuncLiterals(in decl: TopLevelDecl) {
 switch decl {
 case .funcDecl(let fd): collectFuncLiterals(in: fd.body?.statements ?? [])
 case .structDecl(let sd): for m in sd.methods { collectFuncLiterals(in: m.body?.statements ?? []) }
 case .objectDecl(let od): for m in od.methods { collectFuncLiterals(in: m.body?.statements ?? []) }
 case .enumDecl(let ed): for m in ed.methods { collectFuncLiterals(in: m.body?.statements ?? []) }
 default: break
 }
 }

 func collectFuncLiterals(in statements: [Statement]) {
 for s in statements { collectFuncLiterals(in: s) }
 }

 func collectFuncLiterals(in stmt: Statement) {
 switch stmt {
 case .varDecl(_, _, let init_, _, _):
 if let e = init_ { collectFuncLiterals(in: e) }
 case .varDestructure(_, _, let init_, _, _):
 // 草稿 A1（批次 1）：收集初始值内的匿名函数字面量。
 if let e = init_ { collectFuncLiterals(in: e) }
 case .assign(let target, let value, _):
 collectFuncLiterals(in: target); collectFuncLiterals(in: value)
 case .expressionStmt(let e, _): collectFuncLiterals(in: e)
 case .returnStatement(let e, _): if let e = e { collectFuncLiterals(in: e) }
 case .ifStatement(let c, let thenB, let elifs, let elseB, _, _):
 collectFuncLiterals(in: c); collectFuncLiterals(in: thenB.statements)
 for el in elifs { collectFuncLiterals(in: el.condition); collectFuncLiterals(in: el.block.statements) }
 if let b = elseB { collectFuncLiterals(in: b.statements) }
 case .whileStatement(let c, let body, let step, _, _):
 collectFuncLiterals(in: c); collectFuncLiterals(in: body.statements)
 if let step = step { collectFuncLiterals(in: step.statements) }
 case .forStatement(_, let iterable, let body, let step, _, _):
 collectFuncLiterals(in: iterable); collectFuncLiterals(in: body.statements)
 if let step = step { collectFuncLiterals(in: step.statements) }
 case .matchStatement(let v, let cases, _):
 collectFuncLiterals(in: v)
 for c in cases { collectFuncLiterals(in: c.block.statements) }
 case .deferStatement(let s, _): collectFuncLiterals(in: s)
 default: break
 }
 }

 func collectFuncLiterals(in expr: Expression) {
 if case .funcLiteral(let decl, let loc) = expr {
 let key = "\(loc.line):\(loc.column)"
 if closures[key] == nil {
 closures[key] = ClosureInfo(id: closureCounter, mangledName: "@__closure_\(closureCounter)",
 body: decl.body ?? Block(statements: [], location: loc))
 closureCounter += 1
 }
 return
 }
 switch expr {
 case .binary(let l, _, let r, _): collectFuncLiterals(in: l); collectFuncLiterals(in: r)
 case .unary(_, let o, _): collectFuncLiterals(in: o)
 case .call(let callee, let args, _):
 collectFuncLiterals(in: callee)
 for a in args { collectFuncLiterals(in: a.expression) }
 case .member(let base, _, _): collectFuncLiterals(in: base)
 case .tupleIndex(let base, _, _): collectFuncLiterals(in: base)
 case .resultUnwrap(let operand, _): collectFuncLiterals(in: operand)
 case .tuple(_, let els, _): for e in els { collectFuncLiterals(in: e) }
 case .arrayLiteral(let els, _): for e in els { collectFuncLiterals(in: e) }
 case .join(let inner, _): collectFuncLiterals(in: inner)
 case .genericConstruct(_, _, let args, _): for a in args { collectFuncLiterals(in: a.expression) }
 case .stringInterpolation(let segs, _):
 for s in segs { if case .expression(let e) = s { collectFuncLiterals(in: e) } }
 default: break
 }
 }

 func collectFuncLiterals(in target: AssignTarget) {
 switch target {
 case .identifier: break
 case .member(let o, _): collectFuncLiterals(in: o)
 case .subscript(let e, let i): collectFuncLiterals(in: e); collectFuncLiterals(in: i)
 }
 }

 func collectIdentifiers(in target: AssignTarget) -> Set<String> {
 switch target {
 case .identifier: return []
 case .member(let o, _): return collectIdentifiers(in: o)
 case .subscript(let e, let i): return collectIdentifiers(in: e).union(collectIdentifiers(in: i))
 }
 }

 /// 收集闭包体内引用的所有标识符名（含 callee 名）；funcLiteral 子表达式视为不透明、不再下探。
 func collectIdentifiers(in decl: FuncDecl) -> Set<String> {
 collectIdentifiers(in: decl.body?.statements ?? [])
 }

 func collectIdentifiers(in statements: [Statement]) -> Set<String> {
 statements.reduce(into: Set<String>()) { $0.formUnion(collectIdentifiers(in: $1)) }
 }

 func collectIdentifiers(in stmt: Statement) -> Set<String> {
 switch stmt {
 case .varDecl(let name, _, let init_, _, _):
 var s = init_.map { collectIdentifiers(in: $0) } ?? []
 s.insert(name); return s
 case .varDestructure(let names, _, let init_, _, _):
 // 草稿 A1（批次 1）：非 `_` 分量为本块定义（不视为外部捕获）；初始值内的标识符照常收集。
 var s = init_.map { collectIdentifiers(in: $0) } ?? []
 s.formUnion(names.filter { $0 != "_" })
 return s
 case .assign(let target, let value, _):
 return collectIdentifiers(in: target).union(collectIdentifiers(in: value))
 case .expressionStmt(let e, _): return collectIdentifiers(in: e)
 case .returnStatement(let e, _): return e.map { collectIdentifiers(in: $0) } ?? []
 case .ifStatement(let c, let thenB, let elifs, let elseB, _, _):
 var s = collectIdentifiers(in: c); s.formUnion(collectIdentifiers(in: thenB.statements))
 for el in elifs { s.formUnion(collectIdentifiers(in: el.condition)); s.formUnion(collectIdentifiers(in: el.block.statements)) }
 if let b = elseB { s.formUnion(collectIdentifiers(in: b.statements)) }
 return s
 case .whileStatement(let c, let body, let step, _, _):
 var s = collectIdentifiers(in: c); s.formUnion(collectIdentifiers(in: body.statements))
 if let step = step { s.formUnion(collectIdentifiers(in: step.statements)) }
 return s
 case .forStatement(let pattern, let iterable, let body, let step, _, _):
 var s = collectIdentifiers(in: iterable); s.formUnion(collectIdentifiers(in: body.statements))
 if let step = step { s.formUnion(collectIdentifiers(in: step.statements)) }
 s.formUnion(pattern.filter { $0 != "_" }) // 模式变量为本块定义（不被视为外部捕获）
 return s
 case .matchStatement(let v, let cases, _):
 var s = collectIdentifiers(in: v)
 for c in cases { s.formUnion(collectIdentifiers(in: c.block.statements)) }
 return s
 case .deferStatement(let st, _): return collectIdentifiers(in: st)
 default: return []
 }
 }

 func collectIdentifiers(in expr: Expression) -> Set<String> {
 switch expr {
 case .identifier(let name, _): return [name]
 case .binary(let l, _, let r, _): return collectIdentifiers(in: l).union(collectIdentifiers(in: r))
 case .unary(_, let o, _): return collectIdentifiers(in: o)
 case .call(let callee, let args, _):
 var s = collectIdentifiers(in: callee)
 for a in args { s.formUnion(collectIdentifiers(in: a.expression)) }
 return s
 case .member(let base, _, _): return collectIdentifiers(in: base)
 case .tupleIndex(let base, _, _): return collectIdentifiers(in: base)
 case .resultUnwrap(let operand, _): return collectIdentifiers(in: operand)
 case .tuple(_, let els, _): return els.reduce(into: Set<String>()) { $0.formUnion(collectIdentifiers(in: $1)) }
 case .arrayLiteral(let els, _): return els.reduce(into: Set<String>()) { $0.formUnion(collectIdentifiers(in: $1)) }
 case .join(let inner, _): return collectIdentifiers(in: inner)
 case .genericConstruct(_, _, let args, _):
 return args.reduce(into: Set<String>()) { $0.formUnion(collectIdentifiers(in: $1.expression)) }
 case .stringInterpolation(let segs, _):
 return segs.reduce(into: Set<String>()) {
 if case .expression(let e) = $1 { $0.formUnion(collectIdentifiers(in: e)) }
 }
 default: return []
 }
 }

 func declaredVars(in statements: [Statement]) -> Set<String> {
 statements.reduce(into: Set<String>()) {
 if case .varDecl(let name, _, _, _, _) = $1 { $0.insert(name) }
 // 草稿 A1（批次 1）：解构声明中的非 `_` 分量同样是本块定义。
 if case .varDestructure(let names, _, _, _, _) = $1 { $0.formUnion(names.filter { $0 != "_" }) }
 }
 }

 /// 创建闭包值：在创建点做捕获（自由变量）分析，构造堆 env + fat pointer { code, env }。
 /// 捕获按值复制进 env（逃逸安全，且与值语义立场一致；object 引用经 ptr 复制共享）。
 func generateFuncLiteral(decl: FuncDecl, location: SourceLocation) throws -> IRValue {
 let key = "\(location.line):\(location.column)"
 guard var info = closures[key] else {
 throw IRGenError.unsupportedExpression("anonymous function not pre-registered", sl())
 }
 if !info.computed {
 let used = collectIdentifiers(in: decl)
 let localBound = Set(decl.params.map { $0.name })
 .union(declaredVars(in: decl.body?.statements ?? []))
 var captured: [(name: String, irType: String, fieldIndex: Int)] = []
 var fieldIndex = 0
 for name in used where !localBound.contains(name) {
 // 仅捕获创建点符号表中存在、且非函数类型变量（避免把闭包当捕获）的标识符。
 guard let entry = symbolTable[name], entry.type != "{ ptr, ptr }" else { continue }
 captured.append((name: name, irType: entry.type, fieldIndex: fieldIndex))
 fieldIndex += 1
 }
 info.captured = captured
 info.paramNames = decl.params.map { $0.name }
 info.paramIRTypes = try decl.params.map { p in
 if let ta = p.typeAnnotation { return try typeMapper.map(ta) }
 if decl.returnTypes.count == 1 { return try typeMapper.map(decl.returnTypes[0]) }
 return "i32"
 }
 info.returnIRType = decl.returnTypes.isEmpty ? "void" : (try typeMapper.map(decl.returnTypes[0]))
 info.computed = true
 closures[key] = info
 }

 let envPtr: String
 if info.captured.isEmpty {
 envPtr = "null"
 } else {
 let envTypeName = "%__closure_env_\(info.id)"
 // 按引用捕获：env 字段为「被捕获变量存储槽的指针」，与解释器 currentEnv 共享语义一致。
 // env 结构类型声明延迟插入模块头（在被创建点的 getelementptr 引用之前）。
 let fieldTypes = info.captured.map { _ in "ptr" }.joined(separator: ", ")
 pendingClosureTypeDecls.append("\(envTypeName) = type { \(fieldTypes) }")
 let alloc = "%t\(nextTemp())"
 emitLine(" \(alloc) = call ptr @malloc(i64 \(info.captured.count * 8))")
 for cap in info.captured {
 let gp = "%t\(nextTemp())"
 emitLine(" \(gp) = getelementptr \(envTypeName), ptr \(alloc), i32 0, i32 \(cap.fieldIndex)")
 emitLine(builder.fmtStore(value: symbolTable[cap.name]!.slot, type: "ptr", ptr: gp))
 }
 envPtr = alloc
 }

 let codeTemp = "%t\(nextTemp())"
 emitLine(" \(codeTemp) = insertvalue { ptr, ptr } { ptr \(info.mangledName), ptr null }, ptr \(info.mangledName), 0")
 let closureTemp = "%t\(nextTemp())"
 emitLine(" \(closureTemp) = insertvalue { ptr, ptr } \(codeTemp), ptr \(envPtr), 1")
 return IRValue(llvmType: "{ ptr, ptr }", ssaName: closureTemp)
 }

 /// 发射单个闭包的模块级 define（由 generate(module:) 在末尾调用，保证 SSA 命名空间唯一）。
 /// 期间临时接管 `ir` 缓冲与符号表：prologue 把 env 捕获按值拷入局部 alloca，body 复用 generateStatement。
 func generateClosureDefine(_ info: ClosureInfo) throws {
 let savedIR = ir
 ir = ""
 let savedSymbol = symbolTable
 let savedDeferred = deferredStatements
 let savedScopeStack = scopeStack
 let savedDepth = currentScopeDepth
 symbolTable = [:]
 deferredStatements = []
 scopeStack = [[]]
 currentScopeDepth = 0

 let envTypeName = "%__closure_env_\(info.id)"
 for cap in info.captured {
 // 按引用捕获：从 env 取回被捕获变量的存储槽指针，注册为局部符号
 // （读写经同一指针，与解释器共享外层变量语义一致；逃逸闭包的生命周期限制见阶段 B 文档）。
 let gp = "%t\(nextTemp())"
 emitLine(" \(gp) = getelementptr \(envTypeName), ptr %env, i32 0, i32 \(cap.fieldIndex)")
 let varSlot = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: varSlot, type: "ptr", ptr: gp))
 symbolTable[cap.name] = (varSlot, cap.irType)
 }
 for (i, t) in info.paramIRTypes.enumerated() {
 let slot = "%arg\(i)_slot"
 emitLine(builder.fmtAlloca(name: slot, type: t))
 emitLine(builder.fmtStore(value: "%arg\(i)", type: t, ptr: slot))
 symbolTable[info.paramNames[i]] = (slot, t)
 registerLocalCollectionVar(info.paramNames[i], slot, t)
 }
 let body = info.body
 for stmt in body.statements {
 try generateStatement(stmt, functionReturnType: info.returnIRType, isMain: false)
 if isTerminatingStatement(stmt) { break }
 }
 let needsExit = body.statements.contains { isTerminatingStatement($0) }
 if needsExit {
 emitLine(builder.fmtBr(labelName: "exit_block"))
 ir += "exit_block:\n"
 emitScopeCleanup()
 if info.returnIRType != "void" {
 emitLine(" ret \(info.returnIRType) undef")
 } else {
 emitLine(" ret void")
 }
 }

 let defineBody = ir
 ir = savedIR
 symbolTable = savedSymbol
 deferredStatements = savedDeferred
 scopeStack = savedScopeStack
 currentScopeDepth = savedDepth

 let fieldTypes = info.captured.map { _ in "ptr" }.joined(separator: ", ")
 var paramsIR: [String] = ["ptr %env"]
 for (i, t) in info.paramIRTypes.enumerated() { paramsIR.append("\(t) %arg\(i)") }
 // 注意：env 结构类型声明已在模块头（pendingClosureTypeDecls）声明，此处不再重复。
 closureDefsIR += "define \(info.returnIRType) \(info.mangledName)(\(paramsIR.joined(separator: ", "))) {\n"
 closureDefsIR += defineBody
 closureDefsIR += "}\n\n"
 }

 /// 间接调用：从 fat pointer 取 code+env，按 retType 发射 `call <ret> code(ptr env, args...)`。
 func generateIndirectCall(closure: IRValue, retType: String, arguments: [CallArgument]) throws -> IRValue {
 let code = "%t\(nextTemp())"
 emitLine(" \(code) = extractvalue { ptr, ptr } \(closure.ssaName), 0")
 let env = "%t\(nextTemp())"
 emitLine(" \(env) = extractvalue { ptr, ptr } \(closure.ssaName), 1")
 var argsIR: [String] = ["ptr \(env)"]
 for arg in arguments {
 let val = try generateCallArgumentValue(arg.expression)
 argsIR.append("\(val.llvmType) \(val.ssaName)")
 }
 if retType == "void" {
 emitLine(" call void \(code)(\(argsIR.joined(separator: ", ")))")
 return IRValue(llvmType: "void", ssaName: "")
 }
 let ret = "%t\(nextTemp())"
 emitLine(" \(ret) = call \(retType) \(code)(\(argsIR.joined(separator: ", ")))")
 return IRValue(llvmType: retType, ssaName: ret)
 }

 /// 实参值生成：具名函数作为值 → 适配器 fat pointer；funcLiteral → 闭包；其余照旧生成。
 ///
 /// #8（higher-order 修复）：间接调用恒按闭包 ABI `code(ptr env, args...)` 发射，而具名函数
 /// 自身是朴素 ABI `fn(args...)`。直接把 `code=@fn` 传入会导致实参错位（`加倍(null, 5)` → 0）。
 /// 故为每个「作为值使用的具名函数」生成一次 **env 忽略适配器** `@__adapter_<mangled>(ptr %env, args...)`，
 /// 体内转调原函数，对齐 ABI。适配器定义体缓冲进 `adapterDefsIR`（去重），模块末尾统一拼接。
 func generateCallArgumentValue(_ expr: Expression) throws -> IRValue {
 if case .identifier(let name, _) = expr,
 !symbolTable.keys.contains(name), knownTopLevelFuncs.contains(name) {
 let mangled = mangle(name)
 try ensureFunctionValueAdapter(mangled: mangled)
 let codeTemp = "%t\(nextTemp())"
 emitLine(" \(codeTemp) = insertvalue { ptr, ptr } { ptr @__adapter_\(mangled), ptr null }, ptr @__adapter_\(mangled), 0")
 let closureTemp = "%t\(nextTemp())"
 emitLine(" \(closureTemp) = insertvalue { ptr, ptr } \(codeTemp), ptr null, 1")
 return IRValue(llvmType: "{ ptr, ptr }", ssaName: closureTemp)
 }
 if case .funcLiteral(let decl, let loc) = expr {
 return try generateFuncLiteral(decl: decl, location: loc)
 }
 return try generateExpression(expr)
 }

 /// 为具名函数生成/去重 env 忽略适配器定义（缓冲进 `adapterDefsIR`，不写入当前 `ir` 缓冲）。
 /// 适配器 ABI 与闭包一致：`define <ret> @__adapter_<mangled>(ptr %env, <t0> %arg0, ...) { ... }`，
 /// 体内把实参从形参槽取回后直接调用原函数。形参/返回类型取自己登记的 `funcParamIRTypes`/`funcReturnIRTypes`。
 private func ensureFunctionValueAdapter(mangled: String) throws {
 guard !adapterSet.contains(mangled) else { return }
 adapterSet.insert(mangled)
 let params = funcParamIRTypes[mangled] ?? []
 let retType = funcReturnIRTypes[mangled] ?? "void"
 // 形参槽 + 取回 + 转调：用固定局部名（函数作用域内唯一，跨函数不冲突）。
 var body = ""
 var callArgs: [String] = []
 for (i, t) in params.enumerated() {
 body += " %arg\(i)_slot = alloca \(t)\n"
 body += " store \(t) %arg\(i), ptr %arg\(i)_slot\n"
 body += " %v\(i) = load \(t), ptr %arg\(i)_slot\n"
 callArgs.append("\(t) %v\(i)")
 }
 var sigArgs = ["ptr %env"]
 for (i, t) in params.enumerated() { sigArgs.append("\(t) %arg\(i)") }
 var def = "define \(retType) @__adapter_\(mangled)(\(sigArgs.joined(separator: ", "))) {\n"
 def += body
 if retType == "void" {
 def += " call void @\(mangled)(\(callArgs.joined(separator: ", ")))\n"
 def += " ret void\n"
 } else {
 def += " %r = call \(retType) @\(mangled)(\(callArgs.joined(separator: ", ")))\n"
 def += " ret \(retType) %r\n"
 }
 def += "}\n\n"
 adapterDefsIR += def
 }
}
