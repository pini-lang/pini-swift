import Foundation

/// 语句 AST 节点
public indirect enum Statement: Equatable {
 case varDecl(name: String, typeAnnotation: TypeAnnotation?, initializer: Expression?, isMutable: Bool, location: SourceLocation)
 /// 元组解构 `var (t, e) = rhs`（草稿 A1，批次 1）：左值模式元组逐分量绑定右值元组；
 /// `_` 为占位（不定义变量）。names 与右值元组分量一一对应。
 case varDestructure(names: [String], typeAnnotation: TypeAnnotation?, initializer: Expression?, isMutable: Bool, location: SourceLocation)
 case assign(target: AssignTarget, value: Expression, location: SourceLocation)
 case returnStatement(value: Expression?, location: SourceLocation)
 case breakStatement(label: String?, location: SourceLocation)
 case continueStatement(label: String?, location: SourceLocation)
 case ifStatement(condition: Expression, thenBlock: Block, elifs: [ElifBranch], elseBlock: Block?, label: String?, location: SourceLocation)
 case whileStatement(condition: Expression, body: Block, step: Block?, label: String?, location: SourceLocation)
 case forStatement(pattern: [String], iterable: Expression, body: Block, step: Block?, label: String?, location: SourceLocation)
 /// match 子块结构（D3①/G28 更新，2026-08-23）：case 缩进进 match 子块，通配 `case _:`。
 /// defaultCase/wildcardBlock 已随 default:/pass 通配子块移除（R2=删除）。
 case matchStatement(value: Expression, cases: [MatchCase], location: SourceLocation)
 case scopedBlock(label: String?, body: Block, location: SourceLocation)
 case tryStatement(expression: Expression, tryBlock: Block, exceptClauses: [ExceptClause], location: SourceLocation)
 /// detach 语句（任务 #13， detach-expr-stmt）：`detach <expr>` 把子任务
 /// 从父 scope 剪枝、主动退出所有权（fire-and-forget 唯一合法出口）。expr 求值为 Future。
 case detachStatement(expression: Expression, location: SourceLocation)
 case expressionStmt(expr: Expression, location: SourceLocation)
 case deferStatement(statement: Statement, location: SourceLocation)
 case passStatement(location: SourceLocation)
}
