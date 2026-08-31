import Foundation

/// #46-B 架构演进：`IRGenerator` 按关注点拆分出的发射器扩展。
/// 字符串化与打印：递归 stringify（int/double/bool/enum/聚合体）、
/// print 单参/多参/插值路径、字符串字面量常量池。
///
/// 拆分为机械搬迁：成员实现逐字节保留，仅访问级别由 `private` 放宽为模块内 `internal`
/// （跨文件 extension 的必要条件）。golden IR 必须字节级不变。
extension IRGenerator {

 // MARK: - 递归 stringify（T2：闭合 G-IR-enum-print）

 /// 将任意 Pini 值格式化为展示字符串，对齐解释器 `stringify`。
 /// 返回指向当前函数帧内 null 结尾字符缓冲区的 `ptr`，供 `printf("%s", ...)` 或 `strcat` 使用。
 /// 聚合类型（enum/struct/object）递归展开；标量按类型格式化；容器（数组/字典/集合，含嵌套）
 /// 经 IR 循环迭代运行时访问器，递归格式化每个元素（#46-D D3，对齐解释器 `stringify` 输出）。
 ///
 /// - Parameter ta: 值的 Pini 类型注解（供容器迭代时推断元素/键/值类型）。`nil` 时容器将报错，
 /// 调用方（print 路径）须经 `resolveExprTypeAnnotation` 提供。
 ///
 /// 注：double 走 `@fmt_double`(`%f`)，与现有 `print(double)` 的 run-llvm 行为一致；
 /// 与解释器 Swift `String(double)`（如 `2.0` vs `2.000000`）的字节级差异属已知残留（同 scalar print），
 /// 黄金对拍测试回避浮点 payload。
 func generateStringify(_ val: IRValue, _ ta: TypeAnnotation? = nil) throws -> IRValue {
 switch val.llvmType {
 case "i32": return try stringifyInt(val)
 case "double": return try stringifyDouble(val)
 case "i1": return try stringifyBool(val)
 // Phase 0：窄/宽整型扩宽到 i32 复用 @snprintf(@fmt_int)（与 i32 同整型 tag）。
 // 注：U8/U16/U64 映射到 i8/i16/i64，sext 对高位正值可能误判符号——已知残留，待带符号信息后修正。
 case "i8", "i16", "i64":
 let ext = "%t\(nextTemp())"
 emitLine(" \(ext) = sext \(val.llvmType) \(val.ssaName) to i32")
 return try stringifyInt(IRValue(llvmType: "i32", ssaName: ext))
 case "float":
 let ext = "%t\(nextTemp())"
 emitLine(" \(ext) = fpext float \(val.ssaName) to double")
 return try stringifyDouble(IRValue(llvmType: "double", ssaName: ext))
 case "ptr":
 // 字符串：解释器输出原始内容（无引号），直接返回该指针
 return val
 case let t where t.hasPrefix("%enum."):
 return try generateStringifyEnum(val)
 case let t where t.hasPrefix("%struct."):
 return try generateStringifyAggregate(val, isObject: false)
 case let t where t.hasPrefix("%object."):
 return try generateStringifyAggregate(val, isObject: true)
 case "%bk_array*":
 guard let ta, case .generic("Array", let params, _) = ta, let elemTA = params.first else {
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端无法推断数组元素类型以格式化（D3 范围：需可推断元素类型的数组字面量/变量/下标）", sl())
 }
 return try generateStringifyArray(val, elemTA: elemTA)
 case "%bk_dict*":
 guard let ta, case .generic("Dictionary", let params, _) = ta, params.count == 2 else {
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端无法推断字典键/值类型以格式化（D3 范围：需可推断类型的字典字面量/变量/下标）", sl())
 }
 return try generateStringifyDict(val, keyTA: params[0], valTA: params[1])
 case "%bk_set*":
 guard let ta, case .generic("Set", let params, _) = ta, let elemTA = params.first else {
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端无法推断集合元素类型以格式化（D3 范围：需可推断类型的集合字面量/变量/下标）", sl())
 }
 return try generateStringifySet(val, elemTA: elemTA)
 case let t where t.hasPrefix("{") && t.hasSuffix("}"):
 // 元组（匿名 struct `{ T0, T1, ... }`）stringify：对齐解释器 `[v0, v1]`（位置元组）
 // 与 `[label: v0, ...]`（命名元组）。标签取自 `ta`；`ta` 为 nil 时退化为位置元组展示。
 return try generateStringifyTuple(val, ta)
 default:
 throw IRGenError.unsupportedFeature(feature:
 "LLVM 后端暂不支持将类型 \(extractTypeName(from: val.llvmType)) 的值格式化为字符串（stringify）；请改用解释器 `pini run`",
 sl())
 }
 }

