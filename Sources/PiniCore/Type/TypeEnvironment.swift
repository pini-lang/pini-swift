import Foundation

/// 类型环境
/// 管理作用域栈，追踪变量类型、函数签名、类型字段与方法
public final class TypeEnvironment {
 private struct Scope {
 var variables: [String: TypeAnnotation] = [:]
 var variableMutable: [String: Bool] = [:]
 var functions: [String: FunctionSignature] = [:]
 }

 public struct FunctionSignature {
 public let params: [TypeAnnotation]
 public let returns: [TypeAnnotation]
 public let isVariadic: Bool

 public init(params: [TypeAnnotation], returns: [TypeAnnotation], isVariadic: Bool = false) {
 self.params = params
 self.returns = returns
 self.isVariadic = isVariadic
 }
 }

 private var scopes: [Scope] = [Scope()]
 private var typeFields: [String: [String: TypeAnnotation]] = [:]
 private var typeMethods: [String: [String: FunctionSignature]] = [:]

 /// 持久变量类型表：供 **codegen 事后 re-infer** 使用（#46-optional / Task #1）。
 /// `defineVariable` 同时写入此表且**作用域 pop 不清除**——因为 `TypeChecker.check`
 /// 在函数体退出时会 pop 子作用域，局部变量从作用域栈消失，若 codegen 再经
 /// `TypeInference.infer(.identifier)` 重推 scrutinee 类型会取不到。此表保留定义处类型，
 /// 作为 `lookupVariable` 的兜底（check 期间作用域栈优先，本表仅在栈中查不到时生效）。
 private var persistentVarTypes: [String: TypeAnnotation] = [:]

 /// #46-optional：持久表兜底开关。**默认 false**——保持「作用域弹出后变量不可见」语义
 /// （`TypeCheckerTests.testTypeEnvVariableDefineAndLookup` 等单测依赖），不污染类型检查。
 /// 仅在 LLVM codegen 重推阶段由 CLI / run-llvm 测试显式置 true（check 结束后作用域栈已收敛）。
 public var persistAcrossScopesForCodegen = false

 public init() {}

 // MARK: - Scope management

 public func pushScope() {
 scopes.append(Scope())
 }

 public func popScope() {
 guard scopes.count > 1 else { return }
 scopes.removeLast()
 }

 // MARK: - Variables

 public func defineVariable(name: String, type: TypeAnnotation, isMutable: Bool = true) {
 let idx = scopes.count - 1
 scopes[idx].variables[name] = type
 scopes[idx].variableMutable[name] = isMutable
 persistentVarTypes[name] = type
 }

 public func lookupVariable(name: String) -> TypeAnnotation? {
 for scope in scopes.reversed() {
 if let t = scope.variables[name] {
 return t
 }
 }
 // 仅当作用域栈已收敛到根（check 结束后 codegen 事后 re-infer）且开关开启时兜底查持久表；
 // 检查进行中（count>1）或开关关闭时不启用，避免屏蔽「变量未声明/越作用域」错误、
 // 也不破坏「作用域弹出后变量不可见」的既有单测语义。
 if scopes.count == 1, persistAcrossScopesForCodegen {
 return persistentVarTypes[name]
 }
 return nil
 }

 /// 查询变量是否可变（对应 `var`/`let`）。`let` 声明返回 false；未记录（理论上不应发生）返回 true 以示不阻止。
 public func lookupVariableMutability(name: String) -> Bool? {
 for scope in scopes.reversed() {
 if let m = scope.variableMutable[name] {
 return m
 }
 }
 return nil
 }

 // MARK: - Functions

 public func defineFunction(name: String, params: [TypeAnnotation], returns: [TypeAnnotation], isVariadic: Bool = false) {
 let sig = FunctionSignature(params: params, returns: returns, isVariadic: isVariadic)
 scopes[scopes.count - 1].functions[name] = sig
 }

 public func lookupFunction(name: String) -> FunctionSignature? {
 for scope in scopes.reversed() {
 if let sig = scope.functions[name] {
 return sig
 }
 }
 return nil
 }

 // MARK: - Type fields and methods

 public func defineStruct(name: String, fields: [(name: String, type: TypeAnnotation)]) {
 var fieldMap: [String: TypeAnnotation] = [:]
 for f in fields {
 fieldMap[f.name] = f.type
 }
 typeFields[name] = fieldMap
 }

