import Foundation

/// 语法降层（desugar / lowering）通道。
///
/// ## 职责
/// 将 Parser 产出的「富语法 AST」转换为「核心 AST」——仅保留语义必要的节点，
/// 糖语法在解析后立即被消除，永不到达类型检查器 / 解释器 / 代码生成器。
///
/// ## 这是语言演化的减震器
/// 新增语法糖 = 改 `Parser`（产出糖节点）+ 在**此处**加一条降层规则；
/// 类型检查器、解释器、双后端代码生成器**零改动**。
/// 反之，若无此层，每个糖都要在 10 个文件的 10 个 switch 里各写一遍，且易漂移分叉。
///
/// ## 当前已降糖
/// - `paren`：`(e)` 括号分组语义为零，已直接在 `Parser.parseTupleOrParen` 处消解
/// （不再构造 `.paren` 节点），并从核心 `Expression` 枚举移除。
/// 本通道保留对 `paren` 的递归兜底（见 `desugar(_:Expression)` 注释），未来若任何
/// 代码路径仍产出分组节点，会在此统一消除。
///
/// ## 扩展方式
/// 新增糖时：在 `Expression`（或 `Statement`）枚举加糖节点 → `Parser` 产出它 →
/// 在下方对应 `desugar(_:)` 重载里把它降为已有核心节点。所有节点遍历都在此集中，
/// 且重载的穷尽性由编译器强制（漏掉新节点会编译报错）。
public enum Desugar {

 // MARK: - 模块入口

 public static func desugar(_ module: Module) -> Module {
 return Module(declarations: module.declarations.map(desugar),
 imports: module.imports,
 exports: module.exports,
 location: module.location)
 }

 // MARK: - 顶级声明

 public static func desugar(_ decl: TopLevelDecl) -> TopLevelDecl {
 switch decl {
 case .structDecl(let s): return .structDecl(desugar(s))
 case .objectDecl(let o): return .objectDecl(desugar(o))
 case .enumDecl(let e): return .enumDecl(desugar(e))
 case .funcDecl(let f): return .funcDecl(desugar(f))
 case .traitDecl(let t): return .traitDecl(desugar(t))
 case .extensionDecl(let x): return .extensionDecl(desugar(x))
 case .foreignDecl(let fd): return .foreignDecl(desugar(fd))
 case .varDecl(let stmt): return .varDecl(desugar(stmt))
 case .statement(let stmt): return .statement(desugar(stmt))
 case .importDecl(let i): return .importDecl(i)
 case .exportDecl(let e): return .exportDecl(e)
 }
 }

 public static func desugar(_ fd: ForeignDecl) -> ForeignDecl {
 return ForeignDecl(
 name: fd.name,
 funcs: fd.funcs.map(desugar),
 location: fd.location
 )
 }

 public static func desugar(_ x: ExtensionDecl) -> ExtensionDecl {
 return ExtensionDecl(
 kind: x.kind,
 targetType: x.targetType,
 targetTypeAnnotation: x.targetTypeAnnotation,
 methods: x.methods.map(desugar),
 location: x.location
 )
 }

 public static func desugar(_ f: FuncDecl) -> FuncDecl {
 return FuncDecl(name: f.name,
 modifiers: f.modifiers,
 genericParams: f.genericParams,
 params: f.params,
 returnTypes: f.returnTypes,
 returnLabels: f.returnLabels,
 isAsync: f.isAsync,
 body: f.body.map(desugar),
 location: f.location)
 }

 public static func desugar(_ s: StructDecl) -> StructDecl {
 return StructDecl(name: s.name,
 genericParams: s.genericParams,
 fields: s.fields.map { FieldDecl(name: $0.name,
 typeAnnotation: $0.typeAnnotation,
 initializer: $0.initializer.map(desugar),
 location: $0.location) },
 methods: s.methods.map(desugar),
 composedType: s.composedType,
 traits: s.traits,
 location: s.location)
 }