 /// 推断表达式的 Pini 类型注解（仅供容器/元组格式化用，不触碰类型系统）。
 /// 覆盖 `print` 常见形态：容器字面量、元组字面量、绑定到容器/元组字面量的变量、数组/字典下标读。其余返回 nil。
 func resolveExprTypeAnnotation(_ expr: Expression) -> TypeAnnotation? {
 switch expr {
 case .arrayLiteral(let els, let loc):
 guard let first = els.first, let et = elementTypeOfLiteral(first) else { return nil }
 return .generic(name: "Array", params: [et], location: loc)
 case .dictionaryLiteral(let entries, let loc):
 guard let first = entries.first,
 let kt = elementTypeOfLiteral(first.key),
 let vt = elementTypeOfLiteral(first.value) else { return nil }
 return .generic(name: "Dictionary", params: [kt, vt], location: loc)
 case .setLiteral(let els, let loc):
 guard let first = els.first, let et = elementTypeOfLiteral(first) else { return nil }
 return .generic(name: "Set", params: [et], location: loc)
 case .tuple(let labels, let els, let loc):
 let elemTAs = els.compactMap { elementTypeOfLiteral($0) }
 guard elemTAs.count == els.count else { return nil }
 return .tuple(labels: labels, elements: elemTAs, location: loc)
 case .identifier(let name, let loc):
 if let et = arrayElementTypeByVar[name] { return .generic(name: "Array", params: [et], location: loc) }
 if let kt = dictKeyTypeByVar[name], let vt = dictValueTypeByVar[name] {
 return .generic(name: "Dictionary", params: [kt, vt], location: loc)
 }
 if let et = setElementTypeByVar[name] { return .generic(name: "Set", params: [et], location: loc) }
 if let tt = tupleTypeByVar[name] { return tt }
 return nil
 case .subscript(let container, _, _):
 // D4.2.2：统一经 resolveSubscriptResultType（容器种类无关），
 // 取代原「先按 Array 试、再按 Dictionary 试」的顺序偏置。
 return try? resolveSubscriptResultType(container)
 default:
 return nil
 }
 }

 /// 把 `src`（指向 null 结尾 C 字符串的 ptr）拼接至 `dst` 缓冲区（原地 strcat，忽略返回值）。
 func strcatBuffer(_ dst: String, _ src: IRValue) {
 emitLine(" \("%t\(nextTemp())") = call ptr @strcat(ptr \(dst), ptr \(src.ssaName))")
 }

