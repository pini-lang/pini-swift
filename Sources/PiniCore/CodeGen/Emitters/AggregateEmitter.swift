import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 聚合体发射：struct/object 构造与字段读写共享解析、enum case 构造与限定名解析。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - struct / object 构造与字段访问（P6-2a / P6-2b）

 /// struct 构造 IR：对齐解释器 `createInstance` 语义——**忽略位置实参**，
 /// 字段取声明处默认值（有 initializer）或零值（无 initializer，对应解释器 null）。
 /// 返回 `%struct.Name*` 指针。
 func generateStructConstruction(structDecl sd: StructDecl) throws -> IRValue {
 let typeName = "%struct.\(mangle(sd.name))"
 let ptr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: ptr, type: typeName))
 for (i, field) in sd.fields.enumerated() {
 let fldPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: typeName, base: ptr, indices: [0, i]))
 let fieldIRType = try typeMapper.map(field.typeAnnotation)
 if let initExpr = field.initializer {
 let val = try generateExpression(initExpr)
 // Phase 0：字段声明宽度对齐（i32 字面量 → 字段宽度，如 I8 字段）。
 let valC = convertNumeric(val, to: fieldIRType)
 emitLine(builder.fmtStore(value: valC.ssaName, type: fieldIRType, ptr: fldPtr))
 } else {
 // R1.1：无初始化器字段补零值——指针类（组合父类型字段）须为 null 而非 0。
 emitLine(builder.fmtStore(value: zeroConst(fieldIRType), type: fieldIRType, ptr: fldPtr))
 }
 }
 return IRValue(llvmType: "\(typeName)*", ssaName: ptr)
 }

 /// object 构造 IR：对齐解释器 `createInstance` 语义（kind=.objectKind）——
 /// **忽略位置实参**，字段取声明处默认值或零值；并在字段 0 写入 refcount 头 = 1，
 /// 对齐解释器 `ObjectReference.refCount` 初始值。返回 `%object.Name*` 指针。
 /// 注：v0.x 无 GC，本阶段仅生成 refcount 初始化，不做 decrement/free（待 ARC IR 阶段）。
 func generateObjectConstruction(objectDecl od: ObjectDecl) throws -> IRValue {
 let typeName = "%object.\(mangle(od.name))"
 let ptr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: ptr, type: typeName))
 // refcount 头（字段 0）= 1
 let rcPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: rcPtr, aggregate: typeName, base: ptr, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "1", type: "i32", ptr: rcPtr))
 for (i, field) in od.fields.enumerated() {
 // 字段偏移 +1：字段 0 为 refcount 头
 let fldPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: typeName, base: ptr, indices: [0, i + 1]))
 let fieldIRType = try typeMapper.map(field.typeAnnotation)
 if let initExpr = field.initializer {
 let val = try generateExpression(initExpr)
 // Phase 0：字段声明宽度对齐（i32 字面量 → 字段宽度，如 I8 字段）。
 let valC = convertNumeric(val, to: fieldIRType)
 emitLine(builder.fmtStore(value: valC.ssaName, type: fieldIRType, ptr: fldPtr))
 } else {
 // R1.1：无初始化器字段补零值——指针类（组合父类型字段）须为 null 而非 0。
 emitLine(builder.fmtStore(value: zeroConst(fieldIRType), type: fieldIRType, ptr: fldPtr))
 }
 }
 return IRValue(llvmType: "\(typeName)*", ssaName: ptr)
 }

 // MARK: - 字段读写共享解析（struct / object）

 /// 解析成员字段的 `getelementptr` 指针：返回字段 IR 类型与指针 SSA 名。
 /// struct 字段从索引 0 起；object 因含 refcount 头，字段偏移 +1。
 func resolveMemberField(base: Expression, memberName: String) throws -> (fieldIRType: String, fldPtr: String) {
 let baseVal = try generateExpression(base)
 guard baseVal.llvmType.hasSuffix("*") else {
 throw IRGenError.unsupportedExpression(kind:
 "member access requires struct/object pointer, got \(baseVal.llvmType)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 let aggName: String
 let fields: [FieldDecl]
 let offset: Int
 if baseVal.llvmType.hasPrefix("%struct.") {
 let name = baseVal.llvmType
 .replacingOccurrences(of: "%struct.", with: "")
 .replacingOccurrences(of: "*", with: "")
 guard let sd = structTypes[name] else {
 throw IRGenError.unsupportedExpression(kind:"unknown struct type \(name)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 aggName = "%struct.\(name)"; fields = sd.fields; offset = 0
 } else if baseVal.llvmType.hasPrefix("%object.") {
 let name = baseVal.llvmType
 .replacingOccurrences(of: "%object.", with: "")
 .replacingOccurrences(of: "*", with: "")
 guard let od = objectTypes[name] else {
 throw IRGenError.unsupportedExpression(kind:"unknown object type \(name)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 aggName = "%object.\(name)"; fields = od.fields; offset = 1
 } else {
 throw IRGenError.unsupportedExpression(kind:
 "member access requires struct/object pointer, got \(baseVal.llvmType)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 guard let idx = fields.firstIndex(where: { $0.name == memberName }) else {
 throw IRGenError.unsupportedExpression(kind:"no field `\(memberName)` on \(aggName)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 let fieldIRType = try typeMapper.map(fields[idx].typeAnnotation)
 let fldPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: aggName, base: baseVal.ssaName, indices: [0, idx + offset]))
 return (fieldIRType, fldPtr)
 }

 /// 字段读取 IR：`getelementptr` + `load`。
 func generateMemberAccess(base: Expression, memberName: String) throws -> IRValue {
 // spec G30 / P2-6：nil 关键字与 `Optional.none` 解析为同一 `.member(Optional, none)` AST。
 // 此处特判，把 `Optional.none` 成员访问降级为构造枚举 none 值（tag=0），复用既有 enum IR 路径，
 // 不新增任何 Expression/Value case。仅 none 走此路；some 的 IR 构造属后续演进（本期未含）。
 if case .identifier(let baseName, _) = base, baseName == "Optional", memberName == "none" {
 return try generateEnumCaseConstruction(enumName: "Optional", tag: 0, params: [], arguments: [])
 }
 // #46-E G40（S3）：LazyRef 的 `.value` —— `bk_lazyref_value(handle)` → 元素 box → `load T`。
 if memberName == "value" {
 let baseVal = try generateExpression(base)
 if baseVal.llvmType == "%bk_lazyref*" {
 let box = try generateLazyRefValue(handle: baseVal)
 guard case .identifier(let baseName, _) = base, let elemIR = lazyRefValueTypeByVar[baseName] else {
 throw IRGenError.unsupportedFeature(feature:
 "LazyRef .value 需经变量访问（LLVM 端元素类型推断暂限标识符 base）", sl())
 }
 let val = builder.freshTemp()
 emitLine(builder.fmtLoad(name: val, type: elemIR, ptr: box.ssaName))
 return IRValue(llvmType: elemIR, ssaName: val)
 }
 }
 // Phase 1（#1）：命名元组 `.名称` 标签访问。元组是匿名 struct `{ ... }`，位置访问 `.0` 走
 // `.tupleIndex`；标签访问经 `tupleTypeByVar` 的 `.tuple(labels:)` 查「标签→下标」后
 // 复用 extractvalue 路径（对齐位置访问）。仅 identifier base 可查标签表；表达式返回的
 // 命名元组无变量名可查，保持既有错误路径（member access requires struct/object pointer）。
 if case .identifier(let baseName, _) = base,
 case .tuple(let labels, _, _)? = tupleTypeByVar[baseName],
 let idx = labels.firstIndex(where: { $0 == memberName }) {
 let baseVal = try generateExpression(base)
 let fieldType = try tupleFieldIRType(baseVal.llvmType, index: idx)
 let tmp = builder.freshTemp()
 emitLine(" \(tmp) = extractvalue \(baseVal.llvmType) \(baseVal.ssaName), \(idx)")
 return IRValue(llvmType: fieldType, ssaName: tmp)
 }
 let (fieldIRType, fldPtr) = try resolveMemberField(base: base, memberName: memberName)
 let val = builder.freshTemp()
 emitLine(builder.fmtLoad(name: val, type: fieldIRType, ptr: fldPtr))
 return IRValue(llvmType: fieldIRType, ssaName: val)
 }

 // MARK: - enum case 构造与 match（P6-2c / P6-3b）

 /// enum case 构造（含关联值）：alloca + store tag + 逐字段 store payload。
 func generateEnumCaseConstruction(enumName: String, tag: Int,
 params: [AssociatedParam],
 arguments: [CallArgument]) throws -> IRValue {
 let typeName = "%enum.\(enumName)"
 let ptr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: ptr, type: typeName))
 // store tag
 let tagPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: tagPtr, aggregate: typeName, base: ptr, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "\(tag)", type: "i32", ptr: tagPtr))

 // #46-optional：内建 Optional 装箱构造。payload 槽为 ptr（泛型 T 消除后单一 IR 类型），
 // 故不能走下方「按值映射」路径（会对 generic T 调 typeMapper.map 失败）。
 if enumName == "Optional" {
 let fldPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: typeName, base: ptr, indices: [0, 1]))
 if tag == 1 {
 // some(x)：分配 box（x 的具体 IR 类型）、存 x、转 ptr 写入 field1。
 // 与解释器 EnumValue(caseName:"some", associatedValues:[x]) 对齐（value 经堆/栈 box 承载）。
 // LLVM 22 全不透明指针：`ptr*` 非法（指针到指针无意义），但 `i32*` 等 typed ptr 仍被容忍；
 // 故元素为不透明指针（String 等，`val.llvmType == "ptr"`）时改用 `{ ptr }` 单字段 struct
 // 包裹（其内存布局与 `ptr` 兼容，解构 `load ptr` 即可取回），其余值类型用 `alloca T` + `bitcast T*→ptr`。
 guard let arg = arguments.first else {
 throw IRGenError.unsupportedFeature(feature:"Optional.some 缺少关联值实参", sl())
 }
 let val = try generateExpression(arg.expression)
 let boxAsPtr = builder.freshTemp()
 if val.llvmType == "ptr" {
 let boxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: boxPtr, type: "{ ptr }"))
 let fld = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fld, aggregate: "{ ptr }", base: boxPtr, indices: [0, 0]))
 emitLine(builder.fmtStore(value: val.ssaName, type: "ptr", ptr: fld))
 emitLine(" \(boxAsPtr) = bitcast { ptr }* \(boxPtr) to ptr")
 } else {
 let boxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: boxPtr, type: val.llvmType))
 emitLine(builder.fmtStore(value: val.ssaName, type: val.llvmType, ptr: boxPtr))
 emitLine(" \(boxAsPtr) = bitcast \(val.llvmType)* \(boxPtr) to ptr")
 }
 emitLine(builder.fmtStore(value: boxAsPtr, type: "ptr", ptr: fldPtr))
 }
 // none（tag==0）不写 field1，与解释器 EnumValue(caseName:"none", []) 一致
 return IRValue(llvmType: "\(typeName)*", ssaName: ptr)
 }

 // 其余枚举：内联按值 store payload（既有路径，逐字节不变）。
 // 显式实参优先；不足部分用关联值默认表达式补位（字面量默认），
 // 与解释器 callFunctionValue 枚举构造分支一致。既无实参也无默认则报错（不应静默留未初始化内存）。
 for i in 0..<params.count {
 let fldPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: typeName, base: ptr, indices: [0, i + 1]))
 if i < arguments.count {
 let val = try generateExpression(arguments[i].expression)
 emitLine(builder.fmtStore(value: val.ssaName, type: val.llvmType, ptr: fldPtr))
 } else if let def = params[i].defaultValue {
 let val = try generateExpression(def)
 emitLine(builder.fmtStore(value: val.ssaName, type: val.llvmType, ptr: fldPtr))
 } else {
 throw IRGenError.unsupportedFeature(feature:
 "枚举用例 \(enumName) 缺少第 \(i + 1) 个关联值实参且无默认值", sl())
 }
 }
 return IRValue(llvmType: "\(typeName)*", ssaName: ptr)
 }

 // MARK: - P5-5 B4：枚举构造限定名解析

 /// 未限定构造 `圆(...)` 的反查：返回唯一所属枚举的「限定键」；多父歧义时抛不支持
 /// （迫使改用 `Parent.圆`）；无登记则返 nil（非枚举构造，回退到函数调用路径）。
 func enumCaseQualifiedKey(forUnqualified caseName: String) throws -> String? {
 let keys = enumCaseUnqualified[caseName] ?? []
 if keys.isEmpty { return nil }
 if keys.count > 1 {
 throw IRGenError.unsupportedFeature(feature:
 "ambiguous unqualified enum construction \(caseName): qualify as Parent.\(caseName)", sl())
 }
 return keys[0]
 }
}