 public static func desugar(_ o: ObjectDecl) -> ObjectDecl {
 return ObjectDecl(name: o.name,
 genericParams: o.genericParams,
 fields: o.fields.map { FieldDecl(name: $0.name,
 typeAnnotation: $0.typeAnnotation,
 initializer: $0.initializer.map(desugar),
 location: $0.location) },
 methods: o.methods.map(desugar),
 traits: o.traits,
 location: o.location)
 }

 public static func desugar(_ e: EnumDecl) -> EnumDecl {
 return EnumDecl(name: e.name,
 genericParams: e.genericParams,
 cases: e.cases.map { c in
 EnumCase(name: c.name,
 associatedParams: c.associatedParams.map { ap in
 AssociatedParam(name: ap.name,
 type: ap.type,
 defaultValue: ap.defaultValue.map(desugar)) },
 location: c.location)
 },
 methods: e.methods.map(desugar),
 location: e.location)
 }

 public static func desugar(_ t: TraitDecl) -> TraitDecl {
 return TraitDecl(name: t.name,
 genericParams: t.genericParams,
 signatures: t.signatures.map(desugar),
 location: t.location)
 }

 // MARK: - 语句

 public static func desugar(_ block: Block) -> Block {
 return Block(statements: block.statements.map(desugar), location: block.location)
 }

 public static func desugar(_ stmt: Statement) -> Statement {
 switch stmt {
 case .varDecl(let name, let typeAnn, let initializer, let isMutable, let loc):
 return .varDecl(name: name, typeAnnotation: typeAnn,
 initializer: initializer.map(desugar), isMutable: isMutable, location: loc)
 case .varDestructure(let names, let typeAnn, let initializer, let isMutable, let loc):
 // 草稿 A1（批次 1）：递归降层初始值，names/typeAnnotation 为结构不动。
 return .varDestructure(names: names, typeAnnotation: typeAnn,
 initializer: initializer.map(desugar), isMutable: isMutable, location: loc)
 case .assign(let target, let value, let loc):
 return .assign(target: desugar(target), value: desugar(value), location: loc)
 case .returnStatement(let value, let loc):
 return .returnStatement(value: value.map(desugar), location: loc)
 case .breakStatement(let label, let loc):
 return .breakStatement(label: label, location: loc)
 case .continueStatement(let label, let loc):
 return .continueStatement(label: label, location: loc)
 case .ifStatement(let cond, let thenBlock, let elifs, let elseBlock, let label, let loc):
 return .ifStatement(condition: desugar(cond),
 thenBlock: desugar(thenBlock),
 elifs: elifs.map { ElifBranch(condition: desugar($0.condition),
 block: desugar($0.block),
 location: $0.location) },
 elseBlock: elseBlock.map(desugar),
 label: label,
 location: loc)
 case .whileStatement(let cond, let body, let step, let label, let loc):
 return .whileStatement(condition: desugar(cond),
 body: desugar(body),
 step: step.map(desugar),
 label: label,
 location: loc)
 case .forStatement(let pattern, let iterable, let body, let step, let label, let loc):
 return .forStatement(pattern: pattern,
 iterable: desugar(iterable),
 body: desugar(body),
 step: step.map(desugar),
 label: label,
 location: loc)
 case .matchStatement(let value, let cases, let loc):
 // D3①：case 列表携带通配（case _:），default/pass 通配字段已移除。
 return .matchStatement(value: desugar(value),
 cases: cases.map { MatchCase(pattern: $0.pattern,
 bindings: $0.bindings,
 block: desugar($0.block),
 location: $0.location) },
 location: loc)
 case .tryStatement(let expr, let tryBlock, let exceptClauses, let loc):
 return .tryStatement(expression: desugar(expr),
 tryBlock: desugar(tryBlock),
 exceptClauses: exceptClauses.map { ExceptClause(errorVar: $0.errorVar,
 body: desugar($0.body),
 location: $0.location) },
 location: loc)
 case .expressionStmt(let expr, let loc):
 return .expressionStmt(expr: desugar(expr), location: loc)
 case .detachStatement(let expr, let loc):
 return .detachStatement(expression: desugar(expr), location: loc)
 case .deferStatement(let inner, let loc):
 return .deferStatement(statement: desugar(inner), location: loc)
 case .passStatement(let loc):
 return .passStatement(location: loc)
 case .scopedBlock(let label, let body, let loc):
 return .scopedBlock(label: label, body: desugar(body), location: loc)
 }
 }

