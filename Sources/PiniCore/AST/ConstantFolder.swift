import Foundation

/// P7-5 常量折叠 AST 重写 pass。
///
/// 在解析后、类型检查前对字面量二元/一元运算做编译期求值折叠，生成等价但更简单的 AST。
/// 严格保持语义：仅折叠「两侧均为同类型字面量」的节点，不改变类型、不消除运行时错误
/// （如除零）、不折叠可能含副作用/短路语义的 `&&`/`||`、不折叠函数调用、不折叠 `power`。
public enum ConstantFolder {

 public static func foldConstants(in module: Module) -> Module {
 let decls = module.declarations.map { fold($0) }
 return Module(declarations: decls, imports: module.imports, exports: module.exports, location: module.location)
 }

 // MARK: - TopLevelDecl

 private static func fold(_ decl: TopLevelDecl) -> TopLevelDecl {
 switch decl {
 case .structDecl(let s):
 return .structDecl(StructDecl(
 name: s.name, genericParams: s.genericParams,
 fields: s.fields.map { FieldDecl(name: $0.name, typeAnnotation: $0.typeAnnotation, initializer: $0.initializer.map(fold), location: $0.location) },
 methods: s.methods.map(fold),
 composedType: s.composedType, traits: s.traits, location: s.location))
 case .objectDecl(let o):
 return .objectDecl(ObjectDecl(
 name: o.name, genericParams: o.genericParams,
 fields: o.fields.map { FieldDecl(name: $0.name, typeAnnotation: $0.typeAnnotation, initializer: $0.initializer.map(fold), location: $0.location) },
 methods: o.methods.map(fold), traits: o.traits, location: o.location))
 case .enumDecl(let e):
 return .enumDecl(EnumDecl(
 name: e.name, genericParams: e.genericParams, cases: e.cases,
 methods: e.methods.map(fold), location: e.location))
 case .funcDecl(let f):
 return .funcDecl(fold(f))
 case .traitDecl(let t):
 // 仅签名，无函数体，无需折叠
 return .traitDecl(t)
 case .extensionDecl(let x):
 return .extensionDecl(ExtensionDecl(
 kind: x.kind, targetType: x.targetType,
 targetTypeAnnotation: x.targetTypeAnnotation,
 methods: x.methods.map(fold), location: x.location))
 case .foreignDecl(let fd):
 // Phase 2a（ADR-015 FFI）：仅签名，无函数体，无需折叠。
 return .foreignDecl(fd)
 case .varDecl(let stmt):
 return .varDecl(fold(stmt))
 case .statement(let stmt):
 return .statement(fold(stmt))
 case .importDecl(let i):
 return .importDecl(i)
 case .exportDecl(let e):
 return .exportDecl(e)
 }
 }

 // MARK: - FuncDecl

 private static func fold(_ f: FuncDecl) -> FuncDecl {
 let body = f.body.map { fold($0) }
 return FuncDecl(name: f.name, modifiers: f.modifiers, genericParams: f.genericParams,
 params: f.params, returnTypes: f.returnTypes, returnLabels: f.returnLabels,
 isAsync: f.isAsync, body: body, location: f.location)
 }

 // MARK: - Statement

 private static func fold(_ stmt: Statement) -> Statement {
 switch stmt {
 case .varDecl(let name, let ta, let init_, let mut, let loc):
 return .varDecl(name: name, typeAnnotation: ta, initializer: init_.map(fold), isMutable: mut, location: loc)
 case .varDestructure(let names, let ta, let init_, let mut, let loc):
 // 草稿 A1（批次 1）：递归折叠初始值；names/typeAnnotation 为结构不动。
 return .varDestructure(names: names, typeAnnotation: ta, initializer: init_.map(fold), isMutable: mut, location: loc)
 case .assign(let target, let value, let loc):
 return .assign(target: fold(target), value: fold(value), location: loc)
 case .returnStatement(let val, let loc):
 return .returnStatement(value: val.map(fold), location: loc)
 case .breakStatement(let lbl, let loc):
 return .breakStatement(label: lbl, location: loc)
 case .continueStatement(let lbl, let loc):
 return .continueStatement(label: lbl, location: loc)
 case .ifStatement(let cond, let thenB, let elifs, let elseB, let label, let loc):
 return .ifStatement(condition: fold(cond), thenBlock: fold(thenB),
 elifs: elifs.map { ElifBranch(condition: fold($0.condition), block: fold($0.block), location: $0.location) },
 elseBlock: elseB.map(fold), label: label, location: loc)
 case .whileStatement(let cond, let body, let stepBlk, let lbl, let loc):
 return .whileStatement(condition: fold(cond), body: fold(body), step: stepBlk.map(fold), label: lbl, location: loc)
 case .forStatement(let pattern, let iterable, let body, let stepBlk, let lbl, let loc):
 return .forStatement(pattern: pattern, iterable: fold(iterable), body: fold(body), step: stepBlk.map(fold), label: lbl, location: loc)
 case .matchStatement(let val, let cases, let loc):
 // D3①：case 列表携带通配（case _:），default/pass 通配字段已移除。
 return .matchStatement(value: fold(val),
 cases: cases.map { MatchCase(pattern: $0.pattern, bindings: $0.bindings, block: fold($0.block), location: $0.location) },
 location: loc)
 case .tryStatement(let expr, let tryB, let excepts, let loc):
 return .tryStatement(expression: fold(expr), tryBlock: fold(tryB),
 exceptClauses: excepts.map { ExceptClause(errorVar: $0.errorVar, body: fold($0.body), location: $0.location) }, location: loc)
 case .expressionStmt(let expr, let loc):
 return .expressionStmt(expr: fold(expr), location: loc)
 case .detachStatement(let expr, let loc):
 return .detachStatement(expression: fold(expr), location: loc)
 case .deferStatement(let s, let loc):
 return .deferStatement(statement: fold(s), location: loc)
 case .passStatement(let loc):
 return .passStatement(location: loc)
 case .scopedBlock(let label, let body, let loc):
 return .scopedBlock(label: label, body: fold(body), location: loc)
 }
 }

