import Foundation

public final class IRGenerator {

 var ir = ""

 var loopStack: [(exitLabel: String, condLabel: String, stepLabel: String?, stepContinueLabel: String?, enclosingDepth: Int, label: String?, isLoop: Bool)] = []

 var symbolTable: [String: (slot: String, type: String)] = [:]

 var typeMapper = IRTypeMapper()

 /// struct 类型注册表：类型名 -> 完整声明（供构造/字段访问解析）。
 var structTypes: [String: StructDecl] = [:]

 /// object 类型注册表：类型名 -> 完整声明（引用类型，含 refcount 头；供构造/字段访问解析）。
 var objectTypes: [String: ObjectDecl] = [:]

 /// enum 声明注册表：枚举名 -> 完整声明（供 match 分发 / 类型映射解析）。
 var enumDecls: [String: EnumDecl] = [:]

 /// enum case → (所属枚举名, tag 序号, 关联参数列表) 映射；键为「限定名」`父. case`
 /// （P5-5 B4：支持跨枚举同名 case，避免单值 case 名被后者覆盖导致串味）。
 /// 关联参数列表用于构造（call 路径）和 match 绑定（payload 提取）。
 var enumCaseTags: [String: (enumName: String, tag: Int, params: [AssociatedParam])] = [:]

 /// P5-5 B4：未限定构造 `圆(...)` 的反查表：case 名 → 其所属枚举的「限定键」列表。
 /// 唯一 → 解析到该键；多父 → 歧义（codegen 报不支持）；空 → 非枚举构造，回退函数调用路径。
 var enumCaseUnqualified: [String: [String]] = [:]

 /// defer 延迟执行语句栈（LIFO 逆序在 return / 函数出口前发射）。
 /// 与 `deferDepths` 平行：每条的注册作用域深度（currentScopeDepth），供**块级** defer 在
 /// 块自然落入出口刷新（对齐解释器 deferStack 逐块语义，见 #8 defer.pini 修复）。
 var deferredStatements: [Statement] = []
 var deferDepths: [Int] = []

 /// #46-D D4.2.3+：分层作用域栈。每层是该块**直接声明**的集合局部（快照 slot/type，解 P2 释放错位）。
 /// 进入块 push 空层、块「自然落入」出口释放本层并 pop；函数/闭包顶层为 `scopeStack[0]`。
 /// 仅「自然落入」边释放（结构化语言保证块末变量必初始化）→ 零 UAF；`return`/`break`/`continue` 终止边不释放（已知无害残留）。
 var scopeStack: [[ScopeVar]] = []
 /// #46-D D4.2.3：当前嵌套块深度（= `scopeStack.count - 1` 的同义视图，供 generateBlock 等维护）。
 var currentScopeDepth: Int = 0

 var funcReturnIRTypes: [String: String] = [:]

 /// 泛型函数模板存储：函数名 -> 原始 FuncDecl（在 specialization 时使用）。
 var genericTemplates: [String: FuncDecl] = [:]

 /// 泛型特化缓存：`"identity<I32>"` -> 特化后的 mangled 函数名 `"identity_I32"`。
 var specializedCache: [String: String] = [:]

 /// 待生成的特化函数体队列（延迟到顶层函数之后，避免嵌套在调用方函数体内）。
 var pendingSpecializations: [(fd: FuncDecl, receiverIRType: String?)] = []

 /// P6-4d: trait 定义注册表：trait 名 → 方法签名列表。
 var traitSignatures: [String: [FuncDecl]] = [:]

 /// P6-4d: 类型 → 实现的 trait 名列表映射。
 var typeTraits: [String: [String]] = [:]

 var stringConstCounter = 0

 var pendingStringConstants: [String] = []

 /// 阶段 B：闭包 env 结构类型声明（如 `%__closure_env_0 = type { ptr, ptr }`），延迟插入模块头，
 /// 保证被创建点的 getelementptr 引用前已声明。
 var pendingClosureTypeDecls: [String] = []

