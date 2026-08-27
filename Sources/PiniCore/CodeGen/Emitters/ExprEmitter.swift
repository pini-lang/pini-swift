import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 表达式发射：字面量/标识符、二元/一元（含复合赋值）、调用分派、下标读、元组/数组字面量。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - 表达式生成

 func generateExpression(_ expr: Expression) throws -> IRValue {
 switch expr {
 case .integerLiteral(let value, _):
 return IRValue(llvmType: "i32", ssaName: String(value))

 case .floatLiteral(let value, _):
 return IRValue(llvmType: "double", ssaName: formatFloat(value))

 case .boolLiteral(let value, _):
 return IRValue(llvmType: "i1", ssaName: value ? "true" : "false")

 case .stringLiteral(let value, _):
 return try generateStringLiteral(value)

 case .tuple(_, let elements, _):
 return try generateTuple(elements)

 case .arrayLiteral(let elements, _):
 return try generateArrayLiteral(elements)

 case .identifier(let name, _):
 if let entry = symbolTable[name] {
 let tempName = builder.freshTemp()
 emitLine(builder.fmtLoad(name: tempName, type: entry.type, ptr: entry.slot))
 return IRValue(llvmType: entry.type, ssaName: tempName)
 }
 // R3：方法内裸字段引用（`return 名字` ≡ `self.名字`）——对齐解释器 bindInstanceFields。
 // 仅当 name 不是局部/参数时回退；首次命中发射 GEP 并缓存进 symbolTable。
 if let field = tryResolveBareSelfField(name) {
 let tempName = builder.freshTemp()
 emitLine(builder.fmtLoad(name: tempName, type: field.type, ptr: field.slot))
 return IRValue(llvmType: field.type, ssaName: tempName)
 }
 // 枚举 case 构造器（无参数）：分配 tagged union 并 store tag
 // （P5-5 B4：经反查表解析未限定名；跨枚举同名且歧义时回退到下方未定义标识符报错）
 if let qKey = try enumCaseQualifiedKey(forUnqualified: name),
 let (enumName, tag, _) = enumCaseTags[qKey] {
 let typeName = "%enum.\(enumName)"
 let ptr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: ptr, type: typeName))
 let tagPtr = builder.freshTemp()
 emitLine(builder.fmtGEP(name: tagPtr, aggregate: typeName, base: ptr, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "\(tag)", type: "i32", ptr: tagPtr))
 return IRValue(llvmType: "\(typeName)*", ssaName: ptr)
 }
 throw IRGenError.unsupportedExpression("undefined identifier \(name)",
 SourceLocation(line: 0, column: 0, fileName: ""))

 case .binary(let left, let op, let right, _):
 return try generateBinary(left: left, op: op, right: right)

 case .unary(let op, let operand, _):
 return try generateUnary(op: op, operand: operand)

 case .call(let callee, let arguments, _):
 return try generateCall(callee: callee, arguments: arguments)

 case .join(let inner, _):
 return try generateExpression(inner)

 case .resultUnwrap:
 // 草稿 A2（批次 1.4，D2）：`^` 解包涉及 err 控制返回（注入返回元组末槽），
 // LLVM 后端暂不支持（明确报错，不静默；解释器路径已支持）。
 throw IRGenError.unsupportedFeature("LLVM 后端暂不支持 `^` 右值糖解包；请改用解释器 `pini run`", sl())

 case .member(let obj, let name, _):
 return try generateMemberAccess(base: obj, memberName: name)

 case .tupleIndex(let object, let index, _):
 // 草稿 A2（批次 1）：元组是 LLVM struct（generateTuple 用 insertvalue 组装），
 // 位置访问 `.0` 用 extractvalue 提取字段；返回类型 = 第 index 个字段的 IR 类型。
 let baseVal = try generateExpression(object)
 let fieldType = try tupleFieldIRType(baseVal.llvmType, index: index)
 let tmp = builder.freshTemp()
 emitLine(" \(tmp) = extractvalue \(baseVal.llvmType) \(baseVal.ssaName), \(index)")
 return IRValue(llvmType: fieldType, ssaName: tmp)

 case .selfKeyword(_), .selfTypeKeyword(_):
 if let entry = symbolTable["self"] {
 let tempName = builder.freshTemp()
 emitLine(builder.fmtLoad(name: tempName, type: entry.type, ptr: entry.slot))
 return IRValue(llvmType: entry.type, ssaName: tempName)
 }
 throw IRGenError.unsupportedExpression("self keyword without self parameter", sl())

 case .genericConstruct(let typeName, let typeArgs, let callArgs, _):
 return try generateGenericCall(typeName: typeName, typeArgs: typeArgs, arguments: callArgs)

 case .stringInterpolation(let segments, _):
 // 仅支持「纯字面量插值」（含空串 ""）：拼接后按字面量生成。
 // 含表达式的插值（如 "x=\(y)"）在一般表达式位置暂不支持；print 走专用插值路径。
 var literalText = ""
 for seg in segments {
 guard case .literal(let text) = seg else {
 throw IRGenError.unsupportedFeature(
 "LLVM 后端暂不支持在表达式位置使用含表达式的字符串插值；请改用 print 的插值，或改用解释器 `pini run`",
 sl())
 }
 literalText += text
 }
 return try generateStringLiteral(literalText)

 case .funcLiteral(let decl, let loc):
 return try generateFuncLiteral(decl: decl, location: loc)

 case .dictionaryLiteral(let entries, _):
 return try generateDictionaryLiteral(entries)
 case .setLiteral(let elements, _):
 return try generateSetLiteral(elements)
 case .subscript:
 return try generateSubscriptRead(expr)
 case .unsafe, .addressOf:
 // Phase 2a（ADR-015 FFI）：LLVM 端 FFI/unsafe 显式 unsupported（用户决策 D1，解释器优先）。
 throw IRGenError.unsupportedFeature(
 "LLVM 后端暂不支持 FFI/unsafe 子系统（`unsafe`/`&`）；请改用解释器 `pini run`",
 sl())
 }
 }

 /// LLVM 端下标读分派骨架（架构演进 #45）。
 ///
 /// 下标容器是任意表达式（**非 identifier-only**）：先生成容器 IR 值再分派，
 /// 从根消除回滚前 `guard case .identifier` 式复发。
 ///
 /// 当前所有容器类型在 LLVM 均抛 unsupported（集合后端已回滚），但类型化分派结构已就绪：
 /// 未来 LLVM 集合/字典复做时，按容器 IR 类型在此注册 codegen 策略即可，调用点零改动。
 func generateSubscriptRead(_ expr: Expression) throws -> IRValue {
 guard case .subscript(let container, let index, let loc) = expr else {
 throw IRGenError.unsupportedExpression(String(describing: expr), sl())
 }
 let containerVal = try generateExpression(container) // 任意表达式容器，非 identifier-only
 let indexVal = try generateExpression(index) // 产生 index IR（下标分派需消费）

 // ADR-008 / #46-D：数组经 opaque handle（%bk_array*）承载，下标读走运行时 shim。
 if containerVal.llvmType == "%bk_array*" {
 guard indexVal.llvmType == "i32" else {
 throw IRGenError.unsupportedFeature("LLVM 后端数组下标需 I32 索引（收到 \(indexVal.llvmType)）", loc)
 }
 usesCollections = true
 // D1：解析元素 Pini 类型 → LLVM 类型（嵌套数组 → 内层 handle `%bk_array*`）。
 let elemTA = try resolveArrayElementType(container)
 let elemLLVM: String
 switch elemTA {
 case .generic("Array", _, _): elemLLVM = "%bk_array*" // 嵌套数组：box 内存的是内层 handle
 default: elemLLVM = try typeMapper.map(elemTA)
 }
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_array* \(containerVal.ssaName) to ptr")
 let boxPtr = builder.freshTemp()
 emitLine(" \(boxPtr) = call ptr @bk_array_get(ptr \(raw), i32 \(indexVal.ssaName))")
 let v = builder.freshTemp()
 emitLine(builder.fmtLoad(name: v, type: elemLLVM, ptr: boxPtr))
 return IRValue(llvmType: elemLLVM, ssaName: v)
 }

 // #46-D D2：字典经 opaque handle（%bk_dict*）承载，键读走运行时 shim @bk_dict_get。
 // 键按自身 IR 类型装箱（字符串键 → ptr box，运行时按 tag 做字节内容比较，与指针身份解耦）。
 // 命中返回稳定值 box ptr；缺失返回 NULL → 据值类型补零值（解释器缺失返回 .null，既有键读取场景一致）。
 if containerVal.llvmType == "%bk_dict*" {
 usesCollections = true
 let (keyBoxPtr, keyWidth, keyTag) = try boxDictKey(indexVal)

 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_dict* \(containerVal.ssaName) to ptr")
 let boxPtr = builder.freshTemp()
 emitLine(" \(boxPtr) = call ptr @bk_dict_get(ptr \(raw), ptr \(keyBoxPtr), i32 \(keyWidth), i32 \(keyTag))")

 let valTA = try resolveDictValueType(container)
 let valLLVM = try collectionAwareLLVMType(valTA)
 let isNull = builder.freshTemp()
 emitLine(" \(isNull) = icmp eq ptr \(boxPtr), null")
 let loadB = "dict_load_\(nextLabel())"
 let nullB = "dict_null_\(nextLabel())"
 let mergeB = "dict_merge_\(nextLabel())"
 emitLine(builder.fmtCondBr(cond: isNull, thenLabelName: nullB, elseLabelName: loadB))
 emitLine("\(loadB):")
 let loaded = builder.freshTemp()
 emitLine(builder.fmtLoad(name: loaded, type: valLLVM, ptr: boxPtr))
 emitLine(builder.fmtBr(labelName: mergeB))
 emitLine("\(nullB):")
 let zeroPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: zeroPtr, type: valLLVM))
 emitLine(builder.fmtStore(value: zeroConst(valLLVM), type: valLLVM, ptr: zeroPtr))
 let zeroLoaded = builder.freshTemp()
 emitLine(builder.fmtLoad(name: zeroLoaded, type: valLLVM, ptr: zeroPtr))
 emitLine(builder.fmtBr(labelName: mergeB))
 emitLine("\(mergeB):")
 let result = builder.freshTemp()
 emitLine(" \(result) = phi \(valLLVM) [ \(loaded), %\(loadB) ], [ \(zeroLoaded), %\(nullB) ]")
 return IRValue(llvmType: valLLVM, ssaName: result)
 }

 if containerVal.llvmType.hasPrefix("[") {
 throw IRGenError.unsupportedFeature("LLVM 后端尚未实现定长数组下标访问（集合后端重做时接入）", loc)
 }
 throw IRGenError.unsupportedFeature("LLVM 后端尚未实现该类型的下标访问: \(containerVal.llvmType)", loc)
 }

 /// LLVM 端数组下标写（#46-D D1.5）：`a[i] = v` 经运行时 shim `@bk_array_set`。
 ///
 /// 与 `generateSubscriptRead` 对称：先生成容器 IR（须为 `%bk_array*` 不透明句柄，
 /// 任意表达式容器非 identifier-only），解析元素 Pini 类型 → LLVM 类型（嵌套数组 → `%bk_array*`），
 /// 装箱（alloca T + store）+ `call void @bk_array_set(ptr handle, i32 idx, ptr boxPtr, i32 width)`，
 /// 与 `generateArrayLiteral` 构造侧完全同构，保证读写一致。
 ///
 /// 复合赋值 `a[i] += 1` 在 `generateAssignOp` 经「读当前 → 运算 → 写回」复用本函数。
 func generateSubscriptWrite(container: Expression, index: Expression, value: IRValue) throws {
 // 容器求值：嵌套路径（`m[0][1] = v` / `d["a"][0] = v`）须先自顶向下完成 COW 分裂链，
 // 否则写入落在共享的内层 box 上、污染别名（#46-D D4.2.2）。
 // 非嵌套 `a[i] = v` 保持原路径：`@bk_*_set` 自身的 ensure_unique + emitHandleWriteBack 已足够
 // （避免为最常见形态多发 IR，也保证既有 golden IR 字节不变）。
 let containerVal: IRValue
 if case .subscript = container {
 containerVal = try emitUniqueContainerHandle(container)
 } else {
 containerVal = try generateExpression(container) // 任意表达式容器（非 identifier-only）
 }
 usesCollections = true
 if containerVal.llvmType == "%bk_array*" {
 let indexVal = try generateExpression(index)
 guard indexVal.llvmType == "i32" else {
 throw IRGenError.unsupportedFeature("LLVM 后端数组下标写需 I32 索引（收到 \(indexVal.llvmType)）", sl())
 }
 // 解析元素 Pini 类型 → LLVM 类型（嵌套数组 → 内层 handle `%bk_array*`）。
 let elemTA = try resolveArrayElementType(container)
 let elemLLVM: String
 switch elemTA {
 case .generic("Array", _, _): elemLLVM = "%bk_array*" // 嵌套数组：box 内存的是内层 handle
 default: elemLLVM = try typeMapper.map(elemTA)
 }
 let (boxedLLVM, width) = try arrayElementIRType(elemLLVM)
 // Phase 0：装箱前把 value 对齐到元素宽度（i32 字面量 → 元素声明宽度）。
 let vC = convertNumeric(value, to: boxedLLVM)
 // 装箱 value（与 generateArrayLiteral 同构）：alloca T + store + 取 boxPtr。
 let boxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: boxPtr, type: boxedLLVM))
 emitLine(builder.fmtStore(value: vC.ssaName, type: boxedLLVM, ptr: boxPtr))
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_array* \(containerVal.ssaName) to ptr")
 let elemTag = bkTagForLLVMType(elemLLVM)
 let newRaw = builder.freshTemp()
 emitLine(" \(newRaw) = call ptr @bk_array_set(ptr \(raw), i32 \(indexVal.ssaName), ptr \(boxPtr), i32 \(width), i32 \(elemTag))")
 // D4.2.1b（COW）：共享句柄被运行时分裂时返回副本，须写回变量槽（详见 emitHandleWriteBack）。
 emitHandleWriteBack(newRaw: newRaw, handleType: "%bk_array*", container: container)
 } else if containerVal.llvmType == "%bk_dict*" {
 // #46-D D2：字典下标写 `d[k] = v` 经运行时 shim `@bk_dict_set`。
 // 键与值各按自身 IR 类型装箱（含 tag），运行时据 tag + 字节内容定位/比较键（与指针身份解耦）。
 let indexVal = try generateExpression(index)
 let (keyBoxLLVM, keyWidth) = try arrayElementIRType(indexVal.llvmType)
 let keyBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: keyBoxPtr, type: keyBoxLLVM))
 emitLine(builder.fmtStore(value: indexVal.ssaName, type: keyBoxLLVM, ptr: keyBoxPtr))
 let keyTag = bkTagForLLVMType(indexVal.llvmType)
 // 值按 value 的 IR 类型装箱（与构造侧同构）。
 let (valBoxLLVM, valWidth) = try arrayElementIRType(value.llvmType)
 // Phase 0：装箱前把 value 对齐到值宽度。
 let vC = convertNumeric(value, to: valBoxLLVM)
 let valBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: valBoxPtr, type: valBoxLLVM))
 emitLine(builder.fmtStore(value: vC.ssaName, type: valBoxLLVM, ptr: valBoxPtr))
 let valTag = bkTagForLLVMType(value.llvmType)
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast %bk_dict* \(containerVal.ssaName) to ptr")
 let newRaw = builder.freshTemp()
 emitLine(" \(newRaw) = call ptr @bk_dict_set(ptr \(raw), ptr \(keyBoxPtr), i32 \(keyWidth), i32 \(keyTag), ptr \(valBoxPtr), i32 \(valWidth), i32 \(valTag))")
 // D4.2.1b（COW）：同数组分支——分裂后的副本句柄须写回变量槽。
 emitHandleWriteBack(newRaw: newRaw, handleType: "%bk_dict*", container: container)
 } else {
 throw IRGenError.unsupportedFeature("LLVM 后端仅支持数组/字典下标写（收到 \(containerVal.llvmType)）", sl())
 }
 }

 func generateBinary(left: Expression, op: BinaryOperator, right: Expression) throws -> IRValue {
 if isAssignOp(op) {
 return try generateAssignOp(left: left, op: op, right: right)
 }

 let lhs = try generateExpression(left)
 let rhs = try generateExpression(right)
 // Phase 1（#8）：字符串 `+` 拼接（String + String）——LLVM 端用缓冲 + strcat 拼接，
 // 替代 `binaryInstr` 的 `add ptr`（非法 IR，导致 lli 崩溃；如 defer.pini 的 result + "..."）。
 if op == .plus, lhs.llvmType == "ptr", rhs.llvmType == "ptr" {
 return try generateStringConcat(lhs, rhs)
 }
 // Phase 0：右操作数隐式对齐到左操作数宽度（字面量恒 i32 → 目标宽度），避免 i8 变量 + i32 字面量等错宽。
 let rhsAdj = convertNumeric(rhs, to: lhs.llvmType)
 let temp = "%t\(nextTemp())"
 let (instr, resultType) = binaryInstr(op: op, operandType: lhs.llvmType)
 emitLine(" \(temp) = \(instr) \(lhs.llvmType) \(lhs.ssaName), \(rhsAdj.ssaName)")
 return IRValue(llvmType: resultType, ssaName: temp)
 }

 /// 字符串 `+` 拼接：分配固定缓冲，`strcat` 依次拼接左右操作数，返回拼接结果指针。
 /// （栈帧生命周期内有效；跨函数返回拼接字符串仍受既有「栈缓冲不逃逸」限制约束。）
 func generateStringConcat(_ lhs: IRValue, _ rhs: IRValue) throws -> IRValue {
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[4096 x i8]"))
 let result = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: result, aggregate: "[4096 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: result))
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(lhs.ssaName))")
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(result), ptr \(rhs.ssaName))")
 return IRValue(llvmType: "ptr", ssaName: result)
 }

 func isAssignOp(_ op: BinaryOperator) -> Bool {
 switch op {
 case .assign, .plusAssign, .minusAssign, .multiplyAssign, .divideAssign, .moduloAssign,
 .andAssign, .orAssign, .xorAssign, .leftShiftAssign, .rightShiftAssign:
 return true
 default:
 return false
 }
 }

 func assignBaseOp(_ op: BinaryOperator) -> BinaryOperator {
 switch op {
 case .plusAssign: return .plus
 case .minusAssign: return .minus
 case .multiplyAssign: return .multiply
 case .divideAssign: return .divide
 case .moduloAssign: return .modulo
 case .andAssign: return .bitwiseAnd
 case .orAssign: return .bitwiseOr
 case .xorAssign: return .bitwiseXor
 case .leftShiftAssign: return .leftShift
 case .rightShiftAssign: return .rightShift
 default: return .assign
 }
 }

 func generateAssignOp(left: Expression, op: BinaryOperator, right: Expression) throws -> IRValue {
 // 成员字段赋值（含复合：c.x = v / c.x += 1）
 if case .member(let obj, let name, _) = left {
 let (fieldIRType, fldPtr) = try resolveMemberField(base: obj, memberName: name)
 let rhs = try generateExpression(right)
 // Phase 0：字段写入宽度对齐（i32 字面量 → 字段声明宽度）。
 let rhsC = convertNumeric(rhs, to: fieldIRType)
 if op == .assign {
 emitLine(builder.fmtStore(value: rhsC.ssaName, type: fieldIRType, ptr: fldPtr))
 return rhsC
 }
 let baseOp = assignBaseOp(op)
 let loadTemp = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loadTemp, type: fieldIRType, ptr: fldPtr))
 let resultTemp = "%t\(nextTemp())"
 let (instr, _) = binaryInstr(op: baseOp, operandType: fieldIRType)
 emitLine(" \(resultTemp) = \(instr) \(fieldIRType) \(loadTemp), \(rhsC.ssaName)")
 emitLine(builder.fmtStore(value: resultTemp, type: fieldIRType, ptr: fldPtr))
 return IRValue(llvmType: fieldIRType, ssaName: resultTemp)
 }
 // 下标写：a[i] = v / a[i] += 1（#46-D D1.5）。容器须为不透明句柄 %bk_array*。
 if case .subscript(let container, let index, _) = left {
 let rhs = try generateExpression(right)
 if op == .assign {
 // D4.2.1b：`a[i] = inner`（把仍被持有的容器变量放进容器）须补一份 share（所有权契约 ③）。
 emitContainerAliasRetain(right, rhs)
 try generateSubscriptWrite(container: container, index: index, value: rhs)
 return rhs
 }
 // 复合赋值：读当前值 → 运算 → 写回（与 .member / .identifier 复合路径对称）。
 let cur = try generateSubscriptRead(left)
 let baseOp = assignBaseOp(op)
 let resultTemp = "%t\(nextTemp())"
 let (instr, _) = binaryInstr(op: baseOp, operandType: cur.llvmType)
 emitLine(" \(resultTemp) = \(instr) \(cur.llvmType) \(cur.ssaName), \(rhs.ssaName)")
 let combined = IRValue(llvmType: cur.llvmType, ssaName: resultTemp)
 try generateSubscriptWrite(container: container, index: index, value: combined)
 return combined
 }

 guard case .identifier(let name, _) = left else {
 throw IRGenError.unsupportedExpression("assign to non-identifier",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 guard let entry = symbolTable[name] else {
 throw IRGenError.unsupportedExpression("assign to undefined variable \(name)",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }

 let rhs = try generateExpression(right)
 // Phase 0：赋值目标宽度对齐（i32 字面量 → 变量声明宽度，如 I8 字段）。
 let rhsC = convertNumeric(rhs, to: entry.type)

 if op == .assign {
 // D4.2.1b：`b = a`（表达式级别名重绑）须补一份 share（所有权契约 ③）。
 // 注：旧句柄的一份 share 在此丢失（泄漏到 `bk_runtime_cleanup` 兜底），精确释放属 D4.2.3。
 emitContainerAliasRetain(right, rhs)
 emitLine(builder.fmtStore(value: rhsC.ssaName, type: entry.type, ptr: entry.slot))
 return rhsC
 }

 let baseOp = assignBaseOp(op)
 let loadTemp = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loadTemp, type: entry.type, ptr: entry.slot))
 let resultTemp = "%t\(nextTemp())"
 let (instr, _) = binaryInstr(op: baseOp, operandType: entry.type)
 emitLine(" \(resultTemp) = \(instr) \(entry.type) \(loadTemp), \(rhsC.ssaName)")
 emitLine(builder.fmtStore(value: resultTemp, type: entry.type, ptr: entry.slot))
 return IRValue(llvmType: entry.type, ssaName: resultTemp)
 }

 func binaryInstr(op: BinaryOperator, operandType: String) -> (String, String) {
 let isFloat = operandType == "double"
 switch op {
 case .plus: return (isFloat ? "fadd" : "add", operandType)
 case .minus: return (isFloat ? "fsub" : "sub", operandType)
 case .multiply: return (isFloat ? "fmul" : "mul", operandType)
 case .divide: return (isFloat ? "fdiv" : "sdiv", operandType)
 case .modulo: return (isFloat ? "frem" : "srem", operandType)
 case .equal: return (isFloat ? "fcmp oeq" : "icmp eq", "i1")
 case .notEqual: return (isFloat ? "fcmp one" : "icmp ne", "i1")
 case .lessThan: return (isFloat ? "fcmp olt" : "icmp slt", "i1")
 case .greaterThan: return (isFloat ? "fcmp ogt" : "icmp sgt", "i1")
 case .lessThanOrEqual: return (isFloat ? "fcmp ole" : "icmp sle", "i1")
 case .greaterThanOrEqual: return (isFloat ? "fcmp oge" : "icmp sge", "i1")
 case .logicalAnd: return ("and", operandType)
 case .logicalOr: return ("or", operandType)
 case .bitwiseAnd: return ("and", operandType)
 case .bitwiseOr: return ("or", operandType)
 case .bitwiseXor: return ("xor", operandType)
 case .leftShift: return ("shl", operandType)
 case .rightShift: return ("ashr", operandType)
 case .power: return ("mul", operandType)
 case .and: return ("and", operandType)
 case .or: return ("or", operandType)
 case .assign, .plusAssign, .minusAssign, .multiplyAssign, .divideAssign, .moduloAssign,
 .andAssign, .orAssign, .xorAssign, .leftShiftAssign, .rightShiftAssign:
 return ("add", operandType)
 }
 }

 // MARK: - 隐式数值宽度对齐（Phase 0：I8/I16/I64/U* 整型与 float 支持）

 private func isIntegerIRType(_ t: String) -> Bool {
 switch t { case "i1", "i8", "i16", "i32", "i64": return true; default: return false }
 }

 private func intIRWidth(_ t: String) -> Int {
 switch t { case "i1": return 1; case "i8": return 8; case "i16": return 16;
 case "i32": return 32; case "i64": return 64; default: return 0 }
 }

 /// 把 src 隐式转换为目标 IR 类型（仅数值类型；同类型或无法识别的组合原样返回，no-op）。
 /// 插入的 IR 仅为宽度/种类不同时的 `sext`/`trunc`/`sitofp`/`fptosi`/`fptrunc`/`fpext`。
 /// 既有 i32/double/i1 路径因同类型而零插入，保证 golden IR 字节不变。
 func convertNumeric(_ src: IRValue, to destType: String) -> IRValue {
 guard src.llvmType != destType else { return src }
 // 整型 → 整型（窄→宽 sext；宽→窄 trunc）
 if isIntegerIRType(src.llvmType) && isIntegerIRType(destType) {
 let sw = intIRWidth(src.llvmType), dw = intIRWidth(destType)
 if sw < dw {
 let t = "%t\(nextTemp())"
 emitLine(" \(t) = sext \(src.llvmType) \(src.ssaName) to \(destType)")
 return IRValue(llvmType: destType, ssaName: t)
 } else if sw > dw {
 let t = "%t\(nextTemp())"
 emitLine(" \(t) = trunc \(src.llvmType) \(src.ssaName) to \(destType)")
 return IRValue(llvmType: destType, ssaName: t)
 }
 return src
 }
 // 整型 → 浮点（有符号）
 if isIntegerIRType(src.llvmType) && (destType == "double" || destType == "float") {
 let dst = destType == "double" ? "double" : "float"
 let t = "%t\(nextTemp())"
 emitLine(" \(t) = sitofp \(src.llvmType) \(src.ssaName) to \(dst)")
 return IRValue(llvmType: dst, ssaName: t)
 }
 // 浮点 → 整型
 if (src.llvmType == "double" || src.llvmType == "float") && isIntegerIRType(destType) {
 let t = "%t\(nextTemp())"
 emitLine(" \(t) = fptosi \(src.llvmType) \(src.ssaName) to \(destType)")
 return IRValue(llvmType: destType, ssaName: t)
 }
 // 浮点 → 浮点
 if (src.llvmType == "double" && destType == "float") || (src.llvmType == "float" && destType == "double") {
 let t = "%t\(nextTemp())"
 let instr = src.llvmType == "double" ? "fptrunc" : "fpext"
 emitLine(" \(t) = \(instr) \(src.llvmType) \(src.ssaName) to \(destType)")
 return IRValue(llvmType: destType, ssaName: t)
 }
 return src
 }

 /// 从 `%struct.X*` 提取接收者 struct 的 mangled 名（X）；非 struct 类型返回 nil。
 /// 供 R1.1 组合类型接收者方法分派（接收者特化名查找）。
 func structReceiverMangledName(from llvmType: String) -> String? {
 guard llvmType.hasPrefix("%struct."), llvmType.hasSuffix("*") else { return nil }
 return String(llvmType.dropFirst("%struct.".count).dropLast())
 }

 /// R3：方法内裸字段引用解析——`self` 的接收者类型（`%struct.X*`/`%object.X*`）中名为 `name`
 /// 的字段视为 `self.name`（对齐解释器 `bindInstanceFields`：方法 env 直接绑定实例字段）。
 /// 首次命中发射 GEP（指向 self 内的字段存储）并缓存进 symbolTable；仅读路径，写仍须 `self.字段`。
 func tryResolveBareSelfField(_ name: String) -> (slot: String, type: String)? {
 guard let selfEntry = symbolTable["self"] else { return nil }
 let rt = selfEntry.type
 let fields: [FieldDecl]
 let aggName: String
 let offsetBase: Int
 if rt.hasPrefix("%struct.") {
 let sname = String(rt.dropFirst("%struct.".count).dropLast())
 guard let sd = structTypes[sname], sd.genericParams.isEmpty else { return nil }
 fields = sd.fields; aggName = "%struct.\(sname)"; offsetBase = 0
 } else if rt.hasPrefix("%object.") {
 let sname = String(rt.dropFirst("%object.".count).dropLast())
 guard let od = objectTypes[sname] else { return nil }
 fields = od.fields; aggName = "%object.\(sname)"; offsetBase = 1
 } else {
 return nil
 }
 guard let idx = fields.firstIndex(where: { $0.name == name }),
 let fldType = try? typeMapper.map(fields[idx].typeAnnotation) else { return nil }
 let selfPtr = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: selfPtr, type: rt, ptr: selfEntry.slot))
 let fldPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: aggName, base: selfPtr, indices: [0, idx + offsetBase]))
 symbolTable[name] = (fldPtr, fldType)
 return (fldPtr, fldType)
 }

 func generateUnary(op: UnaryOperator, operand: Expression) throws -> IRValue {
 let operandVal = try generateExpression(operand)
 let temp = "%t\(nextTemp())"
 switch op {
 case .minus:
 emitLine(" \(temp) = sub \(operandVal.llvmType) 0, \(operandVal.ssaName)")
 return IRValue(llvmType: operandVal.llvmType, ssaName: temp)
 case .plus:
 return operandVal
 case .logicalNot, .not:
 emitLine(" \(temp) = xor i1 \(operandVal.ssaName), true")
 return IRValue(llvmType: "i1", ssaName: temp)
 case .bitwiseNot:
 emitLine(" \(temp) = xor \(operandVal.llvmType) \(operandVal.ssaName), -1")
 return IRValue(llvmType: operandVal.llvmType, ssaName: temp)
 case .increment:
 emitLine(" \(temp) = add \(operandVal.llvmType) \(operandVal.ssaName), 1")
 return IRValue(llvmType: operandVal.llvmType, ssaName: temp)
 case .decrement:
 emitLine(" \(temp) = sub \(operandVal.llvmType) \(operandVal.ssaName), 1")
 return IRValue(llvmType: operandVal.llvmType, ssaName: temp)
 }
 }

 func generateCall(callee: Expression, arguments: [CallArgument]) throws -> IRValue {
 // 阶段 B：直接调用匿名函数字面量（立即调用闭包）。
 if case .funcLiteral(let decl, let loc) = callee {
 let cv = try generateFuncLiteral(decl: decl, location: loc)
 let retType = decl.returnTypes.isEmpty ? "void" : (try typeMapper.map(decl.returnTypes[0]))
 return try generateIndirectCall(closure: cv, retType: retType, arguments: arguments)
 }

 // P5-5 B4：限定枚举构造 `Parent.Case(...)` —— base 是枚举类型名（非值），
 // 直接按「限定键」构造，无需生成 base 表达式（生成类型名会误报未定义标识符）。
 if case .member(let base, let caseName, _) = callee,
 case .identifier(let typeName, _) = base,
 let info = enumCaseTags["\(mangle(typeName)).\(caseName)"] {
 return try generateEnumCaseConstruction(enumName: info.enumName, tag: info.tag,
 params: info.params, arguments: arguments)
 }

 // 方法调用：callee 为 .member(base, name)，self 作为第一个实参传递
 if case .member(let base, let methodName, _) = callee {
 let baseVal = try generateExpression(base)
 // 内置字符串方法
 if baseVal.llvmType == "ptr" {
 if methodName == "contains" { return try generateStringContains(baseVal.ssaName, arguments) }
 if methodName == "upper" { return try generateStringCase(isUpper: true, str: baseVal.ssaName) }
 if methodName == "lower" { return try generateStringCase(isUpper: false, str: baseVal.ssaName) }
 if methodName == "substring" { return try generateStringSubstring(baseVal.ssaName, arguments) }
 if methodName == "split" { return try generateStringSplit(baseVal.ssaName, arguments) }
 throw IRGenError.unsupportedExpression("string method \(methodName) not yet supported in IR", sl())
 }
 // 内置数组方法
 if (baseVal.llvmType.hasPrefix("[") && baseVal.llvmType.hasSuffix("x ptr]"))
 || baseVal.llvmType == "%bk_array*" {
 if methodName == "join" { return try generateArrayJoin(baseVal, arguments) }
 throw IRGenError.unsupportedExpression("array method \(methodName) not yet supported in IR", sl())
 }
 // struct/object/enum 方法分派
 let funcName = methodName
 var allArgs: [String] = ["\(baseVal.llvmType) \(baseVal.ssaName)"]
 for arg in arguments {
 let val = try generateExpression(arg.expression)
 allArgs.append("\(val.llvmType) \(val.ssaName)")
 }
 // R1.1：组合类型接收者 → 优先「接收者特化方法」（`mangle(名)_mangle(接收者)`，见
 // generateFuncDecl 的 composedMethodSuffix）；存在则用之，否则回退 name-only。
 let methodIRName: String
 // 优先查类型自身方法，未命中则回退 trait 默认实现
 let retType: String
 if let baseStruct = structReceiverMangledName(from: baseVal.llvmType),
 let rt = funcReturnIRTypes["\(mangle(funcName))_\(baseStruct)"] {
 methodIRName = "\(mangle(funcName))_\(baseStruct)"
 retType = rt
 } else if let rt = funcReturnIRTypes[mangle(funcName)] {
 methodIRName = mangle(funcName)
 retType = rt
 } else if let traitRT = try tryTraitMethodDispatch(
 typeName: extractTypeName(from: baseVal.llvmType),
 methodName: funcName, baseVal: baseVal) {
 methodIRName = mangle(funcName)
 retType = traitRT
 } else {
 throw IRGenError.unsupportedExpression("undefined method \(funcName)", sl())
 }
 if retType == "void" {
 emitLine(" call void @\(methodIRName)(\(allArgs.joined(separator: ", ")))")
 return IRValue(llvmType: "void", ssaName: "")
 }
 let retTemp = "%t\(nextTemp())"
 emitLine(" \(retTemp) = call \(retType) @\(methodIRName)(\(allArgs.joined(separator: ", ")))")
 return IRValue(llvmType: retType, ssaName: retTemp)
 }

 guard case .identifier(let funcName, _) = callee else {
 throw IRGenError.unsupportedExpression("non-identifier callee",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }

 // 阶段 B：函数类型变量（闭包 / 高阶函数参数 / 具名函数作为值）的间接调用。
 // 判定：标识符在局部符号表且类型为闭包 fat pointer，并有登记返回类型 → 走间接调用。
 if let entry = symbolTable[funcName], entry.type == "{ ptr, ptr }", let retType = funcValueReturnTypes[funcName] {
 let cv = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: cv, type: "{ ptr, ptr }", ptr: entry.slot))
 return try generateIndirectCall(closure: IRValue(llvmType: "{ ptr, ptr }", ssaName: cv),
 retType: retType, arguments: arguments)
 }

 if funcName == "print" {
 return try generatePrintCall(arguments: arguments)
 }

 if funcName == "writeFile" {
 return try generateBuiltinWriteFile(arguments)
 }
 if funcName == "readFile" {
 return try generateBuiltinReadFile(arguments)
 }
 if funcName == "readLine" {
 return try generateBuiltinReadLine()
 }
 if funcName == "assert" {
 return try generateBuiltinAssert(arguments)
 }

 if funcName == "len" {
 return try generateLenCall(arguments: arguments)
 }

 if funcName == "abs" { return try generateBuiltinAbs(arguments) }
 if funcName == "min" { return try generateBuiltinMinMax(isMin: true, arguments) }
 if funcName == "max" { return try generateBuiltinMinMax(isMin: false, arguments) }
 if funcName == "sqrt" { return try generateMathIntrinsic("sqrt", arguments) }
 if funcName == "sin" { return try generateMathIntrinsic("sin", arguments) }
 if funcName == "cos" { return try generateMathIntrinsic("cos", arguments) }
 if funcName == "tan" { return try generateBuiltinTan(arguments) }

 if let sd = structTypes[mangle(funcName)] {
 return try generateStructConstruction(structDecl: sd)
 }

 if let od = objectTypes[mangle(funcName)] {
 return try generateObjectConstruction(objectDecl: od)
 }

 // 枚举 case 构造（含关联值）；按「限定键」解析未限定名（P5-5 B4）
 if let qKey = try enumCaseQualifiedKey(forUnqualified: funcName),
 let (enumName, tag, params) = enumCaseTags[qKey], !params.isEmpty {
 return try generateEnumCaseConstruction(enumName: enumName, tag: tag, params: params, arguments: arguments)
 }

 var callArgs: [String] = []
 for arg in arguments {
 // 阶段 B：实参可能是具名函数（作为值）/匿名函数字面量——生成函数指针或闭包 fat pointer。
 let val = try generateCallArgumentValue(arg.expression)
 callArgs.append("\(val.llvmType) \(val.ssaName)")
 }

 let retTemp = "%t\(nextTemp())"
 guard let retIRType = funcReturnIRTypes[mangle(funcName)] else {
 throw IRGenError.unsupportedExpression("unknown function \(funcName) — not pre-registered",
 sl())
 }
 if retIRType == "void" {
 emitLine(" call void @\(mangle(funcName))(\(callArgs.joined(separator: ", ")))")
 return IRValue(llvmType: "void", ssaName: "")
 }
 emitLine(" \(retTemp) = call \(retIRType) @\(mangle(funcName))(\(callArgs.joined(separator: ", ")))")
 return IRValue(llvmType: retIRType, ssaName: retTemp)
 }

 /// 元组字面量 IR：`(e1, e2, ...)` → LLVM struct 类型 `{ T1, T2, ... }`，
 /// 各元素按自身 IR 类型用 `insertvalue` 从 `undef` 逐字段组装。
 func generateTuple(_ elements: [Expression]) throws -> IRValue {
 var elemVals: [(type: String, ssa: String)] = []
 for e in elements {
 let v = try generateExpression(e)
 elemVals.append((v.llvmType, v.ssaName))
 }
 let structType = "{ " + elemVals.map { $0.type }.joined(separator: ", ") + " }"

 var current = "undef"
 for (i, ev) in elemVals.enumerated() {
 let tmp = "%t\(nextTemp())"
 emitLine(" \(tmp) = insertvalue \(structType) \(current), \(ev.type) \(ev.ssa), \(i)")
 current = tmp
 }
 return IRValue(llvmType: structType, ssaName: current)
 }

 /// 从 LLVM struct 类型字符串解析全部字段的 IR 类型列表（支持嵌套 `{ ... }`）。
 /// 供 `.tupleIndex` 的 extractvalue（tupleFieldIRType）与 `generateStringifyTuple` 共用；
 /// 跨文件 extension 需要 internal（StmtEmitter 的 varDestructure 亦复用）。
 func tupleFieldIRTypes(_ structType: String) throws -> [String] {
 guard structType.hasPrefix("{ ") && structType.hasSuffix(" }") else {
 throw IRGenError.unsupportedFeature("LLVM 后端元组索引要求 struct 类型（收到 \(structType)）", sl())
 }
 let inner = String(structType.dropFirst(2).dropLast(2))
 var depth = 0
 var fields: [String] = []
 var current = ""
 for ch in inner {
 switch ch {
 case "{": depth += 1; current.append(ch)
 case "}": depth -= 1; current.append(ch)
 case "," where depth == 0:
 fields.append(current.trimmingCharacters(in: .whitespaces))
 current = ""
 default: current.append(ch)
 }
 }
 if !current.isEmpty {
 fields.append(current.trimmingCharacters(in: .whitespaces))
 }
 return fields
 }

 /// 从 LLVM struct 类型字符串解析第 index 个字段的 IR 类型（支持嵌套 `{ ... }`）。
 /// 供 `.tupleIndex` 的 extractvalue 结果类型推导（草稿 A2，批次 1）；
 /// 跨文件 extension 需要 internal（StmtEmitter 的 varDestructure 亦复用）。
 func tupleFieldIRType(_ structType: String, index: Int) throws -> String {
 let fields = try tupleFieldIRTypes(structType)
 guard index >= 0 && index < fields.count else {
 throw IRGenError.unsupportedFeature("LLVM 后端元组索引越界（index \(index)，字段数 \(fields.count)）", sl())
 }
 return fields[index]
 }

 // MARK: - #46-D D1：数组元素类型解析（纯 codegen 侧，不触碰类型系统）

 /// 将字典索引表达式装箱为「键 box 指针 + 字节宽 + tag」，供 `@bk_dict_get` / `@bk_dict_contains` 使用。
 /// 与 `generateSubscriptRead` 的键装箱逻辑同源（D2），抽离为 helper 供 D3 缺失键判定（`generatePrintDictSubscriptWithNull`）复用。
 func boxDictKey(_ indexVal: IRValue) throws -> (boxPtr: String, width: Int, tag: Int32) {
 let (keyBoxLLVM, keyWidth) = try arrayElementIRType(indexVal.llvmType)
 let keyBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: keyBoxPtr, type: keyBoxLLVM))
 emitLine(builder.fmtStore(value: indexVal.ssaName, type: keyBoxLLVM, ptr: keyBoxPtr))
 let keyTag = bkTagForLLVMType(indexVal.llvmType)
 return (keyBoxPtr, keyWidth, keyTag)
 }

 /// 数组元素 LLVM 类型 → (llvmType, 字节宽)。D1 支持 I32/F64/Bool/String（及任意指针宽度类型）。
 /// 供 `generateArrayLiteral`（构造）与 `generateSubscriptRead`（解箱）共用，保证读写同构。
 private func arrayElementIRType(_ irType: String) throws -> (llvmType: String, width: Int) {
 switch irType {
 case "i8": return ("i8", 1)
 case "i16": return ("i16", 2)
 case "i32": return ("i32", 4)
 case "i64": return ("i64", 8)
 case "float": return ("float", 4)
 case "double": return ("double", 8)
 case "i1": return ("i1", 1)
 case "ptr", "%bk_array*": return (irType, 8)
 default:
 // 其他具名指针类型（%struct.X* 等）按指针宽度 8 处理，避免误拒；非指针类型（如 { ... } 聚合）不支持。
 if irType.hasSuffix("*") { return (irType, 8) }
 throw IRGenError.unsupportedFeature("D1 暂仅支持 I32/F64/Bool/String 数组元素（收到 \(irType)）", sl())
 }
 }

 /// 自包含字面量元素类型推断（不依赖类型系统 / TypeInference）：用于 codegen 侧集合元素类型解析。
 /// 支持 integerLiteral→I32 / floatLiteral→F64 / stringLiteral|stringInterpolation→String /
 /// boolLiteral→Bool / arrayLiteral→Array<首元素类型> / dictionaryLiteral→Dictionary<K,V> /
 /// setLiteral→Set<首元素类型>（均递归）。其余表达式返回 nil。
 /// `internal`：跨文件 extension（StmtEmitter.record*IfLiteral）亦调用（#46-B 跨文件访问约定）。
 func elementTypeOfLiteral(_ e: Expression) -> TypeAnnotation? {
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 switch e {
 case .integerLiteral: return .simple(name: "I32", location: loc)
 case .floatLiteral: return .simple(name: "F64", location: loc)
 case .stringLiteral, .stringInterpolation: return .simple(name: "String", location: loc)
 case .boolLiteral: return .simple(name: "Bool", location: loc)
 case .arrayLiteral(let els, _):
 guard let first = els.first, let elem = elementTypeOfLiteral(first) else { return nil }
 return .generic(name: "Array", params: [elem], location: loc)
 case .dictionaryLiteral(let entries, _):
 guard let first = entries.first,
 let kt = elementTypeOfLiteral(first.key),
 let vt = elementTypeOfLiteral(first.value) else { return nil }
 return .generic(name: "Dictionary", params: [kt, vt], location: loc)
 case .setLiteral(let els, _):
 guard let first = els.first, let et = elementTypeOfLiteral(first) else { return nil }
 return .generic(name: "Set", params: [et], location: loc)
 case .identifier(let name, _):
 // #46-D D4.2.1b 附带：元素为**容器变量**（`var outer = [inner]` / `["k": inner]` / `{inner}`）时，
 // 由 codegen 侧类型表反构其容器类型，使 outer 也获得元素类型记录
 // （否则 `print(outer)` / `outer[i][j]` 抛「无法推断数组元素类型」——D3 遗留缺口）。
 // 标量变量仍返回 nil（IR 类型无法无损反构 Pini 类型），保持既有护栏：宁可报错不臆造。
 if let et = arrayElementTypeByVar[name] {
 return .generic(name: "Array", params: [et], location: loc)
 }
 if let kt = dictKeyTypeByVar[name], let vt = dictValueTypeByVar[name] {
 return .generic(name: "Dictionary", params: [kt, vt], location: loc)
 }
 if let et = setElementTypeByVar[name] {
 return .generic(name: "Set", params: [et], location: loc)
 }
 return nil
 default: return nil
 }
 }

 /// 是否为集合不透明句柄类型（ADR-008）：值语义相关的 retain / COW 写回仅对这三类生效。
 func isCollectionHandleType(_ t: String) -> Bool {
 return t == "%bk_array*" || t == "%bk_dict*" || t == "%bk_set*"
 }

 /// #46-D D4.2.1b：容器**别名点** retain（所有权契约 ③）。
 ///
 /// 运行时 `bk_*_create` 产出 `shares == 1`，且 `bk_*_set` / `bk_set_add` 对句柄型内容只做
 /// 字节移动、**不** retain（契约 ②）。因此凡是「源句柄仍被别处持有」的复制点，都必须由 codegen
 /// 显式补一份 share，否则原持有者写入时会误判独占而原地改写，污染另一个持有者。
 ///
 /// 判定条件收紧为 RHS 是**变量标识符**且其 IR 类型为集合句柄：
 /// - `var b = a` / `b = a`：两个变量各持一份；
 /// - `var outer = [inner]` / `["k": inner]` / `{inner}`：容器内容与 `inner` 变量各持一份。
 /// 临时值（字面量、函数返回、下标读）无其他持有者，所有权直接移交，不 retain。
 func emitContainerAliasRetain(_ srcExpr: Expression?, _ value: IRValue) {
 guard let srcExpr, case .identifier = srcExpr else { return }
 guard isCollectionHandleType(value.llvmType) else { return }
 usesCollections = true
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast \(value.llvmType) \(value.ssaName) to ptr")
 emitLine(" call void @bk_handle_retain(ptr \(raw))")
 }

 /// #46-D D4.2.1b：COW 写路径的**句柄写回**。
 ///
 /// 运行时 `@bk_*_set` / `@bk_set_add` 在句柄被共享（`shares > 1`）时深拷分裂，写入落在副本上，
 /// 并返回**实际被写入的句柄**。只有把它写回持有该句柄的变量槽，该变量才能看到本次写入
 /// （否则变量仍指向未修改的原 box —— 写入静默丢失）。
 ///
 /// 当前仅处理容器为**变量标识符**（`a[i] = v`）：槽位明确。
 /// - 容器为嵌套下标（`m[i][j] = v`）须自顶向下 `ensure_unique` 链，属 D4.2.2；
 /// - 容器为临时表达式（`[1,2][0] = v`）无其他持有者，句柄必独占，无需写回。
 /// #46-D D4.2.2：嵌套写路径的 **COW 分裂链**，返回「可安全写入的独占容器句柄」。
 ///
 /// 值语义要求 `m[0][0] = 99` 只影响 `m`。但 LLVM 端 `var n = m` 只复制外层裸 ptr，
 /// 且外层槽里存的是**内层句柄的字节**——`m`/`n` 因此共享同一内层 box。若直接对内层写，
 /// 内层 `shares == 1`（内层自己并不知道被两个外层引用过几次）会被误判独占而原地改，污染 `n`。
 ///
 /// 故必须**自顶向下**逐层独占化（顺序不可颠倒：`*_ensure_unique_at` 要求父句柄已独占）：
 /// 1. 根变量 → `@bk_handle_ensure_unique` + 写回变量槽；
 /// 2. 每个中间层 → `@bk_array_ensure_unique_at(parent, i)` / `@bk_dict_ensure_unique_at(parent, key…)`，
 /// 运行时就地改写父槽内的句柄字节（且**不**释放旧句柄，见运行时注释的 UAF 理由）;
 /// 3. 返回最内层句柄，交由调用方 `@bk_*_set` 写入。
 ///
 /// 外层分裂时 `cowCopy` 会对 `tag == .handle` 的槽 `_bkRetainIfHandle`，使内层转为共享，
 /// 于是第 2 步的 `ensure_unique_at` 必然真分裂——两级递归分裂由此闭合。
 ///
 /// 容器为临时值（字面量 / 函数返回）时无其他持有者，句柄必独占，直接求值即可。
 func emitUniqueContainerHandle(_ container: Expression) throws -> IRValue {
 switch container {
 case .identifier(let name, _):
 let v = try generateExpression(container)
 guard isCollectionHandleType(v.llvmType) else { return v }
 usesCollections = true
 let raw = builder.freshTemp()
 emitLine(" \(raw) = bitcast \(v.llvmType) \(v.ssaName) to ptr")
 let newRaw = builder.freshTemp()
 emitLine(" \(newRaw) = call ptr @bk_handle_ensure_unique(ptr \(raw))")
 let typed = builder.freshTemp()
 emitLine(" \(typed) = bitcast ptr \(newRaw) to \(v.llvmType)")
 // 分裂产生副本时必须写回变量槽，否则根变量仍指向旧 box（本次写入静默丢失）。
 if let entry = symbolTable[name], entry.type == v.llvmType {
 emitLine(builder.fmtStore(value: typed, type: v.llvmType, ptr: entry.slot))
 }
 return IRValue(llvmType: v.llvmType, ssaName: typed)

 case .subscript(let inner, let idxExpr, _):
 let parent = try emitUniqueContainerHandle(inner) // 先保证父层独占（顺序契约）
 let selfTA = try resolveSubscriptResultType(inner)
 let selfLLVM = try collectionAwareLLVMType(selfTA)
 guard isCollectionHandleType(selfLLVM) else {
 throw IRGenError.unsupportedFeature("嵌套下标写：中间层非集合句柄（收到 \(selfLLVM)）", sl())
 }
 usesCollections = true
 let parentRaw = builder.freshTemp()
 emitLine(" \(parentRaw) = bitcast \(parent.llvmType) \(parent.ssaName) to ptr")
 let childRaw = builder.freshTemp()
 switch parent.llvmType {
 case "%bk_array*":
 let idxVal = try generateExpression(idxExpr)
 guard idxVal.llvmType == "i32" else {
 throw IRGenError.unsupportedFeature("LLVM 后端数组下标需 I32 索引（收到 \(idxVal.llvmType)）", sl())
 }
 emitLine(" \(childRaw) = call ptr @bk_array_ensure_unique_at(ptr \(parentRaw), i32 \(idxVal.ssaName))")
 case "%bk_dict*":
 let keyVal = try generateExpression(idxExpr)
 let (keyBoxLLVM, keyWidth) = try arrayElementIRType(keyVal.llvmType)
 let keyBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: keyBoxPtr, type: keyBoxLLVM))
 emitLine(builder.fmtStore(value: keyVal.ssaName, type: keyBoxLLVM, ptr: keyBoxPtr))
 let keyTag = bkTagForLLVMType(keyVal.llvmType)
 emitLine(" \(childRaw) = call ptr @bk_dict_ensure_unique_at(ptr \(parentRaw), ptr \(keyBoxPtr), i32 \(keyWidth), i32 \(keyTag))")
 default:
 throw IRGenError.unsupportedFeature("嵌套下标写仅支持数组/字典中间层（收到 \(parent.llvmType)）", sl())
 }
 let typed = builder.freshTemp()
 emitLine(" \(typed) = bitcast ptr \(childRaw) to \(selfLLVM)")
 return IRValue(llvmType: selfLLVM, ssaName: typed)

 default:
 return try generateExpression(container)
 }
 }

 func emitHandleWriteBack(newRaw: String, handleType: String, container: Expression) {
 guard case .identifier(let name, _) = container,
 let entry = symbolTable[name],
 entry.type == handleType else { return }
 let typed = builder.freshTemp()
 emitLine(" \(typed) = bitcast ptr \(newRaw) to \(handleType)")
 emitLine(builder.fmtStore(value: typed, type: handleType, ptr: entry.slot))
 }

 /// box 内容类型标签（与运行时 `_BkTag` 对齐）：codegen 端据 IR 类型产出 tag，
 /// 运行时据此解释字节做相等比较（与指针身份解耦，见 PiniRuntime.swift 注释）。
 private func bkTagForLLVMType(_ t: String) -> Int32 {
 switch t {
 case "i32": return 0
 case "double": return 1
 case "i1": return 2
 case "ptr": return 3
 default:
 // 所有具名指针类型（%bk_array* / %bk_dict* / %bk_set* / %struct.X*）一律按 handle
 return t.hasSuffix("*") ? 4 : 0
 }
 }

 /// 给定 LLVM 类型的文本零值（用于字典缺失键补零 / struct 无初始化器字段补零）：
 /// i32→0 / double→0.0 / i1→0 / 指针类→null（R1.1：组合父类型指针字段须为 null 而非 0）。
 /// `internal`：跨文件 extension（AggregateEmitter 的 struct/object 构造亦调用，#46-B 跨文件访问约定）。
 func zeroConst(_ type: String) -> String {
 switch type {
 case "i8", "i16", "i32", "i64": return "0"
 case "float", "double": return "0.0"
 case "i1": return "0"
 default: return "null"
 }
 }

 /// Pini 类型 → 集合感知的 LLVM 类型：Array/Dictionary/Set 映射到对应 opaque handle，
 /// 其余走 `typeMapper.map`。供字典下标读解箱、嵌套值解析共用。
 func collectionAwareLLVMType(_ ta: TypeAnnotation) throws -> String {
 switch ta {
 case .generic("Array", _, _): return "%bk_array*"
 case .generic("Dictionary", _, _): return "%bk_dict*"
 case .generic("Set", _, _): return "%bk_set*"
 default: return try typeMapper.map(ta)
 }
 }

 /// 解析字典容器的值 Pini 类型（D2：仅 LLVM codegen 用，不触碰类型系统）：
 /// - 字面量直接下标 `d[k]`：直查首条目值类型；
 /// - 变量 `d[k]`：`dictValueTypeByVar`（let/var 绑定字面量时记录）；
 /// - 嵌套字典 `m[k1][k2]`：递归解析内层 Dictionary 的值类型。
 func resolveDictValueType(_ container: Expression) throws -> TypeAnnotation {
 switch container {
 case .dictionaryLiteral(let entries, _):
 guard let first = entries.first, let vt = elementTypeOfLiteral(first.value) else {
 throw IRGenError.unsupportedFeature("空字典无法解析值类型（D2 范围）", sl())
 }
 return vt
 case .identifier(let name, _):
 guard let ta = dictValueTypeByVar[name] else {
 throw IRGenError.unsupportedFeature("LLVM 后端未记录变量 '\(name)' 的字典值类型（D2 范围：仅 let/var 绑定字面量）", sl())
 }
 return ta
 case .subscript(let inner, _, _):
 let selfTA = try resolveSubscriptResultType(inner)
 guard case .generic("Dictionary", let params, _) = selfTA, params.count == 2 else {
 throw IRGenError.unsupportedFeature("嵌套字典下标：内层非 Dictionary 类型（D2 范围）", sl())
 }
 return params[1]
 default:
 throw IRGenError.unsupportedFeature("LLVM 后端不支持该容器类型的字典值解析（D2 范围）", sl())
 }
 }

 /// 解析数组容器的元素 Pini 类型（D1：仅 LLVM codegen 用，不触碰类型系统）：
 /// - 字面量直接下标 `[e...][i]`：直查首元素推断类型；
 /// - 变量 `a[i]`：`arrayElementTypeByVar`（let/var 绑定字面量时记录）；
 /// - 嵌套下标 `m[0][1]`：递归解析内层 Array 的元素类型。
 /// 函数返回的数组 / 其他容器：unsupportedFeature（D1 范围，解释器侧另对齐）。
 func resolveArrayElementType(_ container: Expression) throws -> TypeAnnotation {
 switch container {
 case .arrayLiteral(let els, _):
 guard let first = els.first else {
 throw IRGenError.unsupportedFeature("空数组无法解析元素类型（D1 范围）", sl())
 }
 guard let ta = elementTypeOfLiteral(first) else {
 throw IRGenError.unsupportedFeature("LLVM 后端无法推断字面量首元素类型（D1 范围）", sl())
 }
 return ta
 case .identifier(let name, _):
 guard let ta = arrayElementTypeByVar[name] else {
 throw IRGenError.unsupportedFeature("LLVM 后端未记录变量 '\(name)' 的数组元素类型（D1 范围：仅 let/var 绑定字面量）", sl())
 }
 return ta
 case .subscript(let inner, _, _):
 let selfTA = try resolveSubscriptResultType(inner)
 guard case .generic("Array", let params, _) = selfTA, let elem = params.first else {
 throw IRGenError.unsupportedFeature("嵌套数组下标：内层非 Array 类型（D1 范围）", sl())
 }
 return elem
 default:
 throw IRGenError.unsupportedFeature("LLVM 后端不支持该容器类型的数组元素解析（D1 范围）", sl())
 }
 }

 /// 解析下标表达式 `inner[...]` 的**结果**类型（容器种类无关）：
 /// inner 是 `Array<E>` → `E`；inner 是 `Dictionary<K, V>` → `V`。
 ///
 /// #46-D D4.2.2 修复：此前 `resolveArrayElementType` / `resolveDictValueType` 的 `.subscript`
 /// 分支各自**递归调用自己**，等价于假定「整条嵌套链同种容器」。混合嵌套因此误报：
 /// - `d["a"][0] = v`（外层字典、内层数组）→「未记录变量 'd' 的数组元素类型」；
 /// - `arr[0]["k"] = v`（外层数组、内层字典）→「未记录变量 'arr' 的字典值类型」。
 /// 现统一先解析 inner 自身的容器类型（`resolveExprTypeAnnotation`），再据其种类取元素/值类型。
 func resolveSubscriptResultType(_ inner: Expression) throws -> TypeAnnotation {
 guard let ta = resolveExprTypeAnnotation(inner) else {
 throw IRGenError.unsupportedFeature("LLVM 后端无法解析嵌套下标的内层容器类型（D4.2.2 范围）", sl())
 }
 switch ta {
 case .generic("Array", let params, _) where !params.isEmpty:
 return params[0]
 case .generic("Dictionary", let params, _) where params.count == 2:
 return params[1]
 default:
 throw IRGenError.unsupportedFeature("嵌套下标：内层非 Array / Dictionary 类型（收到 \(ta)）", sl())
 }
 }

 /// 数组字面量 IR（ADR-008 / #46-D）：`[e1, e2, ...]` 经运行时 shim 构造不透明句柄。
 /// - `bk_array_create(N)` 返回 `ptr` 句柄，bitcast 为 `%bk_array*`；
 /// - 每个元素按自身 IR 类型装箱（alloca T + store），再经 `bk_array_set(ptr, idx, boxPtr, elemBytes)`
 /// 写入运行时拥有的堆 box（D1：元素类型经 IR 类型推断，支持 I32/F64/Bool/String）。
 /// 返回 `%bk_array*` 类型，被 `varDecl` 的 alloca/store 路径以「opaque handle」语义承载。
 /// 与字符串 `ptr` 类型区分，使 `len`/下标可据 IR 类型分派（无需 IRValue 标志位）。
 func generateArrayLiteral(_ elements: [Expression]) throws -> IRValue {
 usesCollections = true
 // 空数组 []：运行时 bk_array_create(0) 支持（返回 len=0 空句柄），与解释器侧对齐。
 guard !elements.isEmpty else {
 let createTmp = builder.freshTemp() // %tN : ptr（原始 void* 句柄）
 emitLine(" \(createTmp) = call ptr @bk_array_create(i32 0)")
 let handle = builder.freshTemp() // %tN : %bk_array*（类型化句柄）
 emitLine(" \(handle) = bitcast ptr \(createTmp) to %bk_array*")
 return IRValue(llvmType: "%bk_array*", ssaName: handle)
 }
 var elemVals: [IRValue] = []
 for e in elements {
 elemVals.append(try generateExpression(e))
 }
 // 同构检查：全部元素 IR 类型须等于首个（假定数组同构）。
 let elemType = elemVals[0].llvmType
 for ev in elemVals {
 guard ev.llvmType == elemType else {
 throw IRGenError.unsupportedFeature(
 "heterogeneous array literal is not supported in LLVM IR (mixed \(ev.llvmType) and \(elemType))", sl())
 }
 }
 // 首元素 IR 类型 → (llvmType, 字节宽)；装箱后写入运行时堆 box。
 let (boxedLLVM, width) = try arrayElementIRType(elemType)

 let n = elemVals.count
 let createTmp = builder.freshTemp() // %tN : ptr（原始 void* 句柄）
 emitLine(" \(createTmp) = call ptr @bk_array_create(i32 \(n))")
 let elemTag = bkTagForLLVMType(elemType)
 // D4.2.1b：`@bk_array_set` 改为返回实际被写入的句柄（COW 分裂时为副本）。构造中的句柄恒独占
 // （create 即 shares==1），返回值必等于入参，但仍逐次线程化，使构造路径与写路径同构、不留特例。
 var curRaw = createTmp
 for (i, ev) in elemVals.enumerated() {
 // 装箱：alloca T + store 元素值 + 取 boxPtr（复用在 Optional.some 验证的装箱手法）
 let boxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: boxPtr, type: boxedLLVM))
 emitLine(builder.fmtStore(value: ev.ssaName, type: boxedLLVM, ptr: boxPtr))
 // `var outer = [inner]`：inner 变量仍持有该句柄，须补一份 share（所有权契约 ③）。
 emitContainerAliasRetain(elements[i], ev)
 let nextRaw = builder.freshTemp()
 emitLine(" \(nextRaw) = call ptr @bk_array_set(ptr \(curRaw), i32 \(i), ptr \(boxPtr), i32 \(width), i32 \(elemTag))")
 curRaw = nextRaw
 }
 let handle = builder.freshTemp() // %tN : %bk_array*（类型化句柄）
 emitLine(" \(handle) = bitcast ptr \(curRaw) to %bk_array*")
 return IRValue(llvmType: "%bk_array*", ssaName: handle)
 }

 /// 字典字面量 IR（ADR-008 / #46-D D2）：`[k1: v1, k2: v2]` 经运行时 shim 构造不透明句柄。
 /// - `bk_dict_create()` 返回 `ptr` 句柄，bitcast 为 `%bk_dict*`；
 /// - 每条目：键与值各按自身 IR 类型装箱（alloca T + store），再经
 /// `bk_dict_set(ptr, keyBox, keyBytes, keyTag, valBox, valBytes, valTag)` 写入运行时堆 box。
 /// `keyTag/valTag` 由 `bkTagForLLVMType` 据 IR 类型产出，运行时据此（与指针身份解耦）做键相等比较。
 /// 返回 `%bk_dict*` 类型，被 `varDecl` 的 alloca/store 路径以「opaque handle」语义承载。
 func generateDictionaryLiteral(_ entries: [DictEntry]) throws -> IRValue {
 usesCollections = true
 let createTmp = builder.freshTemp() // %tN : ptr（原始 void* 句柄）
 emitLine(" \(createTmp) = call ptr @bk_dict_create()")
 // D4.2.1b：`@bk_dict_set` 改为返回实际被写入的句柄，逐条目线程化（构造中恒独占，与写路径同构）。
 var curRaw = createTmp
 for entry in entries {
 let kVal = try generateExpression(entry.key)
 let (kBoxLLVM, kWidth) = try arrayElementIRType(kVal.llvmType)
 let kBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: kBoxPtr, type: kBoxLLVM))
 emitLine(builder.fmtStore(value: kVal.ssaName, type: kBoxLLVM, ptr: kBoxPtr))
 let kTag = bkTagForLLVMType(kVal.llvmType)

 let vVal = try generateExpression(entry.value)
 let (vBoxLLVM, vWidth) = try arrayElementIRType(vVal.llvmType)
 let vBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: vBoxPtr, type: vBoxLLVM))
 emitLine(builder.fmtStore(value: vVal.ssaName, type: vBoxLLVM, ptr: vBoxPtr))
 let vTag = bkTagForLLVMType(vVal.llvmType)
 // `["k": inner]`：键/值为仍被持有的容器变量时补一份 share（所有权契约 ③）。
 emitContainerAliasRetain(entry.key, kVal)
 emitContainerAliasRetain(entry.value, vVal)

 let nextRaw = builder.freshTemp()
 emitLine(" \(nextRaw) = call ptr @bk_dict_set(ptr \(curRaw), ptr \(kBoxPtr), i32 \(kWidth), i32 \(kTag), ptr \(vBoxPtr), i32 \(vWidth), i32 \(vTag))")
 curRaw = nextRaw
 }
 let handle = builder.freshTemp() // %tN : %bk_dict*（类型化句柄）
 emitLine(" \(handle) = bitcast ptr \(curRaw) to %bk_dict*")
 return IRValue(llvmType: "%bk_dict*", ssaName: handle)
 }

 /// 集合字面量 IR（ADR-008 / #46-D D2）：`{e1, e2, ...}` 经运行时 shim 构造不透明句柄。
 /// - `bk_set_create()` 返回 `ptr` 句柄，bitcast 为 `%bk_set*`；
 /// - 每个元素按自身 IR 类型装箱，再经 `bk_set_add(ptr, boxPtr, elemBytes, elemTag)` 去重插入。
 /// 返回 `%bk_set*` 类型。
 func generateSetLiteral(_ elements: [Expression]) throws -> IRValue {
 usesCollections = true
 let createTmp = builder.freshTemp() // %tN : ptr（原始 void* 句柄）
 emitLine(" \(createTmp) = call ptr @bk_set_create()")
 // D4.2.1b：`@bk_set_add` 改为返回实际被写入的句柄，逐元素线程化（构造中恒独占，与写路径同构）。
 var curRaw = createTmp
 for elem in elements {
 let eVal = try generateExpression(elem)
 let (eBoxLLVM, eWidth) = try arrayElementIRType(eVal.llvmType)
 let eBoxPtr = builder.freshTemp()
 emitLine(builder.fmtAlloca(name: eBoxPtr, type: eBoxLLVM))
 emitLine(builder.fmtStore(value: eVal.ssaName, type: eBoxLLVM, ptr: eBoxPtr))
 let eTag = bkTagForLLVMType(eVal.llvmType)
 // `{inner}`：元素为仍被持有的容器变量时补一份 share（所有权契约 ③）。
 emitContainerAliasRetain(elem, eVal)
 let nextRaw = builder.freshTemp()
 emitLine(" \(nextRaw) = call ptr @bk_set_add(ptr \(curRaw), ptr \(eBoxPtr), i32 \(eWidth), i32 \(eTag))")
 curRaw = nextRaw
 }
 let handle = builder.freshTemp() // %tN : %bk_set*（类型化句柄）
 emitLine(" \(handle) = bitcast ptr \(curRaw) to %bk_set*")
 return IRValue(llvmType: "%bk_set*", ssaName: handle)
 }
}