 private static func fold(_ block: Block) -> Block {
 return Block(statements: block.statements.map { fold($0) }, location: block.location)
 }

 private static func fold(_ target: AssignTarget) -> AssignTarget {
 switch target {
 case .identifier(let name):
 return .identifier(name: name)
 case .member(let obj, let name):
 return .member(object: fold(obj), name: name)
 case .subscript(let expr, let index):
 return .subscript(expr: fold(expr), index: fold(index))
 }
 }

 // MARK: - Expression

 private static func fold(_ expr: Expression) -> Expression {
 switch expr {
 case .binary(let l, let op, let r, let loc):
 return foldBinary(fold(l), op, fold(r), loc)
 case .unary(let op, let operand, let loc):
 return foldUnary(op, fold(operand), loc)
 case .call(let callee, let args, let loc):
 return .call(callee: fold(callee), arguments: args.map { CallArgument(label: $0.label, expression: fold($0.expression)) }, location: loc)
 case .member(let obj, let name, let loc):
 return .member(object: fold(obj), name: name, location: loc)
 case .resultUnwrap(let operand, let loc):
 // 草稿 A2（批次 1.4，D2）：递归折叠被解包表达式。
 return .resultUnwrap(operand: fold(operand), location: loc)
 case .tupleIndex(let obj, let index, let loc):
 // 草稿 A2（批次 1）：递归折叠 object；常量元组字面量可折叠为对应字面量。
 let folded = fold(obj)
 if case .tuple(_, let elems, _) = folded, index >= 0 && index < elems.count {
 return elems[index]
 }
 return .tupleIndex(object: folded, index: index, location: loc)
 case .tuple(let labels, let elems, let loc):
 // 草稿 A2（批次 1.3，D1）：保留命名元组标签。
 return .tuple(labels: labels, elements: elems.map(fold), location: loc)
 case .arrayLiteral(let elems, let loc):
 return .arrayLiteral(elements: elems.map(fold), location: loc)
 case .dictionaryLiteral(let entries, let loc):
 return .dictionaryLiteral(entries: entries.map { DictEntry(key: fold($0.key), value: fold($0.value)) }, location: loc)
 case .setLiteral(let elems, let loc):
 return .setLiteral(elements: elems.map(fold), location: loc)
 case .subscript(let e, let idx, let loc):
 return .subscript(expr: fold(e), index: fold(idx), location: loc)
 case .unsafe(let operand, let loc):
 // Phase 2a（ADR-015 FFI）：不安全消耗点——递归折叠操作数。
 return .unsafe(operand: fold(operand), location: loc)
 case .addressOf(let operand, let loc):
 // Phase 2a（ADR-015 FFI）：取地址——递归折叠操作数（折叠只做常量归约，地址不变）。
 return .addressOf(operand: fold(operand), location: loc)
 case .stringInterpolation(let segs, let loc):
 let fsegs = segs.map { (seg) -> InterpolationSegment in
 switch seg {
 case .literal(let s): return .literal(s)
 case .expression(let e): return .expression(fold(e))
 }
 }
 return .stringInterpolation(segments: fsegs, location: loc)
 default:
 return expr
 }
 }

 // MARK: - 字面量折叠

 private static func foldBinary(_ l: Expression, _ op: BinaryOperator, _ r: Expression, _ loc: SourceLocation) -> Expression {
 switch (l, r) {
 case (.integerLiteral(let a, _), .integerLiteral(let b, _)):
 return foldInt(a, op, b, loc)
 case (.floatLiteral(let a, _), .floatLiteral(let b, _)):
 return foldFloat(a, op, b, loc)
 case (.stringLiteral(let a, _), .stringLiteral(let b, _)):
 if op == .plus { return .stringLiteral(value: a + b, location: loc) }
 return .binary(left: l, op: op, right: r, location: loc)
 case (.boolLiteral(let a, _), .boolLiteral(let b, _)):
 return foldBool(a, op, b, loc)
 default:
 return .binary(left: l, op: op, right: r, location: loc)
 }
 }