 var headerEndOffset = 0 // globals + types 结束位置，运行时新增常量插入于此

 /// #46-D / ADR-008：当前模块是否用到集合后端。
 /// 任一 `@bk_*` 调用点（数组字面量/下标/len）置 true；模块末尾据此追加
 /// `%bk_array = type { ptr }` 与 `@bk_*` 声明（前向引用已验证合法，避免预扫描）。
 /// 非集合程序保持 false → 不追加任何声明 → 现有 golden IR 字节级不变。
 var usesCollections = false

 /// #46-D D1：codegen 侧数组元素 Pini 类型表（变量名 → 元素类型）。
 /// 不触碰类型系统（类型层数组仍推断为 nil，保持「语义不变」护栏）：仅在 `let`/`var`
 /// 绑定到数组字面量时记录首元素类型，供 `generateSubscriptRead` 解析元素 LLVM 类型。
 /// 字面量直接下标 `[e...][i]` 不经此表，改为直查字面量首元素（见 ExprEmitter.resolveArrayElementType）。
 var arrayElementTypeByVar: [String: TypeAnnotation] = [:]

 /// #46-D D2：变量绑定到字典字面量时，记录其「键 / 值」首元素 Pini 类型到下表，
 /// 供 `generateSubscriptRead`/`generateSubscriptWrite` 解析值 LLVM 类型（不触碰类型系统，与 D1 同护栏）。
 /// 键类型经自包含 `elementTypeOfLiteral` 推断（字面量），不依赖 TypeInference，故单元测路径（typeInference 为 nil）亦能记录。
 var dictKeyTypeByVar: [String: TypeAnnotation] = [:]
 var dictValueTypeByVar: [String: TypeAnnotation] = [:]
 /// #46-D D3：变量绑定到集合字面量时，记录其元素 Pini 类型，供 `print` 容器格式化（`generateStringify`）推断元素类型。
 var setElementTypeByVar: [String: TypeAnnotation] = [:]

 /// 批次 1.3（D1）：变量绑定到元组字面量时，记录其 Pini 元组类型（labels + 元素类型），
 /// 供 `print` 元组格式化（`generateStringifyTuple`）显示命名标签与递归格式化嵌套元素。
 /// 不触碰类型系统：与容器 `*ByVar` 同护栏（无类型则不显示标签，不臆造）。
 var tupleTypeByVar: [String: TypeAnnotation] = [:]

 /// #46-optional / Task #1：LLVM 管线先类型检查后注入（见 `PiniCLI` 三命令路径）。
 /// `match a:` 解构 `Optional.some(v)` 时需 concrete T，而 Optional 单一无类型 IR、
 /// AST 不携带类型，故在 codegen 前经 `TypeChecker.check` 推导后复用其 `infer`。
 /// 默认 nil —— 既有单元测试直接 `IRGenerator().generate`（零类型信息）路径不受影响，
 /// golden IR 字节级不变；仅 CLI 与实际 run-llvm 测试注入后启用。
 public var typeInference: TypeInference? = nil

 // MARK: - 阶段 B：一等函数 + 闭包（匿名函数提升 / 间接调用 / 捕获环境）
 /// 闭包（funcLiteral）提升信息。每个匿名函数在模块预遍历中分配稳定 id；
 /// 首次被求值（创建点）时计算捕获变量并标记 computed，定义延迟到模块末尾发射。
 struct ClosureInfo {
 let id: Int
 let mangledName: String
 let body: Block
 var returnIRType: String = "void"
 var captured: [(name: String, irType: String, fieldIndex: Int)] = []
 var paramNames: [String] = []
 var paramIRTypes: [String] = []
 var computed: Bool = false
 }

 /// 闭包注册表，键为 `funcLiteral.location` 的 "行:列"（AST 节点级稳定标识）。
 var closures: [String: ClosureInfo] = [:]