 func stringifyInt(_ val: IRValue) throws -> IRValue {
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[32 x i8]"))
 let bufp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufp, aggregate: "[32 x i8]", base: buf, indices: [0, 0]))
 emitLine(" call i32 (ptr, i64, ptr, ...) @snprintf(ptr \(bufp), i64 31, ptr @fmt_int, i32 \(val.ssaName))")
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 func stringifyDouble(_ val: IRValue) throws -> IRValue {
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[64 x i8]"))
 let bufp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufp, aggregate: "[64 x i8]", base: buf, indices: [0, 0]))
 emitLine(" call i32 (ptr, i64, ptr, ...) @snprintf(ptr \(bufp), i64 63, ptr @fmt_double, double \(val.ssaName))")
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 func stringifyBool(_ val: IRValue) throws -> IRValue {
 let sel = "%t\(nextTemp())"
 emitLine(" \(sel) = select i1 \(val.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false")
 return IRValue(llvmType: "ptr", ssaName: sel)
 }

 /// 枚举 stringify：`caseName` 或 `caseName(p0: v0, p1: v1)`（命名关联值加 `name: ` 前缀，
 /// 与解释器 `enumValue` 输出逐字节一致）。按 tag `switch` 分发到各 case 块，统一汇入 merge 块。
 func generateStringifyEnum(_ val: IRValue) throws -> IRValue {
 let ptrType = val.llvmType // e.g. "%enum.Shape*"
 let aggName = String(ptrType.dropLast()) // e.g. "%enum.Shape"
 let enumName = extractTypeName(from: ptrType) // mangled, e.g. "Shape"
 guard let ed = enumDecls[enumName] else {
 throw IRGenError.unsupportedFeature(feature:"LLVM 后端 stringify 未知枚举类型 \(enumName)", sl())
 }

 // 加载 tag（GEP(0,0)）
 let tagPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: tagPtr, aggregate: aggName, base: val.ssaName, indices: [0, 0]))
 let tagVal = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: tagVal, type: "i32", ptr: tagPtr))

 // 结果缓冲区
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[1024 x i8]"))
 let bufp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufp, aggregate: "[1024 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: bufp))

 let lbl = nextLabel()
 let merge = "str_enum_merge_\(lbl)"
 var caseLbls: [String] = []
 for i in 0..<ed.cases.count { caseLbls.append("str_enum_\(lbl)_\(i)") }

 // switch i32 tagVal, label %merge [ i32 0, label %c0 i32 1, label %c1 ... ]
 var sw = " switch i32 \(tagVal), label %\(merge) ["
 for i in 0..<ed.cases.count { sw += " i32 \(i), label %\(caseLbls[i])" }
 sw += " ]"
 emitLine(sw)

 for (i, c) in ed.cases.enumerated() {
 emitLine("\(caseLbls[i]):")
 strcatBuffer(bufp, try generateStringLiteral(c.name))
 if !c.associatedParams.isEmpty {
 strcatBuffer(bufp, try generateStringLiteral("("))
 for j in 0..<c.associatedParams.count {
 if j > 0 { strcatBuffer(bufp, try generateStringLiteral(", ")) }
 if let pname = c.associatedParams[j].name {
 strcatBuffer(bufp, try generateStringLiteral("\(pname): "))
 }
 let fldPtr = "%t\(nextTemp())"
 emitLine(" \(fldPtr) = getelementptr \(aggName), ptr \(val.ssaName), i32 0, i32 \(j + 1)")
 let fIR = try typeMapper.map(c.associatedParams[j].type)
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: fIR, ptr: fldPtr))
 strcatBuffer(bufp, try generateStringify(IRValue(llvmType: fIR, ssaName: loaded), c.associatedParams[j].type))
 }
 strcatBuffer(bufp, try generateStringLiteral(")"))
 }
 emitLine(builder.fmtBr(labelName: merge))
 }
 emitLine("\(merge):")
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// struct/object stringify：`TypeName{key: value, key: value}`（字段按声明顺序，引用类型含 refcount 头故偏移 +1）。
 func generateStringifyAggregate(_ val: IRValue, isObject: Bool) throws -> IRValue {
 let ptrType = val.llvmType
 let aggName = String(ptrType.dropLast())
 let baseName = extractTypeName(from: ptrType) // mangled
 let fields: [FieldDecl]
 let offset: Int
 let typeName: String
 if isObject {
 guard let od = objectTypes[baseName] else {
 throw IRGenError.unsupportedFeature(feature:"LLVM 后端 stringify 未知 object 类型 \(baseName)", sl())
 }
 fields = od.fields; offset = 1; typeName = od.name
 } else {
 guard let sd = structTypes[baseName] else {
 throw IRGenError.unsupportedFeature(feature:"LLVM 后端 stringify 未知 struct 类型 \(baseName)", sl())
 }
 fields = sd.fields; offset = 0; typeName = sd.name
 }

 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[1024 x i8]"))
 let bufp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufp, aggregate: "[1024 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: bufp))

 strcatBuffer(bufp, try generateStringLiteral(typeName))
 strcatBuffer(bufp, try generateStringLiteral("{"))
 // 字段按名排序展示（与解释器 `stringify` 排序一致）；GEP 仍用声明序索引 declIdx 定位。
 let sorted = fields.enumerated().sorted { $0.element.name < $1.element.name }
 var first = true
 for (declIdx, f) in sorted {
 if !first { strcatBuffer(bufp, try generateStringLiteral(", ")) }
 first = false
 strcatBuffer(bufp, try generateStringLiteral("\(f.name): "))
 let fldPtr = "%t\(nextTemp())"
 emitLine(" \(fldPtr) = getelementptr \(aggName), ptr \(val.ssaName), i32 0, i32 \(declIdx + offset)")
 let fIR = try typeMapper.map(f.typeAnnotation)
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: fIR, ptr: fldPtr))
 strcatBuffer(bufp, try generateStringify(IRValue(llvmType: fIR, ssaName: loaded), f.typeAnnotation))
 }
 strcatBuffer(bufp, try generateStringLiteral("}"))
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// 元组 stringify：对齐解释器 `stringify` 的 `[v0, v1]`（位置元组）与 `[label: v0, ...]`（命名元组）。
 ///
 /// 元组在 IR 中是匿名 struct `{ T0, T1, ... }`（草稿 A2，批次 1）。`val` 为 SSA 寄存器中的
 /// struct 值，需 `alloca` + `store` 取指针后逐字段 `getelementptr` / `load`，再递归 `generateStringify`
 /// （字段可为标量/容器/嵌套元组）。标签取自 `ta`（.tuple 携带 labels）；`ta` 为 nil 时退化为位置元组。
 /// 字段元素类型注解（嵌套容器/元组递归用）同样取自 `ta.elements`。
 func generateStringifyTuple(_ val: IRValue, _ ta: TypeAnnotation? = nil) throws -> IRValue {
 let structType = val.llvmType // "{ i32, i32 }"
 let fieldTypes = try tupleFieldIRTypes(structType)
 var labels: [String?] = []
 var elemTAs: [TypeAnnotation] = []
 if case .tuple(let ls, let els, _) = ta {
 labels = ls
 elemTAs = els
 }

 let ptr = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: ptr, type: structType))
 emitLine(builder.fmtStore(value: val.ssaName, type: structType, ptr: ptr))

 let (buf, bufp) = try makeStringifyBuffer()
 strcatBuffer(bufp, try generateStringLiteral("["))
 for (i, ft) in fieldTypes.enumerated() {
 if i > 0 { strcatBuffer(bufp, try generateStringLiteral(", ")) }
 if i < labels.count, let lab = labels[i], !lab.isEmpty {
 strcatBuffer(bufp, try generateStringLiteral("\(lab): "))
 }
 let fldPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: fldPtr, aggregate: structType, base: ptr, indices: [0, i]))
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: ft, ptr: fldPtr))
 let fta: TypeAnnotation? = i < elemTAs.count ? elemTAs[i] : nil
 strcatBuffer(bufp, try generateStringify(IRValue(llvmType: ft, ssaName: loaded), fta))
 }
 strcatBuffer(bufp, try generateStringLiteral("]"))
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// 聚合类型判定：枚举/结构/对象/集合（IR 以 `%` 前缀命名）与元组（匿名 struct `{ ... }`）
 /// 均走递归 stringify（对齐解释器展示语义），不直接作为 printf 变参（避免乱码/崩溃）。
 private func isAggregateForStringify(_ t: String) -> Bool {
 t.hasPrefix("%") || (t.hasPrefix("{") && t.hasSuffix("}"))
 }

 // MARK: - 容器格式化（#46-D D3：对齐解释器 `stringify` 的 [a, b] / {k: v} / {a, b}）

 /// 数组格式化：`[e0, e1, ...]`（递归 stringify 每个元素，对齐解释器）。经 IR 循环迭代
 /// `@bk_array_len` / `@bk_array_get`，元素类型由 `elemTA` 推断（嵌套数组 → `%bk_array*`，递归）。
 private func generateStringifyArray(_ val: IRValue, elemTA: TypeAnnotation) throws -> IRValue {
 usesCollections = true
 let elemLLVM = try collectionAwareLLVMType(elemTA)
 let (buf, bufp) = try makeStringifyBuffer()
 strcatBuffer(bufp, try generateStringLiteral("["))
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast %bk_array* \(val.ssaName) to ptr")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i32 @bk_array_len(ptr \(raw))")
 let (ivar, iv, cmp, condL, bodyL, sepL, elemL, endL) = try stringifyLoopLabels()
 emitLine(" \(cmp) = icmp slt i32 \(iv), \(len)")
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: bodyL, elseLabelName: endL))
 emitLine("\(bodyL):")
 let isFirst = "%t\(nextTemp())"
 emitLine(" \(isFirst) = icmp eq i32 \(iv), 0")
 emitLine(builder.fmtCondBr(cond: isFirst, thenLabelName: elemL, elseLabelName: sepL))
 emitLine("\(sepL):")
 strcatBuffer(bufp, try generateStringLiteral(", "))
 emitLine(builder.fmtBr(labelName: elemL))
 emitLine("\(elemL):")
 let box = "%t\(nextTemp())"
 emitLine(" \(box) = call ptr @bk_array_get(ptr \(raw), i32 \(iv))")
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: elemLLVM, ptr: box))
 let estr = try generateStringify(IRValue(llvmType: elemLLVM, ssaName: loaded), elemTA)
 strcatBuffer(bufp, estr)
 try stringifyLoopInc(iv, ivar, condL)
 emitLine("\(endL):")
 strcatBuffer(bufp, try generateStringLiteral("]"))
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// 字典格式化：`{k0: v0, k1: v1, ...}`（键/值各自递归 stringify，对齐解释器）。
 private func generateStringifyDict(_ val: IRValue, keyTA: TypeAnnotation, valTA: TypeAnnotation) throws -> IRValue {
 usesCollections = true
 let keyLLVM = try collectionAwareLLVMType(keyTA)
 let valLLVM = try collectionAwareLLVMType(valTA)
 let (buf, bufp) = try makeStringifyBuffer()
 strcatBuffer(bufp, try generateStringLiteral("{"))
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast %bk_dict* \(val.ssaName) to ptr")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i32 @bk_dict_len(ptr \(raw))")
 let (ivar, iv, cmp, condL, bodyL, sepL, elemL, endL) = try stringifyLoopLabels()
 emitLine(" \(cmp) = icmp slt i32 \(iv), \(len)")
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: bodyL, elseLabelName: endL))
 emitLine("\(bodyL):")
 let isFirst = "%t\(nextTemp())"
 emitLine(" \(isFirst) = icmp eq i32 \(iv), 0")
 emitLine(builder.fmtCondBr(cond: isFirst, thenLabelName: elemL, elseLabelName: sepL))
 emitLine("\(sepL):")
 strcatBuffer(bufp, try generateStringLiteral(", "))
 emitLine(builder.fmtBr(labelName: elemL))
 emitLine("\(elemL):")
 let kbox = "%t\(nextTemp())"
 emitLine(" \(kbox) = call ptr @bk_dict_key_at(ptr \(raw), i32 \(iv))")
 let kloaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: kloaded, type: keyLLVM, ptr: kbox))
 let kstr = try generateStringify(IRValue(llvmType: keyLLVM, ssaName: kloaded), keyTA)
 strcatBuffer(bufp, kstr)
 strcatBuffer(bufp, try generateStringLiteral(": "))
 let vbox = "%t\(nextTemp())"
 emitLine(" \(vbox) = call ptr @bk_dict_val_at(ptr \(raw), i32 \(iv))")
 let vloaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: vloaded, type: valLLVM, ptr: vbox))
 let vstr = try generateStringify(IRValue(llvmType: valLLVM, ssaName: vloaded), valTA)
 strcatBuffer(bufp, vstr)
 try stringifyLoopInc(iv, ivar, condL)
 emitLine("\(endL):")
 strcatBuffer(bufp, try generateStringLiteral("}"))
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// 集合格式化：`{e0, e1, ...}`（每个元素递归 stringify，对齐解释器）。
 private func generateStringifySet(_ val: IRValue, elemTA: TypeAnnotation) throws -> IRValue {
 usesCollections = true
 let elemLLVM = try collectionAwareLLVMType(elemTA)
 let (buf, bufp) = try makeStringifyBuffer()
 strcatBuffer(bufp, try generateStringLiteral("{"))
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast %bk_set* \(val.ssaName) to ptr")
 let len = "%t\(nextTemp())"
 emitLine(" \(len) = call i32 @bk_set_len(ptr \(raw))")
 let (ivar, iv, cmp, condL, bodyL, sepL, elemL, endL) = try stringifyLoopLabels()
 emitLine(" \(cmp) = icmp slt i32 \(iv), \(len)")
 emitLine(builder.fmtCondBr(cond: cmp, thenLabelName: bodyL, elseLabelName: endL))
 emitLine("\(bodyL):")
 let isFirst = "%t\(nextTemp())"
 emitLine(" \(isFirst) = icmp eq i32 \(iv), 0")
 emitLine(builder.fmtCondBr(cond: isFirst, thenLabelName: elemL, elseLabelName: sepL))
 emitLine("\(sepL):")
 strcatBuffer(bufp, try generateStringLiteral(", "))
 emitLine(builder.fmtBr(labelName: elemL))
 emitLine("\(elemL):")
 let box = "%t\(nextTemp())"
 emitLine(" \(box) = call ptr @bk_set_at(ptr \(raw), i32 \(iv))")
 let loaded = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: loaded, type: elemLLVM, ptr: box))
 let estr = try generateStringify(IRValue(llvmType: elemLLVM, ssaName: loaded), elemTA)
 strcatBuffer(bufp, estr)
 try stringifyLoopInc(iv, ivar, condL)
 emitLine("\(endL):")
 strcatBuffer(bufp, try generateStringLiteral("}"))
 return IRValue(llvmType: "ptr", ssaName: bufp)
 }

 /// 分配 [1024 x i8] 结果缓冲并返回 (alloca 名, gep 指针名)。
 private func makeStringifyBuffer() throws -> (String, String) {
 let buf = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: buf, type: "[1024 x i8]"))
 let bufp = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: bufp, aggregate: "[1024 x i8]", base: buf, indices: [0, 0]))
 emitLine(builder.fmtStore(value: "0", type: "i8", ptr: bufp))
 return (buf, bufp)
 }

 /// 生成循环标签四元组与循环变量（i32，初值 0，跳到条件块）。
 private func stringifyLoopLabels() throws -> (ivar: String, iv: String, cmp: String, condL: String, bodyL: String, sepL: String, elemL: String, endL: String) {
 let ivar = "%t\(nextTemp())"
 emitLine(builder.fmtAlloca(name: ivar, type: "i32"))
 emitLine(builder.fmtStore(value: "0", type: "i32", ptr: ivar))
 let label = nextLabel()
 let condL = "str_cond_\(label)", bodyL = "str_body_\(label)", sepL = "str_sep_\(label)", elemL = "str_elem_\(label)", endL = "str_end_\(label)"
 emitLine(builder.fmtBr(labelName: condL))
 emitLine("\(condL):")
 let iv = "%t\(nextTemp())"
 emitLine(builder.fmtLoad(name: iv, type: "i32", ptr: ivar))
 let cmp = "%t\(nextTemp())"
 return (ivar, iv, cmp, condL, bodyL, sepL, elemL, endL)
 }

 /// 循环增量：iv++ 并跳回条件块。
 private func stringifyLoopInc(_ iv: String, _ ivar: String, _ condL: String) throws {
 let iv2 = "%t\(nextTemp())"
 emitLine(" \(iv2) = add i32 \(iv), 1")
 emitLine(builder.fmtStore(value: iv2, type: "i32", ptr: ivar))
 emitLine(builder.fmtBr(labelName: condL))
 }

 func generatePrintCall(arguments: [CallArgument]) throws -> IRValue {
 guard !arguments.isEmpty else {
 emitLine(" call i32 (ptr, ...) @printf(ptr @fmt_int, i32 0)")
 return IRValue(llvmType: "void", ssaName: "")
 }

 // 多参 print：空格连接 + 末尾换行，构造格式串 + 单 printf
 if arguments.count > 1 {
 return try generateMultiArgPrint(arguments)
 }

 let arg = arguments[0]
 if case .stringInterpolation(let segments, _) = arg.expression {
 return try generateInterpolationPrint(segments)
 }

 // #46-D D3：缺失键闭合——`print(d[k])` 键缺失时 LLVM 输出 "null"，对齐解释器 `stringify(.null)` → "null"。
 // 既有键场景仍走下方正常 stringify（命中返回值 / 缺失补零值的分歧在此统一为 "null"）。
 if case .subscript(let dContainer, _, _) = arg.expression,
 (try? resolveDictValueType(dContainer)) != nil {
 return try generatePrintDictSubscriptWithNull(arg.expression)
 }

 var result = try generateExpression(arg.expression)

 // T2（G-IR-enum-print）+ D3：聚合/容器/元组类型递归 stringify，
 // 对齐解释器展示语义；不再 fail-loud（此前静默打印指针乱码）。
 if isAggregateForStringify(result.llvmType) {
 result = try generateStringify(result, resolveExprTypeAnnotation(arg.expression))
 }

 // Bool 收口：与解释器一致输出 `true`/`false`（而非 1/0）。
 // 用 select 在两个格式串常量间择一，直接作为 printf 的格式串传入
 // （`@fmt_bool_true` 内容为 "true\00"，printf 遇 NUL 停止，故无需额外 `%s`）。
 if result.llvmType == "i1" {
 let sel = "%t\(nextTemp())"
 emitLine(" \(sel) = select i1 \(result.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false")
 emitLine(" call i32 (ptr, ...) @printf(ptr \(sel))")
 return IRValue(llvmType: "void", ssaName: "")
 }

 let fmtVar: String
 switch result.llvmType {
 case "i32": fmtVar = "@fmt_int"
 case "double": fmtVar = "@fmt_double"
 case "i8", "i16", "i64":
 // Phase 0：窄/宽整型扩宽到 i32 走 @fmt_int（与 i32 同整型 tag）。
 let ext = "%t\(nextTemp())"
 emitLine(" \(ext) = sext \(result.llvmType) \(result.ssaName) to i32")
 result = IRValue(llvmType: "i32", ssaName: ext)
 fmtVar = "@fmt_int"
 case "float":
 let ext = "%t\(nextTemp())"
 emitLine(" \(ext) = fpext float \(result.ssaName) to double")
 result = IRValue(llvmType: "double", ssaName: ext)
 fmtVar = "@fmt_double"
 default: fmtVar = "@fmt_string"
 }

 emitLine(" call i32 (ptr, ...) @printf(ptr \(fmtVar), \(result.llvmType) \(result.ssaName))")
 return IRValue(llvmType: "void", ssaName: "")
 }

 /// `print(d[k])` 缺失键闭合（#46-D D3）：键命中走正常 stringify（返回值），键缺失经 `@bk_dict_contains`
 /// 判定并输出字面量 "null"，对齐解释器 `stringify(.null)` → "null"。闭合 D2 遗留的「缺失键 LLVM 补零值」分歧。
 private func generatePrintDictSubscriptWithNull(_ expr: Expression) throws -> IRValue {
 guard case .subscript(let container, let index, _) = expr else {
 throw IRGenError.unsupportedExpression(kind:"internal: expected subscript in D3 print", sl())
 }
 usesCollections = true
 let dictVal = try generateExpression(container) // %bk_dict*
 let raw = "%t\(nextTemp())"
 emitLine(" \(raw) = bitcast %bk_dict* \(dictVal.ssaName) to ptr")
 let indexVal = try generateExpression(index)
 let (keyBoxPtr, keyWidth, keyTag) = try boxDictKey(indexVal)
 let presentI32 = "%t\(nextTemp())"
 emitLine(" \(presentI32) = call i32 @bk_dict_contains(ptr \(raw), ptr \(keyBoxPtr), i32 \(keyWidth), i32 \(keyTag))")
 let present = "%t\(nextTemp())"
 emitLine(" \(present) = icmp ne i32 \(presentI32), 0")
 // 正常生成读（缺失补零值），再 stringify；命中取之，缺失取 "null"。
 let val = try generateExpression(expr)
 let valStr = try generateStringify(val, resolveExprTypeAnnotation(expr))
 let nullStr = try generateStringLiteral("null")
 let sel = "%t\(nextTemp())"
 emitLine(" \(sel) = select i1 \(present), ptr \(valStr.ssaName), ptr \(nullStr.ssaName)")
 emitLine(" call i32 (ptr, ...) @printf(ptr @fmt_string, ptr \(sel))")
 return IRValue(llvmType: "void", ssaName: "")
 }

 func generateMultiArgPrint(_ arguments: [CallArgument]) throws -> IRValue {
 var fmtParts: [String] = []
 var values: [(type: String, ssa: String, isBool: Bool)] = []
 for arg in arguments {
 var val = try generateExpression(arg.expression)
 // T2（G-IR-enum-print）+ D3：聚合/容器/元组类型递归 stringify，对齐解释器展示语义。
 if isAggregateForStringify(val.llvmType) {
 val = try generateStringify(val, resolveExprTypeAnnotation(arg.expression))
 }
 let spec: String
 switch val.llvmType {
 case "i32": spec = "%d"
 case "double": spec = "%g"
 case "i1": spec = "%s"
 default: spec = "%s"
 }
 fmtParts.append(spec)
 values.append((val.llvmType, val.ssaName, val.llvmType == "i1"))
 }

 let fmt = fmtParts.joined(separator: " ") + "\n"
 let id = stringConstCounter; stringConstCounter += 1
 let name = "@.str\(id)"
 let fmtBytes = Array(fmt.utf8)
 let len = fmtBytes.count + 1
 var hex = ""
 for b in fmtBytes { hex += String(format: "\\%02X", b) }
 pendingStringConstants.append("\(name) = private constant [\(len) x i8] c\"\(hex)\\00\"")

 let fmtPtr = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: fmtPtr, aggregate: "[\(len) x i8]", base: name, indices: [0, 0]))

 var callParts: [String] = ["ptr \(fmtPtr)"]
 for v in values {
 if v.isBool {
 let sel = "%t\(nextTemp())"
 emitLine(" \(sel) = select i1 \(v.ssa), ptr @fmt_bool_true, ptr @fmt_bool_false")
 callParts.append("ptr \(sel)")
 } else {
 callParts.append("\(v.type) \(v.ssa)")
 }
 }
 emitLine(" call i32 (ptr, ...) @printf(\(callParts.joined(separator: ", ")))")
 return IRValue(llvmType: "void", ssaName: "")
 }

 func generateStringLiteral(_ value: String) throws -> IRValue {
 let bytes = Array(value.utf8)
 let len = bytes.count + 1
 let id = stringConstCounter
 stringConstCounter += 1
 let name = "@.str\(id)"
 var hex = ""
 for b in bytes { hex += String(format: "\\%02X", b) }
 pendingStringConstants.append("\(name) = private constant [\(len) x i8] c\"\(hex)\\00\"")
 let gep = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: gep, aggregate: "[\(len) x i8]", base: name, indices: [0, 0]))
 return IRValue(llvmType: "ptr", ssaName: gep)
 }

 /// 字符串插值打印：`print("x=\(x) y=\(y)")`。
 /// 将各段拼成**单个 printf 格式串**：literal 段原样写入（`%` 转义为 `%%`），
 /// expression 段按其 IR 类型选择 `%d`/`%f`/`%s` 格式符并作为变参传入。
 /// 格式串常量走与 `generateStringLiteral` 相同的机制（pending 后随函数体 flush）。
 func generateInterpolationPrint(_ segments: [InterpolationSegment]) throws -> IRValue {
 var fmtBytes: [UInt8] = []
 var argValues: [(llvmType: String, ssaName: String)] = []

 for seg in segments {
 switch seg {
 case .literal(let text):
 // 转义 %，避免被 printf 误当作格式符
 for b in text.utf8 {
 if b == 0x25 { fmtBytes.append(0x25) }
 fmtBytes.append(b)
 }
 case .expression(let expr):
 let val = try generateExpression(expr)
 switch val.llvmType {
 case "i32":
 fmtBytes.append(contentsOf: Array("%d".utf8))
 argValues.append((val.llvmType, val.ssaName))
 case "double":
 fmtBytes.append(contentsOf: Array("%f".utf8))
 argValues.append((val.llvmType, val.ssaName))
 case "i1":
 // Bool 收口：select 出 "true"/"false" 指针，按 %s 输出
 // （与解释器及 print(bool) 一致，不再输出 1/0）
 let sel = "%t\(nextTemp())"
 emitLine(" \(sel) = select i1 \(val.ssaName), ptr @fmt_bool_true, ptr @fmt_bool_false")
 fmtBytes.append(contentsOf: Array("%s".utf8))
 argValues.append(("ptr", sel))
 default:
 // D3（T1 收口）：聚合/容器类型（IR 中以 `%` 前缀命名，如枚举/结构/集合/对象）
 // 经 `generateStringify` 递归格式化（对齐解释器展示语义），不再 fail-loud。
 // 其余（ptr 字符串）按 %s 正常输出。
 if isAggregateForStringify(val.llvmType) {
 let str = try generateStringify(val, resolveExprTypeAnnotation(expr))
 fmtBytes.append(contentsOf: Array("%s".utf8))
 argValues.append(("ptr", str.ssaName))
 } else {
 fmtBytes.append(contentsOf: Array("%s".utf8))
 argValues.append((val.llvmType, val.ssaName))
 }
 }
 }
 }

 // 生成格式串常量（与 generateStringLiteral 同机制）
 let len = fmtBytes.count + 1
 let id = stringConstCounter
 stringConstCounter += 1
 let name = "@.str\(id)"
 var hex = ""
 for b in fmtBytes { hex += String(format: "\\%02X", b) }
 pendingStringConstants.append("\(name) = private constant [\(len) x i8] c\"\(hex)\\00\"")

 let gep = "%t\(nextTemp())"
 emitLine(builder.fmtGEP(name: gep, aggregate: "[\(len) x i8]", base: name, indices: [0, 0]))

 var callArgs: [String] = []
 for (t, s) in argValues {
 callArgs.append("\(t) \(s)")
 }
 let argList = callArgs.isEmpty ? "" : ", " + callArgs.joined(separator: ", ")
 emitLine(" call i32 (ptr, ...) @printf(ptr \(gep)\(argList))")
 return IRValue(llvmType: "void", ssaName: "")
 }
}