 public func lookupField(typeName: String, fieldName: String) -> TypeAnnotation? {
 return typeFields[typeName]?[fieldName]
 }

 /// 取某类型的**全部字段类型**。B3-1 任务隔离用它递归下钻，识别「引用藏在 struct 字段里」的偷渡。
 /// 返回 nil 表示该名字不是已登记的聚合类型（如内建类型或未知类型）。
 public func lookupFieldTypes(typeName: String) -> [TypeAnnotation]? {
 guard let fields = typeFields[typeName] else { return nil }
 // 按字段名排序，保证递归下钻时命中的"首个引用类型"稳定可复现（Dictionary 遍历顺序不定）
 return fields.sorted { $0.key < $1.key }.map { $0.value }
 }

 public func defineMethod(typeName: String, methodName: String, params: [TypeAnnotation], returns: [TypeAnnotation]) {
 let sig = FunctionSignature(params: params, returns: returns)
 if typeMethods[typeName] == nil {
 typeMethods[typeName] = [:]
 }
 typeMethods[typeName]?[methodName] = sig
 }

 public func lookupMethod(typeName: String, methodName: String) -> FunctionSignature? {
 return typeMethods[typeName]?[methodName]
 }

 /// 内建泛型类型（Array 等）的元素类型参数占位名。内建方法签名用它表达
 /// 「与接收者元素类型相同」，查找时按接收者的类型实参代入。
 private static let builtinElementParam = "T"

 /// 成员方法签名查找的统一入口：先按**用户泛型**特化，再按**内建泛型**代入。
 ///
 /// 修复 H2（2026-08-30）：此前 `Array<Token>.append` 走 `lookupMethod` 直接返回
 /// 登记的 `Array<Any>`，元素类型在返回处被擦除，类型化累积器无法存活。
 ///
 /// - Parameter typeArgs: 接收者的类型实参；`nil` = 接收者无类型实参（退化场景），
 ///   此时占位 `T` 代入 `Any`，行为与修复前一致。
 public func lookupMethodSignature(
 typeName: String, typeArgs: [TypeAnnotation]?, methodName: String
 ) -> FunctionSignature? {
 if let args = typeArgs,
 let sig = lookupSpecializedMethod(typeName: typeName, typeArgs: args, methodName: methodName) {
 return sig
 }
 guard let sig = typeMethods[typeName]?[methodName] else { return nil }
 // 代入用的是占位类型，位置无语义（仅用于构造 TypeAnnotation），取空位置即可。
 let loc = SourceLocation(line: 0, column: 0, fileName: "")
 let element = typeArgs?.first ?? .simple(name: "Any", location: loc)
 let substitutor = TypeSubstitutor(bindings: [Self.builtinElementParam: element])
 return FunctionSignature(
 params: sig.params.map { substitutor.substitute(type: $0) },
 returns: sig.returns.map { substitutor.substitute(type: $0) }
 )
 }

 // MARK: - Traits

 /// trait 声明注册表：traitName -> TraitDecl（含方法签名，body 非空即默认实现）。
 private var traits: [String: TraitDecl] = [:]

 public func defineTrait(name: String, trait: TraitDecl) {
 traits[name] = trait
 }

 public func lookupTrait(name: String) -> TraitDecl? {
 return traits[name]
 }

 // MARK: - 内建类型 conformance 标记（ADR-020 步骤 A）

 /// 内建类型的特征遵循标记（typeName -> trait 集合）。仅承载声明：
 /// 用户源码里的 `实现: 特征` 仍走 verifyTraitConformance 严格校验，
 /// 内建标记不触发校验（内建方法由 registerBuiltinTypes 的 defineMethod
 /// 路径供给，逐方法严格校验随步骤 B 特征派发切换一并启用）。
 private var builtinConformances: [String: Set<String>] = [:]

 public func markConformance(typeName: String, traits: [String]) {
 builtinConformances[typeName, default: []].formUnion(traits)
 }

 public func conformsTo(typeName: String, traitName: String) -> Bool {
 return builtinConformances[typeName]?.contains(traitName) ?? false
 }

 // MARK: - Generic types