 /// 待拼接的闭包模块级定义（env 结构类型 + define 体），在 generate(module:) 末尾追加。
 var closureDefsIR = ""

 /// 绑定到函数类型的值（闭包变量 / 高阶函数参数 / 具名函数作为值）的返回 IR 类型，
 /// 供间接调用 `call <ret>` 确定返回类型。
 var funcValueReturnTypes: [String: String] = [:]

 /// 已知顶层/全局函数名（unmangled），供「把具名函数当作值传递」生成函数指针。
 var knownTopLevelFuncs: Set<String> = []

 /// R4：标量 match 字符串比较用到 `@strcmp` 时置位，模块末尾条件追加声明（golden IR 不变）。
 var usesStrCmp = false

 /// #46-E G41（R2）：assert 内建用到 `@bk_panic` 时置位，模块末尾条件追加声明（golden IR 不变）。
 var usesAssert = false

 /// #46-E G40（S3 LLVM 端）：LazyRef 用到 `%bk_lazyref` / `@bk_lazyref_*` 时置位，条件追加声明。
 var usesLazyRef = false
 /// LazyRef 类型特化 wrapper 定义缓冲（`define ptr @__lazyref_wrapper_<T>(ptr %code, ptr %env)`），
 /// 模块末尾随 adapterDefsIR 一起发射。key = T 的 IR 类型字符串，去重。
 var lazyrefWrappersIR = ""
 var lazyrefWrapperSet: Set<String> = []
 /// LazyRef 变量 → 元素 T 的 IR 类型（`.value` load 需要）；varDecl 时从 `LazyRef<T>` 显式类型登记。
 var lazyRefValueTypeByVar: [String: String] = [:]

 /// 具名函数的形参 IR 类型（mangled → [paramIRType]），供「函数作为值」的 env 忽略适配器构造。
 var funcParamIRTypes: [String: [String]] = [:]

 /// 具名函数作为值 → 适配器 `@__adapter_<mangled>(ptr %env, args...) { call @<mangled>(args...) }`：
 /// 对齐闭包 ABI（code 恒收 env 首参），修复 named function 被间接调用时 ABI 错位（#8 higher-order）。
 /// 去重：同一函数只生成一次适配器。定义体拼接进 `adapterDefsIR`，模块末尾随 closureDefsIR 一起发射。
 var adapterDefsIR = ""
 var adapterSet: Set<String> = []

 var closureCounter = 0

 /// #46-A：共享 IR 构建器（集中指令格式 + temp/label 计数器）。不持有 `ir` 缓冲区，
 /// 调用方经 `builder.fmtX` 取字节级确定的指令行、`emitLine` 落盘，golden IR 零差异。
 var builder = IRBuilder()

 public init() {}

