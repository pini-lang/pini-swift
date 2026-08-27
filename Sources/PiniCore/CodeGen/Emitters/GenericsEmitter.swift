import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 泛型单态化与 trait 方法分发：类型参数替换、特化缓存、trait 方法特化。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - P6-4b: 泛型函数单态化

 /// 泛型构造调用：`identity<I32>(42)` 或 `盒<I32>()` 的 IR 生成。
 /// 查找泛型模板 → 构建类型替换映射 → 特化函数体生成（若未缓存）→ 发射调用。
 /// R2：`typeName` 为泛型 struct 模板时走 `generateGenericStructConstruct`（单态化 + 构造）。
 func generateGenericCall(typeName: String, typeArgs: [TypeAnnotation], arguments: [CallArgument]) throws -> IRValue {
 // #46-E G40（S3）：`LazyRef<T>(初始化闭包)` —— 内建泛型包装类型，特判优先。
 if typeName == "LazyRef" {
 return try generateLazyRefConstruct(typeArgs: typeArgs, arguments: arguments)
 }
 // R2：泛型 struct 类型单态化（`盒<I32>()`）——structTypes 中登记的模板优先于 genericTemplates。
 if structTypes[mangle(typeName)]?.genericParams.isEmpty == false {
 return try generateGenericStructConstruct(typeName: typeName, typeArgs: typeArgs, arguments: arguments)
 }
 guard let template = genericTemplates[mangle(typeName)] else {
 throw IRGenError.unsupportedExpression("unknown generic function \(typeName)", sl())
 }
 guard template.genericParams.count == typeArgs.count else {
 throw IRGenError.unsupportedExpression(
 "type arg count mismatch: \(typeName) expects \(template.genericParams.count), got \(typeArgs.count)", sl())
 }

 // 构建类型替换映射：泛型参数名 → 具体 TypeAnnotation
 var substitution: [String: TypeAnnotation] = [:]
 for (i, gp) in template.genericParams.enumerated() {
 substitution[gp.name] = typeArgs[i]
 }

 // Mangling：`identity<I32>` → `identity_I32`
 let cacheKey = "\(typeName)<\(typeArgs.map { $0.describe() }.joined(separator: ","))>"
 let irTypeStrings: [String] = try typeArgs.map { try typeMapper.map($0) }
 let specializedName = "\(typeName)_\(irTypeStrings.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: "_"))"

 // 若未特化过，预注册返回类型 + 加入待生成队列
 if specializedCache[cacheKey] == nil {
 let specializedFD = specializeFuncDecl(template, substitution: substitution, specializedName: specializedName)
 try registerFuncReturnType(specializedFD)
 pendingSpecializations.append((specializedFD, nil))
 specializedCache[cacheKey] = specializedName
 }

 // 发射调用
 var callArgs: [String] = []
 for arg in arguments {
 let val = try generateExpression(arg.expression)
 callArgs.append("\(val.llvmType) \(val.ssaName)")
 }

 let retType = funcReturnIRTypes[mangle(specializedName)] ?? "void"
 if retType == "void" {
 emitLine(" call void @\(mangle(specializedName))(\(callArgs.joined(separator: ", ")))")
 return IRValue(llvmType: "void", ssaName: "")
 }
 let retTemp = "%t\(nextTemp())"
 emitLine(" \(retTemp) = call \(retType) @\(mangle(specializedName))(\(callArgs.joined(separator: ", ")))")
 return IRValue(llvmType: retType, ssaName: retTemp)
 }

 /// 创建类型替换后的特化 FuncDecl。
 /// 将泛型参数名（如 `"T"`）替换为具体 TypeAnnotation（如 `.simple("I32")`）。
 /// 注意：泛型参数在类型注解中以 `.simple("T")` 出现，而非 `.generic`。
 func specializeFuncDecl(_ fd: FuncDecl, substitution: [String: TypeAnnotation], specializedName: String) -> FuncDecl {
 let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { ta in
 guard let ta = ta else { return nil }
 // 处理 `.simple("T")`：若名称匹配泛型参数，则替换
 if case .simple(let name, _) = ta, let sub = substitution[name] {
 return sub
 }
 return ta
 }

 let newParams = fd.params.map { p in
 Parameter(name: p.name, typeAnnotation: resolveType(p.typeAnnotation))
 }

 let newReturnTypes = fd.returnTypes.map(resolveType).compactMap { $0 }

 return FuncDecl(
 name: specializedName,
 modifiers: fd.modifiers,
 genericParams: [], // 特化版本不再有泛型参数
 params: newParams,
 returnTypes: newReturnTypes,
 returnLabels: fd.returnLabels,
 isAsync: fd.isAsync,
 body: fd.body,
 location: fd.location
 )
 }

 // MARK: - R2: 泛型 struct 类型单态化

 /// `盒<I32>()` 构造：确保特化已注册（幂等），随后按常规 struct 构造。
 /// 类型声明由 emitStructTypeDecls 统一发射（特化在预扫描阶段已登记进 structTypes）。
 func generateGenericStructConstruct(typeName: String, typeArgs: [TypeAnnotation], arguments: [CallArgument]) throws -> IRValue {
 try registerGenericStructSpecialization(typeName: typeName, typeArgs: typeArgs)
 let irTypeStrings: [String] = try typeArgs.map { try typeMapper.map($0) }
 let specializedName = "\(typeName)_\(irTypeStrings.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: "_"))"
 guard let concrete = structTypes[mangle(specializedName)] else {
 throw IRGenError.unsupportedExpression("specialized struct \(specializedName) not registered", sl())
 }
 return try generateStructConstruction(structDecl: concrete)
 }

 /// 注册泛型 struct 单态化（幂等，ializedCache 去重）：特化 StructDecl 登记进
 /// `structTypes`/`typeMapper`/`specializedCache`，特化方法入队 `pendingSpecializations`
 /// （接收者特化名已在 specializeStructDecl 重命名，R1.1 分派自动命中）。
 /// 由 `generateGenericStructConstruct` 与预扫描 `precollectGenericStructUses` 共用，
 /// 使特化类型声明在 emitStructTypeDecls 阶段就绪（避免 LLVM "Cannot allocate unsized type"）。
 func registerGenericStructSpecialization(typeName: String, typeArgs: [TypeAnnotation]) throws {
 guard let template = structTypes[mangle(typeName)], !template.genericParams.isEmpty else { return }
 guard template.genericParams.count == typeArgs.count else {
 throw IRGenError.unsupportedExpression(
 "type arg count mismatch: \(typeName) expects \(template.genericParams.count), got \(typeArgs.count)", sl())
 }
 var substitution: [String: TypeAnnotation] = [:]
 for (i, gp) in template.genericParams.enumerated() { substitution[gp.name] = typeArgs[i] }
 let irTypeStrings: [String] = try typeArgs.map { try typeMapper.map($0) }
 let specializedName = "\(typeName)_\(irTypeStrings.map { $0.replacingOccurrences(of: " ", with: "_") }.joined(separator: "_"))"
 let cacheKey = "\(typeName)<\(typeArgs.map { $0.describe() }.joined(separator: ","))>"
 guard specializedCache[cacheKey] == nil else { return }
 let specializedSD = specializeStructDecl(template, substitution: substitution, specializedName: specializedName)
 let mangledSD = mangle(specializedName)
 structTypes[mangledSD] = specializedSD
 typeMapper.addKnownStruct(name: specializedName, irName: mangledSD)
 for md in specializedSD.methods {
 try registerFuncReturnType(md)
 pendingSpecializations.append((md, "%struct.\(mangledSD)*"))
 }
 specializedCache[cacheKey] = specializedName
 }

 /// 预扫描整个模块 AST，收集所有「泛型 struct 构造」`盒<T>(...)` 并预注册特化，
 /// 使特化类型声明先于任何函数体（含 alloca）发射（R2；对齐 collectFuncLiterals 的遍历骨架）。
 func precollectGenericStructUses(in decl: TopLevelDecl) {
 switch decl {
 case .funcDecl(let fd): precollectGenericStructUses(in: fd.body?.statements ?? [])
 case .structDecl(let sd): for m in sd.methods { precollectGenericStructUses(in: m.body?.statements ?? []) }
 case .objectDecl(let od): for m in od.methods { precollectGenericStructUses(in: m.body?.statements ?? []) }
 case .enumDecl(let ed): for m in ed.methods { precollectGenericStructUses(in: m.body?.statements ?? []) }
 default: break
 }
 }

 func precollectGenericStructUses(in statements: [Statement]) {
 for s in statements { precollectGenericStructUses(in: s) }
 }

 func precollectGenericStructUses(in stmt: Statement) {
 switch stmt {
 case .varDecl(_, _, let init_, _, _):
 if let e = init_ { precollectGenericStructUses(in: e) }
 case .varDestructure(_, _, let init_, _, _):
 if let e = init_ { precollectGenericStructUses(in: e) }
 case .assign(let target, let value, _):
 precollectGenericStructUses(in: target); precollectGenericStructUses(in: value)
 case .expressionStmt(let e, _): precollectGenericStructUses(in: e)
 case .returnStatement(let e, _): if let e = e { precollectGenericStructUses(in: e) }
 case .ifStatement(let c, let thenB, let elifs, let elseB, _, _):
 precollectGenericStructUses(in: c); precollectGenericStructUses(in: thenB.statements)
 for el in elifs { precollectGenericStructUses(in: el.condition); precollectGenericStructUses(in: el.block.statements) }
 if let b = elseB { precollectGenericStructUses(in: b.statements) }
 case .whileStatement(let c, let body, let step, _, _):
 precollectGenericStructUses(in: c); precollectGenericStructUses(in: body.statements)
 if let step = step { precollectGenericStructUses(in: step.statements) }
 case .forStatement(_, let iterable, let body, let step, _, _):
 precollectGenericStructUses(in: iterable); precollectGenericStructUses(in: body.statements)
 if let step = step { precollectGenericStructUses(in: step.statements) }
 case .matchStatement(let v, let cases, _):
 precollectGenericStructUses(in: v)
 for c in cases { precollectGenericStructUses(in: c.block.statements) }
 case .deferStatement(let s, _): precollectGenericStructUses(in: s)
 default: break
 }
 }

 func precollectGenericStructUses(in expr: Expression) {
 switch expr {
 case .genericConstruct(let typeName, let typeArgs, _, _):
 // R2：泛型 struct 构造预注册（模板在 structTypes 中、genericParams 非空）。
 if structTypes[mangle(typeName)]?.genericParams.isEmpty == false {
 try? registerGenericStructSpecialization(typeName: typeName, typeArgs: typeArgs)
 }
 case .binary(let l, _, let r, _): precollectGenericStructUses(in: l); precollectGenericStructUses(in: r)
 case .unary(_, let o, _): precollectGenericStructUses(in: o)
 case .call(let callee, let args, _):
 precollectGenericStructUses(in: callee)
 for a in args { precollectGenericStructUses(in: a.expression) }
 case .member(let base, _, _): precollectGenericStructUses(in: base)
 case .tupleIndex(let base, _, _): precollectGenericStructUses(in: base)
 case .resultUnwrap(let operand, _): precollectGenericStructUses(in: operand)
 case .tuple(_, let els, _): for e in els { precollectGenericStructUses(in: e) }
 case .arrayLiteral(let els, _): for e in els { precollectGenericStructUses(in: e) }
 case .join(let inner, _): precollectGenericStructUses(in: inner)
 case .stringInterpolation(let segs, _):
 for s in segs { if case .expression(let e) = s { precollectGenericStructUses(in: e) } }
 default: break
 }
 }

 func precollectGenericStructUses(in target: AssignTarget) {
 switch target {
 case .identifier: break
 case .member(let o, _): precollectGenericStructUses(in: o)
 case .subscript(let e, let i): precollectGenericStructUses(in: e); precollectGenericStructUses(in: i)
 }
 }

 /// 泛型 struct 模板 → 特化 StructDecl：字段/方法中的类型参数 `T` 替换为具体类型；
 /// 方法重命名为「接收者特化名」（`取_盒_I32`），使 R1.1 分派（`mangle(名)_mangle(接收者)`）命中。
 func specializeStructDecl(_ sd: StructDecl, substitution: [String: TypeAnnotation], specializedName: String) -> StructDecl {
 let resolveType: (TypeAnnotation?) -> TypeAnnotation? = { ta in
 guard let ta = ta else { return nil }
 if case .simple(let name, _) = ta, let sub = substitution[name] { return sub }
 return ta
 }
 let newFields = sd.fields.map { f in
 FieldDecl(name: f.name, typeAnnotation: resolveType(f.typeAnnotation) ?? f.typeAnnotation,
 initializer: f.initializer, location: f.location)
 }
 let newMethods = sd.methods.map { md -> FuncDecl in
 let newParams = md.params.map { p in Parameter(name: p.name, typeAnnotation: resolveType(p.typeAnnotation)) }
 let newReturns = md.returnTypes.map(resolveType).compactMap { $0 }
 return FuncDecl(name: "\(md.name)_\(specializedName)", modifiers: md.modifiers, genericParams: [],
 params: newParams, returnTypes: newReturns, returnLabels: md.returnLabels,
 isAsync: md.isAsync, body: md.body, location: md.location)
 }
 return StructDecl(name: specializedName, genericParams: [], fields: newFields, methods: newMethods,
 composedType: sd.composedType, traits: sd.traits, location: sd.location)
 }

 // MARK: - P6-4d: trait 方法分发

 /// 从 LLVM IR 类型字符串中提取 Pini 类型名。
 /// `"%struct.gou*"` → `"gou"`, `"%object.counter*"` → `"counter"`
 func extractTypeName(from llvmType: String) -> String {
 var t = llvmType
 if t.hasPrefix("%struct.") { t = String(t.dropFirst(8)) }
 else if t.hasPrefix("%object.") { t = String(t.dropFirst(8)) }
 else if t.hasPrefix("%enum.") { t = String(t.dropFirst(6)) }
 if t.hasSuffix("*") { t = String(t.dropLast(1)) }
 return t
 }

 /// 尝试通过 trait 默认实现分派方法调用。
 /// 返回找到的方法返回 IR 类型，若所有 trait 均无匹配则返回 nil。
 /// 副作用：若找到 trait 默认实现，生成该类型的特化方法函数。
 func tryTraitMethodDispatch(typeName: String, methodName: String, baseVal: IRValue) throws -> String? {
 guard let traitNames = typeTraits[typeName] else { return nil }

 for traitName in traitNames {
 guard let signatures = traitSignatures[traitName] else {
 // trait 可能未在当前模块定义（跨模块 trait）— 跳过
 continue
 }
 // 查找 trait 中匹配的方法（必须有 body，即默认实现）
 guard let traitMethod = signatures.first(where: { $0.name == methodName && $0.body != nil }) else {
 continue
 }
 // 特化 trait 方法：剥除 self 参数，由 generateFuncDecl 通过 receiverIRType 添加
 let specializedFD = specializeTraitMethod(traitMethod, for: typeName, receiverIRType: baseVal.llvmType)
 let mangledFuncName = mangle(specializedFD.name)
 // 注册返回类型并加入待生成队列
 try registerFuncReturnType(specializedFD)
 pendingSpecializations.append((specializedFD, baseVal.llvmType))
 return funcReturnIRTypes[mangledFuncName]
 }
 return nil
 }

 /// 为具体类型特化 trait 方法：剥除 self 参数（将由 generateFuncDecl 通过 receiverIRType 添加）。
 func specializeTraitMethod(_ tm: FuncDecl, for typeName: String, receiverIRType: String) -> FuncDecl {
 // 剥除 self 参数（trait 方法第一个参数为 self），后续参数保留
 let actualParams: [Parameter]
 if tm.params.first?.name == "self" {
 actualParams = Array(tm.params.dropFirst())
 } else {
 actualParams = tm.params
 }
 return FuncDecl(
 name: tm.name,
 modifiers: tm.modifiers,
 genericParams: [],
 params: actualParams,
 returnTypes: tm.returnTypes,
 returnLabels: tm.returnLabels,
 isAsync: tm.isAsync,
 body: tm.body,
 location: tm.location
 )
 }

 func mangleTypeAnnotation(_ ta: TypeAnnotation) -> TypeAnnotation {
 switch ta {
 case .simple(let name, let loc): return .simple(name: mangle(name), location: loc)
 case .generic(let name, let params, let loc):
 return .generic(name: mangle(name), params: params.map { mangleTypeAnnotation($0) }, location: loc)
 default: return ta
 }
 }
}