 private struct GenericTypeTemplate {
 let genericParams: [String]
 let fields: [(name: String, type: TypeAnnotation)]
 let methods: [(name: String, params: [TypeAnnotation], returns: [TypeAnnotation])]
 }

 private var genericTypes: [String: GenericTypeTemplate] = [:]

 public func defineGenericStruct(
 name: String,
 genericParams: [String],
 fields: [(name: String, type: TypeAnnotation)],
 methods: [(name: String, params: [TypeAnnotation], returns: [TypeAnnotation])] = []
 ) {
 genericTypes[name] = GenericTypeTemplate(
 genericParams: genericParams,
 fields: fields,
 methods: methods
 )
 }

 /// 返回已注册泛型类型的类型形参个数；未注册返回 nil（P2-2.3 用于实例化实参个数校验）。
 public func genericParamCount(name: String) -> Int? {
 return genericTypes[name]?.genericParams.count
 }

 public func lookupSpecializedField(
 typeName: String,
 typeArgs: [TypeAnnotation],
 fieldName: String
 ) -> TypeAnnotation? {
 guard let template = genericTypes[typeName] else { return nil }
 guard typeArgs.count == template.genericParams.count else { return nil }

 var bindings: [String: TypeAnnotation] = [:]
 for i in 0..<template.genericParams.count {
 bindings[template.genericParams[i]] = typeArgs[i]
 }
 let substitutor = TypeSubstitutor(bindings: bindings)

 for field in template.fields {
 if field.name == fieldName {
 return substitutor.substitute(type: field.type)
 }
 }
 return nil
 }

 public func lookupSpecializedMethod(
 typeName: String,
 typeArgs: [TypeAnnotation],
 methodName: String
 ) -> FunctionSignature? {
 guard let template = genericTypes[typeName] else { return nil }
 guard typeArgs.count == template.genericParams.count else { return nil }

 var bindings: [String: TypeAnnotation] = [:]
 for i in 0..<template.genericParams.count {
 bindings[template.genericParams[i]] = typeArgs[i]
 }
 let substitutor = TypeSubstitutor(bindings: bindings)

 for method in template.methods {
 if method.name == methodName {
 let subParams = method.params.map { substitutor.substitute(type: $0) }
 let subReturns = method.returns.map { substitutor.substitute(type: $0) }
 return FunctionSignature(params: subParams, returns: subReturns)
 }
 }
 return nil
 }

 // MARK: - Generic functions

 private struct GenericFunctionTemplate {
 let genericParams: [String]
 let params: [TypeAnnotation]
 let returns: [TypeAnnotation]
 }

 private var genericFunctions: [String: GenericFunctionTemplate] = [:]

 public func defineGenericFunction(
 name: String,
 genericParams: [String],
 params: [TypeAnnotation],
 returns: [TypeAnnotation]
 ) {
 genericFunctions[name] = GenericFunctionTemplate(
 genericParams: genericParams,
 params: params,
 returns: returns
 )
 }

 public func genericFunctionParamCount(name: String) -> Int? {
 return genericFunctions[name]?.genericParams.count
 }

 /// 把泛型函数签名中的类型形参 T 按实参 bindings 替换，得到特化 FunctionSignature。
 /// 供 TypeChecker 做端到端调用点比对（P3-0：T 占位通配——调用点把 T 绑定为实参类型后再比对）。
 public func lookupSpecializedFunctionSignature(
 name: String,
 typeArgs: [TypeAnnotation]
 ) -> FunctionSignature? {
 guard let tmpl = genericFunctions[name] else { return nil }
 guard typeArgs.count == tmpl.genericParams.count else { return nil }

 var bindings: [String: TypeAnnotation] = [:]
 for i in 0..<tmpl.genericParams.count {
 bindings[tmpl.genericParams[i]] = typeArgs[i]
 }
 let substitutor = TypeSubstitutor(bindings: bindings)

 let subParams = tmpl.params.map { substitutor.substitute(type: $0) }
 let subReturns = tmpl.returns.map { substitutor.substitute(type: $0) }
 return FunctionSignature(params: subParams, returns: subReturns)
 }

 // MARK: - Enums