 public func generate(module: Module) throws -> String {
 ir = ""
 builder.reset()
 symbolTable = [:]
 stringConstCounter = 0
 pendingStringConstants = []
 pendingClosureTypeDecls = []
 traitSignatures = [:]
 typeTraits = [:]
 usesCollections = false
 usesStrCmp = false
 usesAssert = false
 usesLazyRef = false
 lazyrefWrappersIR = ""
 lazyrefWrapperSet = []
 lazyRefValueTypeByVar = [:]
 arrayElementTypeByVar = [:]
 dictKeyTypeByVar = [:]
 dictValueTypeByVar = [:]
 setElementTypeByVar = [:]
 tupleTypeByVar = [:]

 try emitGlobals()
 emitPendingStringConstants()
 try emitStructTypeDecls()
 try emitObjectTypeDecls()
 try emitEnumTypeDecls()
 headerEndOffset = ir.count // 记录 header 结束位置，供运行时常量插入

 // 预遍历：收集 struct / object / enum 类型定义，供类型映射与构造/字段访问/match 解析
 // ADR-016 规则 3.2/3.14：先收集扩展块方法，合并进目标类型的方法表（类型声明与扩展块可任意顺序）。
 var extMethodsByType: [String: [FuncDecl]] = [:]
 for decl in module.declarations {
 if case .extensionDecl(let x) = decl, x.kind != .traitExt {
 extMethodsByType[x.targetType, default: []].append(contentsOf: x.methods)
 }
 }
 for decl in module.declarations {
 if case .structDecl(let sd) = decl {
 structTypes[mangle(sd.name)] = StructDecl(
 name: sd.name, genericParams: sd.genericParams, fields: sd.fields,
 methods: sd.methods + (extMethodsByType[sd.name] ?? []),
 composedType: sd.composedType, traits: sd.traits, location: sd.location)
 if !sd.traits.isEmpty { typeTraits[mangle(sd.name)] = sd.traits }
 } else if case .objectDecl(let od) = decl {
 objectTypes[mangle(od.name)] = ObjectDecl(
 name: od.name, genericParams: od.genericParams, fields: od.fields,
 methods: od.methods + (extMethodsByType[od.name] ?? []),
 traits: od.traits, location: od.location)
 if !od.traits.isEmpty { typeTraits[mangle(od.name)] = od.traits }
 } else if case .enumDecl(var ed) = decl {
 // Mangle associated param types
 ed = EnumDecl(name: ed.name, genericParams: ed.genericParams,
 cases: ed.cases.map { ec in
 EnumCase(name: ec.name,
 associatedParams: ec.associatedParams.map { ap in
 AssociatedParam(name: ap.name, type: mangleTypeAnnotation(ap.type),
 defaultValue: ap.defaultValue)
 }, location: ec.location)
 },
 methods: ed.methods + (extMethodsByType[ed.name] ?? []),
 location: ed.location)
 enumDecls[mangle(ed.name)] = ed
 for (tag, ec) in ed.cases.enumerated() {
 let mangledParams = ec.associatedParams.map { ap in
 AssociatedParam(
 name: ap.name,
 type: mangleTypeAnnotation(ap.type),
 // 保留关联值默认表达式（字面量默认），供构造期按默认补位；
 // 否则 run-llvm 会漏写 payload（未初始化内存，输出乱码）。
 defaultValue: ap.defaultValue
 )
 }
 let qualifiedKey = "\(mangle(ed.name)).\(ec.name)" // P5-5 B4：限定键
 enumCaseTags[qualifiedKey] = (enumName: mangle(ed.name), tag: tag, params: mangledParams)
 enumCaseUnqualified[ec.name, default: []].append(qualifiedKey)
 }
 }
 }
 // R1.1：结构体内嵌组合——合并 composedType 父类型的字段/方法进子类型
 // （对齐解释器 mergeComposedType：子在前、父未覆盖项随后、同名子覆盖父）。
 mergeComposedStructTypes()
 // R2：预扫描泛型 struct 构造（`盒<I32>()`）并预注册单态化，使特化类型声明
 // 先于任何函数体（含 alloca）经 emitStructTypeDecls 发射。
 for decl in module.declarations {
 precollectGenericStructUses(in: decl)
 }
 try registerBuiltinOptional()
 typeMapper.setKnownStructs(Set(structTypes.keys))
 typeMapper.setKnownObjects(Set(objectTypes.keys))
 typeMapper.setKnownEnums(Set(enumDecls.keys))
 // 同时注册原始名→mangled IR 名映射（供 typeMapper 输出正确 IR 类型）
 for sd in structTypes.values { typeMapper.addKnownStruct(name: sd.name, irName: mangle(sd.name)) }
 for od in objectTypes.values { typeMapper.addKnownObject(name: od.name, irName: mangle(od.name)) }
 for ed in enumDecls.values { typeMapper.addKnownEnum(name: ed.name, irName: mangle(ed.name)) }
 try emitStructTypeDecls()
 try emitObjectTypeDecls()
 try emitEnumTypeDecls()

 // 预注册所有函数返回类型，避免前向引用时 generateCall 回退到 "i32"（D2 修复）
 for decl in module.declarations {
 if case .funcDecl(let fd) = decl {
 if fd.genericParams.isEmpty {
 try registerFuncReturnType(fd)
 } else {
 // P6-4b: 存储泛型模板，特化在 call site 发生时执行
 genericTemplates[mangle(fd.name)] = fd
 }
 }
 // P6-4d: 存储 trait 定义
 if case .traitDecl(let td) = decl {
 traitSignatures[td.name] = td.signatures
 }
 // 注册 struct/object/enum 内的方法函数（R2：泛型 struct 模板的方法含未替换类型参数，
 // 跳过预注册——由 generateGenericStructConstruct 单态化后在构造点注册特化版本）。
 let methods: [FuncDecl] = {
 switch decl {
 case .structDecl(let s): return s.genericParams.isEmpty ? s.methods : []
 case .objectDecl(let o): return o.methods
 case .enumDecl(let e): return e.methods
 default: return []
 }
 }()
 for md in methods where md.genericParams.isEmpty {
 try registerFuncReturnType(md)
 }
 }

 // 阶段 B：预遍历收集所有匿名函数（funcLiteral）并分配稳定 id；登记顶层函数名
 // （供「具名函数作为值传递」生成函数指针）。
 for decl in module.declarations {
 if case .funcDecl(let fd) = decl { knownTopLevelFuncs.insert(fd.name) }
 collectFuncLiterals(in: decl)
 }

 for decl in module.declarations {
 switch decl {
 case .funcDecl(let fd):
 try generateFuncDecl(fd)
 case .structDecl(let sd):
 // R1.1：方法从「合并后」的 structTypes 生成（含组合父类型方法）；组合类型
 // 的所有方法用「接收者特化名」发射（父/子同名方法各自按自身布局编译，避免
 // `@mangle(方法名)` 撞名/错布局），非组合类型保持 name-only（golden IR 不变）。
 // R2：泛型 struct 模板（genericParams 非空）方法不在此生成——由
 // generateGenericStructConstruct 在构造点单态化后入队 pendingSpecializations。
 let merged = structTypes[mangle(sd.name)] ?? sd
 guard merged.genericParams.isEmpty else { break }
 for md in merged.methods {
 try generateFuncDecl(md, receiverIRType: "%struct.\(mangle(merged.name))*",
 composedMethodSuffix: merged.composedType != nil ? mangle(merged.name) : nil)
 }
 // 类型定义已在 emitStructTypeDecls() 预遍历阶段 emit
 case .objectDecl(let od):
 for md in od.methods { try generateFuncDecl(md, receiverIRType: "%object.\(mangle(od.name))*") }
 // 类型定义已在 emitObjectTypeDecls() 预遍历阶段 emit
 case .enumDecl(let ed):
 for md in ed.methods { try generateFuncDecl(md, receiverIRType: "%enum.\(mangle(ed.name))*") }
 // 类型定义已在 emitEnumTypeDecls() 预遍历阶段 emit
 case .traitDecl:
 // P6-4d: trait 定义已在预注册阶段存储，此处无额外生成
 break
 case .extensionDecl:
 // 扩展块方法已在上方预遍历合并进 structTypes/objectTypes/enumDecls，
 // 随类型一并生成，此处无需单独发射。
 break
 case .foreignDecl:
 // Phase 2a（ADR-015 FFI）：LLVM 端 foreign 显式 unsupported（用户决策 D1，解释器优先）。
 throw IRGenError.unsupportedFeature(
 "LLVM 后端暂不支持 `[名称|foreign]` 块；请改用解释器 `pini run`",
 SourceLocation(line: 0, column: 0, fileName: ""))
 case .varDecl, .statement, .importDecl, .exportDecl:
 throw IRGenError.unsupportedFeature("top-level statement/var",
 SourceLocation(line: 0, column: 0, fileName: ""))
 }
 }

 // P6-4b: 生成所有待特化的函数体（延迟到顶层函数之后，避免嵌套）
 while !pendingSpecializations.isEmpty {
 let batch = pendingSpecializations
 pendingSpecializations = []
 for (fd, receiverIRType) in batch {
 try generateFuncDecl(fd, receiverIRType: receiverIRType)
 }
 }

 // 阶段 B：生成所有被创建过的闭包的模块级定义（延迟到顶层函数与特化之后，
 // 保证 SSA 命名空间唯一、env 结构类型声明就位）。定义体缓存在 closureDefsIR，随后拼接。
 for info in closures.values where info.computed {
 try generateClosureDefine(info)
 }
 ir += closureDefsIR
 // #8：具名函数作为值的 env 忽略适配器（`@__adapter_<mangled>`）紧随闭包定义拼接。
 ir += adapterDefsIR
 // #46-E G40（S3）：LazyRef 类型特化 wrapper（`@__lazyref_wrapper_<T>`）紧随适配器拼接。
 ir += lazyrefWrappersIR

 emitPendingStringConstants()

 // #46-D / ADR-008：集合后端运行时声明。
 // 前向引用已验证合法（llvm-as 通过），故置于模块末尾、依据 usesCollections 条件追加，
 // 避免预扫描；非集合程序不追加 → golden IR 字节级不变。
 if usesCollections {
 ir += "\n; 运行时集合后端（ADR-008：Swift shim，C ABI opaque handle）\n"
 ir += "%bk_array = type { ptr }\n"
 ir += "declare ptr @bk_array_create(i32)\n"
 ir += "declare ptr @bk_array_set(ptr, i32, ptr, i32, i32)\n"
 ir += "declare ptr @bk_array_get(ptr, i32)\n"
 ir += "declare i32 @bk_array_len(ptr)\n"
 ir += "%bk_dict = type { ptr }\n"
 ir += "declare ptr @bk_dict_create()\n"
 ir += "declare ptr @bk_dict_set(ptr, ptr, i32, i32, ptr, i32, i32)\n"
 ir += "declare ptr @bk_dict_get(ptr, ptr, i32, i32)\n"
 ir += "declare i32 @bk_dict_len(ptr)\n"
 ir += "%bk_set = type { ptr }\n"
 ir += "declare ptr @bk_set_create()\n"
 ir += "declare ptr @bk_set_add(ptr, ptr, i32, i32)\n"
 ir += "declare i32 @bk_set_len(ptr)\n"
 ir += "declare ptr @bk_dict_key_at(ptr, i32)\n"
 ir += "declare ptr @bk_dict_val_at(ptr, i32)\n"
 ir += "declare ptr @bk_set_at(ptr, i32)\n"
 ir += "declare i32 @bk_dict_contains(ptr, ptr, i32, i32)\n"
 // #46-D D4（COW）：显式 share count 与写时分裂原语（类型无关，见 PiniRuntime 所有权契约）。
 ir += "declare void @bk_handle_retain(ptr)\n"
 ir += "declare ptr @bk_handle_ensure_unique(ptr)\n"
 ir += "declare ptr @bk_array_ensure_unique_at(ptr, i32)\n"
 ir += "declare ptr @bk_dict_ensure_unique_at(ptr, ptr, i32, i32)\n"
 // #46-D D4.2.3：出口精确释放——句柄离开作用域/重赋值时递减一份 share（_bkReleaseShare）。
 ir += "declare void @bk_array_destroy(ptr)\n"
 ir += "declare void @bk_dict_destroy(ptr)\n"
 ir += "declare void @bk_set_destroy(ptr)\n"
 }
 // G41（test 块，R2）：assert 内建失败路径——bk_panic 打印消息到 stderr 并 abort（不返回）。
 if usesAssert {
 ir += "declare void @bk_panic(ptr)\n"
 }
 // G40（S3）：LazyRef 类型 + C ABI（once 锁求值、统一 ptr ABI）。
 if usesLazyRef {
 ir += "%bk_lazyref = type { ptr }\n"
 ir += "declare ptr @bk_lazyref_create(ptr, ptr, ptr, i32, i32)\n"
 ir += "declare ptr @bk_lazyref_value(ptr)\n"
 ir += "declare void @bk_lazyref_destroy(ptr)\n"
 }
 // R4：标量 match 字符串比较（strcmp==0）用到的声明，条件追加（golden IR 不变）。
 if usesStrCmp {
 ir += "declare i32 @strcmp(ptr, ptr)\n"
 }

 return ir
 }

