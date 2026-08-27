import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 模块级发射：全局声明、类型声明（struct/object/enum）、内建 Optional 注册、
/// 函数定义生成、defer 出口发射、字符串常量回填模块头。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 /// LLVM IR 局部标识符：仅含 ASCII 字母/数字/下划线的名字直接使用；否则加引号
 /// （如 `%"路径"`），因 lli/llvm-as 对非 ASCII 标识符要求引号包裹（修复 try.pini 等
 /// 含中文形参名函数的 LLVM 解析失败）。ASCII 名不变 → 既有 golden IR 字节不变。
 func irLocalIdentifier(_ name: String) -> String {
 let asciiOK = name.unicodeScalars.allSatisfy { s in
 guard s.isASCII else { return false }
 let v = s.value
 return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95
 }
 return asciiOK ? name : "\"\(name)\""
 }

 // MARK: - 全局声明

 func emitGlobals() throws {
 ir += "; ============================================================\n"
 ir += "; Pini LLVM IR Module\n"
 ir += "; ============================================================\n\n"

 ir += "; 外部函数声明\n"
 ir += "declare i32 @printf(ptr, ...)\n"
 ir += "declare i64 @strlen(ptr)\n"
 ir += "declare double @llvm.sqrt.f64(double)\n"
 ir += "declare double @llvm.sin.f64(double)\n"
 ir += "declare double @llvm.cos.f64(double)\n"
 ir += "declare ptr @fgets(ptr, i32, ptr)\n"
 ir += "declare ptr @fopen(ptr, ptr)\n"
 ir += "declare i64 @fwrite(ptr, i64, i64, ptr)\n"
 ir += "declare i32 @fclose(ptr)\n"
 ir += " declare i64 @fread(ptr, i64, i64, ptr)\n"
 ir += "declare ptr @strstr(ptr, ptr)\n"
 ir += "declare ptr @strtok(ptr, ptr)\n"
 ir += "declare ptr @strcat(ptr, ptr)\n"
 ir += "declare i32 @toupper(i32)\n"
 ir += "declare i32 @tolower(i32)\n"
 ir += "declare ptr @memcpy(ptr, ptr, i64)\n"
 ir += "declare ptr @malloc(i64)\n"
 ir += "declare i32 @snprintf(ptr, i64, ptr, ...)\n"
 ir += "@__stdinp = external global ptr\n\n"

 ir += "; 格式字符串常量\n"
 ir += "@fmt_int = private constant [3 x i8] c\"%d\\00\"\n"
 ir += "@fmt_double = private constant [4 x i8] c\"%f\\00\\00\"\n"
 ir += "@fmt_double_simple = private constant [4 x i8] c\"%g\\00\\00\"\n"
 ir += "@fmt_bool_true = private constant [6 x i8] c\"true\\00\\00\"\n"
 ir += "@fmt_bool_false = private constant [7 x i8] c\"false\\00\\00\"\n"
 ir += "@fmt_string = private constant [3 x i8] c\"%s\\00\"\n"
 ir += "@.fopen_w = private constant [2 x i8] c\"w\\00\"\n"
 ir += "@.fopen_r = private constant [2 x i8] c\"r\\00\"\n"
 ir += "@.split_lbr = private constant [2 x i8] c\"[\\00\"\n"
 ir += "@.split_rbr = private constant [2 x i8] c\"]\\00\"\n"
 ir += "@.split_sep = private constant [3 x i8] c\", \\00\"\n\n"
 }

 /// emit 所有已收集 struct 类型的 LLVM 命名结构定义：
 /// `%struct.Name = type { fieldType1, fieldType2, ... }`
 func emitStructTypeDecls() throws {
 guard !structTypes.isEmpty else { return }
 ir += "; 复合类型定义\n"
 for (name, sd) in structTypes {
 // R2：泛型 struct 模板（含未替换类型参数 T）不发射类型声明（`{ T }` 非法 IR）；
 // 具体实例由 generateGenericStructConstruct 单态化后在模块末尾补发。
 guard sd.genericParams.isEmpty else { continue }
 let fieldTypes = try sd.fields.map { try typeMapper.map($0.typeAnnotation) }
 let body = fieldTypes.joined(separator: ", ")
 ir += "%struct.\(name) = type { \(body) }\n"
 }
 ir += "\n"
 }

 /// emit 所有已收集 object 类型的 LLVM 命名结构定义（引用类型）：
 /// `%object.Name = type { i32, fieldType1, fieldType2, ... }`
 /// 字段 0 为 `i32` 引用计数头（refcount header），其余为实际字段——
 /// 对齐解释器 `ObjectReference.refCount`（创建时置 1），为未来 ARC/free 预留头字段。
 /// 注：v0.x 无 GC，本阶段仅布局并初始化 refcount=1，不生成 decrement/free。
 func emitObjectTypeDecls() throws {
 guard !objectTypes.isEmpty else { return }
 ir += "; 复合类型定义（object：引用类型，字段 0 为 i32 refcount 头）\n"
 for (name, od) in objectTypes {
 let fieldTypes = try od.fields.map { try typeMapper.map($0.typeAnnotation) }
 let body = (["i32"] + fieldTypes).joined(separator: ", ")
 ir += "%object.\(name) = type { \(body) }\n"
 }
 ir += "\n"
 }

 /// emit 所有已收集 enum 类型的 LLVM 命名结构定义（tagged union）：
 /// - 简单枚举（无关联值）：`%enum.Name = type { i32 }`
 /// - 关联值枚举：`%enum.Name = type { i32, payloadType1, ... }`（payload 字段按最大 case arity 排布）
 func emitEnumTypeDecls() throws {
 guard !enumDecls.isEmpty else { return }
 ir += "; 复合类型定义（enum：tagged union，字段 0 为 i32 tag）\n"
 for (name, ed) in enumDecls {
 // #46-optional：内建 Optional 单一 IR 类型，payload 槽为 ptr（装箱 so 泛型 T 可行）。
 // 若走通用路径会对 generic T 调 typeMapper.map 触发 unsupportedType，故特判。
 if name == "Optional" {
 ir += "%enum.Optional = type { i32, ptr }\n"
 continue
 }
 let maxArity = ed.cases.map { $0.associatedParams.count }.max() ?? 0
 let payloadTypes: [String]
 if maxArity > 0 {
 // 取最大 arity case 的类型映射作为 union 字段
 if let maxCase = ed.cases.first(where: { $0.associatedParams.count == maxArity }) {
 payloadTypes = try maxCase.associatedParams.map { try typeMapper.map($0.type) }
 } else {
 payloadTypes = []
 }
 } else {
 payloadTypes = []
 }
 let body = (["i32"] + payloadTypes).joined(separator: ", ")
 ir += "%enum.\(name) = type { \(body) }\n"
 }
 ir += "\n"
 }

 // MARK: - spec G30 / P2-6：内建 Optional 的 IR 注册

 /// 向 IR 枚举表注册「合成」的 `Optional` 枚举，使其可经既有 enum IR 路径处理
 /// （`nil`/`Optional.none` 构造、enum stringify、`case none:` 匹配）。
 /// - `none`（tag=0，无关联值）：与解释器共用同一语义 `nil` == `Optional.none`，stringify 输出 "none"。
 /// - `some`（tag=1，1 个关联值）：携带泛型 T 元素，IR 层以单一 `ptr` 装箱承载
 /// （见 `generateEnumCaseConstruction` 装箱构造 与 `generateMatchStatement` 装箱解构）。
 /// 元素 concrete 类型 T 在 codegen 期经 `typeInference.infer(scrutinee)` 取得
 /// （Optional 单一无类型 IR、AST 不携带类型，故不能静态映射）。
 func registerBuiltinOptional() throws {
 guard enumDecls["Optional"] == nil else { return }
 let loc = sl()
 let someParam = AssociatedParam(name: "value", type: .generic(name: "T", params: [], location: loc))
 let decl = EnumDecl(
 name: "Optional",
 genericParams: [GenericParam(name: "T")],
 cases: [
 EnumCase(name: "none", associatedParams: [], location: loc),
 EnumCase(name: "some", associatedParams: [someParam], location: loc),
 ],
 methods: [],
 location: loc
 )
 enumDecls["Optional"] = decl
 // P5-5 B4 同款键格式："\(mangle(ed.name)).\(ec.name)"
 enumCaseTags["Optional.none"] = (enumName: "Optional", tag: 0, params: [])
 enumCaseUnqualified["none", default: []].append("Optional.none")
 enumCaseTags["Optional.some"] = (enumName: "Optional", tag: 1, params: [someParam])
 enumCaseUnqualified["some", default: []].append("Optional.some")
 }

 // MARK: - 函数生成

 func registerFuncReturnType(_ fd: FuncDecl) throws {
 let isMain = fd.name == "main"
 let ret: String
 if fd.returnTypes.isEmpty {
 ret = isMain ? "i32" : "void"
 } else if fd.returnTypes.count == 1 {
 ret = try typeMapper.map(fd.returnTypes[0])
 } else {
 let types = try fd.returnTypes.map { try typeMapper.map($0) }
 ret = "{ " + types.joined(separator: ", ") + " }"
 }
 funcReturnIRTypes[mangle(fd.name)] = ret
 }

 func generateFuncDecl(_ fd: FuncDecl, receiverIRType: String? = nil, composedMethodSuffix: String? = nil) throws {
 if !fd.genericParams.isEmpty {
 // P6-4b: 泛型函数存储为模板，特化在 genericConstruct 调用时执行
 genericTemplates[mangle(fd.name)] = fd
 return
 }

 // R1.1：组合类型接收者的方法用「接收者特化名」发射（`@mangle(方法名)_mangle(接收者)`），
 // 使父/子组合类型的同名方法各自按自身字段布局编译，互不撞名。
 let fnIRName = composedMethodSuffix.map { "\(mangle(fd.name))_\($0)" } ?? mangle(fd.name)

 // Pini 方法使用显式 self 参数（如 `add|self()`），self 已在 fd.params 中，
 // 按正常函数生成即可（self 参数自动注册到 symbolTable，self.field 走 member access）。

 let isMain = fd.name == "main"

 let returnIRType: String
 if fd.returnTypes.isEmpty {
 returnIRType = isMain ? "i32" : "void"
 } else if fd.returnTypes.count == 1 {
 returnIRType = try typeMapper.map(fd.returnTypes[0])
 } else {
 let types = try fd.returnTypes.map { try typeMapper.map($0) }
 returnIRType = "{ " + types.joined(separator: ", ") + " }"
 }

 funcReturnIRTypes[fnIRName] = returnIRType

 let paramTypes: [String] = try fd.params.map { p in
 guard let typeAnn = p.typeAnnotation else {
 if isMain { return "i32" }
 // P6-4a: 推断缺失类型注解的参数类型。
 // 策略：若函数有单一返回类型，回退为返回类型（覆盖 `func add(x, y) -> I32` 场景）；
 // 否则回退为 i32（解释器默认数值类型）。
 if fd.returnTypes.count == 1 {
 return try typeMapper.map(fd.returnTypes[0])
 }
 return "i32"
 }
 return try typeMapper.map(typeAnn)
 }
 // #8：登记形参 IR 类型（mangled → [IRType]），供「具名函数作为值」的 env 忽略适配器构造。
 funcParamIRTypes[fnIRName] = paramTypes

 var paramList: [String] = []
 if let rt = receiverIRType {
 paramList.append("\(rt) %self")
 }
 for (i, param) in fd.params.enumerated() {
 let irType = paramTypes[i]
 paramList.append("\(irType) %\(irLocalIdentifier(param.name))")
 }

 if fd.isAsync {
 ir += "; async function (MVP: synchronous)\n"
 }

 ir += "define \(returnIRType) @\(fnIRName)(\(paramList.joined(separator: ", "))) {\n"

 symbolTable = [:]
 builder.reset()
 deferredStatements = []
 scopeStack = [[]]
 currentScopeDepth = 0

 if let rt = receiverIRType {
 emitLine(builder.fmtAlloca(name: "%self_slot", type: rt))
 emitLine(builder.fmtStore(value: "%self", type: rt, ptr: "%self_slot"))
 symbolTable["self"] = ("%self_slot", rt)
 }

 for (i, param) in fd.params.enumerated() {
 let allocaName = "%\(mangle(param.name))_slot"
 let irType = paramTypes[i]
 // 阶段 B：函数类型形参（高阶函数）——记录其返回 IR 类型，供函数体内间接调用确定 ret。
 if case .function(_, let rets, _, _) = param.typeAnnotation {
 funcValueReturnTypes[param.name] = rets.isEmpty ? "void" : ((try? typeMapper.map(rets[0])) ?? "void")
 }
 emitLine(builder.fmtAlloca(name: allocaName, type: irType))
 emitLine(builder.fmtStore(value: "%\(irLocalIdentifier(param.name))", type: irType, ptr: allocaName))
 symbolTable[param.name] = (allocaName, irType)
 registerLocalCollectionVar(param.name, allocaName, irType)
 }

 if let body = fd.body {
 for stmt in body.statements {
 try generateStatement(stmt, functionReturnType: returnIRType, isMain: isMain)
 if isTerminatingStatement(stmt) {
 break
 }
 }
 }

 let needsExitBlock: Bool
 if let body = fd.body {
 needsExitBlock = !body.statements.contains { isTerminatingStatement($0) }
 } else {
 needsExitBlock = true
 }

 if needsExitBlock {
 ir += "\n"
 // Bug A（run-llvm 非法 IR）：当函数体末条语句不是终止语句（如 print/表达式/var）
 // 或控制流（if/while/match）的合并块无后续语句时，当前块缺终止指令，紧跟的
 // `exit_block:` 标签会使 lli 报 "expected instruction opcode"。在此补 `br` 终止当前块。
 ir += builder.fmtBr(labelName: "exit_block") + "\n"
 ir += "exit_block:\n"
 try emitDeferred(functionReturnType: returnIRType, isMain: isMain)
 emitScopeCleanup()
 if isMain {
 ir += " ret i32 0\n"
 } else if returnIRType != "void" {
 ir += " ret \(returnIRType) undef\n"
 } else {
 ir += " ret void\n"
 }
 }

 ir += "}\n\n"
 }

 // MARK: - defer 延迟执行（P6-3a）

 /// 按 LIFO 逆序发射所有 pending 的 defer 语句到 IR（对齐解释器 deferStack 逆序语义）。
 /// 函数出口/return 路径：flush 所有残留 defer（含函数级与尚未刷新的内层；块级 defer 已在
 /// 其块自然落入出口经 `flushDeferredForScope` 提前刷新）。
 func emitDeferred(functionReturnType: String, isMain: Bool) throws {
 guard !deferredStatements.isEmpty else { return }
 let defers = deferredStatements
 deferredStatements = []
 deferDepths = []
 for stmt in defers.reversed() {
 try generateStatement(stmt, functionReturnType: functionReturnType, isMain: isMain)
 }
 }

 func emitPendingStringConstants() {
 defer { pendingStringConstants = [] }
 var decls = pendingStringConstants.map { "\($0)\n" }.joined()
 // 阶段 B：闭包 env 结构类型声明一并插入模块头，确保早于任何引用。
 if !pendingClosureTypeDecls.isEmpty {
 decls += pendingClosureTypeDecls.map { "\($0)\n" }.joined()
 pendingClosureTypeDecls = []
 }
 guard !decls.isEmpty else { return }
 if headerEndOffset > 0, headerEndOffset < ir.count {
 // 运行时新增常量：插入到 header 结束位置（类型定义之后，函数体之前）
 let idx = ir.index(ir.startIndex, offsetBy: headerEndOffset)
 ir.insert(contentsOf: decls, at: idx)
 } else {
 ir += decls
 }
 }
}