 public static func desugar(_ target: AssignTarget) -> AssignTarget {
 switch target {
 case .identifier(let name):
 return .identifier(name: name)
 case .member(let object, let name):
 return .member(object: desugar(object), name: name)
 case .subscript(let expr, let index):
 return .subscript(expr: desugar(expr), index: desugar(index))
 }
 }

 // MARK: - 表达式

 /// 递归降层单个表达式。
 ///
 /// `paren` 已由 `Parser` 在语法边界消解、不再出现在核心 `Expression` 枚举，
 /// 故此处无需 `.paren` 分支；但若未来任何路径仍产出 `Expression.paren`，
 /// 应在此加：`case .paren(let inner, _): return desugar(inner)`。
 public static func desugar(_ expr: Expression) -> Expression {
 switch expr {
 case .identifier, .integerLiteral, .floatLiteral, .stringLiteral,
 .boolLiteral, .selfKeyword, .selfTypeKeyword:
 return expr

 case .stringInterpolation(let segments, let loc):
 let newSegments = segments.map { seg -> InterpolationSegment in
 switch seg {
 case .literal(let s): return .literal(s)
 case .expression(let e): return .expression(desugar(e))
 }
 }
 return .stringInterpolation(segments: newSegments, location: loc)

 case .binary(let l, let op, let r, let loc):
 return .binary(left: desugar(l), op: op, right: desugar(r), location: loc)
 case .unary(let op, let operand, let loc):
 return .unary(op: op, operand: desugar(operand), location: loc)
 case .call(let callee, let args, let loc):
 return .call(callee: desugar(callee),
 arguments: args.map { CallArgument(label: $0.label, expression: desugar($0.expression)) },
 location: loc)
 case .member(let obj, let name, let loc):
 return .member(object: desugar(obj), name: name, location: loc)
 case .resultUnwrap(let operand, let loc):
 // 草稿 A2（批次 1.4，D2）：递归降层被解包表达式。
 return .resultUnwrap(operand: desugar(operand), location: loc)
 case .tupleIndex(let obj, let index, let loc):
 // 草稿 A2（批次 1）：递归降层 object，索引为常量不动。
 return .tupleIndex(object: desugar(obj), index: index, location: loc)
 case .tuple(let labels, let elems, let loc):
 // 草稿 A2（批次 1.3，D1）：保留命名元组标签。
 return .tuple(labels: labels, elements: elems.map(desugar), location: loc)
 case .arrayLiteral(let elems, let loc):
 return .arrayLiteral(elements: elems.map(desugar), location: loc)
 case .dictionaryLiteral(let entries, let loc):
 return .dictionaryLiteral(entries: entries.map { DictEntry(key: desugar($0.key),
 value: desugar($0.value)) },
 location: loc)
 case .setLiteral(let elems, let loc):
 return .setLiteral(elements: elems.map(desugar), location: loc)
 case .subscript(let container, let index, let loc):
 // 下标容器是任意表达式（非 identifier-only），由 Parser 保证；此处仅递归降层两侧子表达式。
 return .subscript(expr: desugar(container), index: desugar(index), location: loc)
 case .funcLiteral(let decl, let loc):
 return .funcLiteral(decl: desugar(decl), location: loc)
 case .genericConstruct(let typeName, let typeArgs, let args, let loc):
 return .genericConstruct(typeName: typeName,
 typeArgs: typeArgs,
 arguments: args.map { CallArgument(label: $0.label,
 expression: desugar($0.expression)) },
 location: loc)
 case .join(let inner, let loc):
 return .join(desugar(inner), loc)
 case .unsafe(let operand, let loc):
 return .unsafe(operand: desugar(operand), location: loc)
 case .addressOf(let operand, let loc):
 return .addressOf(operand: desugar(operand), location: loc)
 }
 }
}