 func sl() -> SourceLocation { SourceLocation(line: 0, column: 0, fileName: "") }

 /// 将非 ASCII 标识符 hex-encode 为 LLVM IR 兼容的名称（`点` → `_u70B9`）。
 func mangle(_ name: String) -> String {
 var needs = false
 for c in name.utf8 { if c > 127 { needs = true; break } }
 if !needs { return name }
 var r = ""
 for c in name.unicodeScalars {
 if c.value < 128 { r.append(Character(c)) }
 else { r += "_u" + String(format: "%04X", c.value) }
 }
 return r
 }

 // MARK: - 工具方法

 func emitLine(_ line: String) {
 ir += line + "\n"
 }

 func nextTemp() -> Int { builder.freshTempIndex() }

 func nextLabel() -> Int { builder.freshLabel() }

 /// R1.1：结构体内嵌组合——把 `composedType` 父类型的字段/方法递归合并进子类型。
 ///
 /// 对齐解释器 `mergeComposedType` 语义：**子类型自己的字段/方法在前**，父类型中未被子类型
 /// 同名覆盖的项随后追加（同名子覆盖父）；嵌套组合（A 组合 B 组合 C）递归解析，`visited` 防环。
 /// 合并后 `structTypes[name].fields/.methods` 即最终的 IR 布局与分派表，后续
 /// `emitStructTypeDecls` / `resolveMemberField` / 方法生成全部自动对齐（composition.pini 修复）。
 private func mergeComposedStructTypes() {
 func merged(_ sd: StructDecl, _ visited: inout Set<String>) -> (fields: [FieldDecl], methods: [FuncDecl]) {
 guard let parentName = sd.composedType,
 let parent = structTypes[mangle(parentName)] else {
 return (sd.fields, sd.methods)
 }
 let pKey = mangle(parentName)
 guard !visited.contains(pKey) else { return (sd.fields, sd.methods) }
 visited.insert(pKey)
 let (pFields, pMethods) = merged(parent, &visited)
 let childFieldNames = Set(sd.fields.map { $0.name })
 let childMethodNames = Set(sd.methods.map { $0.name })
 let fields = sd.fields + pFields.filter { !childFieldNames.contains($0.name) }
 let methods = sd.methods + pMethods.filter { !childMethodNames.contains($0.name) }
 return (fields, methods)
 }
 let keys = Array(structTypes.keys)
 for name in keys {
 guard let sd = structTypes[name], sd.composedType != nil else { continue }
 var visited: Set<String> = [name]
 let (fields, methods) = merged(sd, &visited)
 structTypes[name] = StructDecl(name: sd.name, genericParams: sd.genericParams,
 fields: fields, methods: methods,
 composedType: sd.composedType,
 traits: sd.traits, location: sd.location)
 }
 }

 func formatFloat(_ value: Double) -> String {
 if value.isNaN || value.isInfinite {
 return String(value)
 }
 if value == Double(Int64(value)) && abs(value) < 1e15 {
 return String(format: "%.1f", value)
 }
 return String(value)
 }
}
