import Foundation

/// #46-D D4.2.3+：块级集合变量释放用的快照（登记时固化 slot/type，解 P2 同名重声明释放错位）。
struct ScopeVar {
 let name: String
 let slot: String
 let type: String
}

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 语句与控制流发射：变量声明/赋值、if/elif、while(+step)、block 终结判定、match 分发。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 /// #46-D D1：变量绑定到数组字面量时，记录其首元素 Pini 类型到 `arrayElementTypeByVar`，
 /// 供 `generateSubscriptRead` 解析元素 LLVM 类型。不触碰类型系统（类型层数组仍推断为 nil）。
 /// 元素类型经自包含 `elementTypeOfLiteral` 推断（字面量 + 嵌套数组字面量），不依赖 TypeInference，
 /// 故单元测 `IRGenerator().generate` 路径（typeInference 为 nil）亦能正确记录。
 private func recordArrayElementTypeIfLiteral(_ name: String, _ initExpr: Expression?) {
 guard let initExpr,
 case .arrayLiteral(let els, _) = initExpr,
 let first = els.first,
 let ta = elementTypeOfLiteral(first) else { return }
 arrayElementTypeByVar[name] = ta
 }

 /// #46-D D2：变量绑定到字典字面量时，记录其「键 / 值」首元素 Pini 类型到
 /// `dictKeyTypeByVar` / `dictValueTypeByVar`，供字典下标读/写解析值 LLVM 类型（不触碰类型系统）。
 private func recordDictTypesIfLiteral(_ name: String, _ initExpr: Expression?) {
 guard let initExpr,
 case .dictionaryLiteral(let entries, _) = initExpr,
 let first = entries.first,
 let kt = elementTypeOfLiteral(first.key),
 let vt = elementTypeOfLiteral(first.value) else { return }
 dictKeyTypeByVar[name] = kt
 dictValueTypeByVar[name] = vt
 }

 /// #46-D D3：变量绑定到集合字面量时，记录其首元素 Pini 类型到 `setElementTypeByVar`，
 /// 供 `print` 容器格式化（`generateStringify`）推断元素 LLVM 类型（不触碰类型系统，与 D1/D2 同护栏）。
 private func recordSetElementTypeIfLiteral(_ name: String, _ initExpr: Expression?) {
 guard let initExpr,
 case .setLiteral(let els, _) = initExpr,
 let first = els.first,
 let ta = elementTypeOfLiteral(first) else { return }
 setElementTypeByVar[name] = ta
 }

 /// #46-D D4.2.0：容器**别名绑定**（`var b = a`）的元素类型传播。
 ///
 /// D1–D3 的 `record*IfLiteral` 只在初始化器为字面量时记录元素类型，故 `var b = a` 后
 /// `b` 无类型记录，下标读/写与 `print(b)` 会抛
 /// `IRGenError.unsupportedFeature(feature:"LLVM 后端未记录变量 'b' 的数组元素类型…")`。
 ///
 /// 别名共享同一不透明句柄（`%bk_array*` 等），元素类型必然与源变量一致，故直接复制记录条目。
 /// 仅处理 `.identifier` RHS（`b = a`）；表达式返回的容器（函数调用等）仍不记录，
 /// 保持 D1 既有护栏（宁可报错，不臆造类型）。不触碰类型系统。
 private func propagateContainerTypesIfAlias(_ name: String, _ initExpr: Expression?) {
 guard let initExpr, case .identifier(let src, _) = initExpr else { return }
 if let et = arrayElementTypeByVar[src] { arrayElementTypeByVar[name] = et }
 if let kt = dictKeyTypeByVar[src], let vt = dictValueTypeByVar[src] {
 dictKeyTypeByVar[name] = kt
 dictValueTypeByVar[name] = vt
 }
 if let et = setElementTypeByVar[src] { setElementTypeByVar[name] = et }
 if let tt = tupleTypeByVar[src] { tupleTypeByVar[name] = tt }
 }

 /// 批次 1.3（D1）：变量绑定到元组字面量时，记录其 Pini 元组类型（labels + 元素类型），
 /// 供 `print` 元组格式化（`generateStringifyTuple`）显示命名标签与递归格式化嵌套元素。
 /// 仅当每个元素均可经 `elementTypeOfLiteral` 推断（字面量）时记录；否则不臆造类型。
 private func recordTupleTypeIfLiteral(_ name: String, _ initExpr: Expression?) {
 guard let initExpr,
 case .tuple(let labels, let els, let loc) = initExpr else { return }
 let elemTAs = els.compactMap { elementTypeOfLiteral($0) }
 guard elemTAs.count == els.count else { return }
 tupleTypeByVar[name] = .tuple(labels: labels, elements: elemTAs, location: loc)
 }

 /// D1–D3 字面量记录 + D4.2.0 别名传播的统一入口。两条 varDecl 路径与 assign 共用，
 /// 避免记录逻辑在多处漂移（#44 desugar 教训：糖/元信息登记须收口到单点）。
 func recordContainerTypes(_ name: String, _ initExpr: Expression?) {
 recordArrayElementTypeIfLiteral(name, initExpr)
 recordDictTypesIfLiteral(name, initExpr)
 recordSetElementTypeIfLiteral(name, initExpr)
 recordTupleTypeIfLiteral(name, initExpr)
 propagateContainerTypesIfAlias(name, initExpr)
 }

 /// G40（S3）：登记 LazyRef 变量的元素 IR 类型（`.value` 的 `load T` 需要）。
 /// 来源：显式类型标注 `var r: LazyRef<T>`（typeAnnotation）、构造 `LazyRef<T>(闭包)`（genericConstruct）、
 /// 或别名传播 `var s = r`（r 已登记）。
 func recordLazyRefValueType(_ name: String, typeAnnotation: TypeAnnotation?, initializer: Expression?) {
 if let ta = typeAnnotation,
 case .generic(let gname, let params, _) = ta, gname == "LazyRef",
 let t = params.first {
 lazyRefValueTypeByVar[name] = try? typeMapper.map(t)
 return
 }
 if let initExpr = initializer,
 case .genericConstruct(let gname, let typeArgs, _, _) = initExpr, gname == "LazyRef",
 let t = typeArgs.first {
 lazyRefValueTypeByVar[name] = try? typeMapper.map(t)
 return
 }
 // 别名传播：`var s = r`（r 是 LazyRef 变量）——s 共享 r 的元素类型。
 if let initExpr = initializer,
 case .identifier(let srcName, _) = initExpr,
 let t = lazyRefValueTypeByVar[srcName] {
 lazyRefValueTypeByVar[name] = t
 }
 }

 // MARK: - #46-D D4.2.3 作用域精确释放（块级）

 /// 登记局部集合变量（用于块级/函数出口清理）。推到当前作用域层 `scopeStack[currentScopeDepth]`，
 /// 固化 (slot,type) 快照（解 P2：避免后续同名重声明覆盖 symbolTable 后释放错位）。
 /// 去重：同层同名只记一次（变量遮蔽/重声明），否则出口释放两次（过释放→UAF）。
 /// 跨文件 extension（ModuleEmitter/ClosureEmitter/match 亦调用）→ 必须 `internal`（#46-B 拆分护栏）。
 func registerLocalCollectionVar(_ name: String, _ slot: String, _ irType: String) {
 guard currentScopeDepth < scopeStack.count else { return }
 guard isCollectionHandleType(irType) else { return }
 // 所有 depth 都登记（块级释放的基础）；去重基于当前层避免重复释放。
 if scopeStack[currentScopeDepth].contains(where: { $0.name == name }) { return }
 scopeStack[currentScopeDepth].append(ScopeVar(name: name, slot: slot, type: irType))
 }

 /// 集合句柄类型 → 对应的 `bk_*_destroy` 函数名。
 func bkDestroyFnName(for irType: String) -> String {
 switch irType {
 case "%bk_array*": return "bk_array_destroy"
 case "%bk_dict*": return "bk_dict_destroy"
 case "%bk_set*": return "bk_set_destroy"
 default: return "bk_array_destroy" // 不可达（调用方已 isCollectionHandleType 守卫）
 }
 }

 /// D4.2.3-a：重赋值前释放「旧句柄」的一份 share（所有权契约：精确释放，避免泄漏）。
 func emitContainerDestroy(_ slot: String, _ irType: String) {
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: irType, ptr: slot))
 emitLine(" call void @\(bkDestroyFnName(for: irType))(ptr \(loaded))")
 }

 /// 块「自然落入」出口清理：释放本层（depth）集合局部的一份 share（反向序）。
 /// 安全前提：仅由 generateBlock / match 块在「自然落入」边调用——结构化语言保证控制流到达块末时，
 /// 块内所有声明变量必已初始化，故释放本层变量不会读脏 slot（零 UAF）。
 func emitBlockCleanup(_ depth: Int) {
 guard depth < scopeStack.count else { return }
 for v in scopeStack[depth].reversed() {
 emitContainerDestroy(v.slot, v.type)
 }
 }

 /// 发射指定作用域深度（`depth`）的全部 pending defer 到**当前 IR 位置**（LIFO 逆序），
 /// **不移除**——同一深度的 defer 须出现在该作用域的每个运行时出口块（自然落入 / break /
 /// continue），由各出口分别发射；`removeDeferredForScope` 在作用域出口全部生成完后清理，
 /// 防止函数出口 `emitDeferred` 重复发射。
 func emitDeferredForScope(_ depth: Int, functionReturnType: String, isMain: Bool) throws {
 guard !deferredStatements.isEmpty else { return }
 let toEmit = deferredStatements.enumerated().filter { deferDepths[$0.offset] == depth }.map { $0.element }
 for stmt in toEmit.reversed() {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain)
 }
 }

 /// 从 pending 列表移除指定深度的 defer（作用域出口已全部生成，避免函数出口重复发射）。
 func removeDeferredForScope(_ depth: Int) {
 guard !deferredStatements.isEmpty else { return }
 var keep: [Statement] = []
 var keepD: [Int] = []
 for (i, stmt) in deferredStatements.enumerated() {
 if deferDepths[i] != depth { keep.append(stmt); keepD.append(deferDepths[i]) }
 }
 deferredStatements = keep
 deferDepths = keepD
 }

 /// 函数/闭包出口清理：遍历所有残留层（反向层序、层内反向序）释放集合局部的一份 share。
 /// 已知残留：`return`/`break`/`continue` 终止边未清理的层变量漏一份 share（无害）；match/if 内联残留同。
 func emitScopeCleanup() {
 for layer in scopeStack.reversed() {
 for v in layer.reversed() {
 emitContainerDestroy(v.slot, v.type)
 }
 }
 }

 func generateStatement(_ stmt: Statement, functionReturnType: String, isMain: Bool, continueTarget: String? = nil) throws {
 switch stmt {
 case .returnStatement(let value, _):
 try emitDeferred(functionReturnType: functionReturnType, isMain: isMain)
 // D5 终止边精确释放：return 直接退出函数，放弃当前所有存活作用域层（0..currentScopeDepth）。
 // 函数 fall-through 出口的 emitScopeCleanup 仅在未走 return 路径时到达 → 无双重释放。
 emitScopeCleanup()
 if let v = value {
 let result = try generateExpression(v)
 ir += " ret \(functionReturnType) \(result.ssaName)\n"
 } else {
 if isMain || functionReturnType != "void" {
 ir += " ret \(functionReturnType) 0\n"
 } else {
 ir += " ret void\n"
 }
 }

 case .expressionStmt(let expr, _):
 try generateExpression(expr)

 case .varDecl(let name, let typeAnnotation, let initializer, _, _):
 let irType: String
 if let ta = typeAnnotation {
 irType = try typeMapper.map(ta)
 } else if let initExpr = initializer {
 let result = try generateExpression(initExpr)
 irType = result.llvmType
 let allocaName = "%\(mangle(name))_slot"
 emitLine(builder.fmtAlloca(name: allocaName, type: irType))
 // #46-D D4.2.1b：`var b = a` 别名绑定须补一份 share（所有权契约 ③），
 // 否则 a/b 任一方写入时运行时误判独占、原地改写，污染另一方。
 emitContainerAliasRetain(initExpr, result)
 emitLine(builder.fmtStore(value: result.ssaName, type: result.llvmType, ptr: allocaName))
 symbolTable[name] = (allocaName, irType)
 registerLocalCollectionVar(name, allocaName, irType)
 // #46-D D1/D2/D3 字面量元素类型记录 + D4.2.0 别名（`var b = a`）传播。
 recordContainerTypes(name, initializer)
 // G40（S3）：LazyRef<T> 变量登记元素 IR 类型（`.value` load 需要）。
 recordLazyRefValueType(name, typeAnnotation: typeAnnotation, initializer: initializer)
 // 阶段 B：变量绑定到匿名函数 → 记录其返回 IR 类型，供后续间接调用确定 ret。
 if let initExpr = initializer, case .funcLiteral(let decl, _) = initExpr {
 funcValueReturnTypes[name] = decl.returnTypes.isEmpty ? "void" : ((try? typeMapper.map(decl.returnTypes[0])) ?? "void")
 }
 return
 } else {
 irType = "i32"
 }
 let allocaName = "%\(mangle(name))_slot"
 emitLine(builder.fmtAlloca(name: allocaName, type: irType))
 if let initExpr = initializer {
 let result = try generateExpression(initExpr)
 // #46-D D4.2.1b：显式类型标注路径同样在别名绑定点补 share（所有权契约 ③）。
 emitContainerAliasRetain(initExpr, result)
 emitLine(builder.fmtStore(value: result.ssaName, type: result.llvmType, ptr: allocaName))
 }
 symbolTable[name] = (allocaName, irType)
 registerLocalCollectionVar(name, allocaName, irType)
 // #46-D D1/D2/D3 字面量元素类型记录 + D4.2.0 别名（`var b = a`）传播。
 recordContainerTypes(name, initializer)
 // G40（S3）：LazyRef<T> 变量登记元素 IR 类型（`.value` load 需要）。
 recordLazyRefValueType(name, typeAnnotation: typeAnnotation, initializer: initializer)
 // 阶段 B：变量绑定到匿名函数 → 记录其返回 IR 类型，供后续间接调用确定 ret。
 if let initExpr = initializer, case .funcLiteral(let decl, _) = initExpr {
 funcValueReturnTypes[name] = decl.returnTypes.isEmpty ? "void" : ((try? typeMapper.map(decl.returnTypes[0])) ?? "void")
 }

 case .varDestructure(let names, _, let initializer, _, _):
 // 草稿 A1（批次 1）：元组解构在 LLVM 端 = 生成 tuple struct → 逐槽 extractvalue → store 到各变量 slot。
 guard let initExpr = initializer else {
 throw IRGenError.unsupportedFeature(feature:"解构声明缺少初始值", SourceLocation(line: 0, column: 0, fileName: ""))
 }
 let result = try generateExpression(initExpr)
 for (i, name) in names.enumerated() where name != "_" {
 let fieldType = try tupleFieldIRType(result.llvmType, index: i)
 let allocaName = "%\(mangle(name))_slot"
 emitLine(builder.fmtAlloca(name: allocaName, type: fieldType))
 let tmp = builder.freshTemp()
 emitLine(" \(tmp) = extractvalue \(result.llvmType) \(result.ssaName), \(i)")
 emitLine(builder.fmtStore(value: tmp, type: fieldType, ptr: allocaName))
 symbolTable[name] = (allocaName, fieldType)
 }

 case .assign(target: let target, value: let value, let location):
 let rhs = try generateExpression(value)
 switch target {
 case .identifier(let name):
 guard let entry = symbolTable[name] else {
 throw IRGenError.unsupportedFeature(feature:"assign to undefined variable \(name)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 // #46-D D4.2.1b：`b = a` 重绑别名同样补一份 share（所有权契约 ③）。
 // D4.2.3-a：写回新值前，若本变量持集合句柄，先释放「旧句柄」的一份 share（精确释放）。
 if isCollectionHandleType(entry.type) {
 emitContainerDestroy(entry.slot, entry.type)
 }
 emitContainerAliasRetain(value, rhs)
 let rhsC = convertNumeric(rhs, to: entry.type)
 emitLine(builder.fmtStore(value: rhsC.ssaName, type: entry.type, ptr: entry.slot))
 // #46-D D4.2.0：`b = a`（重新绑定别名）/`b = [1,2]`（重绑字面量）同样更新元素类型记录，
 // 否则 b 沿用旧类型，下标读会按错误宽度解箱。
 recordContainerTypes(name, value)
 // 阶段 B：赋值右侧为匿名函数 → 记录返回 IR 类型。
 if case .funcLiteral(let decl, _) = value {
 funcValueReturnTypes[name] = decl.returnTypes.isEmpty ? "void" : ((try? typeMapper.map(decl.returnTypes[0])) ?? "void")
 }
 case .member(let obj, let name):
 let (fieldIRType, fldPtr) = try resolveMemberField(base: obj, memberName: name)
 let rhsC = convertNumeric(rhs, to: fieldIRType)
 emitLine(builder.fmtStore(value: rhsC.ssaName, type: fieldIRType, ptr: fldPtr))
 case .subscript(let container, let index):
 // #46-D D1.5：数组下标写 `a[i] = v`。复合赋值已在 Parser 折叠为 assign 值内的 binary，
 // 故此处恒以 .assign 分派到 generateAssignOp（其内对复合 op 另有读-算-写路径，备表达式级调用）。
 _ = try generateAssignOp(left: .subscript(expr: container, index: index, location: location), op: .assign, right: value)
 }

 case .ifStatement(let condition, let thenBlock, let elifs, let elseBlock, _, _):
 try generateIfStatement(condition: condition, thenBlock: thenBlock,
 elifs: elifs, elseBlock: elseBlock,
 functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: continueTarget)

 case .whileStatement(let condition, let body, let step, let blockLabel, _):
 try generateWhileStatement(condition: condition, body: body, step: step, blockLabel: blockLabel,
 functionReturnType: functionReturnType, isMain: isMain)

 case .forStatement(let pattern, let iterable, let body, let step, let blockLabel, _):
 try generateForStatement(pattern: pattern, iterable: iterable, body: body, step: step, blockLabel: blockLabel,
 functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: continueTarget)

 case .scopedBlock(let label, let body, _):
 try generateScopeStatement(label: label, body: body, functionReturnType: functionReturnType, isMain: isMain)

 case .breakStatement(let label, let loc):
 guard let frame = loopFrame(for: label) else {
 throw IRGenError.unsupportedStatement(kind:"break outside loop", loc)
 }
 // D5 终止边精确释放：break 放弃目标帧体层及嵌套块（enclosingDepth+1..currentScopeDepth），
 // 结构化语言保证这些层变量在 break 点必已初始化 → 零 UAF；外层存活层不误伤。
 let abandoned = (frame.enclosingDepth + 1)...currentScopeDepth
 // R1.2：被放弃各层的 defer 在 break 出口块发射（LIFO，内层→外层）；不移除——
 // 若 break 在嵌套 if 内、循环体自然落入出口随后仍生成，该出口亦须发射（供其他迭代）。
 for d in abandoned.reversed() {
 try emitDeferredForScope(d, functionReturnType: functionReturnType, isMain: isMain)
 }
 for d in abandoned { emitBlockCleanup(d) }
 emitLine(builder.fmtBr(labelName: frame.exitLabel))

 case .continueStatement(let label, let loc):
 guard let loop = loopFrame(for: label) else {
 throw IRGenError.unsupportedStatement(kind:"continue outside loop", loc)
 }
 // D5 终止边精确释放：continue 同样放弃本轮循环体层及嵌套块（语义同 break，避免本轮迭代尾部变量泄漏）。
 let abandonedC = (loop.enclosingDepth + 1)...currentScopeDepth
 // R1.2：被放弃各层的 defer 在 continue 出口块发射（LIFO，内层→外层）；不移除。
 for d in abandonedC.reversed() {
 try emitDeferredForScope(d, functionReturnType: functionReturnType, isMain: isMain)
 }
 for d in abandonedC { emitBlockCleanup(d) }
 // 带标签 continue → 目标帧自身（step 入口 / scope 重跑点 condLabel）；无标签 →
 // step 块内 continue 跳 step 末尾（continueTarget），否则跳目标帧 step 入口（执行 step 后回条件块）。
 let target: String
 if label != nil {
 target = loop.stepLabel ?? loop.condLabel
 } else {
 target = continueTarget ?? loop.stepLabel ?? loop.condLabel
 }
 emitLine(builder.fmtBr(labelName: target))

 case .matchStatement(let value, let cases, _):
 try generateMatchStatement(value: value, cases: cases,
 functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: continueTarget)
 case .passStatement(_):
 return
 case .captureStatement(_):
 // H-1：静态纯度声明，IR 无形——闭包捕获由 ClosureEmitter 自 body 分析得出
 return
 case .detachStatement(_, let detachLoc):
 // 任务 #13：detach 语句为解释器级 fire-and-forget 出口；LLVM 后端（D1 暂缓 FFI）
 // 尚未实现对应运行时原语，显式 unsupported（可逆）。
 throw IRGenError.unsupportedStatement(kind:"detach 语句暂不支持 LLVM 后端（解释器已支持）", detachLoc)
 case .deferStatement(let statement, _):
 // 记录注册作用域深度：块级 defer 在该块自然落入出口按 LIFO 刷新（#8）。
 deferredStatements.append(statement)
 deferDepths.append(currentScopeDepth)
 case .tryStatement(let expression, let tryBlock, let exceptClauses, _):
 try generateTryStatement(expression: expression, tryBlock: tryBlock,
 exceptClauses: exceptClauses,
 functionReturnType: functionReturnType, isMain: isMain)
 }
 }

 /// try 语句 IR（#5）：基于**返回元组显式传播**的错误模型，对齐解释器 `executeTry`。
 ///
 /// 语义：求值 `expression`（通常为返回 `(值, 错误,)` 元组的调用）→ 取第 2 字段作错误槽；
 /// 空串/null → 成功路径执行 tryBlock；非空 → 执行第一个 except 子句（绑定 `errorVar` 到错误值）。
 /// LLVM 仅支持 String（ptr）错误槽（文档化模式）；非元组结果恒走成功路径；其他错误槽类型 fail-loud。
 func generateTryStatement(expression: Expression, tryBlock: Block, exceptClauses: [ExceptClause],
 functionReturnType: String, isMain: Bool) throws {
 let result = try generateExpression(expression)
 // 元组（匿名 struct，≥2 字段）才有错误槽；否则恒成功（对齐解释器：非元组 errorValue 为 null）。
 let errFieldType: String?
 if result.llvmType.hasPrefix("{ ") && result.llvmType.hasSuffix(" }") {
 let fields = try tupleFieldIRTypes(result.llvmType)
 errFieldType = fields.count >= 2 ? fields[1] : nil
 } else {
 errFieldType = nil
 }

 guard let errFieldType else {
 _ = try generateBlock(tryBlock, functionReturnType: functionReturnType, isMain: isMain)
 return
 }
 // 仅支持 String（ptr）错误槽：strlen==0 视为成功；其余类型显式报不支持（不臆造语义）。
 guard errFieldType == "ptr" else {
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端 try 仅支持 String 错误槽（收到 \(errFieldType)）；请改用解释器 `pini run`", sl())
 }

 let label = nextLabel()
 let successL = "try_success_\(label)", errL = "try_err_\(label)", endL = "try_end_\(label)"
 let errVal = "%t\(nextTemp())"
 emitLine(" \(errVal) = extractvalue \(result.llvmType) \(result.ssaName), 1")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i64 @strlen(ptr \(errVal))")
 let isEmpty = "%t\(nextTemp())"
 emitLine(" \(isEmpty) = icmp eq i64 \(len), 0")
 emitLine(builder.fmtCondBr(cond: isEmpty, thenLabelName: successL, elseLabelName: errL))

 emitLine("\(successL):")
 if !tryBlock.statements.isEmpty {
 let terminated = try generateBlock(tryBlock, functionReturnType: functionReturnType, isMain: isMain)
 if !terminated { emitLine(builder.fmtBr(labelName: endL)) }
 } else {
 emitLine(builder.fmtBr(labelName: endL))
 }

 emitLine("\(errL):")
 // 仅执行第一个 except 子句（对齐解释器：命中首个子句后 return）。
 if let clause = exceptClauses.first {
 let slot = "%\(mangle(clause.errorVar))_slot"
 emitLine(builder.fmtAlloca(name: slot, type: "ptr"))
 emitLine(builder.fmtStore(value: errVal, type: "ptr", ptr: slot))
 symbolTable[clause.errorVar] = (slot, "ptr")
 _ = try generateBlock(clause.body, functionReturnType: functionReturnType, isMain: isMain)
 }
 emitLine(builder.fmtBr(labelName: endL))
 emitLine("\(endL):")
 }

 // MARK: - 控制流生成

 func generateIfStatement(condition: Expression, thenBlock: Block,
 elifs: [ElifBranch], elseBlock: Block?,
 functionReturnType: String, isMain: Bool,
 continueTarget: String? = nil) throws {
 let label = nextLabel()
 let condLabel = "if_cond_\(label)"
 let thenLabel = "if_then_\(label)"
 let mergeLabel = "if_merge_\(label)"
 let elseEntryLabel = "if_else_\(label)"

 emitLine(builder.fmtBr(labelName: condLabel))
 emitLine(builder.fmtLabelDef(condLabel))
 let condVal = try generateExpression(condition)
 emitLine(builder.fmtCondBr(cond: condVal.ssaName, thenLabelName: thenLabel, elseLabelName: elseEntryLabel))

 emitLine(builder.fmtLabelDef(thenLabel))
 let thenTerminated = try generateBlock(thenBlock, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if !thenTerminated {
 emitLine(builder.fmtBr(labelName: mergeLabel))
 }

 emitLine(builder.fmtLabelDef(elseEntryLabel))
 if !elifs.isEmpty {
 try generateElifChain(elifs: elifs, elseBlock: elseBlock,
 mergeLabel: mergeLabel,
 functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: continueTarget)
 } else if let eb = elseBlock {
 let elseTerminated = try generateBlock(eb, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if !elseTerminated {
 emitLine(builder.fmtBr(labelName: mergeLabel))
 }
 } else {
 emitLine(builder.fmtBr(labelName: mergeLabel))
 }

 emitLine(builder.fmtLabelDef(mergeLabel))
 }

 func generateElifChain(elifs: [ElifBranch], elseBlock: Block?, mergeLabel: String,
 functionReturnType: String, isMain: Bool,
 continueTarget: String? = nil) throws {
 let count = elifs.count
 for (i, elif) in elifs.enumerated() {
 let label = nextLabel()
 let elifCondLabel = "elif_cond_\(label)"
 let elifThenLabel = "elif_then_\(label)"

 emitLine(builder.fmtBr(labelName: elifCondLabel))
 emitLine(builder.fmtLabelDef(elifCondLabel))
 let condVal = try generateExpression(elif.condition)

 let nextLabel: String
 let isLast = i == count - 1
 if isLast {
 if let eb = elseBlock {
 nextLabel = "elif_else_\(label)"
 } else {
 nextLabel = mergeLabel
 }
 } else {
 nextLabel = "elif_next_\(label)"
 }
 emitLine(builder.fmtCondBr(cond: condVal.ssaName, thenLabelName: elifThenLabel, elseLabelName: nextLabel))

 emitLine(builder.fmtLabelDef(elifThenLabel))
 let elifTerminated = try generateBlock(elif.block, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if !elifTerminated {
 emitLine(builder.fmtBr(labelName: mergeLabel))
 }

 if isLast {
 if let eb = elseBlock {
 emitLine(builder.fmtLabelDef(nextLabel))
 let elseTerminated = try generateBlock(eb, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if !elseTerminated {
 emitLine(builder.fmtBr(labelName: mergeLabel))
 }
 }
 } else {
 emitLine(builder.fmtLabelDef(nextLabel))
 }
 }
 }

 func generateWhileStatement(condition: Expression, body: Block, step: Block?, blockLabel: String?,
 functionReturnType: String, isMain: Bool) throws {
 let label = nextLabel()
 let condLabel = "while_cond_\(label)"
 let bodyLabel = "while_body_\(label)"
 let stepLabel = "while_step_\(label)"
 let stepEndLabel = "while_step_end_\(label)"
 let exitLabel = "while_exit_\(label)"
 // D5 终止边精确释放：记录循环体「外层」作用域深度，供 break/continue 清理被放弃的
 // 循环体层及嵌套块（enclosingDepth+1 .. currentScopeDepth），不误伤外层存活变量。
 let loopEnclosingDepth = currentScopeDepth

 emitLine(builder.fmtBr(labelName: condLabel))
 if let step = step {
 loopStack.append((exitLabel: exitLabel, condLabel: condLabel, stepLabel: stepLabel, stepContinueLabel: stepEndLabel, enclosingDepth: loopEnclosingDepth, label: blockLabel, isLoop: true))
 } else {
 loopStack.append((exitLabel: exitLabel, condLabel: condLabel, stepLabel: nil, stepContinueLabel: nil, enclosingDepth: loopEnclosingDepth, label: blockLabel, isLoop: true))
 }
 emitLine(builder.fmtLabelDef(condLabel))
 let condVal = try generateExpression(condition)
 emitLine(builder.fmtCondBr(cond: condVal.ssaName, thenLabelName: bodyLabel, elseLabelName: exitLabel))

 emitLine(builder.fmtLabelDef(bodyLabel))
 // 体内部 continue 跳到 step 入口（执行 step 后再回条件块）；无 step 时直接回条件块
 let bodyTerminated = try generateBlock(body, functionReturnType: functionReturnType, isMain: isMain, continueTarget: step != nil ? stepLabel : nil)
 if !bodyTerminated {
 if let _ = step {
 emitLine(builder.fmtBr(labelName: stepLabel))
 } else {
 emitLine(builder.fmtBr(labelName: condLabel))
 }
 }

 if let step = step {
 emitLine(builder.fmtLabelDef(stepLabel))
 // step 块内部 continue 跳到 step 末尾（不重执行 step 自身），随后回条件块
 let stepTerminated = try generateBlock(step, functionReturnType: functionReturnType, isMain: isMain, continueTarget: stepEndLabel)
 if !stepTerminated {
 emitLine(builder.fmtBr(labelName: stepEndLabel))
 }
 emitLine(builder.fmtLabelDef(stepEndLabel))
 emitLine(builder.fmtBr(labelName: condLabel))
 }

 emitLine(builder.fmtLabelDef(exitLabel))
 loopStack.removeLast()
 }

 /// ADR-013：`scope 块标签:` 带标签无条件子块。
 /// 块体默认执行一次；`break 标签` 跳出 scope、`continue 标签` 续行（重跑块体，语义同续行到 scope）。
 /// 复用 while/for 的 loopStack 帧机制，使块内 `break 标签`/`continue 标签` 按标签名定向。
 func generateScopeStatement(label: String?, body: Block, functionReturnType: String, isMain: Bool) throws {
 let lbl = nextLabel()
 let startLabel = "scope_start_\(lbl)"
 let exitLabel = "scope_exit_\(lbl)"
 let scopeEnclosingDepth = currentScopeDepth

 emitLine(builder.fmtBr(labelName: startLabel))
 // D5 终止边精确释放：记录块体「外层」作用域深度，供 break/continue 清理被放弃的块体层。
 loopStack.append((exitLabel: exitLabel, condLabel: startLabel, stepLabel: nil, stepContinueLabel: nil, enclosingDepth: scopeEnclosingDepth, label: label, isLoop: false))
 emitLine(builder.fmtLabelDef(startLabel))
 // 语义对齐 executeScope（ADR-013）：正常执行完块体 → 落到 exitLabel（scope 只跑一次，
 // 不自行循环）；`break 标签`/`continue 标签` 由 break/continue handler 按标签名定向到
 // 本帧的 exitLabel / condLabel(=startLabel 重跑)；无标签 break/continue → 直取最近循环帧
 // （isLoop=true，跳过 scope），与解释器一致。
 let bodyTerminated = try generateBlock(body, functionReturnType: functionReturnType, isMain: isMain, continueTarget: nil)
 if !bodyTerminated {
 emitLine(builder.fmtBr(labelName: exitLabel))
 }
 emitLine(builder.fmtLabelDef(exitLabel))
 loopStack.removeLast()
 }

 /// 定位 break/continue 的目标帧（ADR-013 标签定向）：
 /// 带标签 → 沿 loopStack 自上而下找标签匹配帧（scope/while/for 均可）；
 /// 无标签 → 最近**循环**帧（isLoop=true，跳过 scope 帧——与解释器 executeScope 一致：
 /// 无标签 break/continue 在 scope 内不终结 scope，继续上浮到最近循环）。
 private func loopFrame(for label: String?)
 -> (exitLabel: String, condLabel: String, stepLabel: String?, stepContinueLabel: String?, enclosingDepth: Int, label: String?, isLoop: Bool)? {
 if let label = label {
 return loopStack.reversed().first { $0.label == label }
 }
 return loopStack.reversed().first { $0.isLoop }
 }

 /// `for (模式元组,) in 集合值: body [step: block]`（G36）
 /// 模式元组 ↔ 集合元素一一对应：数组/集合=1 字段、字典=2 字段 (k,v)；`_` 占位忽略。
 /// 复用 D5 终止边清理：loopStack 记录 enclosingDepth，body/step 经 generateBlock 自然落入边
 /// 块级释放；break/continue 放弃被终止层。索引递增位于每轮末尾（body 后 / step 后）。
 /// 范围：iterable 支持字面量或已登记集合变量；模式变量暂不支持集合元素（嵌套集合迭代，报错）。
 func generateForStatement(pattern: [String], iterable: Expression, body: Block, step: Block?, blockLabel: String?,
 functionReturnType: String, isMain: Bool, continueTarget: String? = nil) throws {
 let info = try forIterableInfo(iterable)
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 guard pattern.count == info.elemTAs.count else {
 throw IRGenError.unsupportedStatement(kind:
 "for 模式元组字段数（\(pattern.count)）须与集合元素字段数（\(info.elemTAs.count)）一一对应",
 loc)
 }
 let label = nextLabel()
 let condLabel = "for_cond_\(label)"
 let bodyLabel = "for_body_\(label)"
 let stepLabel = "for_step_\(label)"
 let stepEndLabel = "for_step_end_\(label)"
 let incLabel = "for_inc_\(label)"
 let exitLabel = "for_exit_\(label)"
 let loopEnclosingDepth = currentScopeDepth

 // 集合句柄 → 长度
 let iterVal = try generateExpression(iterable)
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast \(iterVal.llvmType) \(iterVal.ssaName) to ptr")
 let lenFn = info.kind == "dict" ? "bk_dict_len" : (info.kind == "set" ? "bk_set_len" : "bk_array_len")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i32 @\(lenFn)(ptr \(raw))")

 // 循环索引 i（alloca + 初始 0 + 每轮末尾 +1）
 let iSlot = "%for_i_\(label)_slot"
 emitLine(builder.fmtAlloca(name: iSlot, type: "i32"))
 emitLine(builder.fmtStore(value: "0", type: "i32", ptr: iSlot))

 emitLine(builder.fmtBr(labelName: condLabel))
 loopStack.append((exitLabel: exitLabel, condLabel: condLabel, stepLabel: step != nil ? stepLabel : nil, stepContinueLabel: stepEndLabel, enclosingDepth: loopEnclosingDepth, label: blockLabel, isLoop: true))

 emitLine(builder.fmtLabelDef(condLabel))
 let iv = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: iv, type: "i32", ptr: iSlot))
 let cmp = "%t\(nextTemp())"
 emitLine(" \(cmp) = icmp slt i32 \(iv), \(len)")
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: bodyLabel, elseLabelName: exitLabel))

 emitLine(builder.fmtLabelDef(bodyLabel))
 let ivBody = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: ivBody, type: "i32", ptr: iSlot))
 // 手写 body 层（等价 generateBlock，但模式变量须登记进同一层）：
 // 集合句柄模式变量（嵌套集合迭代）随每轮 body 自然落入边精确释放；标量/字符串无需释放。
 // break/continue 终止边由 D5 handler 清理（enclosingDepth+1..currentScopeDepth 覆盖本层）。
 currentScopeDepth += 1
 scopeStack.append([])
 for (i, name) in pattern.enumerated() where name != "_" {
 let ta = info.elemTAs[i]
 let elemLLVM = try collectionAwareLLVMType(ta)
 let getFn: String
 switch info.kind {
 case "dict": getFn = i == 0 ? "bk_dict_key_at" : "bk_dict_val_at"
 case "set": getFn = "bk_set_at"
 default: getFn = "bk_array_get"
 }
 let box = "%t\(nextTemp())"
 emitLine(" \(box) = call ptr @\(getFn)(ptr \(raw), i32 \(ivBody))")
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: elemLLVM, ptr: box))
 let allocaName = "%\(mangle(name))_\(label)_slot"
 emitLine(builder.fmtAlloca(name: allocaName, type: elemLLVM))
 emitLine(builder.fmtStore(value: loaded, type: elemLLVM, ptr: allocaName))
 symbolTable[name] = (allocaName, elemLLVM)
 if isCollectionHandleType(elemLLVM) {
 registerLocalCollectionVar(name, allocaName, elemLLVM)
 // 模式变量绑定集合句柄：记录元素/键值 TA（供 body 内 `row[0]`/`d[k]` 下标解析，对齐 varDecl recordContainerTypes）
 switch ta {
 case .generic("Array", let params, _) where params.count == 1:
 arrayElementTypeByVar[name] = params[0]
 case .generic("Dictionary", let params, _) where params.count == 2:
 dictKeyTypeByVar[name] = params[0]
 dictValueTypeByVar[name] = params[1]
 case .generic("Set", let params, _) where params.count == 1:
 setElementTypeByVar[name] = params[0]
 default: break
 }
 }
 }
 var bodyTerminated = false
 for stmt in body.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: step != nil ? stepLabel : incLabel)
 if isTerminatingStatement(stmt) {
 bodyTerminated = true
 break
 }
 }
 if !bodyTerminated {
 try emitDeferredForScope(currentScopeDepth, functionReturnType: functionReturnType, isMain: isMain)
 removeDeferredForScope(currentScopeDepth)
 emitBlockCleanup(currentScopeDepth)
 } else {
 removeDeferredForScope(currentScopeDepth)
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1

 // 自然落入边回跳；终止边（return/break/continue）已转移控制流，不重复 br。
 if !bodyTerminated {
 emitLine(builder.fmtBr(labelName: step != nil ? stepLabel : incLabel))
 }

 if let step = step {
 emitLine(builder.fmtLabelDef(stepLabel))
 let stepTerminated = try generateBlock(step, functionReturnType: functionReturnType, isMain: isMain, continueTarget: stepEndLabel)
 if !stepTerminated {
 emitLine(builder.fmtBr(labelName: stepEndLabel))
 }
 emitLine(builder.fmtLabelDef(stepEndLabel))
 emitLine(builder.fmtBr(labelName: incLabel))
 }

 // 索引递增（每轮末尾，所有回 cond 路径必经：body 尾 / step 尾 / continue）
 emitLine(builder.fmtLabelDef(incLabel))
 let ivInc = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: ivInc, type: "i32", ptr: iSlot))
 let next = "%t\(nextTemp())"
 emitLine(" \(next) = add i32 \(ivInc), 1")
 emitLine(builder.fmtStore(value: next, type: "i32", ptr: iSlot))
 emitLine(builder.fmtBr(labelName: condLabel))

 emitLine(builder.fmtLabelDef(exitLabel))
 loopStack.removeLast()
 }

 /// for-in 迭代集合信息（G36）：kind = array/dict/set；elemTAs = 元素/键值 TypeAnnotation 列表（与模式元组一一对应）。
 /// 范围：iterable 为字面量（elementTypeOfLiteral 推断）或已登记集合变量（arrayElementTypeByVar 等表）。
 private func forIterableInfo(_ iterable: Expression) throws -> (kind: String, elemTAs: [TypeAnnotation]) {
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 switch iterable {
 case .arrayLiteral(let els, _):
 guard let first = els.first, let et = elementTypeOfLiteral(first) else {
 throw IRGenError.unsupportedStatement(kind:"无法推断 for-in 数组元素类型", loc)
 }
 return ("array", [et])
 case .dictionaryLiteral(let entries, _):
 guard let first = entries.first,
 let kt = elementTypeOfLiteral(first.key),
 let vt = elementTypeOfLiteral(first.value) else {
 throw IRGenError.unsupportedStatement(kind:"无法推断 for-in 字典键值类型", loc)
 }
 return ("dict", [kt, vt])
 case .setLiteral(let els, _):
 guard let first = els.first, let et = elementTypeOfLiteral(first) else {
 throw IRGenError.unsupportedStatement(kind:"无法推断 for-in 集合元素类型", loc)
 }
 return ("set", [et])
 case .identifier(let name, _):
 if let et = arrayElementTypeByVar[name] { return ("array", [et]) }
 if let kt = dictKeyTypeByVar[name], let vt = dictValueTypeByVar[name] { return ("dict", [kt, vt]) }
 if let et = setElementTypeByVar[name] { return ("set", [et]) }
 throw IRGenError.unsupportedStatement(kind:"for-in 迭代目标无法推断集合元素类型（仅支持字面量或已登记集合变量）", loc)
 default:
 throw IRGenError.unsupportedStatement(kind:"for-in 迭代目标暂不支持该表达式形态（仅支持字面量或变量标识符）", loc)
 }
 }

 func generateBlock(_ block: Block, functionReturnType: String, isMain: Bool, continueTarget: String? = nil) throws -> Bool {
 currentScopeDepth += 1
 scopeStack.append([])
 var terminated = false
 for stmt in block.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if isTerminatingStatement(stmt) {
 terminated = true
 break
 }
 }
 // 块级精确释放：仅「自然落入」边释放本层（结构化语言保证块末变量必初始化 → 零 UAF）；
 // `return`/`break`/`continue` 终止边不释放（已知无害残留，避免读脏 slot）。
 if !terminated {
 // R1.2：自然落入出口发射本层 defer（运行于每个 fall-through 迭代），随后清理 pending，
 // 防止函数出口重复发射；终止边（return 已 emitDeferred / break / continue 已 emit）只清理不重复发射。
 try emitDeferredForScope(currentScopeDepth, functionReturnType: functionReturnType, isMain: isMain)
 removeDeferredForScope(currentScopeDepth)
 emitBlockCleanup(currentScopeDepth)
 } else {
 removeDeferredForScope(currentScopeDepth)
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1
 return terminated
 }

 func isTerminatingStatement(_ stmt: Statement) -> Bool {
 if case .returnStatement = stmt {
 return true
 }
 // D5：break/continue 转移控制流离开当前块（跳至循环出口/条件），其后语句不可达，
 // 视为块终止 → generateBlock 不再发射尾部清理/br，消除「终结指令后再塞指令」非法 IR。
 if case .breakStatement = stmt {
 return true
 }
 if case .continueStatement = stmt {
 return true
 }
 if case .matchStatement(_, let cases, _) = stmt {
 let allCasesReturn = cases.allSatisfy { mc in
 mc.block.statements.contains { if case .returnStatement = $0 { true } else { false } }
 }
 // D3①：兜底 = `case _:` 通配分支（旧 defaultCase/wildcardBlock 字段已移除）。
 let wildcardReturns = cases.first { if case .wildcard = $0.pattern { true } else { false } }?
 .block.statements.contains { if case .returnStatement = $0 { true } else { false } } ?? false
 return allCasesReturn && wildcardReturns
 }
 return false
 }

 /// 枚举 match 分发：load tag → `switch i32` 跳转至各 case / `case _:` 通配兜底。
 /// R4：全部为字面量/通配模式（int/float/string/bool/`_`）时走标量比较链（HIGH-2 IR 路径）。
 func generateMatchStatement(value: Expression, cases: [MatchCase],
 functionReturnType: String, isMain: Bool,
 continueTarget: String? = nil) throws {
 // R4：标量/字面量 match 判定——非枚举模式（int/float/string/bool/wildcard）全部走标量路径。
 let isScalarMatch = cases.allSatisfy { mc in
 switch mc.pattern {
 case .enumCase: return false
 case .intLiteral, .floatLiteral, .stringLiteral, .boolLiteral, .wildcard: return true
 }
 }
 if isScalarMatch {
 return try generateScalarMatchStatement(value: value, cases: cases,
 functionReturnType: functionReturnType, isMain: isMain,
 continueTarget: continueTarget)
 }
 let matchVal = try generateExpression(value)
 // 剥离尾部 "*" 以获取聚合类型名（如 %enum.Shape）
 let enumType = String(matchVal.llvmType.dropLast())
 // P5-5 B4：match 按被匹配值的 IR 类型反查父枚举，避免跨枚举同名 case 串味
 let enumParentName = enumType.replacingOccurrences(of: "%enum.", with: "")
 let tagPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: tagPtr, aggregate: enumType, base: matchVal.ssaName, indices: [0, 0]))
 let tagVal = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: tagVal, type: "i32", ptr: tagPtr))

 let matchLabels = nextLabel()
 let endLabel = "match_end_\(matchLabels)"
 let defaultLabel = "match_default_\(matchLabels)"

 // 构建 switch 分支表
 var arms: [(tag: Int, label: String)] = []
 for (i, mc) in cases.enumerated() {
 // D3①：通配 case（case _:）由 switch 的 default 目标兜底，不入分支表。
 if case .wildcard = mc.pattern { continue }
 guard case .enumCase(let name) = mc.pattern else {
 throw IRGenError.unsupportedFeature(feature:"match 字面量模式暂不支持 IR 后端（HIGH-2 IR 路径待实现，仅解释器支持）", mc.location)
 }
 if let (_, tag, _) = enumCaseTags["\(enumParentName).\(name)"] {
 arms.append((tag, "match_case_\(matchLabels)_\(i)"))
 }
 }
 let armStr = arms.map { "i32 \($0.tag), label %\($0.label)" }.joined(separator: "\n ")
 emitLine(" switch i32 \(tagVal), label %\(defaultLabel) [")
 if !arms.isEmpty {
 emitLine(" \(armStr)")
 }
 emitLine(" ]")

 // 生成各 case 块（含 payload 绑定注入）
 var hasForwardedToEnd = false
 for (i, mc) in cases.enumerated() {
 // D3①：通配 case（case _:）不在 switch 分支表——switch 的 default 目标即通配兜底，
 // 其 block 在下文 defaultLabel 处执行；此处跳过（无 tag、无绑定）。
 if case .wildcard = mc.pattern { continue }
 let caseLabel = "match_case_\(matchLabels)_\(i)"
 emitLine("")
 emitLine(" \(caseLabel):")
 // 进入 case 块层（手动层管理：隔离跨 case 未初始化 UAF；case 内集合变量块末自然落入时释放）
 currentScopeDepth += 1
 scopeStack.append([])
 // 注入 payload 绑定：从 enum union 提取关联值并绑定到局部变量
 guard case .enumCase(let name) = mc.pattern else {
 throw IRGenError.unsupportedFeature(feature:"match 字面量模式暂不支持 IR 后端（HIGH-2 IR 路径待实现，仅解释器支持）", mc.location)
 }
 if !mc.bindings.isEmpty, let (_, _, params) = enumCaseTags["\(enumParentName).\(name)"] {
 let isOptionalSome = (enumParentName == "Optional" && name == "some")
 for (bi, binding) in mc.bindings.enumerated() {
 let payloadIdx = min(bi, params.count - 1)
 // #46-optional：match Optional.some(v) 走装箱解构——field1 是 ptr（box），
 // 需 concrete T 才能 bitcast 回 T* 并 load。T 来自 typeInference 重推 scrutinee 类型
 // （Optional 单一无类型 IR、AST 不携带类型，故不能静态映射 params[payloadIdx].type）。
 if isOptionalSome {
 guard let ti = typeInference,
 let subjectType = ti.infer(expression: value),
 case .generic(_, let typeArgs, _) = subjectType,
 let elemType = typeArgs.first else {
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端 match Optional.some 需类型信息：请先经 TypeChecker（CLI 路径已注入 typeInference）", sl())
 }
 // 元素 concrete 类型；若无法映射（如 Optional<Any>，仅来自 none/nil），
 // 退化为 ptr——该 some 分支对 none 是死代码，装箱槽恒为 ptr，产出合法 IR 即可。
 let tIRType: String
 if let mapped = try? typeMapper.map(elemType) {
 tIRType = mapped
 } else {
 tIRType = "ptr"
 }
 let fldPtr = "%t\(nextTemp())"
 emitLine(" \(fldPtr) = getelementptr \(enumType), ptr \(matchVal.ssaName), i32 0, i32 \(payloadIdx + 1)")
 // field1 是 box（ptr，指向堆/栈上的值内存）。LLVM 22 全不透明指针，
 // 不允许 ptr*；故**直接 load T**（box 即指向 T 的内存），无需 bitcast ptr→T*。
 let boxPtr = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: boxPtr, type: "ptr", ptr: fldPtr))
 let val = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: val, type: tIRType, ptr: boxPtr))
 let slot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: slot, type: tIRType))
 emitLine(builder.fmtStore(value: val, type: tIRType, ptr: slot))
 symbolTable[binding.varName] = (slot, tIRType)
 registerLocalCollectionVar(binding.varName, slot, tIRType)
 } else {
 let paramType = try typeMapper.map(params[payloadIdx].type)
 let fldPtr = "%t\(nextTemp())"
 emitLine(" \(fldPtr) = getelementptr \(enumType), ptr \(matchVal.ssaName), i32 0, i32 \(payloadIdx + 1)")
 let val = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: val, type: paramType, ptr: fldPtr))
 let slot = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: slot, type: paramType))
 emitLine(builder.fmtStore(value: val, type: paramType, ptr: slot))
 symbolTable[binding.varName] = (slot, paramType)
 registerLocalCollectionVar(binding.varName, slot, paramType)
 }
 }
 }
 for stmt in mc.block.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 }
 let lastLine = ir.split(separator: "\n").last ?? ""
 if !lastLine.trimmingCharacters(in: .whitespaces).hasPrefix("ret") {
 hasForwardedToEnd = true
 emitBlockCleanup(currentScopeDepth)
 emitLine(builder.fmtBr(labelName: endLabel))
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1
 }

 // 生成 default 块（D3①：`case _:` 通配即兜底，旧 defaultCase/wildcardBlock 字段已移除）
 emitLine("")
 emitLine(" \(defaultLabel):")
 // 进入 default/wildcard 块层（与 case 块对称隔离）
 currentScopeDepth += 1
 scopeStack.append([])
 let fallback = cases.first { mc in if case .wildcard = mc.pattern { true } else { false } }?.block
 if let fallback = fallback {
 for stmt in fallback.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 }
 }
 let lastLine = ir.split(separator: "\n").last ?? ""
 if !lastLine.trimmingCharacters(in: .whitespaces).hasPrefix("ret") {
 hasForwardedToEnd = true
 emitBlockCleanup(currentScopeDepth)
 emitLine(builder.fmtBr(labelName: endLabel))
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1

 // 合并点
 emitLine("")
 emitLine(" \(endLabel):")
 // 如果没有分支到达此合并点（所有 case 都 return），标记为 unreachable
 if !hasForwardedToEnd {
 emitLine(" unreachable")
 }
 }

 /// R4：标量/字面量 match（HIGH-2 IR 路径）——`match x: case 1: ... case _:`。
 /// 逐 case 生成「值 == 字面量」比较 + 条件分支链（顺序匹配，首个命中执行），
 /// `case _:` 通配为兜底（无通配且未命中 → 跳过到 end）。支持 i32/i64/i8/i16/double/float/i1
 /// 与字符串（strcmp==0）。对齐解释器：按声明顺序首中即止。
 func generateScalarMatchStatement(value: Expression, cases: [MatchCase],
 functionReturnType: String, isMain: Bool,
 continueTarget: String?) throws {
 let matchVal = try generateExpression(value)
 let label = nextLabel()
 let endLabel = "match_end_\(label)"
 let defaultLabel = "match_default_\(label)"

 // 字面量比较操作数（按值 IR 类型）；不匹配的类型组合返回 nil（抛不支持，不臆造）。
 let literalOperand: (MatchPattern) throws -> String? = { pattern in
 switch (matchVal.llvmType, pattern) {
 case ("i8", .intLiteral(let n)), ("i16", .intLiteral(let n)),
 ("i32", .intLiteral(let n)), ("i64", .intLiteral(let n)):
 return "\(n)"
 case ("float", .floatLiteral(let f)), ("double", .floatLiteral(let f)):
 return self.formatFloat(f)
 case ("i1", .boolLiteral(let b)):
 return b ? "true" : "false"
 case ("ptr", .stringLiteral(_)):
 return nil // 字符串走 strcmp 路径
 default:
 return nil
 }
 }

 let nonWildcard = cases.enumerated().filter { if case .wildcard = $0.element.pattern { false } else { true } }
 // 若全是通配（无实际分支），直接落 default。
 guard !nonWildcard.isEmpty else {
 return try generateScalarCaseBlock(cases.first { if case .wildcard = $0.pattern { true } else { false } }?.block,
 endLabel: endLabel, defaultLabel: defaultLabel, hasFallthrough: false,
 functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 }
 let condLabels = nonWildcard.map { "match_cond_\(label)_\($0.offset)" }
 emitLine(builder.fmtBr(labelName: condLabels[0]))

 var hasForwardedToEnd = false
 for (ci, (i, mc)) in nonWildcard.enumerated() {
 let condL = condLabels[ci]
 let caseL = "match_case_\(label)_\(i)"
 emitLine("")
 emitLine(" \(condL):")
 let cmp: String
 if matchVal.llvmType == "ptr", case .stringLiteral(let lit) = mc.pattern {
 usesStrCmp = true
 let litPtr = try generateStringLiteral(lit)
 let scmp = "%t\(nextTemp())"
 emitLine(" \(scmp) = call i32 @strcmp(ptr \(matchVal.ssaName), ptr \(litPtr.ssaName))")
 let zero = "%t\(nextTemp())"
 emitLine(" \(zero) = icmp eq i32 \(scmp), 0")
 cmp = zero
 } else if let operand = try literalOperand(mc.pattern) {
 let instr = (matchVal.llvmType == "double" || matchVal.llvmType == "float") ? "fcmp oeq" : "icmp eq"
 let cmpT = "%t\(nextTemp())"
 emitLine(" \(cmpT) = \(instr) \(matchVal.llvmType) \(matchVal.ssaName), \(operand)")
 cmp = cmpT
 } else {
 throw IRGenError.unsupportedFeature(feature:
 "match 字面量模式与值类型不匹配（\(mc.pattern) vs \(matchVal.llvmType)）", mc.location)
 }
 let nextL = ci + 1 < condLabels.count ? condLabels[ci + 1] : defaultLabel
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: caseL, elseLabelName: nextL))
 emitLine("")
 emitLine(" \(caseL):")
 // case 块层（手动层管理，与枚举 match 对称）
 currentScopeDepth += 1
 scopeStack.append([])
 var terminated = false
 for stmt in mc.block.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if isTerminatingStatement(stmt) { terminated = true; break }
 }
 if !terminated {
 hasForwardedToEnd = true
 try emitDeferredForScope(currentScopeDepth, functionReturnType: functionReturnType, isMain: isMain)
 removeDeferredForScope(currentScopeDepth)
 emitBlockCleanup(currentScopeDepth)
 emitLine(builder.fmtBr(labelName: endLabel))
 } else {
 removeDeferredForScope(currentScopeDepth)
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1
 }

 // 通配兜底 / 未命中合并
 emitLine("")
 emitLine(" \(defaultLabel):")
 let wildcardBlock = cases.first { mc in if case .wildcard = mc.pattern { true } else { false } }?.block
 currentScopeDepth += 1
 scopeStack.append([])
 if let wb = wildcardBlock {
 var terminated = false
 for stmt in wb.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if isTerminatingStatement(stmt) { terminated = true; break }
 }
 if !terminated {
 hasForwardedToEnd = true
 try emitDeferredForScope(currentScopeDepth, functionReturnType: functionReturnType, isMain: isMain)
 removeDeferredForScope(currentScopeDepth)
 emitBlockCleanup(currentScopeDepth)
 emitLine(builder.fmtBr(labelName: endLabel))
 } else {
 removeDeferredForScope(currentScopeDepth)
 }
 } else {
 emitLine(builder.fmtBr(labelName: endLabel))
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1

 emitLine("")
 emitLine(" \(endLabel):")
 if !hasForwardedToEnd {
 emitLine(" unreachable")
 }
 }

 /// 执行单个 match case 块（供全通配等无分支场景复用）。
 private func generateScalarCaseBlock(_ block: Block?, endLabel: String, defaultLabel: String,
 hasFallthrough: Bool, functionReturnType: String, isMain: Bool,
 continueTarget: String?) throws {
 emitLine(builder.fmtBr(labelName: defaultLabel))
 emitLine("")
 emitLine(" \(defaultLabel):")
 currentScopeDepth += 1
 scopeStack.append([])
 if let b = block {
 var terminated = false
 for stmt in b.statements {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain, continueTarget: continueTarget)
 if isTerminatingStatement(stmt) { terminated = true; break }
 }
 if !terminated {
 emitLine(builder.fmtBr(labelName: endLabel))
 }
 } else {
 emitLine(builder.fmtBr(labelName: endLabel))
 }
 scopeStack.removeLast()
 currentScopeDepth -= 1
 emitLine("")
 emitLine(" \(endLabel):")
 emitLine(" unreachable")
 }
}