 /// 判别联合注册表：enumName -> caseName -> 关联参数（字段名? + 类型）。
 /// 供 TypeChecker 实现「枚举变体 → 联合类型」可赋值性（判别联合子类型）与 match 模式绑定类型注入。
 private var enumCases: [String: [String: [(name: String?, type: TypeAnnotation)]]] = [:]
 private var enumCaseToParent: [String: String] = [:]
 /// 每个枚举用例「带默认值的关联值字段数」，供 arity 校验容忍字面量默认值。
 /// 键为 枚举名 → 用例名 → 默认值字段数。
 private var enumCaseDefaultedCounts: [String: [String: Int]] = [:]

 public func defineEnum(
 name: String,
 cases: [String: [(name: String?, type: TypeAnnotation)]],
 defaultedCounts: [String: Int] = [:]
 ) {
 enumCases[name] = cases
 enumCaseDefaultedCounts[name] = defaultedCounts
 for (caseName, _) in cases {
 enumCaseToParent[caseName] = name
 }
 }

 public func isEnum(name: String) -> Bool {
 return enumCases[name] != nil
 }

 public func lookupEnumCase(enumName: String, caseName: String) -> [(name: String?, type: TypeAnnotation)]? {
 return enumCases[enumName]?[caseName]
 }

 /// 取枚举用例的关联值字段，同时覆盖非泛型（`defineEnum`）与泛型（`defineGenericEnum`）两种注册。
 /// 泛型枚举返回的是**未特化**的原始字段（占位类型 `T` 等），仅供「仅校验 arity / 不依赖
 /// 期望类型的基础比对」使用；需要特化类型比对请改用 `lookupSpecializedEnumCase`。
 public func lookupEnumCaseFields(
 enumName: String, caseName: String
 ) -> [(name: String?, type: TypeAnnotation)]? {
 if let nonGeneric = enumCases[enumName] {
 return nonGeneric[caseName]
 }
 if let template = genericEnums[enumName] {
 return template.cases[caseName]
 }
 return nil
 }

 /// 枚举用例构造的「最少必填实参个数」= 总字段数 − 带默认值的字段数。
 /// 供 arity 校验容忍默认值（字面量默认）：`东()`（0 个实参）对 `东(0)` 合法，
 /// 既可全省略也可补传；合法区间 `[required … total]`。
 public func enumCaseRequiredArity(enumName: String, caseName: String) -> Int? {
 let total: Int?
 if let nonGeneric = enumCases[enumName] {
 total = nonGeneric[caseName]?.count
 } else {
 total = genericEnums[enumName]?.cases[caseName]?.count
 }
 guard let t = total else { return nil }
 let defaulted = enumCaseDefaultedCounts[enumName]?[caseName] ?? 0
 return max(0, t - defaulted)
 }

 public func parentEnum(of caseName: String) -> String? {
 return enumCaseToParent[caseName]
 }

 // MARK: - Generic enums (P5 B0-1：泛型枚举特化，闭合 R1)

 private struct GenericEnumTemplate {
 let genericParams: [String]
 let cases: [String: [(name: String?, type: TypeAnnotation)]]
 }

 private var genericEnums: [String: GenericEnumTemplate] = [:]

 public func defineGenericEnum(
 name: String,
 genericParams: [String],
 cases: [String: [(name: String?, type: TypeAnnotation)]],
 defaultedCounts: [String: Int] = [:]
 ) {
 genericEnums[name] = GenericEnumTemplate(genericParams: genericParams, cases: cases)
 enumCaseDefaultedCounts[name] = defaultedCounts
 for (caseName, _) in cases {
 enumCaseToParent[caseName] = name
 }
 }

 public func genericEnumParamCount(name: String) -> Int? {
 return genericEnums[name]?.genericParams.count
 }

 public func lookupSpecializedEnumCase(
 typeName: String,
 typeArgs: [TypeAnnotation],
 caseName: String
 ) -> [(name: String?, type: TypeAnnotation)]? {
 guard let template = genericEnums[typeName] else { return nil }
 guard typeArgs.count == template.genericParams.count else { return nil }
 guard let rawCases = template.cases[caseName] else { return nil }

 var bindings: [String: TypeAnnotation] = [:]
 for i in 0..<template.genericParams.count {
 bindings[template.genericParams[i]] = typeArgs[i]
 }
 let substitutor = TypeSubstitutor(bindings: bindings)
 return rawCases.map { (name: $0.name, type: substitutor.substitute(type: $0.type)) }
 }
}