 private static func foldInt(_ a: Int, _ op: BinaryOperator, _ b: Int, _ loc: SourceLocation) -> Expression {
 switch op {
 case .plus: return .integerLiteral(value: a + b, location: loc)
 case .minus: return .integerLiteral(value: a - b, location: loc)
 case .multiply: return .integerLiteral(value: a * b, location: loc)
 case .divide:
 guard b != 0 else { return .binary(left: .integerLiteral(value: a, location: loc), op: op, right: .integerLiteral(value: b, location: loc), location: loc) }
 return .integerLiteral(value: a / b, location: loc)
 case .modulo:
 guard b != 0 else { return .binary(left: .integerLiteral(value: a, location: loc), op: op, right: .integerLiteral(value: b, location: loc), location: loc) }
 return .integerLiteral(value: a % b, location: loc)
 case .equal: return .boolLiteral(value: a == b, location: loc)
 case .notEqual: return .boolLiteral(value: a != b, location: loc)
 case .lessThan: return .boolLiteral(value: a < b, location: loc)
 case .greaterThan: return .boolLiteral(value: a > b, location: loc)
 case .lessThanOrEqual: return .boolLiteral(value: a <= b, location: loc)
 case .greaterThanOrEqual: return .boolLiteral(value: a >= b, location: loc)
 case .bitwiseAnd: return .integerLiteral(value: a & b, location: loc)
 case .bitwiseOr: return .integerLiteral(value: a | b, location: loc)
 case .bitwiseXor: return .integerLiteral(value: a ^ b, location: loc)
 case .leftShift: return .integerLiteral(value: a << b, location: loc)
 case .rightShift: return .integerLiteral(value: a >> b, location: loc)
 default:
 // logicalAnd / logicalOr / power / assign 族：保留原节点（短路/副作用/溢出风险）
 return .binary(left: .integerLiteral(value: a, location: loc), op: op, right: .integerLiteral(value: b, location: loc), location: loc)
 }
 }

 private static func foldFloat(_ a: Double, _ op: BinaryOperator, _ b: Double, _ loc: SourceLocation) -> Expression {
 switch op {
 case .plus: return .floatLiteral(value: a + b, location: loc)
 case .minus: return .floatLiteral(value: a - b, location: loc)
 case .multiply: return .floatLiteral(value: a * b, location: loc)
 case .divide:
 guard b != 0 else { return .binary(left: .floatLiteral(value: a, location: loc), op: op, right: .floatLiteral(value: b, location: loc), location: loc) }
 return .floatLiteral(value: a / b, location: loc)
 case .equal: return .boolLiteral(value: a == b, location: loc)
 case .notEqual: return .boolLiteral(value: a != b, location: loc)
 case .lessThan: return .boolLiteral(value: a < b, location: loc)
 case .greaterThan: return .boolLiteral(value: a > b, location: loc)
 case .lessThanOrEqual: return .boolLiteral(value: a <= b, location: loc)
 case .greaterThanOrEqual: return .boolLiteral(value: a >= b, location: loc)
 default:
 return .binary(left: .floatLiteral(value: a, location: loc), op: op, right: .floatLiteral(value: b, location: loc), location: loc)
 }
 }

 private static func foldBool(_ a: Bool, _ op: BinaryOperator, _ b: Bool, _ loc: SourceLocation) -> Expression {
 switch op {
 case .equal: return .boolLiteral(value: a == b, location: loc)
 case .notEqual: return .boolLiteral(value: a != b, location: loc)
 // logicalAnd / logicalOr：保留原节点（短路/副作用）
 default:
 return .binary(left: .boolLiteral(value: a, location: loc), op: op, right: .boolLiteral(value: b, location: loc), location: loc)
 }
 }

 private static func foldUnary(_ op: UnaryOperator, _ operand: Expression, _ loc: SourceLocation) -> Expression {
 switch (op, operand) {
 case (.minus, .integerLiteral(let v, _)): return .integerLiteral(value: -v, location: loc)
 case (.minus, .floatLiteral(let v, _)): return .floatLiteral(value: -v, location: loc)
 case (.plus, .integerLiteral(let v, _)): return .integerLiteral(value: v, location: loc)
 case (.plus, .floatLiteral(let v, _)): return .floatLiteral(value: v, location: loc)
 case (.logicalNot, .boolLiteral(let v, _)), (.not, .boolLiteral(let v, _)): return .boolLiteral(value: !v, location: loc)
 case (.bitwiseNot, .integerLiteral(let v, _)): return .integerLiteral(value: ~v, location: loc)
 default:
 return .unary(op: op, operand: operand, location: loc)
 }
 }
}
