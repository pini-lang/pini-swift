import Foundation

/// 类型推断
/// 负责推断表达式的类型
public final class TypeInference {
 public let environment: TypeEnvironment?

 public init(environment: TypeEnvironment? = nil) {
 self.environment = environment
 }

 /// 推断表达式类型
 /// - Parameter expected: 调用点提供的期望类型（仅对 `.lambda` 生效，用于自顶向下推断）。
 public func infer(
 expression: Expression,
 expected: TypeAnnotation? = nil,
 scopedParams: [String: TypeAnnotation]? = nil
 ) -> TypeAnnotation? {
 switch expression {
 case .integerLiteral(_, let loc):
 return .simple(name: "I32", location: loc)

 case .floatLiteral(_, let loc):
 return .simple(name: "F64", location: loc)

 case .stringLiteral(_, let loc):
 return .simple(name: "String", location: loc)

 case .stringInterpolation(_, let loc):
 return .simple(name: "String", location: loc)

 case .boolLiteral(_, let loc):
 return .simple(name: "Bool", location: loc)

 case .binary(let left, let op, _, _):
 let leftType = infer(expression: left, scopedParams: scopedParams)
 // 算术运算符返回操作数类型
 switch op {
 case .plus, .minus, .multiply, .divide, .modulo,
 .bitwiseAnd, .bitwiseOr, .bitwiseXor, .leftShift, .rightShift,
 .assign, .plusAssign, .minusAssign, .multiplyAssign, .divideAssign,
 .moduloAssign, .andAssign, .orAssign, .xorAssign,
 .leftShiftAssign, .rightShiftAssign:
 return leftType
 case .equal, .notEqual, .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual,
 .and, .or:
 return .simple(name: "Bool", location: SourceLocation(line: 0, column: 0, fileName: ""))
 }

 case .unary(let op, let operand, _):
 let operandType = infer(expression: operand)
 switch op {
 case .not:
 return .simple(name: "Bool", location: SourceLocation(line: 0, column: 0, fileName: ""))
 case .forceUnwrap:
 // 后缀 `!` 的类型 = Optional<T> 的内部类型 T；非 Optional / 不可推断时回退 nil（交由 TypeChecker 报错）。
 if case .generic(let name, let params, _) = operandType, name == "Optional", !params.isEmpty {
 return params[0]
 }
 return nil
 default:
 return operandType
 }


 case .genericConstruct(let typeName, let typeArgs, _, let loc):
 // P2-1.4：泛型构造返回特化类型 Box<T> 等，供成员方法调用点推断对象类型
 return .generic(name: typeName, params: typeArgs, location: loc)

 case .tuple(let labels, let elements, let loc):
 var elemTypes: [TypeAnnotation] = []
 for elem in elements {
 if let t = infer(expression: elem) {
 elemTypes.append(t)
 }
 }
 // 草稿 A2（批次 1.3，D1）：字面量命名元组的标签随类型推断一并保留。
 return .tuple(labels: labels, elements: elemTypes, location: loc)

 case .tupleIndex(let object, let index, let loc):
 // 草稿 A2（批次 1）：`.0` 位置访问的类型 = 元组类型的第 index 个分量；
 // 非元组对象或越界返回 nil，交由 TypeChecker 报错（此处仅做推断）。
 guard let t = infer(expression: object) else { return nil }
 if case .tuple(_, let elements, _) = t, index >= 0 && index < elements.count {
 return elements[index]
 }
 return nil

 case .identifier(let name, let location):
 // 内建 Optional 枚举类型：静态层作为已知类型引用（裸 Optional / Optional.none 成员访问），
 // 与解释器对 Optional.some/Optional.none 的特判对齐（闭合 B2 静态缺口）。
 if name == "Optional" {
 return .generic(name: "Optional", params: [.simple(name: "Any", location: location)], location: location)
 }
 if let sp = scopedParams, let t = sp[name] { return t }
 return environment?.lookupVariable(name: name)

 case .call(let callee, let arguments, let loc):
 if case .member(let object, let memberName, _) = callee,
 case .identifier(let typeName, _) = object,
 typeName == "Optional" && memberName == "some",
 !arguments.isEmpty {
 let argType = infer(expression: arguments[0].expression)
 if let t = argType {
 return .generic(name: "Optional", params: [t], location: loc)
 }
 return .generic(name: "Optional", params: [.simple(name: "Any", location: loc)], location: loc)
 }

 if case .member(let object, let memberName, _) = callee,
 case .identifier(let typeName, _) = object,
 typeName == "Optional" && memberName == "none" {
 return .generic(name: "Optional", params: [.simple(name: "Any", location: loc)], location: loc)
 }

 // ADR-026 D2：限定枚举用例构造 Enum.case(args) 推断为父枚举类型，
 // 使以其为 scrutinee 的 match 按正确父枚举解析 case 字段。
 if case .member(let object, let caseName, _) = callee,
 case .identifier(let typeName, _) = object,
 let env = environment,
 env.lookupEnumCase(enumName: typeName, caseName: caseName) != nil {
 return .simple(name: typeName, location: loc)
 }

 // 点号用例构造（proposal-dot-case-construction，成员意图）：推断优先级为
 // 期望类型命中候选 > 唯一父枚举（与裸名构造的唯一优先相反——前导点即声明
 // 「这是某枚举的成员」）。期望不可知且歧义时返回例名占位，报错交 TypeChecker；
 // 用户枚举候选为空时内建 some/none 直达 Optional（与 `nil` 的推断对齐）。
 if case .dotCaseRef(let caseName, _) = callee, let env = environment {
 let caseParents = env.parentEnums(of: caseName)
 if let exp = expected {
 switch exp {
 case .simple(let en, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 case .generic(let en, _, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 default:
 break
 }
 }
 if caseParents.count == 1 {
 return .simple(name: caseParents[0], location: loc)
 }
 if caseName == "some", !arguments.isEmpty,
 let t = infer(expression: arguments[0].expression, scopedParams: scopedParams) {
 return .generic(name: "Optional", params: [t], location: loc)
 }
 if caseName == "some" || caseName == "none" {
 return .generic(name: "Optional", params: [.simple(name: "Any", location: loc)], location: loc)
 }
 return .simple(name: caseName, location: loc)
 }

 // P2-1.4：成员方法调用返回类型推断（obj.method(args)）。
 // Optional.some / .none 已在上方特判并返回，此处仅处理普通成员方法。
 if case .member(let object, let memberName, _) = callee, let env = environment {
 let objType = infer(expression: object)
 switch objType {
 case .simple(let typeName, _):
 if let sig = env.lookupMethod(typeName: typeName, methodName: memberName) {
 return methodReturn(for: sig, loc: loc)
 }
 case .generic(let typeName, let typeArgs, _):
 if let sig = env.lookupSpecializedMethod(typeName: typeName, typeArgs: typeArgs, methodName: memberName) {
 return methodReturn(for: sig, loc: loc)
 }
 default:
 break
 }
 return nil
 }

 if case .identifier(let name, _) = callee, let env = environment {
 if let sig = env.lookupFunction(name: name) {
 if sig.returns.count == 1 {
 return sig.returns[0]
 } else if sig.returns.isEmpty {
 return nil
 } else {
 return .tuple(labels: [], elements: sig.returns, location: loc)
 }
 }
 // 高阶函数：被调者是函数类型参数/变量（f(x)）——返回其声明返回类型。
 // 此前此处退化为 .simple(name) 导致 return f(x) 类型误判为「类型 f」。
 if case .function(_, let returns, _, _) = env.lookupVariable(name: name) {
 if returns.count == 1 {
 return returns[0]
 } else if returns.isEmpty {
 return nil
 } else {
 return .tuple(labels: [], elements: returns, location: loc)
 }
 }
 // ADR-026 D5（缩窄版）：裸名 case 构造且父枚举唯一 → 推断为父枚举类型，
 // 使 case 值可在期望父枚举的位置（return/关联值）通过检查（G-P3）。
 let caseParents = env.parentEnums(of: name)
 if caseParents.count == 1 {
 return .simple(name: caseParents[0], location: loc)
 }
 // ADR-026 D1（实参位补全）：歧义 case 名且期望类型命中候选 → 按期望解析。
 // 此前实参位置不线程期望类型，跨枚举同名 case（如两个 none）在实参位
 // 无法构造——S4.9 宿主对等改名回退的前置。
 if let exp = expected {
 switch exp {
 case .simple(let en, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 case .generic(let en, _, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 default:
 break
 }
 }
 return .simple(name: name, location: loc)
 }
 return nil

 case .member(let object, let name, let loc):
 // B2：裸 Optional.none 成员访问（无调用）→ 视为 Optional<Any> 值，与解释器对齐。
 if case .identifier(let typeName, _) = object, typeName == "Optional", name == "none" {
 return .generic(name: "Optional", params: [.simple(name: "Any", location: loc)], location: loc)
 }
 // 草稿 A2（批次 1.3，D1）：命名元组 `.名称` 标签访问——object 推断为元组且 labels 含 name
 // 时返回对应元素类型；未知标签返回 nil，交由 TypeChecker 报错。
 if let objType = infer(expression: object),
 case .tuple(let labels, let elements, _) = objType,
 let idx = labels.firstIndex(of: name) {
 return elements[idx]
 }
 guard let env = environment else { return nil }
 let objType = infer(expression: object)
 guard let t = objType else { return nil }
 switch t {
 case .simple(let typeName, _):
 return env.lookupField(typeName: typeName, fieldName: name)
 case .generic(let typeName, let typeArgs, _):
 return env.lookupSpecializedField(
 typeName: typeName,
 typeArgs: typeArgs,
 fieldName: name
 )
 default:
 return nil
 }

 case .funcLiteral(let decl, let loc):
 return inferFuncLiteral(decl: decl, expected: expected, location: loc)

 case .selfKeyword:
 // ADR-026 D3：self 在方法体内已登记为接收对象类型（checkBody 的 defineVariable），
 // 与外部标识符接收者同路径解析，修复合绑定退化 Any（G-P8）。
 return environment?.lookupVariable(name: "self")

 case .selfTypeKeyword:
 return nil

 case .dotCaseRef(let name, let loc):
 // 点号用例构造（无实参形态，成员意图）：推断优先级 = 期望类型命中候选 > 唯一
 // 父枚举；用户枚举候选为空时内建 none 直达 Optional<Any>（与 `nil` 对齐）。
 guard let env = environment else { return nil }
 let caseParents = env.parentEnums(of: name)
 if let exp = expected {
 switch exp {
 case .simple(let en, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 case .generic(let en, _, _):
 if caseParents.contains(en) { return .simple(name: en, location: loc) }
 default:
 break
 }
 }
 if caseParents.count == 1 {
 return .simple(name: caseParents[0], location: loc)
 }
 if name == "none" {
 return .generic(name: "Optional", params: [.simple(name: "Any", location: loc)], location: loc)
 }
 return .simple(name: name, location: loc)

 case .arrayLiteral, .dictionaryLiteral, .setLiteral:
 return nil

 case .subscript(let container, let index, let loc):
 // 批 2（G48 三通道）：下标是**安全断言通道**——静态类型 = 元素类型 `T`（越界 panic，
 // E5-005），不再是 Optional<T>（旧 P2-E 行为）。容错通道为 `.get(i)`（Optional<T>）。
 // 仅当容器类型可静态解析时给出精确元素类型；否则回退 nil（未知），不报错。
 guard let containerType = infer(expression: container, scopedParams: scopedParams) else { return nil }
 switch containerType {
 case .generic(let name, let params, _) where name == "Array":
 return params.first ?? .simple(name: "Any", location: loc)
 case .generic(let name, let params, _) where name == "Dictionary":
 return params.last ?? .simple(name: "Any", location: loc)
 case .simple(let name, _) where name == "String":
 return .simple(name: "String", location: loc)
 default:
 return nil
 }

 case .join(let inner, _):
 // `await`/`wait` fut 归约为 `Result<T, E>`（fut : Future<T, E>）。
 // 操作数类型不可解析或非 Future 时返回 nil，交由 TypeChecker 报错（此处仅做推断）。
 guard let operand = infer(expression: inner) else { return nil }
 if case .generic(let name, let params, let loc) = operand,
 name == "Future" || name == "Chan",
 params.count == 2 {
 return .generic(name: "Result", params: params, location: loc)
 }
 return nil

 case .resultUnwrap(let operand, _):
 // 草稿 A2（批次 1.4，D2）：`^expr` 的类型 = Result 的第一个泛型参数（载荷 T）。
 guard let t = infer(expression: operand) else { return nil }
 if case .generic(let name, let params, _) = t, name == "Result", !params.isEmpty {
 return params[0]
 }
 return nil

 case .unsafe(let operand, _):
 // Phase 2a（ADR-015 FFI）：`unsafe expr` 的类型 = 操作数类型（类型不变，仅加不安全上下文）。
 return infer(expression: operand)
 case .addressOf(let operand, let loc):
 // Phase 2a（ADR-015 FFI）：`&x` 的类型 = `*T`（指向操作数类型的指针）。
 guard let inner = infer(expression: operand) else { return nil }
 return .pointer(element: inner, location: loc)
 }
 }

 /// 将方法签名归约为返回类型注解（P2-1.4 复用）。
 private func methodReturn(for sig: TypeEnvironment.FunctionSignature, loc: SourceLocation) -> TypeAnnotation? {
 if sig.returns.count == 1 {
 return sig.returns[0]
 } else if sig.returns.isEmpty {
 return nil
 } else {
 return .tuple(labels: [], elements: sig.returns, location: loc)
 }
 }

 // MARK: - 匿名函数（funcLiteral）双向类型推断

 /// 推断匿名函数（funcLiteral）类型：参数标注优先、返回类型标注优先（闭合 L1，G29）。
 /// 优先级：参数 = `p.typeAnnotation` > 体运算符反推 > 期望函数类型 > 返回类型标注(单一具体) > 通配 `_`；
 /// 返回 = `decl.returnTypes` > 块体 return 语句反推 > 期望 > 通配 `_`。
 private func inferFuncLiteral(
 decl: FuncDecl,
 expected: TypeAnnotation?,
 location: SourceLocation
 ) -> TypeAnnotation? {
 let params = decl.params

 // 自顶向下：期望函数类型灌入参数与返回
 var expectedParamTypes: [TypeAnnotation?] = Array(repeating: nil, count: params.count)
 var expectedReturns: [TypeAnnotation?] = []
 if case .function(let ep, let er, _, _) = expected, ep.count == params.count {
 expectedParamTypes = ep.map { $0 }
 expectedReturns = er.map { $0 }
 }

 // 自底向上：参数出现在运算符且另一操作数是字面量时反推类型
 let paramNames = Set(params.map { $0.name })
 var bottomUp: [String: TypeAnnotation] = [:]
 if let body = decl.body {
 collectLambdaParamConstraints(in: body, paramNames: paramNames, into: &bottomUp)
 }

 // 返回类型标注（单一具体、非通配）→ 作为未标注参数的回退。
 // 与顶层函数「参数无标注→从返回类型推断」规则一致（spec G29）；仅当无标注/无体反推/无期望时生效，
 // 修复 closures.pini 中 `func (n,) -> (I32,): return n * n` 因 n*n 两操作数皆变量、无字面量，
 // 自底向上收不到约束而把 n 推成 `_`，进而 `应用(sq, 7)` 比对 `(I32)->(I32)` 报 mismatch 的缺口。
 let fallbackReturnType: TypeAnnotation?
 if decl.returnTypes.count == 1,
 case .simple(let rn, _) = decl.returnTypes[0], rn != "_" {
 fallbackReturnType = decl.returnTypes[0]
 } else {
 fallbackReturnType = nil
 }

 // 参数类型：标注 > 体反推 > 期望 > 返回类型回退 > 通配
 let paramTypes: [TypeAnnotation] = params.enumerated().map { (i, p) in
 if let ann = p.typeAnnotation { return ann }
 if let bt = bottomUp[p.name] { return bt }
 if i < expectedParamTypes.count, let et = expectedParamTypes[i] { return et }
 if let fr = fallbackReturnType { return fr }
 return .simple(name: "_", location: location)
 }

 let paramMap = Dictionary(uniqueKeysWithValues: zip(params.map { $0.name }, paramTypes))

 // 返回类型：标注 > 块体 return 反推 > 期望 > 通配
 let returnTypes: [TypeAnnotation]
 if !decl.returnTypes.isEmpty {
 returnTypes = decl.returnTypes
 } else if let body = decl.body, let rt = inferBlockReturnType(of: body, scopedParams: paramMap) {
 returnTypes = [rt]
 } else if !expectedReturns.isEmpty {
 returnTypes = expectedReturns.compactMap { $0 }
 } else {
 returnTypes = [.simple(name: "_", location: location)]
 }

 // 捕获（自由变量）类型分析（缺口②修复）：闭包体标识符 − (参数 ∪ 局部 var)，
 // 余下即在创建点作用域可见、被闭包捕获的外层变量；取其在当前环境下的类型填入 captured。
 // 与阶段 B 已落地的 IRGenerator free-variable 分析同算法（修复方案）。
 // 仅取类型可解析者（不可解析的哨兵/未知名跳过，不误报）。
 var capturedTypes: [TypeAnnotation] = []
 if let body = decl.body {
 let used = collectIdentifiers(in: decl)
 let localBound = Set(params.map { $0.name })
 .union(declaredVars(in: body.statements))
 for name in used where !localBound.contains(name) {
 if let t = environment?.lookupVariable(name: name) {
 capturedTypes.append(t)
 }
 }
 }

 return .function(params: paramTypes, returns: returnTypes, captured: capturedTypes, location: location)
 }

 // MARK: - 自由变量分析（捕获集计算，复用阶段 B 同算法）

 /// 收集闭包体内引用的全部标识符名（含 callee 名）；funcLiteral 子表达式视为不透明、不再下探。
 private func collectIdentifiers(in decl: FuncDecl) -> Set<String> {
 collectIdentifiers(in: decl.body?.statements ?? [])
 }
 private func collectIdentifiers(in statements: [Statement]) -> Set<String> {
 statements.reduce(into: Set<String>()) { $0.formUnion(collectIdentifiers(in: $1)) }
 }
 private func collectIdentifiers(in stmt: Statement) -> Set<String> {
 switch stmt {
 case .varDecl(let name, _, let init_, _, _):
 var s = init_.map { collectIdentifiers(in: $0) } ?? []
 s.insert(name); return s
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
 var s = collectIdentifiers(in: c); s.formUnion(collectIdentifiers(in: body.statements)); if let step = step { s.formUnion(collectIdentifiers(in: step.statements)) }; return s
 case .forStatement(_, let iterable, let body, let step, _, _):
 var s = collectIdentifiers(in: iterable); s.formUnion(collectIdentifiers(in: body.statements)); if let step = step { s.formUnion(collectIdentifiers(in: step.statements)) }; return s
 case .matchStatement(let v, let cases, _):
 var s = collectIdentifiers(in: v)
 for c in cases { s.formUnion(collectIdentifiers(in: c.block.statements)) }
 return s
 case .deferStatement(let st, _): return collectIdentifiers(in: st)
 default: return []
 }
 }
 private func collectIdentifiers(in target: AssignTarget) -> Set<String> {
 switch target {
 case .identifier: return []
 case .member(let o, _): return collectIdentifiers(in: o)
 case .subscript(let e, let i): return collectIdentifiers(in: e).union(collectIdentifiers(in: i))
 }
 }
 private func collectIdentifiers(in expr: Expression) -> Set<String> {
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
 private func declaredVars(in statements: [Statement]) -> Set<String> {
 statements.reduce(into: Set<String>()) {
 if case .varDecl(let name, _, _, _, _) = $1 { $0.insert(name) }
 }
 }

 /// 从块体推断返回类型：取第一条带值 `return` 表达式的推断类型。
 private func inferBlockReturnType(
 of block: Block,
 scopedParams: [String: TypeAnnotation]? = nil
 ) -> TypeAnnotation? {
 for stmt in block.statements {
 if case .returnStatement(let value, _) = stmt, let v = value {
 return infer(expression: v, scopedParams: scopedParams)
 }
 }
 return nil
 }

 /// 从一条语句里收集 lambda 参数的类型约束（自底向上）。
 private func collectLambdaParamConstraints(
 in stmt: Statement,
 paramNames: Set<String>,
 into constraints: inout [String: TypeAnnotation]
 ) {
 switch stmt {
 case .expressionStmt(let expr, _):
 collectLambdaParamConstraints(in: expr, paramNames: paramNames, into: &constraints)
 case .returnStatement(let value, _):
 if let v = value { collectLambdaParamConstraints(in: v, paramNames: paramNames, into: &constraints) }
 case .varDecl(_, _, let init_, _, _):
 if let i = init_ { collectLambdaParamConstraints(in: i, paramNames: paramNames, into: &constraints) }
 case .assign(_, let value, _):
 collectLambdaParamConstraints(in: value, paramNames: paramNames, into: &constraints)
 case .ifStatement(let cond, let then, let elifs, let elseB, _, _):
 collectLambdaParamConstraints(in: cond, paramNames: paramNames, into: &constraints)
 collectLambdaParamConstraints(in: then, paramNames: paramNames, into: &constraints)
 for e in elifs {
 collectLambdaParamConstraints(in: e.condition, paramNames: paramNames, into: &constraints)
 collectLambdaParamConstraints(in: e.block, paramNames: paramNames, into: &constraints)
 }
 if let eb = elseB { collectLambdaParamConstraints(in: eb, paramNames: paramNames, into: &constraints) }
 case .whileStatement(let cond, let body, let step, _, _):
 collectLambdaParamConstraints(in: cond, paramNames: paramNames, into: &constraints)
 collectLambdaParamConstraints(in: body, paramNames: paramNames, into: &constraints)
 if let step = step { collectLambdaParamConstraints(in: step, paramNames: paramNames, into: &constraints) }
 case .forStatement(_, let iterable, let body, let step, _, _):
 collectLambdaParamConstraints(in: iterable, paramNames: paramNames, into: &constraints)
 collectLambdaParamConstraints(in: body, paramNames: paramNames, into: &constraints)
 if let step = step { collectLambdaParamConstraints(in: step, paramNames: paramNames, into: &constraints) }
 case .matchStatement(let value, let cases, _):
 collectLambdaParamConstraints(in: value, paramNames: paramNames, into: &constraints)
 for c in cases { collectLambdaParamConstraints(in: c.block, paramNames: paramNames, into: &constraints) }
 default:
 break
 }
 }

 /// 遍历代码块收集约束。
 private func collectLambdaParamConstraints(
 in block: Block,
 paramNames: Set<String>,
 into constraints: inout [String: TypeAnnotation]
 ) {
 for s in block.statements {
 collectLambdaParamConstraints(in: s, paramNames: paramNames, into: &constraints)
 }
 }

 /// 从一条表达式里收集 lambda 参数的类型约束（自底向上）。
 private func collectLambdaParamConstraints(
 in expr: Expression,
 paramNames: Set<String>,
 into constraints: inout [String: TypeAnnotation]
 ) {
 switch expr {
 case .binary(let left, _, let right, _):
 if case .identifier(let ln, _) = left, paramNames.contains(ln) {
 if let rt = infer(expression: right) { constraints[ln] = rt }
 }
 if case .identifier(let rn, _) = right, paramNames.contains(rn) {
 if let lt = infer(expression: left) { constraints[rn] = lt }
 }
 collectLambdaParamConstraints(in: left, paramNames: paramNames, into: &constraints)
 collectLambdaParamConstraints(in: right, paramNames: paramNames, into: &constraints)
 case .unary(_, let operand, _):
 collectLambdaParamConstraints(in: operand, paramNames: paramNames, into: &constraints)
 case .call(let callee, let args, _):
 collectLambdaParamConstraints(in: callee, paramNames: paramNames, into: &constraints)
 for a in args { collectLambdaParamConstraints(in: a.expression, paramNames: paramNames, into: &constraints) }
 case .member(let obj, _, _):
 collectLambdaParamConstraints(in: obj, paramNames: paramNames, into: &constraints)
 case .tupleIndex(let obj, _, _):
 collectLambdaParamConstraints(in: obj, paramNames: paramNames, into: &constraints)
 default:
 break
 }
 }

 /// 推断 lambda 体的返回类型（自底向上）；scopedParams 提供 lambda 形参类型以解析形参标识符。
 private func inferLambdaReturnType(
 of stmt: Statement,
 scopedParams: [String: TypeAnnotation]? = nil
 ) -> TypeAnnotation? {
 switch stmt {
 case .expressionStmt(let expr, _):
 return infer(expression: expr, scopedParams: scopedParams)
 case .returnStatement(let value, _):
 guard let v = value else { return nil }
 return infer(expression: v, scopedParams: scopedParams)
 case .varDecl(_, _, let init_, _, _):
 guard let i = init_ else { return nil }
 return infer(expression: i, scopedParams: scopedParams)
 case .varDestructure(_, _, let init_, _, _):
 // 草稿 A1（批次 1）：解构初始值参与返回类型反推。
 guard let i = init_ else { return nil }
 return infer(expression: i, scopedParams: scopedParams)
 default:
 return nil
 }
 }
}
